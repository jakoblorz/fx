const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const contract = @import("contract.zig");

const Allocator = std.mem.Allocator;
const Result = contract.Result;
const State = contract.State;
const CancelFlag = ?*const std.atomic.Value(bool);
const endpoint = "unix:///var/run/docker.sock";
const container_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const smoke_command = "test \"$(id -u)\" != 0 && test \"$PWD\" = /workspace && test -d /workspace && test -w /workspace && test -w /tmp && test -w /home/fx";

/// Runner output belongs to the allocator supplied to run. The native runner
/// only launches Docker, never a host shell. Injectable for deterministic tests.
pub const Runner = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, Allocator, []const []const u8, []const u8, CancelFlag) anyerror!Result = runDocker,
};

pub const Runtime = struct {
    alloc: Allocator,
    /// Borrowed for the runtime's lifetime; canonicalized again before setup.
    workspace_root: []const u8,
    mutex: std.Io.Mutex = .init,
    lifecycle: State = .unconfigured,
    runner: Runner = .{},
    config_dir: ?[]u8 = null,
    container_name: ?[]u8 = null,
    image_name: ?[]u8 = null,
    container_id: ?[]u8 = null,
    image_id: ?[]u8 = null,
    user: ?[]u8 = null,
    cancel_flag: CancelFlag = null,
    record_path: ?[]u8 = null,
    record_workspace: ?[]u8 = null,
    container_may_exist: bool = false,
    image_may_exist: bool = false,

    pub fn init(alloc: Allocator, workspace_root: []const u8) Runtime {
        return .{ .alloc = alloc, .workspace_root = workspace_root };
    }

    pub fn state(self: *Runtime) State {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.lifecycle;
    }

    pub fn deinit(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        _ = self.cleanup();
        self.freeIdentity();
        self.container_may_exist = false;
        self.image_may_exist = false;
        if (self.config_dir) |value| self.alloc.free(value);
        if (self.user) |value| self.alloc.free(value);
        self.freeRecord();
        self.config_dir = null;
        self.user = null;
        self.lifecycle = .unconfigured;
    }

    pub fn execute(self: *Runtime, alloc: Allocator, tool_name: []const u8, args_json: []const u8) !Result {
        return self.executeWithCancel(alloc, tool_name, args_json, null);
    }

    pub fn executeWithCancel(self: *Runtime, alloc: Allocator, tool_name: []const u8, args_json: []const u8, cancel_flag: CancelFlag) !Result {
        try checkCancel(cancel_flag);
        while (!self.mutex.tryLock()) {
            try checkCancel(cancel_flag);
            try io_mod.getIo().sleep(.fromMilliseconds(10), .awake);
        }
        defer self.mutex.unlock(io_mod.getIo());
        try checkCancel(cancel_flag);
        self.cancel_flag = cancel_flag;
        defer self.cancel_flag = null;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{ .allocate = .alloc_always }) catch |err| return failure(alloc, err);
        defer parsed.deinit();
        const req = contract.request(tool_name, parsed.value) catch |err| return failure(alloc, err);
        switch (req) {
            .container_setup => |dockerfile| {
                if (self.lifecycle == .running) return failure(alloc, error.AlreadyConfigured);
                self.lifecycle = .building;
                const result = self.setup(alloc, dockerfile) catch |err| {
                    self.lifecycle = .failed;
                    _ = self.cleanup();
                    return failure(alloc, err);
                };
                if (!result.success) {
                    self.lifecycle = .failed;
                    _ = self.cleanup();
                } else self.lifecycle = .running;
                return result;
            },
            .shell => |command| {
                if (self.lifecycle != .running) return failure(alloc, error.ContainerNotRunning);
                return self.exec(alloc, command) catch |err| {
                    self.lifecycle = .failed;
                    _ = self.cleanup();
                    return failure(alloc, err);
                };
            },
        }
    }

    fn setup(self: *Runtime, alloc: Allocator, dockerfile: []const u8) !Result {
        if (!self.cleanup()) return error.CleanupRequired;
        self.freeRecord();
        if (self.config_dir) |value| self.alloc.free(value);
        self.config_dir = null;
        if (self.user) |value| self.alloc.free(value);
        self.user = null;
        const home = io_mod.getenv("HOME") orelse profile_paths.fxHomeParent() orelse return error.HomeUnavailable;
        const canonical_home = try io_mod.realpathAlloc(alloc, home);
        defer alloc.free(canonical_home);
        const profile = try profile_paths.rootDir(alloc, home);
        defer alloc.free(profile);
        // The profile is initialized by the host. Following any symlink here
        // could put build inputs in the repository or expose host credentials.
        var profile_dir = try io_mod.openDirAbsoluteNoFollow(profile, .{});
        defer profile_dir.close(io_mod.getIo());
        const canonical_profile = try io_mod.realpathAlloc(alloc, profile);
        defer alloc.free(canonical_profile);
        const workspace = try io_mod.realpathAlloc(alloc, self.workspace_root);
        defer alloc.free(workspace);
        try contract.validateWorkspace(workspace, canonical_home, canonical_profile);
        try validateGit(workspace);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(workspace, &digest, .{});
        const workspace_hash = std.fmt.bytesToHex(digest, .lower);
        var random: [16]u8 = undefined;
        io_mod.getIo().random(&random);
        const token = std.fmt.bytesToHex(random, .lower);
        var containers = try createPrivateDir(profile_dir, "containers");
        defer containers.close(io_mod.getIo());
        var workspace_dir = try createPrivateDir(containers, &workspace_hash);
        defer workspace_dir.close(io_mod.getIo());
        // A fresh context, not a reused folder that may contain stale inputs.
        try workspace_dir.createDir(io_mod.getIo(), &token, .fromMode(0o700));
        var run_dir = try workspace_dir.openDir(io_mod.getIo(), &token, .{ .follow_symlinks = false });
        defer run_dir.close(io_mod.getIo());
        var context = try createPrivateDir(run_dir, "context");
        defer context.close(io_mod.getIo());
        try context.writeFile(io_mod.getIo(), .{ .sub_path = "Dockerfile", .data = dockerfile, .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) } });
        var config = try createPrivateDir(run_dir, "docker-config");
        config.close(io_mod.getIo());
        self.config_dir = try profile_paths.rootPath(self.alloc, home, &.{ "containers", &workspace_hash, &token, "docker-config" });
        const context_path = try profile_paths.rootPath(alloc, home, &.{ "containers", &workspace_hash, &token, "context" });
        defer alloc.free(context_path);
        self.container_name = try self.alloc.print("fx-sandbox-{s}", .{token});
        self.image_name = try self.alloc.print("fx-sandbox:{s}", .{token});
        self.record_path = try profile_paths.rootPath(self.alloc, home, &.{ "containers", &workspace_hash, &token, "recovery.json" });
        self.record_workspace = try self.alloc.dupe(u8, workspace);
        try self.writeRecord("building");
        // A root host still executes as an unprivileged numeric container user.
        const uid = std.c.getuid();
        const gid = std.c.getgid();
        self.user = try self.alloc.print("{d}:{d}", .{ if (uid == 0) @as(u32, 65534) else uid, if (gid == 0) @as(u32, 65534) else gid });
        return self.launch(alloc, context_path, workspace);
    }

    fn launch(self: *Runtime, alloc: Allocator, context_path: []const u8, workspace: []const u8) !Result {
        const dockerfile_path = try std.Io.Dir.path.join(alloc, &.{ context_path, "Dockerfile" });
        defer alloc.free(dockerfile_path);
        self.image_may_exist = true;
        const built = try self.docker(alloc, &.{ "build", "--label", "dev.fx.container-tools=true", "--tag", self.image_name.?, "--file", dockerfile_path, "--", context_path });
        if (!built.success) return built;
        built.deinit(alloc);
        const inspected = try self.docker(alloc, &.{ "image", "inspect", self.image_name.? });
        defer inspected.deinit(alloc);
        if (!inspected.success) return .{ .text = try alloc.dupe(u8, inspected.text), .success = false };
        const metadata = try std.json.parseFromSlice(std.json.Value, alloc, inspected.text, .{});
        defer metadata.deinit();
        const image_id = try safeImage(metadata.value);
        self.image_id = try self.alloc.dupe(u8, image_id);
        try self.writeRecord("image_built");
        const mount = try workspaceMount(alloc, workspace);
        defer alloc.free(mount);
        const args = try createArgs(alloc, self.container_name.?, self.user.?, mount, image_id);
        defer alloc.free(args);
        self.container_may_exist = true;
        const created = try self.docker(alloc, args);
        if (!created.success) return created;
        defer created.deinit(alloc);
        const first_line = created.text[0 .. std.mem.findScalar(u8, created.text, '\n') orelse created.text.len];
        try validateContainerId(first_line);
        self.container_id = try self.alloc.dupe(u8, first_line);
        try self.writeRecord("created");
        const started = try self.docker(alloc, &.{ "start", self.container_id.? });
        if (!started.success) return started;
        started.deinit(alloc);
        const smoke = try self.exec(alloc, smoke_command);
        if (!smoke.success) {
            defer smoke.deinit(alloc);
            return .{ .text = try alloc.print("Container smoke test failed. The image must provide /bin/sh and id, and numeric user {s} must be able to write /workspace, /tmp, and /home/fx. {s}", .{ self.user.?, smoke.text }), .success = false };
        }
        smoke.deinit(alloc);
        try self.writeRecord("running");
        return .{ .text = try alloc.dupe(u8, "Container configured and running. Shell commands run only in /workspace inside the container."), .success = true };
    }

    fn exec(self: *Runtime, alloc: Allocator, command: []const u8) !Result {
        return self.docker(alloc, &.{ "exec", "--user", self.user.?, "--workdir", "/workspace", "--", self.container_id orelse self.container_name.?, "/bin/sh", "-c", command });
    }

    fn docker(self: *Runtime, alloc: Allocator, args: []const []const u8) !Result {
        try checkCancel(self.cancel_flag);
        const argv = try alloc.alloc([]const u8, args.len + 5);
        defer alloc.free(argv);
        @memcpy(argv[0..5], &[_][]const u8{ "docker", "--host", endpoint, "--config", self.config_dir.? });
        @memcpy(argv[5..], args);
        return self.runner.run(self.runner.context, alloc, argv, self.config_dir.?, self.cancel_flag);
    }

    fn cleanup(self: *Runtime) bool {
        // Cleanup must still work after the operation's cancellation token fires.
        const cancel = self.cancel_flag;
        self.cancel_flag = null;
        defer self.cancel_flag = cancel;
        if (self.container_may_exist) {
            const removed = self.remove(&.{ "rm", "--force", "--volumes", self.container_id orelse self.container_name.? }, "No such container:");
            if (!removed) return self.cleanupFailed();
            self.container_may_exist = false;
        }
        // Never remove the image while a container may still refer to it.
        if (self.image_may_exist) {
            const removed = self.removeImage();
            if (!removed) return self.cleanupFailed();
            self.image_may_exist = false;
        }
        if (self.record_path != null) self.writeRecord("cleaned") catch |err| {
            std.log.warn("container cleanup succeeded but recovery record update failed: {s}: {s}", .{ self.record_path.?, @errorName(err) });
        };
        self.freeIdentity();
        return true;
    }

    fn remove(self: *Runtime, args: []const []const u8, absent: []const u8) bool {
        const result = self.docker(self.alloc, args) catch return false;
        defer result.deinit(self.alloc);
        return result.success or std.mem.find(u8, result.text, absent) != null;
    }

    fn removeImage(self: *Runtime) bool {
        // Sessions may build identical content with different owned tags. Never
        // remove a shared image by ID, nor a tag reassigned since this build.
        if (self.image_id) |expected| {
            const inspected = self.docker(self.alloc, &.{ "image", "inspect", "--format", "{{.Id}}", self.image_name.? }) catch return false;
            defer inspected.deinit(self.alloc);
            if (!inspected.success) return std.mem.find(u8, inspected.text, "No such image:") != null;
            if (!std.mem.eql(u8, std.mem.trim(u8, inspected.text, " \t\r\n"), expected)) return false;
        }
        return self.remove(&.{ "image", "rm", self.image_name.? }, "No such image:");
    }

    fn cleanupFailed(self: *Runtime) bool {
        if (self.record_path != null) self.writeRecord("cleanup_failed") catch {};
        std.log.warn("container cleanup failed; recovery record: {s}; container: {s}; image: {s}", .{
            self.record_path orelse "unavailable", self.container_name orelse "none", self.image_name orelse "none",
        });
        return false;
    }

    fn freeIdentity(self: *Runtime) void {
        if (self.container_name) |name| self.alloc.free(name);
        if (self.image_name) |name| self.alloc.free(name);
        self.container_name = null;
        self.image_name = null;
        if (self.container_id) |id| self.alloc.free(id);
        if (self.image_id) |id| self.alloc.free(id);
        self.container_id = null;
        self.image_id = null;
    }

    fn freeRecord(self: *Runtime) void {
        if (self.record_path) |path| self.alloc.free(path);
        if (self.record_workspace) |workspace| self.alloc.free(workspace);
        self.record_path = null;
        self.record_workspace = null;
    }

    fn writeRecord(self: *Runtime, status: []const u8) !void {
        const path = self.record_path orelse return;
        var json: std.Io.Writer.Allocating = .init(self.alloc);
        defer json.deinit();
        try std.json.Stringify.value(.{
            .container_name = self.container_name,
            .image_name = self.image_name,
            .container_id = self.container_id,
            .image_id = self.image_id,
            .workspace_root = self.record_workspace,
            .endpoint = endpoint,
            .status = status,
        }, .{}, &json.writer);
        var parent = try io_mod.openDirAbsoluteNoFollow(std.Io.Dir.path.dirname(path).?, .{});
        defer parent.close(io_mod.getIo());
        var file = try parent.createFileAtomic(io_mod.getIo(), std.Io.Dir.path.basename(path), .{ .replace = true, .permissions = .fromMode(0o600) });
        defer file.deinit(io_mod.getIo());
        try file.file.writeStreamingAll(io_mod.getIo(), json.written());
        try file.file.sync(io_mod.getIo());
        try file.replace(io_mod.getIo());
    }
};

