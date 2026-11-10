//! Portable memory storage contract. Providers borrow their context; callers
//! own returned filenames/lists and release them with the supplied allocator.
const std = @import("std");

pub const codec = @import("codec.zig");
pub const Native = @import("native.zig").Native;
pub const Metadata = std.json.ObjectMap;
pub const errorMessage = @import("errors.zig").message;

/// All slices and metadata belong to arena. Use deinit, not individual frees.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    filename: []const u8,
    /// Complete stored Markdown, including any frontmatter delimiters/header.
    content: []const u8,
    frontmatter: ?Metadata,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Host-injectable, synchronous provider. A future libfx host can implement
/// this contract without depending on native filesystem/profile state.
///
/// write replaces one complete document atomically and returns its canonical
/// filename. list and query return sorted canonical filenames, not paths.
/// Missing stores list/query as empty; missing documents return FileNotFound.
/// Query predicates are ANDed. Null requires key existence (including a null
/// value); scalars compare by JSON type, or match a scalar array member.
/// Validation failures and storage errors propagate without partial results.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, ?Metadata) anyerror![]u8,
        list: *const fn (*anyopaque, std.mem.Allocator) anyerror![][]const u8,
        read: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!Document,
        query: *const fn (*anyopaque, std.mem.Allocator, Metadata) anyerror![][]const u8,
    };

    pub fn write(self: Provider, alloc: std.mem.Allocator, content: []const u8, filename: []const u8, frontmatter: ?Metadata) ![]u8 {
        return self.vtable.write(self.ptr, alloc, content, filename, frontmatter);
    }

    pub fn list(self: Provider, alloc: std.mem.Allocator) ![][]const u8 {
        return self.vtable.list(self.ptr, alloc);
    }

    pub fn read(self: Provider, alloc: std.mem.Allocator, filename: []const u8) !Document {
        return self.vtable.read(self.ptr, alloc, filename);
    }

    pub fn query(self: Provider, alloc: std.mem.Allocator, predicates: Metadata) ![][]const u8 {
        return self.vtable.query(self.ptr, alloc, predicates);
    }
};

pub fn freeNames(alloc: std.mem.Allocator, names: [][]const u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

/// A portable single leaf, with an optional lowercase .md suffix. The caller
/// owns the normalized name. Rejects separators, controls, dotfiles, device
/// path syntax, and overlong names before touching the filesystem.
pub fn normalizeFilename(alloc: std.mem.Allocator, filename: []const u8) ![]u8 {
    const stem = if (std.mem.endsWith(u8, filename, ".md")) filename[0 .. filename.len - 3] else filename;
    if (stem.len == 0 or stem[0] == '.' or stem.len > 200 or !std.unicode.utf8ValidateSlice(stem)) return error.InvalidMemoryFilename;
    for (stem) |c| {
        if (c < 0x20 or c == 0x7f or std.mem.findScalar(u8, "/\\:*?\"<>|", c) != null) return error.InvalidMemoryFilename;
    }
    if (std.mem.trim(u8, stem, " .").len != stem.len) return error.InvalidMemoryFilename;
    return alloc.print("{s}.md", .{stem});
}

test "memory filenames normalize once and reject unsafe leaves" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "note", "note.md" }) |input| {
        const name = try normalizeFilename(alloc, input);
        defer alloc.free(name);
        try std.testing.expectEqualStrings("note.md", name);
    }
    for ([_][]const u8{ "", ".md", ".", "..", "../x", "/x", "a/b", "a\\b", "a\n", "a\x00b", " hidden", "tail.", "a:b" }) |input| {
        try std.testing.expectError(error.InvalidMemoryFilename, normalizeFilename(alloc, input));
    }
}

test {
    _ = @import("native.zig");
    _ = codec;
}
