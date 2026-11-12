const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const sandbox = @import("../../core/sandbox/sandbox.zig");

const Input = struct {};

fn deinit(raw: *anyopaque, alloc: std.mem.Allocator) void {
    alloc.destroy(@as(*Input, @ptrCast(@alignCast(raw))));
}

pub fn decodeSetup(ctx: dispatch.DispatchContext, args_json: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    return decode(ctx, args_json, true);
}

pub fn decodeShell(ctx: dispatch.DispatchContext, args_json: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    return decode(ctx, args_json, false);
}

fn decode(ctx: dispatch.DispatchContext, args_json: []const u8, setup: bool) dispatch.DispatchError!dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return fail(ctx, "Container tool arguments must be valid JSON.");
    };
    defer parsed.deinit();
    _ = sandbox.parseRequest(if (setup) "container_setup" else "shell", parsed.value) catch |err| {
        return .{ .failure = try ctx.allocator.print("Invalid container tool arguments: {s}.", .{@errorName(err)}) };
    };
    const input = try ctx.allocator.create(Input);
    input.* = .{};
    return .{ .input = .{ .ptr = input, .deinit_fn = deinit } };
}

fn fail(ctx: dispatch.DispatchContext, text: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(u8, text) };
}

// These descriptors participate in ordinary permission admission, but only the
// container execution domain may run them. Generic dispatch always fails shut.
pub fn unavailable(ctx: dispatch.DispatchContext, _: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(u8, "Container execution authority is unavailable; no host tool ran.") };
}

pub fn readsOnly(_: dispatch.ToolInput) bool {
    return false;
}

pub fn irreversible(_: dispatch.ToolInput) bool {
    return true;
}

test "container tools reject native shell controls and arbitrary setup paths" {
    const ctx: dispatch.DispatchContext = .{ .allocator = std.testing.allocator };
    for ([_][]const u8{
        "{\"dockerfile\":\"FROM alpine\",\"path\":\"/tmp/arbitrary\"}",
        "{\"dockerfile\":\"\"}",
    }) |json| {
        const result = try decodeSetup(ctx, json);
        switch (result) {
            .failure => |text| std.testing.allocator.free(text),
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestUnexpectedResult;
            },
        }
    }
    for ([_][]const u8{
        "{\"action\":\"run\",\"command\":\"pwd\",\"tty\":true}",
        "{\"action\":\"run\",\"command\":\"pwd\",\"cwd\":\"/\"}",
        "{\"action\":\"interact\",\"session_id\":\"host\"}",
    }) |json| {
        const result = try decodeShell(ctx, json);
        switch (result) {
            .failure => |text| std.testing.allocator.free(text),
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "container tool valid input does not grant generic host execution" {
    const ctx: dispatch.DispatchContext = .{ .allocator = std.testing.allocator };
    const result = try decodeShell(ctx, "{\"action\":\"run\",\"command\":\"pwd\"}");
    const input = result.input;
    defer input.deinit(std.testing.allocator);
    const execution = try unavailable(ctx, input);
    defer execution.deinit(std.testing.allocator);
    try std.testing.expect(execution == .failure);
}