fn failure(alloc: Allocator, err: anyerror) !Result {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .text = try alloc.print("Container runtime failed: {s}. No command was run on the host.", .{@errorName(err)}), .success = false };
}

fn createPrivateDir(parent: std.Io.Dir, name: []const u8) !std.Io.Dir {
    parent.createDir(io_mod.getIo(), name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return parent.openDir(io_mod.getIo(), name, .{ .follow_symlinks = false });
}

fn validateGit(workspace: []const u8) !void {
    var dir = try io_mod.openDirAbsoluteNoFollow(workspace, .{});
    defer dir.close(io_mod.getIo());
    // Linked worktrees refer to host paths outside the one allowed bind.
    var git_dir = dir.openDir(io_mod.getIo(), ".git", .{ .follow_symlinks = false }) catch return error.LinkedOrMissingGitDirectory;
    git_dir.close(io_mod.getIo());
}

/// Reject image-defined writable mounts and deferred build triggers. Image
/// environment stays inside the container. Entry point, user and health checks are
/// overridden by createArgs. The returned immutable ID borrows from metadata.
fn safeImage(metadata: std.json.Value) ![]const u8 {
    if (metadata != .array or metadata.array.items.len != 1) return error.UnsafeImageMetadata;
    const image = metadata.array.items[0];
    if (image != .object) return error.UnsafeImageMetadata;
    const id = image.object.get("Id") orelse return error.UnsafeImageMetadata;
    if (id != .string or !std.mem.startsWith(u8, id.string, "sha256:") or id.string.len != 71) return error.UnsafeImageMetadata;
    for (id.string[7..]) |c| if (!std.ascii.isHex(c)) return error.UnsafeImageMetadata;
    const config = image.object.get("Config") orelse return error.UnsafeImageMetadata;
    if (config != .object) return error.UnsafeImageMetadata;
    const volumes = config.object.get("Volumes") orelse .null;
    if (volumes != .null and (volumes != .object or volumes.object.count() != 0)) return error.ImageVolumesUnsupported;
    const on_build = config.object.get("OnBuild") orelse .null;
    if (on_build != .null and (on_build != .array or on_build.array.items.len != 0)) return error.UnsafeImageMetadata;
    const env = config.object.get("Env") orelse .null;
    if (env != .null) {
        if (env != .array) return error.UnsafeImageMetadata;
        for (env.array.items) |entry| {
            if (entry != .string) return error.UnsafeImageMetadata;
            if (std.mem.findScalar(u8, entry.string, '=') == null or std.mem.findScalar(u8, entry.string, 0) != null) return error.UnsafeImageMetadata;
        }
    }
    return id.string;
}

fn workspaceMount(alloc: Allocator, workspace: []const u8) ![]u8 {
    return alloc.print("type=bind,src={s},dst=/workspace,bind-recursive=disabled", .{workspace});
}

fn validateContainerId(id: []const u8) !void {
    if (id.len != 64) return error.UnsafeContainerIdentity;
    for (id) |byte| if (!std.ascii.isHex(byte)) return error.UnsafeContainerIdentity;
}

fn createArgs(alloc: Allocator, name: []const u8, user: []const u8, mount: []const u8, image: []const u8) ![][]const u8 {
    return alloc.dupe([]const u8, &.{
        "create",                                   "--label",        "dev.fx.container-tools=true",                 "--name",      name,                           "--user",           user,
        "--workdir",                                "/workspace",     "--entrypoint",                                "/bin/sh",     "--network",                    "none",             "--cap-drop",
        "ALL",                                      "--security-opt", "no-new-privileges:true",                      "--read-only", "--pids-limit",                 "256",              "--memory",
        "2g",                                       "--cpus",         "2",                                           "--ulimit",    "nofile=1024:1024",             "--no-healthcheck", "--tmpfs",
        "/tmp:rw,nosuid,nodev,size=256m,mode=1777", "--tmpfs",        "/home/fx:rw,nosuid,nodev,size=64m,mode=1777", "--env",       "HOME=/home/fx",                "--env",            "PATH=" ++ container_path,
        "--env",                                    "LANG=C",         "--env",                                       "LC_ALL=C",    "--env",                        "TZ=UTC",           "--mount",
        mount,                                      "--",             image,                                         "-c",          "while :; do sleep 3600; done",
    });
}

fn runDocker(_: ?*anyopaque, alloc: Allocator, argv: []const []const u8, config_dir: []const u8, cancel_flag: CancelFlag) !Result {
    try checkCancel(cancel_flag);
    var task: DockerTask = .{ .alloc = alloc, .argv = argv, .config_dir = config_dir };
    const io = io_mod.getIo();
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(if (std.mem.eql(u8, argv[5], "build")) 900 else if (std.mem.eql(u8, argv[5], "exec")) 120 else 15), .clock = .awake });
    var future = try io.concurrent(DockerTask.run, .{&task});
    while (!task.done.load(.acquire)) {
        const canceled = isCanceled(cancel_flag);
        if (canceled or !std.Io.Clock.Timestamp.compare(.now(io, .awake), .lt, deadline)) {
            future.cancel(io);
            if (task.result) |result| result.deinit(alloc) else |_| {}
            return if (canceled) error.Canceled else error.Timeout;
        }
        io.sleep(.fromMilliseconds(10), .awake) catch |err| {
            future.cancel(io);
            if (task.result) |result| result.deinit(alloc) else |_| {}
            return err;
        };
    }
    future.await(io);
    return task.result;
}

