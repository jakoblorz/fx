const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    content: []const u8,
    frontmatter: ?std.json.ObjectMap,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidFrontmatter => "Frontmatter must be a flat YAML mapping of scalars or scalar arrays.",
        error.InvalidMemoryQuery => "Memory queries must map keys to scalar values; null tests whether a key exists.",
        error.AlreadyHasFrontmatter => "Content already has YAML frontmatter; pass metadata separately.",
        else => @errorName(err),
    };
}

/// The caller owns the returned bytes. Metadata is emitted as YAML with JSON
/// quoted strings and flow sequences, never as interpolated YAML source.
pub fn encode(alloc: Allocator, content: []const u8, frontmatter: ?std.json.ObjectMap) ![]u8 {
    if (opening(content) != null) return error.AlreadyHasFrontmatter;
    const metadata = frontmatter orelse return alloc.dupe(u8, content);
    try validateFrontmatter(metadata);
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try out.writer.writeAll("---\n");
    var it = metadata.iterator();
    while (it.next()) |entry| {
        try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
        try out.writer.writeAll(": ");
        try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    try out.writer.writeAll("---\n");
    try out.writer.writeAll(content);
    return out.toOwnedSlice();
}

pub fn validateFrontmatter(frontmatter: ?std.json.ObjectMap) !void {
    var it = (frontmatter orelse return).iterator();
    while (it.next()) |entry| {
        if (!std.unicode.utf8ValidateSlice(entry.key_ptr.*)) return error.InvalidFrontmatter;
        try validate(entry.value_ptr.*, true);
    }
}

pub fn validateQuery(query: std.json.ObjectMap) !void {
    var it = query.iterator();
    while (it.next()) |entry| {
        if (!std.unicode.utf8ValidateSlice(entry.key_ptr.*)) return error.InvalidMemoryQuery;
        validate(entry.value_ptr.*, false) catch |err| switch (err) {
            error.InvalidFrontmatter => return error.InvalidMemoryQuery,
        };
    }
}

// Compatibility for callers that want an explanation rather than a message.
pub const explainError = errorMessage;

fn validate(value: Value, allow_array: bool) !void {
    switch (value) {
        .null, .bool, .integer => {},
        .string => |s| if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidFrontmatter,
        .float => |n| if (!std.math.isFinite(n)) return error.InvalidFrontmatter,
        .number_string => |s| if (Number.init(s) == null) return error.InvalidFrontmatter,
        .array => |a| {
            if (!allow_array) return error.InvalidFrontmatter;
            for (a.items) |item| try validate(item, false);
        },
        .object => return error.InvalidFrontmatter,
    }
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

// A delimiter must occupy a whole line. Recognize a BOM and leading blank
// space so callers cannot accidentally attach a second metadata document.
fn opening(bytes: []const u8) ?usize {
    var offset: usize = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) 3 else 0;
    while (offset < bytes.len and std.ascii.isWhitespace(bytes[offset])) : (offset += 1) {}
    const end = std.mem.findScalarPos(u8, bytes, offset, '\n') orelse bytes.len;
    if (!std.mem.eql(u8, trim(bytes[offset..end]), "---")) return null;
    return if (end < bytes.len) end + 1 else end;
}

/// Decoded owns both content and metadata; neither borrows the input bytes.
/// This intentionally accepts only flat YAML, not aliases, tags, nested maps,
/// multiline scalars, or implicit YAML 1.1 boolean/date coercions.
pub fn decode(alloc: Allocator, bytes: []const u8) !Decoded {
    var result: Decoded = .{ .arena = .init(alloc), .content = undefined, .frontmatter = null };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const start = opening(bytes) orelse {
        result.content = try arena.dupe(u8, bytes);
        return result;
    };
    var pos = start;
    var metadata: std.json.ObjectMap = .empty;
    var sequence_key: ?[]const u8 = null;
    while (pos < bytes.len) {
        const end = std.mem.findScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
        const raw = bytes[pos..end];
        pos = if (end < bytes.len) end + 1 else end;
        const line = trim(raw);
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "...")) {
            result.content = try arena.dupe(u8, bytes[pos..]);
            result.frontmatter = metadata;
            return result;
        }
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidFrontmatter;
        if (line[0] == '-' and (line.len == 1 or std.ascii.isWhitespace(line[1]))) {
            const key = sequence_key orelse return error.InvalidFrontmatter;
            const value = metadata.getPtr(key).?;
            if (value.* == .null) value.* = .{ .array = .init(arena) };
            if (value.* != .array) return error.InvalidFrontmatter;
            const item = try parseScalar(arena, stripComment(trim(line[1..])));
            try value.array.append(item);
            continue;
        }
        if (raw.len != line.len and raw.len > 0 and (raw[0] == ' ' or raw[0] == '\t')) return error.InvalidFrontmatter;
        const colon = mappingColon(line) orelse return error.InvalidFrontmatter;
        const key_text = trim(line[0..colon]);
        if (key_text.len == 0) return error.InvalidFrontmatter;
        const key = if (key_text[0] == '"' or key_text[0] == '\'') blk: {
            const parsed = try parseScalar(arena, key_text);
            if (parsed != .string) return error.InvalidFrontmatter;
            break :blk parsed.string;
        } else blk: {
            if (std.mem.findAny(u8, key_text, "{}[],&*!|>@`#") != null) return error.InvalidFrontmatter;
            break :blk try arena.dupe(u8, key_text);
        };
        if (metadata.contains(key)) return error.InvalidFrontmatter;
        const text = stripComment(trim(line[colon + 1 ..]));
        const value = if (text.len > 0 and text[0] == '[') try parseArray(arena, text) else try parseScalar(arena, text);
        try metadata.put(arena, key, value);
        sequence_key = if (text.len == 0) key else null;
    }
    return error.InvalidFrontmatter;
}

