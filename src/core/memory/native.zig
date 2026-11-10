const std = @import("std");
const memory = @import("memory.zig");
const codec = @import("codec.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const sort = @import("../shared/sort_utils.zig").sort;

const max_document_bytes = 8 * 1024 * 1024;

/// Native profile backend. Borrows home; honors profile_paths' initialized
/// FX_HOME override. No handles or allocations survive an operation.
pub const Native = struct {
    home: []const u8,

    pub fn init(home: []const u8) Native {
        return .{ .home = home };
    }

    pub fn provider(self: *Native) memory.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Caller owns the absolute path; this does not create/open the store.
    pub fn rootPath(self: Native, alloc: std.mem.Allocator) ![]u8 {
        return profile_paths.rootPath(alloc, self.home, &.{"memory"});
    }

    fn open(self: Native, create: bool) !?io_mod.VerifiedDir {
        var parent = io_mod.openDirAbsoluteNoFollow(profile_paths.rootParent(self.home), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => if (create) return err else return null,
            else => return err,
        };
        defer parent.close(io_mod.getIo());
        if (create) {
            var profile = try io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, profile_paths.rootName());
            defer profile.close();
            return try io_mod.openOrCreateVerifiedPrivateDir(&profile, "memory");
        }
        var parent_verified: io_mod.VerifiedDir = .{ .dir = parent };
        var profile = (try io_mod.openRealDirIfPresent(&parent_verified, profile_paths.rootName())) orelse return null;
        defer profile.close();
        return try io_mod.openRealDirIfPresent(&profile, "memory");
    }

    const vtable: memory.Provider.VTable = .{
        .write = write,
        .list = list,
        .read = read,
        .query = query,
    };

    fn from(ptr: *anyopaque) *Native {
        return @ptrCast(@alignCast(ptr));
    }

    fn write(ptr: *anyopaque, alloc: std.mem.Allocator, content: []const u8, filename: []const u8, frontmatter: ?memory.Metadata) ![]u8 {
        const name = try memory.normalizeFilename(alloc, filename);
        errdefer alloc.free(name);
        const bytes = try codec.encode(alloc, content, frontmatter);
        defer alloc.free(bytes);
        if (bytes.len > max_document_bytes) return error.MemoryDocumentTooLarge;
        var dir = (try from(ptr).open(true)).?;
        defer dir.close();
        try io_mod.durableReplaceVerified(alloc, &dir, name, bytes);
        return name;
    }

    fn list(ptr: *anyopaque, alloc: std.mem.Allocator) ![][]const u8 {
        var dir = (try from(ptr).open(false)) orelse return alloc.alloc([]const u8, 0);
        defer dir.close();
        return listIn(alloc, dir.dir);
    }

    fn listIn(alloc: std.mem.Allocator, dir: std.Io.Dir) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        var iter = dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const name = memory.normalizeFilename(alloc, entry.name) catch |err| switch (err) {
                error.InvalidMemoryFilename => continue,
                else => return err,
            };
            errdefer alloc.free(name);
            const stat = try dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false });
            if (stat.kind != .file or stat.nlink != 1) return error.UnsafeMemoryFile;
            try names.append(alloc, name);
        }
        sort([]const u8, names.items, {}, lessThan);
        return names.toOwnedSlice(alloc);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn read(ptr: *anyopaque, alloc: std.mem.Allocator, filename: []const u8) !memory.Document {
        const name = try memory.normalizeFilename(alloc, filename);
        defer alloc.free(name);
        var dir = (try from(ptr).open(false)) orelse return error.FileNotFound;
        defer dir.close();
        return readIn(alloc, dir.dir, name, .best_effort);
    }

    const DecodeMode = enum { best_effort, strict };

    fn readIn(alloc: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, mode: DecodeMode) !memory.Document {
        var file = io_mod.openExistingReadOnlyRegularFile(dir, name, .no_follow) catch |err| switch (err) {
            error.DurablePathUnsafe, error.SymLinkLoop => return error.UnsafeMemoryFile,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file or stat.nlink != 1) return error.UnsafeMemoryFile;
        if (stat.size > max_document_bytes) return error.MemoryDocumentTooLarge;
        const bytes = try io_mod.readFileToEnd(alloc, &file, max_document_bytes);
        defer alloc.free(bytes);
        var decoded = codec.decode(alloc, bytes) catch |err| switch (err) {
            error.InvalidFrontmatter => if (mode == .strict) return err else codec.Decoded{
                .arena = .init(alloc),
                .content = "",
                .frontmatter = null,
            },
            else => return err,
        };
        errdefer decoded.deinit();
        const owned_name = try decoded.arena.allocator().dupe(u8, name);
        const raw_content = try decoded.arena.allocator().dupe(u8, bytes);
        return .{ .arena = decoded.arena, .filename = owned_name, .content = raw_content, .frontmatter = decoded.frontmatter };
    }

    fn query(ptr: *anyopaque, alloc: std.mem.Allocator, predicates: memory.Metadata) ![][]const u8 {
        try codec.validateQuery(predicates);
        var dir = (try from(ptr).open(false)) orelse return alloc.alloc([]const u8, 0);
        defer dir.close();
        const names = try listIn(alloc, dir.dir);
        defer memory.freeNames(alloc, names);
        var found: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (found.items) |name| alloc.free(name);
            found.deinit(alloc);
        }
        for (names) |name| {
            var document = try readIn(alloc, dir.dir, name, .strict);
            defer document.deinit();
            if (codec.matches(document.frontmatter, predicates)) {
                const copy = try alloc.dupe(u8, name);
                errdefer alloc.free(copy);
                try found.append(alloc, copy);
            }
        }
        return found.toOwnedSlice(alloc);
    }
};