const DockerTask = struct {
    alloc: Allocator,
    argv: []const []const u8,
    config_dir: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!Result = error.Canceled,

    fn run(self: *DockerTask) void {
        self.result = runDockerBlocking(self.alloc, self.argv, self.config_dir);
        self.done.store(true, .release);
    }
};

fn isCanceled(flag: CancelFlag) bool {
    return if (flag) |value| value.load(.acquire) else false;
}

fn checkCancel(flag: CancelFlag) !void {
    if (isCanceled(flag)) return error.Canceled;
}

fn runDockerBlocking(alloc: Allocator, argv: []const []const u8, config_dir: []const u8) !Result {
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin");
    try environment.put("HOME", config_dir);
    try environment.put("LANG", "C");
    // No inherited Docker contexts, credential helpers, proxies, or fx secrets.
    const process = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .environ_map = &environment,
        .cwd = .{ .path = config_dir },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer alloc.free(process.stdout);
    defer alloc.free(process.stderr);
    return .{
        .text = try std.mem.concat(alloc, u8, &.{ process.stdout, process.stderr }),
        .success = process.term == .exited and process.term.exited == 0,
    };
}

test "sandbox lifecycle never falls back before setup" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, "/not-a-workspace");
    defer runtime.deinit();
    const result = try runtime.execute(alloc, "shell", "{\"action\":\"run\",\"command\":\"touch /tmp/never-on-host\"}");
    defer result.deinit(alloc);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(State.unconfigured, runtime.state());
    const setup = try runtime.execute(alloc, "container_setup", "{\"dockerfile\":\"FROM alpine\"}");
    defer setup.deinit(alloc);
    try std.testing.expect(!setup.success);
    try std.testing.expectEqual(State.failed, runtime.state());
}

