//! Native container experiment's entire tool surface. No ordinary host tool
//! is retained, including tools a profile or saved session previously selected.
const std = @import("std");
const dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_set = @import("../core/tooling/tool_set.zig");
const implementation = @import("../tools/shell/container_tool.zig");
const sandbox = @import("../core/sandbox/sandbox.zig");

const setup_description = "Write the repository's Dockerfile under the fx profile and build its local tool container. Call this before shell. Include all required tools in the image. The build context contains only this Dockerfile, not repository files. Use a Linux image with /bin/sh and sleep. Runtime is non-root with a read-only image, writable /tmp, and the repository at /workspace. Network access is unavailable at runtime. A failed definition can be revised; a running container cannot be replaced in this session.";
const shell_description = "Run one foreground command inside the repository's local container using action=run. First call container_setup successfully. The working directory is /workspace; use this shell for all file reads, searches, edits, builds, and tests. No host shell, host environment, host tools, TTY, managed background handles, MCP bridge, or network access is available. Output is bounded.";

const setup = dispatch.Tool{
    .name = "container_setup",
    .description = setup_description,
    .model_schema = .{
        .name = "container_setup",
        .description = setup_description,
        .input_schema = .{
            .properties = &.{.{ .name = "dockerfile", .json_type = .string, .bounds = &.{ .max_length = sandbox.max_text_bytes } }},
            .required = &.{"dockerfile"},
            .additional_properties = false,
        },
    },
    .executor_kind = .host,
    .activity_kind = .command,
    .requires_approval = true,
    .action_label = "Building",
    .completed_action_label = "Built",
    .label_arg_default = "container toolchain",
    .decode = implementation.decodeSetup,
    .call = implementation.unavailable,
    .reads_only_fn = implementation.readsOnly,
    .irreversible_fn = implementation.irreversible,
};

const shell = dispatch.Tool{
    .name = "shell",
    .description = shell_description,
    .model_schema = .{
        .name = "shell",
        .description = shell_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"run"} } },
                .{ .name = "command", .json_type = .string, .bounds = &.{ .max_length = sandbox.max_text_bytes } },
            },
            .required = &.{ "action", "command" },
            .additional_properties = false,
        },
    },
    // Ordinary, exact-argument host-tool admission avoids running native shell
    // snapshot capture or host git planning for this isolated command.
    .executor_kind = .host,
    .activity_kind = .command,
    .requires_approval = true,
    .action_label = "Running",
    .completed_action_label = "Ran",
    .label_arg_kind = .none,
    .label_arg_default = "container command",
    .decode = implementation.decodeShell,
    .call = implementation.unavailable,
    .reads_only_fn = implementation.readsOnly,
    .irreversible_fn = implementation.irreversible,
};

const all = [_]dispatch.Tool{ setup, shell };
pub const advertisement_set = tool_set.ToolSet{
    .registry = .{ .tools = &all },
    .order = &.{ "container_setup", "shell" },
    .read_only_tool_names = &.{},
};

test "container domain rejects both generic host dispatch entry points" {
    const alloc = std.testing.allocator;
    const ctx: dispatch.DispatchContext = .{ .allocator = alloc, .container_tools = true };
    const call = @import("../core/shared/message.zig").ToolCall{
        .id = "host-dispatch-fence",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"pwd\"}",
    };
    const ordinary = try dispatch.dispatchToolCall(ctx, advertisement_set.registry, call);
    defer ordinary.deinit(alloc);
    try std.testing.expect(ordinary.status == .failure);
    const authorized = try dispatch.dispatchAuthorizedToolCall(ctx, advertisement_set.registry, call);
    defer authorized.deinit(alloc);
    try std.testing.expect(authorized.status == .failure);
}

pub fn allows(name: []const u8) bool {
    return sandbox.allowsTool(name);
}

test "container experiment exposes no ordinary host or dynamic tools" {
    try std.testing.expectEqual(@as(usize, 2), advertisement_set.registry.tools.len);
    for ([_][]const u8{ "write_file", "read_file", "edit_file", "glob_files", "grep_files", "toolbox", "subagent", "web_fetch", "install_skill", "mcp_tool" }) |name| {
        try std.testing.expect(!allows(name));
        try std.testing.expect(advertisement_set.registry.lookup(name) == null);
    }
    for (all) |tool| {
        try std.testing.expect(!tool.provider_executed);
        try std.testing.expect(tool.executor_kind == .host);
        try std.testing.expect(tool.captured_command_fn == null);
        try std.testing.expect(tool.take_file_mutation_input_fn == null);
        try std.testing.expect(tool.requires_approval);
    }
    _ = implementation;
}
