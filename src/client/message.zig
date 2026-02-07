const std = @import("std");

/// Role in a chat conversation.
pub const Role = enum {
    system,
    user,
    assistant,

    pub fn jsonStringify(self: Role, jw: anytype) !void {
        try jw.write(@tagName(self));
    }
};

/// A single message in the chat conversation.
pub const ChatMessage = struct {
    role: Role,
    content: []const u8,
};

/// Request body for POST /chat/completions (OpenAI-compatible).
pub const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    max_tokens: u32 = 8192,
    temperature: f64 = 0.0,
    stream: bool = true,
};

/// Build the JSON request body for chat/completions.
pub fn buildRequestBody(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{\"model\":\"");
    try writeEscaped(writer, request.model);
    try writer.writeAll("\",\"messages\":[");

    for (request.messages, 0..) |msg, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"role\":\"");
        try writer.writeAll(@tagName(msg.role));
        try writer.writeAll("\",\"content\":\"");
        try writeEscaped(writer, msg.content);
        try writer.writeAll("\"}");
    }

    try writer.writeAll("],\"max_tokens\":");
    try std.fmt.formatInt(request.max_tokens, 10, .lower, .{}, writer);
    try writer.writeAll(",\"temperature\":");
    try writer.print("{d:.1}", .{request.temperature});

    if (request.stream) {
        try writer.writeAll(",\"stream\":true");
    }

    try writer.writeByte('}');
    return buf.toOwnedSlice();
}

/// Write a JSON-escaped string (handles \n, \r, \t, \\, \", control chars).
fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{c});
            },
            else => try writer.writeByte(c),
        }
    }
}

test "buildRequestBody: basic request" {
    const allocator = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "You are a coding assistant." },
        .{ .role = .user, .content = "hello" },
    };
    const body = try buildRequestBody(allocator, .{
        .model = "glm-4.7-flash",
        .messages = &messages,
        .max_tokens = 1024,
        .temperature = 0.7,
        .stream = true,
    });
    defer allocator.free(body);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("glm-4.7-flash", parsed.value.object.get("model").?.string);
    try std.testing.expect(parsed.value.object.get("stream").?.bool == true);
    try std.testing.expectEqual(@as(i64, 1024), parsed.value.object.get("max_tokens").?.integer);
}

test "buildRequestBody: escapes special chars" {
    const allocator = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "line1\nline2\t\"quoted\"" },
    };
    const body = try buildRequestBody(allocator, .{
        .model = "test",
        .messages = &messages,
    });
    defer allocator.free(body);

    // Should be valid JSON despite special chars in content
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string;
    try std.testing.expectEqualStrings("line1\nline2\t\"quoted\"", content);
}