test "sandbox create arguments fix isolation and command boundaries" {
    const alloc = std.testing.allocator;
    const mount = try workspaceMount(alloc, "/repo");
    defer alloc.free(mount);
    try std.testing.expectEqualStrings("type=bind,src=/repo,dst=/workspace,bind-recursive=disabled", mount);
    const args = try createArgs(alloc, "fx-test", "1000:1000", mount, "sha256:test");
    defer alloc.free(args);
    const joined = try std.mem.join(alloc, " ", args);
    defer alloc.free(joined);
    for ([_][]const u8{ "--network none", "--cap-drop ALL", "--read-only", "no-new-privileges:true", "--user 1000:1000", "--entrypoint /bin/sh", "--no-healthcheck", "--workdir /workspace" }) |expected| {
        try std.testing.expect(std.mem.find(u8, joined, expected) != null);
    }
}

test "sandbox rejects image volumes and validates inherited environment" {
    const alloc = std.testing.allocator;
    const prefix = "[{\"Id\":\"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"Config\":{";
    const safe = try std.json.parseFromSlice(std.json.Value, alloc, prefix ++ "\"Volumes\":null,\"OnBuild\":null,\"Env\":[\"PATH=/bin\"]}}]", .{});
    defer safe.deinit();
    _ = try safeImage(safe.value);
    const volumes = try std.json.parseFromSlice(std.json.Value, alloc, prefix ++ "\"Volumes\":{\"/extra\":{}},\"OnBuild\":null,\"Env\":null}}]", .{});
    defer volumes.deinit();
    try std.testing.expectError(error.ImageVolumesUnsupported, safeImage(volumes.value));
    const env = try std.json.parseFromSlice(std.json.Value, alloc, prefix ++ "\"Volumes\":null,\"OnBuild\":null,\"Env\":[\"LD_PRELOAD=/evil.so\"]}}]", .{});
    defer env.deinit();
    _ = try safeImage(env.value);
}