fn mappingColon(line: []const u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote == '"' and c == '\\') {
            escaped = true;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == ':' and (i + 1 == line.len or std.ascii.isWhitespace(line[i + 1]))) return i;
    }
    return null;
}

fn stripComment(text: []const u8) []const u8 {
    var quote: u8 = 0;
    var escaped = false;
    for (text, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote == '"' and c == '\\') {
            escaped = true;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if ((c == '"' or c == '\'') and (i == 0 or text[i - 1] == '[' or text[i - 1] == ',' or std.ascii.isWhitespace(text[i - 1]))) {
            quote = c;
        } else if (c == '#' and (i == 0 or std.ascii.isWhitespace(text[i - 1]))) return trim(text[0..i]);
    }
    return trim(text);
}

fn parseScalar(alloc: Allocator, text: []const u8) !Value {
    if (text.len == 0) return .null;
    if (text[0] == '"') {
        const parsed = std.json.parseFromSliceLeaky(Value, alloc, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFrontmatter,
        };
        if (parsed != .string) return error.InvalidFrontmatter;
        return parsed;
    }
    if (text[0] == '\'') {
        if (text.len < 2 or text[text.len - 1] != '\'') return error.InvalidFrontmatter;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < text.len - 1) : (i += 1) {
            if (text[i] == '\'') {
                if (i + 1 >= text.len - 1 or text[i + 1] != '\'') return error.InvalidFrontmatter;
                i += 1;
            }
            try out.append(alloc, text[i]);
        }
        return .{ .string = try out.toOwnedSlice(alloc) };
    }
    if (std.mem.findAny(u8, text, "\r\n") != null) return error.InvalidFrontmatter;
    if (std.mem.findScalar(u8, "{}[],&*!|>@`%", text[0]) != null) return error.InvalidFrontmatter;
    if (mappingColon(text) != null or text[0] == '?' or (text[0] == '-' and text.len > 1 and std.ascii.isWhitespace(text[1]))) return error.InvalidFrontmatter;
    if (std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "Null") or std.mem.eql(u8, text, "NULL") or std.mem.eql(u8, text, "~")) return .null;
    if (std.ascii.eqlIgnoreCase(text, "true")) return .{ .bool = true };
    if (std.ascii.eqlIgnoreCase(text, "false")) return .{ .bool = false };
    if (try parseYamlNumber(alloc, text)) |number| return number;
    if (std.ascii.eqlIgnoreCase(text, ".nan") or std.ascii.eqlIgnoreCase(text, ".inf") or std.ascii.eqlIgnoreCase(text, "-.inf") or std.ascii.eqlIgnoreCase(text, "+.inf")) return error.InvalidFrontmatter;
    return .{ .string = try alloc.dupe(u8, text) };
}

