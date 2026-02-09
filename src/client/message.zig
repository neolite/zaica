const std = @import("std");

/// Role in a chat conversation.
pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn jsonStringify(self: Role, jw: anytype) !void {
        try jw.write(@tagName(self));
    }
};

/// A function definition for tool registration.
pub const FunctionDef = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON schema string for parameters.
    parameters: []const u8,
};

/// A tool definition (OpenAI-compatible format).
pub const ToolDef = struct {
    function: FunctionDef,
};

/// A function call returned by the LLM.
pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

/// A tool call returned by the LLM.
pub const ToolCall = struct {
    id: []const u8,
    function: FunctionCall,
};

/// A regular text message (system, user, or assistant).
pub const TextMessage = struct {
    role: Role,
    content: []const u8,
};

/// An assistant message containing tool calls (no text content).
pub const ToolUseMessage = struct {
    tool_calls: []const ToolCall,
};

/// A tool result message sent back to the LLM.
pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    content: []const u8,
};

/// A single message in the chat conversation.
/// Tagged union supporting text, tool use, and tool result variants.
pub const ChatMessage = union(enum) {
    text: TextMessage,
    tool_use: ToolUseMessage,
    tool_result: ToolResultMessage,
};

/// Request body for POST /chat/completions (OpenAI-compatible).
pub const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    max_tokens: u32 = 8192,
    temperature: f64 = 0.0,
    stream: bool = true,
    tools: ?[]const ToolDef = null,
};

/// Build the JSON request body for chat/completions.
pub fn buildRequestBody(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"model\":\"");
    try writeEscaped(writer, request.model);
    try writer.writeAll("\",\"messages\":[");

    for (request.messages, 0..) |msg, i| {
        if (i > 0) try writer.writeByte(',');
        try writeMessage(writer, msg);
    }

    try writer.writeAll("],\"max_tokens\":");
    try writer.print("{d}", .{request.max_tokens});
    try writer.writeAll(",\"temperature\":");
    try writer.print("{d:.1}", .{request.temperature});

    if (request.stream) {
        try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");
    }

    if (request.tools) |tools| {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, ti| {
            if (ti > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
            try writeEscaped(writer, tool.function.name);
            try writer.writeAll("\",\"description\":\"");
            try writeEscaped(writer, tool.function.description);
            try writer.writeAll("\",\"parameters\":");
            // parameters is raw JSON — write directly, not escaped
            try writer.writeAll(tool.function.parameters);
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }

    try writer.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

/// Serialize a single ChatMessage to JSON.
fn writeMessage(writer: anytype, msg: ChatMessage) !void {
    switch (msg) {
        .text => |tm| {
            try writer.writeAll("{\"role\":\"");
            try writer.writeAll(@tagName(tm.role));
            try writer.writeAll("\",\"content\":\"");
            try writeEscaped(writer, tm.content);
            try writer.writeAll("\"}");
        },
        .tool_use => |tu| {
            try writer.writeAll("{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[");
            for (tu.tool_calls, 0..) |tc, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":\"");
                try writeEscaped(writer, tc.id);
                try writer.writeAll("\",\"type\":\"function\",\"function\":{\"name\":\"");
                try writeEscaped(writer, tc.function.name);
                try writer.writeAll("\",\"arguments\":\"");
                try writeEscaped(writer, tc.function.arguments);
                try writer.writeAll("\"}}");
            }
            try writer.writeAll("]}");
        },
        .tool_result => |tr| {
            try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":\"");
            try writeEscaped(writer, tr.tool_call_id);
            try writer.writeAll("\",\"content\":\"");
            try writeEscaped(writer, tr.content);
            try writer.writeAll("\"}");
        },
    }
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

/// Free all allocator-owned memory in a ChatMessage.
/// System message content is borrowed from config and must not be freed.
pub fn freeMessage(allocator: std.mem.Allocator, msg: ChatMessage) void {
    switch (msg) {
        .text => |tm| {
            if (tm.role != .system) {
                allocator.free(tm.content);
            }
        },
        .tool_use => |tu| {
            for (tu.tool_calls) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.function.name);
                allocator.free(tc.function.arguments);
            }
            allocator.free(tu.tool_calls);
        },
        .tool_result => |tr| {
            allocator.free(tr.tool_call_id);
            allocator.free(tr.content);
        },
    }
}

test "buildRequestBody: basic request" {
    const allocator = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .text = .{ .role = .system, .content = "You are a coding assistant." } },
        .{ .text = .{ .role = .user, .content = "hello" } },
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
        .{ .text = .{ .role = .user, .content = "line1\nline2\t\"quoted\"" } },
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

test "buildRequestBody: tool_use message" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]ToolCall{
        .{
            .id = "call_123",
            .function = .{ .name = "read_file", .arguments = "{\"path\":\"foo.txt\"}" },
        },
    };
    const messages = [_]ChatMessage{
        .{ .text = .{ .role = .user, .content = "read foo.txt" } },
        .{ .tool_use = .{ .tool_calls = &tool_calls } },
    };
    const body = try buildRequestBody(allocator, .{
        .model = "test",
        .messages = &messages,
    });
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const msgs = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    const assistant_msg = msgs[1].object;
    try std.testing.expectEqualStrings("assistant", assistant_msg.get("role").?.string);
    const tcs = assistant_msg.get("tool_calls").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tcs.len);
    try std.testing.expectEqualStrings("call_123", tcs[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("function", tcs[0].object.get("type").?.string);
}

test "buildRequestBody: tool_result message" {
    const allocator = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .tool_result = .{ .tool_call_id = "call_123", .content = "file contents here" } },
    };
    const body = try buildRequestBody(allocator, .{
        .model = "test",
        .messages = &messages,
    });
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const msg = parsed.value.object.get("messages").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool", msg.get("role").?.string);
    try std.testing.expectEqualStrings("call_123", msg.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("file contents here", msg.get("content").?.string);
}

test "buildRequestBody: with tools array" {
    const allocator = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .text = .{ .role = .user, .content = "hello" } },
    };
    const tools = [_]ToolDef{
        .{ .function = .{
            .name = "read_file",
            .description = "Read a file",
            .parameters = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
        } },
    };
    const body = try buildRequestBody(allocator, .{
        .model = "test",
        .messages = &messages,
        .tools = &tools,
    });
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const tools_arr = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools_arr.len);
    const func = tools_arr[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("read_file", func.get("name").?.string);
    // parameters should be a parsed object, not an escaped string
    const params = func.get("parameters").?;
    try std.testing.expect(params == .object);
}