const MockRunner = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    spawn_error: bool = false,
    expected_command: ?[]const u8 = null,
    cancel_on_exec: ?*std.atomic.Value(bool) = null,
    cleanup_without_cancel: bool = false,
    expected_container_target: ?[]const u8 = null,
    expected_image_target: ?[]const u8 = null,
    inspect_image_id: []const u8 = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    image_missing: bool = false,

    fn run(context: ?*anyopaque, alloc: Allocator, argv: []const []const u8, config: []const u8, cancel_flag: CancelFlag) !Result {
        try checkCancel(cancel_flag);
        const self: *MockRunner = @ptrCast(@alignCast(context.?));
        try std.testing.expectEqualStrings("docker", argv[0]);
        try std.testing.expectEqualStrings("--host", argv[1]);
        try std.testing.expectEqualStrings(endpoint, argv[2]);
        try std.testing.expectEqualStrings("--config", argv[3]);
        try std.testing.expectEqualStrings(config, argv[4]);
        self.calls += 1;
        if (std.mem.eql(u8, argv[5], "rm")) self.cleanup_without_cancel = cancel_flag == null;
        if (self.expected_container_target) |target| {
            if (std.mem.eql(u8, argv[5], "exec")) try std.testing.expectEqualStrings(target, argv[11]);
            if (std.mem.eql(u8, argv[5], "rm")) try std.testing.expectEqualStrings(target, argv[8]);
        }
        if (self.expected_image_target) |target| {
            if (std.mem.eql(u8, argv[5], "image") and std.mem.eql(u8, argv[6], "rm")) try std.testing.expectEqualStrings(target, argv[7]);
        }
        if (self.cancel_on_exec) |flag| {
            if (std.mem.eql(u8, argv[5], "exec")) {
                flag.store(true, .release);
                return error.Canceled;
            }
        }
        if (self.expected_command) |command| {
            if (std.mem.eql(u8, argv[5], "exec")) {
                try std.testing.expectEqual(@as(usize, 15), argv.len);
                try std.testing.expectEqualStrings("--user", argv[6]);
                try std.testing.expectEqualStrings("1000:1000", argv[7]);
                try std.testing.expectEqualStrings("--workdir", argv[8]);
                try std.testing.expectEqualStrings("/workspace", argv[9]);
                try std.testing.expectEqualStrings("--", argv[10]);
                try std.testing.expectEqualStrings("/bin/sh", argv[12]);
                try std.testing.expectEqualStrings("-c", argv[13]);
                try std.testing.expectEqualStrings(command, argv[14]);
            }
        }
        if (self.spawn_error) return error.FileNotFound;
        const formatted_inspect = std.mem.eql(u8, argv[5], "image") and std.mem.eql(u8, argv[6], "inspect") and argv.len == 10;
        if (formatted_inspect) {
            try std.testing.expectEqualStrings("--format", argv[7]);
            try std.testing.expectEqualStrings("{{.Id}}", argv[8]);
        }
        const success = self.fail_at != self.calls and !(formatted_inspect and self.image_missing);
        const text = if (formatted_inspect and self.image_missing) "Error response from daemon: No such image: fx-mock:test" else if (formatted_inspect) self.inspect_image_id else if (std.mem.eql(u8, argv[5], "image") and std.mem.eql(u8, argv[6], "inspect"))
            "[{\"Id\":\"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"Config\":{\"Volumes\":null,\"OnBuild\":null,\"Env\":null}}]"
        else if (success and std.mem.eql(u8, argv[5], "create")) "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n" else if (success) "mock-ok" else "mock-failure";
        return .{ .text = try alloc.dupe(u8, text), .success = success };
    }
};

