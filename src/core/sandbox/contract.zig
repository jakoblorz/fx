const std = @import("std");

pub const State = enum { unconfigured, building, running, failed };
pub const max_text_bytes = 64 * 1024;

/// The caller owns text and releases it with deinit using execute's allocator.
pub const Result = struct {
    text: []u8,
    success: bool,

    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }
};

pub const Request = union(enum) {
    container_setup: []const u8,
    shell: []const u8,
};

pub fn allowsTool(name: []const u8) bool {
    return std.meta.stringToEnum(std.meta.Tag(Request), name) != null;
}

/// Returned strings borrow from value. No extra fields are accepted in this slice.
pub fn request(tool_name: []const u8, value: std.json.Value) !Request {
    if (value != .object) return error.InvalidArguments;
    const object = value.object;
    if (std.mem.eql(u8, tool_name, "container_setup")) {
        if (object.count() != 1) return error.InvalidArguments;
        const dockerfile = object.get("dockerfile") orelse return error.InvalidArguments;
        if (dockerfile != .string or dockerfile.string.len == 0 or dockerfile.string.len > max_text_bytes or std.mem.findScalar(u8, dockerfile.string, 0) != null) return error.InvalidArguments;
        if (std.mem.startsWith(u8, dockerfile.string, "\xef\xbb\xbf")) return error.ExternalFrontendUnsupported;
        // External Dockerfile frontends are executable build plugins. This
        // slice uses only the daemon's built-in Dockerfile frontend.
        var lines = std.mem.splitScalar(u8, dockerfile.string, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "#")) {
                const directive = std.mem.trimStart(u8, trimmed[1..], " \t");
                if (std.ascii.startsWithIgnoreCase(directive, "syntax")) return error.ExternalFrontendUnsupported;
            }
        }
        return .{ .container_setup = dockerfile.string };
    }
    if (std.mem.eql(u8, tool_name, "shell")) {
        if (object.count() != 2) return error.InvalidArguments;
        const action = object.get("action") orelse return error.InvalidArguments;
        const command = object.get("command") orelse return error.InvalidArguments;
        if (action != .string or !std.mem.eql(u8, action.string, "run") or command != .string or command.string.len == 0 or command.string.len > max_text_bytes or std.mem.findScalar(u8, command.string, 0) != null) return error.InvalidArguments;
        return .{ .shell = command.string };
    }
    return error.UnsupportedTool;
}

pub fn containsPath(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, "/") or std.mem.eql(u8, parent, child) or
        (std.mem.startsWith(u8, child, parent) and child.len > parent.len and child[parent.len] == '/');
}

/// Paths must already be canonical. Never expose the profile or the whole home.
pub fn validateWorkspace(workspace: []const u8, home: []const u8, profile: []const u8) !void {
    if (!std.Io.Dir.path.isAbsolute(workspace) or containsPath(workspace, home) or containsPath(workspace, profile) or containsPath(profile, workspace)) return error.UnsafeWorkspace;
    // Docker's --mount grammar is comma-separated and cannot escape these bytes.
    for (workspace) |byte| if (byte == ',' or byte < 0x20 or byte == 0x7f) return error.UnsafeWorkspace;
}

test "sandbox contract rejects extra controls and non-run shell" {
    const alloc = std.testing.allocator;
    const inputs = [_][]const u8{
        "{\"dockerfile\":\"FROM alpine\",\"mounts\":[]}",
        "{\"action\":\"run\",\"command\":\"true\",\"cwd\":\"/\"}",
        "{\"action\":\"interact\",\"command\":\"true\"}",
    };
    for (inputs, 0..) |input, index| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, input, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidArguments, request(if (index == 0) "container_setup" else "shell", parsed.value));
    }
}

test "sandbox setup rejects external build frontends" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "{\"dockerfile\":\"# syntax=docker/dockerfile:1\\nFROM alpine\"}",
        "{\"dockerfile\":\"# SyNtAx = example/frontend\\nFROM alpine\"}",
        "{\"dockerfile\":\"\\ufeff#syntax=example/frontend\\nFROM alpine\"}",
    }) |input| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, input, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.ExternalFrontendUnsupported, request("container_setup", parsed.value));
    }
}

test "sandbox workspace validation uses component boundaries" {
    try validateWorkspace("/home/example/project", "/home/example", "/home/example/.fx");
    try validateWorkspace("/srv/repo", "/home/example", "/private/profile");
    try std.testing.expectError(error.UnsafeWorkspace, validateWorkspace("/", "/home/example", "/private/profile"));
    try std.testing.expectError(error.UnsafeWorkspace, validateWorkspace("/home", "/home/example", "/private/profile"));
    try std.testing.expectError(error.UnsafeWorkspace, validateWorkspace("/private", "/home/example", "/private/profile"));
    try std.testing.expectError(error.UnsafeWorkspace, validateWorkspace("/private/profile/repo", "/home/example", "/private/profile"));
    try std.testing.expectError(error.UnsafeWorkspace, validateWorkspace("/repo,bad", "/home/example", "/private/profile"));
}
