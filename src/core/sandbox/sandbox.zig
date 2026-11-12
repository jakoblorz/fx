const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const contract = @import("contract.zig");

pub const State = contract.State;
pub const parseRequest = contract.request;
pub const allowsTool = contract.allowsTool;
pub const max_text_bytes = contract.max_text_bytes;
pub const Result = contract.Result;
pub const supported = !build_options.libfx and builtin.target.cpu.arch != .wasm32 and builtin.target.cpu.arch != .wasm64 and (builtin.target.os.tag == .linux or builtin.target.os.tag == .macos);
pub const Runtime = if (supported) @import("native.zig").Runtime else UnsupportedRuntime;
pub const bootstrapPrompt = @import("bootstrap_context.zig").buildPrompt;

const UnsupportedRuntime = struct {
    pub fn init(_: std.mem.Allocator, _: []const u8) UnsupportedRuntime {
        return .{};
    }

    pub fn deinit(_: *UnsupportedRuntime) void {}

    pub fn state(_: *UnsupportedRuntime) State {
        return .unconfigured;
    }

    pub fn execute(self: *UnsupportedRuntime, alloc: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) !Result {
        return self.executeWithCancel(alloc, tool_name, args_json, null);
    }

    pub fn executeWithCancel(_: *UnsupportedRuntime, alloc: std.mem.Allocator, _: []const u8, _: []const u8, cancel_flag: ?*const std.atomic.Value(bool)) !Result {
        if (cancel_flag) |flag| if (flag.load(.acquire)) return error.Canceled;
        return .{ .text = try alloc.dupe(u8, "The native container runtime is unsupported in this host. No command was run."), .success = false };
    }
};

test "container unsupported host never executes or falls back" {
    const alloc = std.testing.allocator;
    var runtime = UnsupportedRuntime.init(alloc, "/workspace");
    defer runtime.deinit();
    const result = try runtime.execute(alloc, "shell", "{\"action\":\"run\",\"command\":\"touch /tmp/never\"}");
    defer result.deinit(alloc);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(State.unconfigured, runtime.state());
}

test {
    _ = contract;
    _ = @import("bootstrap_context.zig");
    if (supported) _ = @import("native.zig");
}