fn mockRuntime(alloc: Allocator, mock: *MockRunner) !Runtime {
    var runtime = Runtime.init(alloc, "/repo");
    errdefer runtime.deinit();
    runtime.runner = .{ .context = mock, .run = MockRunner.run };
    runtime.config_dir = try alloc.dupe(u8, "/empty-docker-config");
    runtime.container_name = try alloc.dupe(u8, "fx-mock");
    runtime.image_name = try alloc.dupe(u8, "fx-mock:test");
    runtime.user = try alloc.dupe(u8, "1000:1000");
    runtime.container_may_exist = true;
    runtime.image_may_exist = true;
    return runtime;
}

test "sandbox launch requires every stage including smoke to succeed" {
    const alloc = std.testing.allocator;
    for (1..6) |failed_stage| {
        var mock: MockRunner = .{ .fail_at = failed_stage };
        var runtime = try mockRuntime(alloc, &mock);
        defer runtime.deinit();
        runtime.lifecycle = .building;
        const result = try runtime.launch(alloc, "/isolated/context", "/repo");
        defer result.deinit(alloc);
        try std.testing.expect(!result.success);
        try std.testing.expectEqual(failed_stage, mock.calls);
        try std.testing.expectEqual(State.building, runtime.state());
    }
    var mock: MockRunner = .{};
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    const result = try runtime.launch(alloc, "/isolated/context", "/repo");
    defer result.deinit(alloc);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 5), mock.calls);
}