fn parseYamlNumber(alloc: Allocator, text: []const u8) !?Value {
    const unsigned = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    if (unsigned.len == 0) return null;
    if (std.mem.startsWith(u8, unsigned, "0x") or std.mem.startsWith(u8, unsigned, "0o")) {
        const base: u8 = if (unsigned[1] == 'x') 16 else 8;
        const magnitude = std.fmt.parseInt(u128, unsigned[2..], base) catch return null;
        const canonical = try alloc.print("{s}{d}", .{ if (text[0] == '-' and magnitude != 0) "-" else "", magnitude });
        if (std.fmt.parseInt(i64, canonical, 10)) |n| return .{ .integer = n } else |_| {}
        return .{ .number_string = canonical };
    }
    var i: usize = 0;
    while (i < unsigned.len and unsigned[i] == '0') : (i += 1) {}
    // JSON requires an integer digit before the dot, and a fractional digit
    // after it. YAML additionally permits +1, 001, .5, and 1.
    const tail = unsigned[i..];
    const prefix = if (tail.len == 0 or tail[0] == '.' or tail[0] == 'e' or tail[0] == 'E') "0" else "";
    const exp = std.mem.findAny(u8, tail, "eE") orelse tail.len;
    const mantissa = tail[0..exp];
    const add_fraction = mantissa.len > 0 and mantissa[mantissa.len - 1] == '.';
    const canonical = try alloc.print("{s}{s}{s}{s}{s}", .{
        if (text[0] == '-') "-" else "", prefix,      mantissa,
        if (add_fraction) "0" else "",   tail[exp..],
    });
    if (Number.init(canonical) == null) return null;
    if (std.fmt.parseInt(i64, canonical, 10)) |n| return .{ .integer = n } else |_| {}
    return .{ .number_string = canonical };
}

fn parseArray(alloc: Allocator, text: []const u8) !Value {
    if (text.len < 2 or text[text.len - 1] != ']') return error.InvalidFrontmatter;
    var result: Value = .{ .array = .init(alloc) };
    const body = trim(text[1 .. text.len - 1]);
    if (body.len == 0) return result;
    var quote: u8 = 0;
    var escaped = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i == body.len or (quote == 0 and body[i] == ',')) {
            if (quote != 0) return error.InvalidFrontmatter;
            const part = trim(body[start..i]);
            if (part.len == 0) {
                if (i == body.len and start != 0) break; // YAML permits a trailing comma.
                return error.InvalidFrontmatter;
            }
            try result.array.append(try parseScalar(alloc, part));
            start = i + 1;
            continue;
        }
        const c = body[i];
        if (escaped) {
            escaped = false;
        } else if (quote == '"' and c == '\\') {
            escaped = true;
        } else if (quote != 0) {
            if (c == quote) quote = 0;
        } else if ((c == '"' or c == '\'') and trim(body[start..i]).len == 0) {
            quote = c;
        } else if (c == '[' or c == ']' or c == '{' or c == '}') return error.InvalidFrontmatter;
    }
    return result;
}

/// AND across query keys. Null means key existence; scalar queries also match
/// elements of stored arrays. Query objects and arrays never match.
pub fn matches(frontmatter: ?std.json.ObjectMap, query: std.json.ObjectMap) bool {
    var it = query.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .object or entry.value_ptr.* == .array) return false;
        const stored = (frontmatter orelse return false).get(entry.key_ptr.*) orelse return false;
        if (entry.value_ptr.* == .null) continue;
        if (stored == .array) {
            var found = false;
            for (stored.array.items) |item| {
                if (scalarEqual(item, entry.value_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        } else if (!scalarEqual(stored, entry.value_ptr.*)) return false;
    }
    return true;
}

fn scalarEqual(a: Value, b: Value) bool {
    var a_buf: [128]u8 = undefined;
    var b_buf: [128]u8 = undefined;
    if (numberText(a, &a_buf)) |at| {
        const bt = numberText(b, &b_buf) orelse return false;
        const an = Number.init(at) orelse return false;
        const bn = Number.init(bt) orelse return false;
        return an.eql(bn);
    }
    return switch (a) {
        .null => b == .null,
        .bool => |v| b == .bool and b.bool == v,
        .string => |v| b == .string and std.mem.eql(u8, v, b.string),
        else => false,
    };
}

fn numberText(value: Value, buf: []u8) ?[]const u8 {
    return switch (value) {
        .integer => |n| std.mem.print(buf, "{d}", .{n}) catch null,
        .float => |n| if (std.math.isFinite(n)) std.mem.print(buf, "{e}", .{n}) catch null else null,
        .number_string => |s| s,
        else => null,
    };
}

// A normalized decimal view keeps equality exact without allocating or rounding
// large integers to floats. The coefficient slice may contain one decimal dot.
const Number = struct {
    digits: []const u8,
    negative: bool,
    exponent: i64,

    fn init(text: []const u8) ?Number {
        if (text.len == 0) return null;
        var i: usize = if (text[0] == '-') 1 else 0;
        const negative = i != 0;
        const start = i;
        if (i == text.len or !std.ascii.isDigit(text[i])) return null;
        if (text[i] == '0') {
            i += 1;
        } else {
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        }
        var fraction: i64 = 0;
        if (i < text.len and text[i] == '.') {
            i += 1;
            const first = i;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) fraction += 1;
            if (i == first) return null;
        }
        const coefficient_end = i;
        var exponent: i64 = 0;
        if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
            i += 1;
            const exp_start = i;
            if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
            const first = i;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
            if (i == first) return null;
            exponent = std.fmt.parseInt(i64, text[exp_start..i], 10) catch return null;
        }
        if (i != text.len) return null;
        exponent = std.math.sub(i64, exponent, fraction) catch return null;
        var first = start;
        while (first < coefficient_end and (text[first] == '0' or text[first] == '.')) : (first += 1) {}
        if (first == coefficient_end) return .{ .digits = "0", .negative = false, .exponent = 0 };
        var last = coefficient_end;
        while (last > first and (text[last - 1] == '0' or text[last - 1] == '.')) {
            if (text[last - 1] == '0') exponent = std.math.add(i64, exponent, 1) catch return null;
            last -= 1;
        }
        return .{ .digits = text[first..last], .negative = negative, .exponent = exponent };
    }

    fn eql(a: Number, b: Number) bool {
        if (a.negative != b.negative or a.exponent != b.exponent) return false;
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.digits.len and j < b.digits.len) {
            if (a.digits[i] == '.') {
                i += 1;
                continue;
            }
            if (b.digits[j] == '.') {
                j += 1;
                continue;
            }
            if (a.digits[i] != b.digits[j]) return false;
            i += 1;
            j += 1;
        }
        return i == a.digits.len and j == b.digits.len;
    }
};