fn testHome(alloc: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn checkReadAllocations(alloc: std.mem.Allocator, provider: memory.Provider) !void {
    var document = try provider.read(alloc, "sample");
    defer document.deinit();
    try std.testing.expect(std.mem.endsWith(u8, document.content, "body"));
}

fn checkListAllocations(alloc: std.mem.Allocator, provider: memory.Provider) !void {
    const names = try provider.list(alloc);
    defer memory.freeNames(alloc, names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
}

fn checkQueryAllocations(alloc: std.mem.Allocator, provider: memory.Provider) !void {
    const names = try provider.query(alloc, .empty);
    defer memory.freeNames(alloc, names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
}

test "memory native read list query release partial allocation failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try testHome(alloc, tmp);
    defer alloc.free(home);
    var native = Native.init(home);
    const provider = native.provider();
    var metadata: memory.Metadata = .empty;
    defer metadata.deinit(alloc);
    try metadata.put(alloc, "quoted", .{ .string = "some text with \"quotes\"" });
    const name = try provider.write(alloc, "body", "sample", metadata);
    defer alloc.free(name);
    const no_resize = @import("../shared/testing_allocator.zig").no_resize;
    try std.testing.checkAllAllocationFailures(no_resize, checkReadAllocations, .{provider});
    try std.testing.checkAllAllocationFailures(no_resize, checkListAllocations, .{provider});
    try std.testing.checkAllAllocationFailures(no_resize, checkQueryAllocations, .{provider});
}

test "memory native reads malformed frontmatter raw while query remains strict" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try testHome(alloc, tmp);
    defer alloc.free(home);
    var native = Native.init(home);
    const provider = native.provider();
    var dir = (try native.open(true)).?;
    defer dir.close();
    const malformed = "---\nnested: {unsupported: true}\n---\nbody";
    try io_mod.durableReplaceVerified(alloc, &dir, "sample.md", malformed);
    var document = try provider.read(alloc, "sample");
    defer document.deinit();
    try std.testing.expectEqualStrings(malformed, document.content);
    try std.testing.expect(document.frontmatter == null);
    try std.testing.expectError(error.InvalidFrontmatter, provider.query(alloc, .empty));
    const no_resize = @import("../shared/testing_allocator.zig").no_resize;
    try std.testing.checkAllAllocationFailures(no_resize, checkReadAllocations, .{provider});
}

test "memory native provider writes lists reads and queries a real profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try testHome(alloc, tmp);
    defer alloc.free(home);
    var native = Native.init(home);
    const provider = native.provider();
    const empty = try provider.list(alloc);
    defer memory.freeNames(alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.FileNotFound, provider.read(alloc, "missing"));
    var metadata: memory.Metadata = .empty;
    defer metadata.deinit(alloc);
    try metadata.put(alloc, "kind", .{ .string = "note" });
    try metadata.put(alloc, "enabled", .{ .bool = true });
    const name = try provider.write(alloc, "body\n", "zeta", metadata);
    defer alloc.free(name);
    try std.testing.expectEqualStrings("zeta.md", name);
    const alpha = try provider.write(alloc, "plain", "alpha.md", null);
    defer alloc.free(alpha);
    var document = try provider.read(alloc, "zeta.md");
    defer document.deinit();
    try std.testing.expect(std.mem.endsWith(u8, document.content, "---\nbody\n"));
    try std.testing.expectEqualStrings("note", document.frontmatter.?.get("kind").?.string);
    const names = try provider.list(alloc);
    defer memory.freeNames(alloc, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("alpha.md", names[0]);
    var predicates: memory.Metadata = .empty;
    defer predicates.deinit(alloc);
    try predicates.put(alloc, "enabled", .null);
    const matches = try provider.query(alloc, predicates);
    defer memory.freeNames(alloc, matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("zeta.md", matches[0]);
    const replacement = try provider.write(alloc, "replacement", "zeta", null);
    defer alloc.free(replacement);
    var replaced = try provider.read(alloc, "zeta");
    defer replaced.deinit();
    try std.testing.expectEqualStrings("replacement", replaced.content);
    try std.testing.expect(replaced.frontmatter == null);
}

test "memory native rejects symlink files and symlink memory directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try testHome(alloc, tmp);
    defer alloc.free(home);
    var native = Native.init(home);
    const provider = native.provider();
    const name = try provider.write(alloc, "original", "safe", null);
    defer alloc.free(name);
    try tmp.dir.symLink(io_mod.getIo(), "safe.md", ".fx/memory/linked.md", .{});
    try std.testing.expectError(error.UnsafeMemoryFile, provider.read(alloc, "linked"));
    try std.testing.expectError(error.DurablePathUnsafe, provider.write(alloc, "no", "linked", null));
    try std.testing.expectError(error.UnsafeMemoryFile, provider.list(alloc));
    var document = try provider.read(alloc, "safe");
    defer document.deinit();
    try std.testing.expectEqualStrings("original", document.content);
    try tmp.dir.deleteFile(io_mod.getIo(), ".fx/memory/linked.md");
    try tmp.dir.rename(".fx/memory", tmp.dir, "saved", io_mod.getIo());
    try tmp.dir.symLink(io_mod.getIo(), "saved", ".fx/memory", .{});
    try std.testing.expectError(error.DurablePathUnsafe, provider.list(alloc));
    try std.testing.expectError(error.DurablePathUnsafe, provider.write(alloc, "no", "other", null));
}

test "memory native validates before creating profile and preserves failed replacements" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try testHome(alloc, tmp);
    defer alloc.free(home);
    var native = Native.init(home);
    const provider = native.provider();
    try std.testing.expectError(error.InvalidMemoryFilename, provider.write(alloc, "text", "../escape", null));
    try std.testing.expectError(error.AlreadyHasFrontmatter, provider.write(alloc, "---\nx: true\n---\n", "safe", null));
    var invalid: memory.Metadata = .empty;
    defer invalid.deinit(alloc);
    try invalid.put(alloc, "nested", .{ .object = .empty });
    try std.testing.expectError(error.InvalidFrontmatter, provider.write(alloc, "text", "safe", invalid));
    try std.testing.expectError(error.InvalidMemoryQuery, provider.query(alloc, invalid));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), ".fx", .{ .follow_symlinks = false }));
    const name = try provider.write(alloc, "original", "safe", null);
    defer alloc.free(name);
    try std.testing.expectError(error.InvalidFrontmatter, provider.write(alloc, "replacement", "safe", invalid));
    var document = try provider.read(alloc, "safe");
    defer document.deinit();
    try std.testing.expectEqualStrings("original", document.content);
}

test "memory native rejects a symlink profile before reading or writing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io_mod.getIo(), "outside", .default_dir);
    try tmp.dir.symLink(io_mod.getIo(), "outside", ".fx", .{});
    const home = try testHome(alloc, tmp);
    defer alloc.free(home);
    var native = Native.init(home);
    const provider = native.provider();
    try std.testing.expectError(error.DurablePathUnsafe, provider.list(alloc));
    try std.testing.expectError(error.DurablePathUnsafe, provider.read(alloc, "safe"));
    try std.testing.expectError(error.DurablePathUnsafe, provider.write(alloc, "text", "safe", null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), "outside/memory", .{}));
}