test "sandbox spawn failure fails closed and running setup is immutable" {
    const alloc = std.testing.allocator;
    var mock: MockRunner = .{ .spawn_error = true };
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    runtime.lifecycle = .running;
    const setup = try runtime.execute(alloc, "container_setup", "{\"dockerfile\":\"FROM alpine\"}");
    defer setup.deinit(alloc);
    try std.testing.expect(!setup.success);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    const result = try runtime.execute(alloc, "shell", "{\"action\":\"run\",\"command\":\"echo host-must-not-run\"}");
    defer result.deinit(alloc);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(State.failed, runtime.state());
    // One exec and one failed container removal. Keep the image and both
    // identities for recovery; never fall back to a host shell.
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
    try std.testing.expect(runtime.container_name != null);
    try std.testing.expect(runtime.image_name != null);
}

test "sandbox shell passes metacharacters as one container-only command" {
    const alloc = std.testing.allocator;
    var mock: MockRunner = .{ .expected_command = "echo hi; touch '/not-on-host'; $(pwd)" };
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    runtime.lifecycle = .running;
    const result = try runtime.execute(alloc, "shell", "{\"action\":\"run\",\"command\":\"echo hi; touch '/not-on-host'; $(pwd)\"}");
    defer result.deinit(alloc);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(State.running, runtime.state());
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

test "sandbox rejects linked worktree git files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git", .data = "gitdir: /outside/worktree" });
    try std.testing.expectError(error.LinkedOrMissingGitDirectory, validateGit(path));
}

test "sandbox cancellation preflight does not call Docker or wait for mutex" {
    const alloc = std.testing.allocator;
    var mock: MockRunner = .{};
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    runtime.mutex.lockUncancelable(std.testing.io);
    const result = runtime.executeWithCancel(alloc, "shell", "{\"action\":\"run\",\"command\":\"true\"}", &cancel);
    runtime.mutex.unlock(std.testing.io);
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
}