test "frontmatter safe roundtrip and owned content" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Value, alloc,
        \\{"title":"true: # tricky\n---","bool":true,"null":null,"n":1.25,"tags":["x",false,2,null],"a: # b":"yes"}
    , .{});
    defer parsed.deinit();
    const encoded = try encode(alloc, "# Body\n", parsed.value.object);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "---\n\"title\": \"true: # tricky\\n---\"\n"));
    var decoded = try decode(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("# Body\n", decoded.content);
    try std.testing.expect(matches(decoded.frontmatter, parsed.value.object) == false); // Arrays are not query scalars.
    try std.testing.expectEqualStrings("true: # tricky\n---", decoded.frontmatter.?.get("title").?.string);
    try std.testing.expectEqual(@as(usize, 4), decoded.frontmatter.?.get("tags").?.array.items.len);
}

test "plain documents and absent versus empty metadata" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, "hello\r\n", null);
    defer alloc.free(bytes);
    var plain = try decode(alloc, bytes);
    defer plain.deinit();
    try std.testing.expect(plain.frontmatter == null);
    try std.testing.expectEqualStrings("hello\r\n", plain.content);
    var empty = try decode(alloc, "---\n---\n");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.frontmatter.?.count());
    try std.testing.expectEqualStrings("", empty.content);
    try std.testing.expect(matches(null, empty.frontmatter.?));
}

test "read flat YAML with CRLF BOM comments quoted values and block sequences" {
    var decoded = try decode(std.testing.allocator, "\xef\xbb\xbf \r\n---\r\n# metadata\r\ntitle: 'it''s YAML' # comment\r\nactive: true\r\nmissing:\r\ntags:\r\n  - one\r\n  - 'two, three'\r\nflow: [plain, 'a,b', false, 1.0, null,]\r\nurl: https://example.com/#anchor\r\n---\r\nbody\r\n");
    defer decoded.deinit();
    const map = decoded.frontmatter.?;
    try std.testing.expectEqualStrings("it's YAML", map.get("title").?.string);
    try std.testing.expect(map.get("active").?.bool);
    try std.testing.expect(map.get("missing").? == .null);
    try std.testing.expectEqual(@as(usize, 2), map.get("tags").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 5), map.get("flow").?.array.items.len);
    try std.testing.expectEqualStrings("https://example.com/#anchor", map.get("url").?.string);
    try std.testing.expectEqualStrings("body\r\n", decoded.content);
}

test "reject malformed and nested metadata and attached frontmatter" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "---\n",                          "---\na: 1\n",            "---\na: {}\n---\n",     "---\na: [[1]]\n---\n",
        "---\na: [1, {x: 2}]\n---\n",     "---\na: 1\na: 2\n---\n", "---\na: \"bad\n---\n",  "---\na: &anchor value\n---\n",
        "---\na:\n  nested: true\n---\n", "---\na: .nan\n---\n",    "---\na: [1,,2]\n---\n", "---\na: 'bad' junk\n---\n",
        "---\n- one\n---\n",
    }) |bytes| try std.testing.expectError(error.InvalidFrontmatter, decode(alloc, bytes));
    for ([_][]const u8{ "---\nkey: value\n---\nbody", "\xef\xbb\xbf\r\n \t---\r\n", "   ---" }) |bytes| {
        try std.testing.expectError(error.AlreadyHasFrontmatter, encode(alloc, bytes, null));
    }
    const plain = try encode(alloc, "--- not a delimiter\n", null);
    alloc.free(plain);
    var parsed = try std.json.parseFromSlice(Value, alloc, "{\"nested\":{}}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidFrontmatter, encode(alloc, "body", parsed.value.object));
}

