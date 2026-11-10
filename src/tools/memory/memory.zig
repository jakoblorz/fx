const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../../core/memory/memory.zig");
const codec = memory.codec;
const io_mod = @import("../../core/shared/io.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
pub const Operation = enum { write, list, read, query };

const Input = struct {
    parsed: std.json.Parsed(std.json.Value),
};

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.parsed.deinit();
    alloc.destroy(input);
}

/// Each callback owns its parsed input until the tool runtime releases it.
pub fn Tool(comptime operation: Operation) type {
    return struct {
        const tool_name = switch (operation) {
            .write => "write_memory",
            .list => "list_memory",
            .read => "read_memory",
            .query => "query_memory",
        };

        pub fn decode(ctx: dispatch.DispatchContext, json: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
            var decoder: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = tool_name };
            // Preserve numeric lexemes so decimal metadata and queries do not
            // round through a floating-point value before exact comparison.
            var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, json, .{ .parse_numbers = false }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failure = try ctx.allocator.print("{s} arguments must be valid JSON", .{tool_name}) },
            };
            var transferred = false;
            defer if (!transferred) parsed.deinit();
            if (parsed.value != .object) return .{ .failure = try ctx.allocator.print("{s} arguments must be an object", .{tool_name}) };
            var fields = parsed.value.object.iterator();
            while (fields.next()) |entry| {
                const key = entry.key_ptr.*;
                const known = switch (operation) {
                    .write => std.mem.eql(u8, key, "content") or std.mem.eql(u8, key, "filename") or std.mem.eql(u8, key, "frontmatter"),
                    .read => std.mem.eql(u8, key, "filename"),
                    .query => std.mem.eql(u8, key, "query"),
                    .list => false,
                };
                if (!known) return .{ .failure = try ctx.allocator.print("{s}: unknown field \"{s}\"", .{ tool_name, key }) };
            }
            if (operation == .write or operation == .read) {
                _ = decoder.requiredString(parsed.value.object, "filename") catch |err| return .{ .failure = try decoder.takeFailure(err) };
            }
            if (operation == .write) {
                _ = decoder.requiredString(parsed.value.object, "content") catch |err| return .{ .failure = try decoder.takeFailure(err) };
                if (parsed.value.object.get("frontmatter")) |value| {
                    if (value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "write_memory field \"frontmatter\" must be an object; omit it when no frontmatter is needed") };
                }
            }
            if (operation == .query) {
                const query = parsed.value.object.get("query") orelse return .{ .failure = try ctx.allocator.dupe(u8, "query_memory requires object field \"query\"") };
                if (query != .object) return .{ .failure = try ctx.allocator.dupe(u8, "query_memory field \"query\" must be an object") };
            }
            const input = try ctx.allocator.create(Input);
            input.* = .{ .parsed = parsed };
            transferred = true;
            return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
        }

        pub fn validate(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!?[]u8 {
            const args = erased.as(Input).parsed.value.object;
            if (operation == .write or operation == .read) {
                const filename = memory.normalizeFilename(ctx.allocator, args.get("filename").?.string) catch |err| return try failureText(ctx.allocator, tool_name, err);
                ctx.allocator.free(filename);
            }
            if (operation == .write) {
                const encoded = codec.encode(ctx.allocator, args.get("content").?.string, frontmatter(args)) catch |err| return try failureText(ctx.allocator, tool_name, err);
                defer ctx.allocator.free(encoded);
                if (encoded.len > 8 * 1024 * 1024) return try failureText(ctx.allocator, tool_name, error.MemoryDocumentTooLarge);
            }
            if (operation == .query) {
                codec.validateQuery(args.get("query").?.object) catch |err| return try failureText(ctx.allocator, tool_name, err);
            }
            return null;
        }

        pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
            if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
            if (ctx.memory_provider) |provider| return execute(ctx, erased, provider);
            if (comptime builtin.target.os.tag == .wasi) {
                return .{ .failure = try ctx.allocator.dupe(u8, "Memory tools are unavailable: this host has not supplied a memory store") };
            } else {
                var store = memory.Native.init(io_mod.homeDir() orelse return .{ .failure = try ctx.allocator.dupe(u8, "Memory tools require HOME or FX_HOME to locate the profile") });
                return execute(ctx, erased, store.provider());
            }
        }

        fn execute(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput, provider: memory.Provider) dispatch.DispatchError!dispatch.ToolResult {
            const args = erased.as(Input).parsed.value.object;
            switch (operation) {
                .write => {
                    const filename = provider.write(ctx.allocator, args.get("content").?.string, args.get("filename").?.string, frontmatter(args)) catch |err| return .{ .failure = try failureText(ctx.allocator, tool_name, err) };
                    defer ctx.allocator.free(filename);
                    return .{ .success = try ctx.allocator.print("Wrote memory {s}", .{filename}) };
                },
                .read => {
                    var document = provider.read(ctx.allocator, args.get("filename").?.string) catch |err| return .{ .failure = try failureText(ctx.allocator, tool_name, err) };
                    defer document.deinit();
                    return .{ .success = try ctx.allocator.dupe(u8, document.content) };
                },
                .list, .query => {
                    const names = (if (operation == .list) provider.list(ctx.allocator) else provider.query(ctx.allocator, args.get("query").?.object)) catch |err| return .{ .failure = try failureText(ctx.allocator, tool_name, err) };
                    defer {
                        for (names) |name| ctx.allocator.free(name);
                        ctx.allocator.free(names);
                    }
                    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
                    defer out.deinit();
                    std.json.Stringify.value(names, .{}, &out.writer) catch return error.OutOfMemory;
                    return .{ .success = try out.toOwnedSlice() };
                },
            }
        }

        pub fn readsOnly(_: dispatch.ToolInput) bool {
            return operation != .write;
        }

        pub fn isIrreversible(_: dispatch.ToolInput) bool {
            return operation == .write;
        }
    };
}

fn frontmatter(args: std.json.ObjectMap) ?std.json.ObjectMap {
    const value = args.get("frontmatter") orelse return null;
    return value.object;
}

fn failureText(alloc: Allocator, tool_name: []const u8, err: anyerror) Allocator.Error![]u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return alloc.print("{s} failed: {s}", .{ tool_name, memory.errorMessage(err) });
}

test "memory tool decoders reject invalid shapes and unexpected fields" {
    const alloc = std.testing.allocator;
    const cases = .{
        .{ Tool(.write).decode, "{\"filename\":\"x\",\"content\":\"body\",\"frontmatter\":[]}" },
        .{ Tool(.write).decode, "{\"filename\":\"x\",\"content\":1}" },
        .{ Tool(.read).decode, "{}" },
        .{ Tool(.list).decode, "{\"path\":\"x\"}" },
        .{ Tool(.query).decode, "{\"query\":[]}" },
    };
    inline for (cases) |case| {
        const result = try case[0](.{ .allocator = alloc }, case[1]);
        switch (result) {
            .failure => |text| {
                defer alloc.free(text);
                try std.testing.expect(text.len > 0);
            },
            .input => |input| {
                input.deinit(alloc);
                return error.TestExpectedFailure;
            },
        }
    }
}