test "sandbox cancellation kills operation then cleanup ignores canceled token" {
    const alloc = std.testing.allocator;
    var cancel: std.atomic.Value(bool) = .init(false);
    var mock: MockRunner = .{ .cancel_on_exec = &cancel };
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    runtime.lifecycle = .running;
    const result = try runtime.executeWithCancel(alloc, "shell", "{\"action\":\"run\",\"command\":\"sleep 30\"}", &cancel);
    defer result.deinit(alloc);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(State.failed, runtime.state());
    try std.testing.expect(mock.cleanup_without_cancel);
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
}

test "sandbox failed cleanup keeps durable identity until successful retry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var mock: MockRunner = .{ .fail_at = 1 };
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    runtime.record_path = try std.Io.Dir.path.join(alloc, &.{ root, "recovery.json" });
    runtime.record_workspace = try alloc.dupe(u8, "/repo");
    try runtime.writeRecord("running");
    try std.testing.expect(!runtime.cleanup());
    try std.testing.expect(runtime.container_name != null);
    try std.testing.expect(runtime.image_name != null);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    const pending = try tmp.dir.readFileAlloc(std.testing.io, "recovery.json", alloc, .limited(8192));
    defer alloc.free(pending);
    for ([_][]const u8{ "cleanup_failed", "fx-mock", "fx-mock:test", "/repo", endpoint }) |expected| {
        try std.testing.expect(std.mem.find(u8, pending, expected) != null);
    }
    mock.fail_at = null;
    try std.testing.expect(runtime.cleanup());
    try std.testing.expect(runtime.container_name == null);
    const cleaned = try tmp.dir.readFileAlloc(std.testing.io, "recovery.json", alloc, .limited(8192));
    defer alloc.free(cleaned);
    try std.testing.expect(std.mem.find(u8, cleaned, "cleaned") != null);
}

const CancelSoon = struct {
    fn run(flag: *std.atomic.Value(bool)) void {
        std.testing.io.sleep(.fromMilliseconds(50), .awake) catch return;
        flag.store(true, .release);
    }
};

test "sandbox process cancellation interrupts wait after output pipes close" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var cancel: std.atomic.Value(bool) = .init(false);
    var setter = try std.testing.io.concurrent(CancelSoon.run, .{&cancel});
    defer setter.cancel(std.testing.io);
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    // A test child deliberately closes both output streams before hanging.
    // Production Runtime only constructs Docker argv, never this host shell.
    try std.testing.expectError(error.Canceled, runDocker(null, alloc, &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec sleep 30", "unused", "unused", "exec" }, root, &cancel));
    const elapsed = start.durationTo(.now(std.testing.io, .awake));
    try std.testing.expect(elapsed.raw.toMilliseconds() < 2000);
}

test "sandbox requires a strict immutable container ID" {
    try validateContainerId("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    try std.testing.expectError(error.UnsafeContainerIdentity, validateContainerId("short"));
    try std.testing.expectError(error.UnsafeContainerIdentity, validateContainerId("x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
}

test "sandbox container operations use immutable IDs and image cleanup verifies owned tag" {
    const alloc = std.testing.allocator;
    const container = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const image = "sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var mock: MockRunner = .{ .expected_container_target = container, .expected_image_target = "fx-mock:test", .inspect_image_id = image };
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    runtime.container_id = try alloc.dupe(u8, container);
    runtime.image_id = try alloc.dupe(u8, image);
    runtime.lifecycle = .running;
    const result = try runtime.execute(alloc, "shell", "{\"action\":\"run\",\"command\":\"true\"}");
    defer result.deinit(alloc);
    try std.testing.expect(result.success);
    try std.testing.expect(runtime.cleanup());
    try std.testing.expectEqual(@as(usize, 4), mock.calls);
}

test "sandbox image cleanup refuses a reassigned tag and accepts an absent tag" {
    const alloc = std.testing.allocator;
    var mock: MockRunner = .{};
    var runtime = try mockRuntime(alloc, &mock);
    defer runtime.deinit();
    runtime.image_id = try alloc.dupe(u8, "sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    // The existing tag points somewhere else. Only the container is removed.
    try std.testing.expect(!runtime.cleanup());
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
    try std.testing.expect(runtime.image_name != null);
    mock.image_missing = true;
    try std.testing.expect(runtime.cleanup());
    // No rm by tag or ID is needed after a confirmed absent tag.
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
}