test "YAML numeric spellings and plain apostrophes" {
    var decoded = try decode(std.testing.allocator, "---\na: +01\nb: .5\nc: 1.\nd: 0x10\ne: -0o10\nf: 001e2\ntext: don't # comment\narray: [don't, 'it''s', .5]\n---\n");
    defer decoded.deinit();
    const map = decoded.frontmatter.?;
    try std.testing.expect(scalarEqual(map.get("a").?, .{ .integer = 1 }));
    try std.testing.expect(scalarEqual(map.get("b").?, .{ .float = 0.5 }));
    try std.testing.expect(scalarEqual(map.get("c").?, .{ .integer = 1 }));
    try std.testing.expect(scalarEqual(map.get("d").?, .{ .integer = 16 }));
    try std.testing.expect(scalarEqual(map.get("e").?, .{ .integer = -8 }));
    try std.testing.expect(scalarEqual(map.get("f").?, .{ .integer = 100 }));
    try std.testing.expectEqualStrings("don't", map.get("text").?.string);
    try std.testing.expectEqualStrings("it's", map.get("array").?.array.items[1].string);
    try std.testing.expect(scalarEqual(.{ .float = 1.0e-300 }, .{ .number_string = "1e-300" }));
}

test "query existence typed equality scalar membership AND and exact numeric equality" {
    const alloc = std.testing.allocator;
    var decoded = try decode(alloc, "---\na: null\nb: [true, 2, 'word']\nc: 1.0\nbig: 9007199254740993\n---\n");
    defer decoded.deinit();
    const Case = struct { query: []const u8, expected: bool };
    for ([_]Case{
        .{ .query = "{}", .expected = true },
        .{ .query = "{\"a\":null}", .expected = true },
        .{ .query = "{\"absent\":null}", .expected = false },
        .{ .query = "{\"b\":true,\"c\":1}", .expected = true },
        .{ .query = "{\"b\":2.0}", .expected = true },
        .{ .query = "{\"b\":\"2\"}", .expected = false },
        .{ .query = "{\"b\":\"word\"}", .expected = true },
        .{ .query = "{\"c\":true}", .expected = false },
        .{ .query = "{\"b\":[true]}", .expected = false },
        .{ .query = "{\"b\":{}}", .expected = false },
        .{ .query = "{\"big\":9007199254740992}", .expected = false },
        .{ .query = "{\"big\":9007199254740993}", .expected = true },
    }) |case| {
        var query = try std.json.parseFromSlice(Value, alloc, case.query, .{});
        defer query.deinit();
        try std.testing.expectEqual(case.expected, matches(decoded.frontmatter, query.value.object));
    }
    try std.testing.expect(scalarEqual(.{ .number_string = "-0.00e3" }, .{ .integer = 0 }));
    try std.testing.expect(scalarEqual(.{ .number_string = "1.2300e2" }, .{ .integer = 123 }));
    try std.testing.expect(scalarEqual(.{ .number_string = "123456789012345678901234567890" }, .{ .number_string = "12345678901234567890123456789e1" }));
    try std.testing.expect(!scalarEqual(.{ .number_string = "123456789012345678901234567891" }, .{ .number_string = "123456789012345678901234567890" }));
}

test "query validation distinguishes invalid query from invalid metadata" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{\"nested\":{}}", "{\"array\":[1]}" }) |json| {
        var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidMemoryQuery, validateQuery(parsed.value.object));
    }
    var query: std.json.ObjectMap = .empty;
    defer query.deinit(alloc);
    try query.put(alloc, "\xff", .null);
    try std.testing.expectError(error.InvalidMemoryQuery, validateQuery(query));
    try std.testing.expectError(error.InvalidFrontmatter, validateFrontmatter(query));
    query.clearRetainingCapacity();
    try query.put(alloc, "number", .{ .float = std.math.inf(f64) });
    try std.testing.expectError(error.InvalidMemoryQuery, validateQuery(query));
    try std.testing.expectError(error.InvalidFrontmatter, validateFrontmatter(query));
}
