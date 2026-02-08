const std = @import("std");

/// A single delta fragment for a tool call being streamed.
pub const ToolCallDelta = struct {
    index: usize,
    id: ?[]const u8 = null,
    function_name: ?[]const u8 = null,
    function_arguments: ?[]const u8 = null,
};

/// Parsed SSE event from a streaming chat/completions response.
pub const SseEvent = union(enum) {
    /// A content delta token to display.
    content: []const u8,
    /// A reasoning/thinking delta (GLM reasoning models).
    reasoning: []const u8,
    /// A streamed fragment of a tool call.
    tool_call_delta: ToolCallDelta,
    /// Stream finished normally.
    done: void,
    /// A line we don't handle (e.g. empty, comment, non-data).
    skip: void,
    /// Error response from the API.
    api_error: []const u8,
};

/// Parse a single SSE line (without trailing \n).
/// Expects lines in the format: "data: {json}" or "data: [DONE]".
pub fn parseSseLine(allocator: std.mem.Allocator, line: []const u8) !SseEvent {
    // Skip empty lines and comments
    if (line.len == 0 or line[0] == ':') return .skip;

    // Only process "data: " prefix
    const prefix = "data: ";
    if (!std.mem.startsWith(u8, line, prefix)) return .skip;
    const payload = line[prefix.len..];

    // Check for stream termination
    if (std.mem.eql(u8, payload, "[DONE]")) return .done;

    // Parse JSON to extract content delta
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        // Check if it's an error response
        if (std.mem.indexOf(u8, payload, "\"error\"")) |_| {
            return .{ .api_error = payload };
        }
        return .skip;
    };
    defer parsed.deinit();

    // Check for error object at top level
    if (parsed.value.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg| {
                if (msg == .string) {
                    return .{ .api_error = try allocator.dupe(u8, msg.string) };
                }
            }
        }
    }

    // Navigate: choices[0]
    const choices = parsed.value.object.get("choices") orelse return .skip;
    if (choices != .array or choices.array.items.len == 0) return .skip;

    const first_choice = choices.array.items[0];
    if (first_choice != .object) return .skip;

    const delta = first_choice.object.get("delta") orelse return .skip;
    if (delta != .object) return .skip;

    // Check finish_reason
    if (first_choice.object.get("finish_reason")) |fr| {
        if (fr == .string) {
            if (std.mem.eql(u8, fr.string, "stop") or std.mem.eql(u8, fr.string, "tool_calls")) {
                // May still have content in same chunk
                if (delta.object.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        return .{ .content = try allocator.dupe(u8, content.string) };
                    }
                }
                return .done;
            }
        }
    }

    // Check for tool_calls delta before content
    if (delta.object.get("tool_calls")) |tc_arr| {
        if (tc_arr == .array and tc_arr.array.items.len > 0) {
            const tc = tc_arr.array.items[0];
            if (tc == .object) {
                return try parseToolCallDelta(allocator, tc.object);
            }
        }
    }

    // Extract content delta
    if (delta.object.get("content")) |content| {
        if (content == .string and content.string.len > 0) {
            return .{ .content = try allocator.dupe(u8, content.string) };
        }
    }

    // Extract reasoning_content (GLM thinking models)
    if (delta.object.get("reasoning_content")) |rc| {
        if (rc == .string and rc.string.len > 0) {
            return .{ .reasoning = try allocator.dupe(u8, rc.string) };
        }
    }

    return .skip;
}

/// Parse a single tool_calls[] element from the delta.
fn parseToolCallDelta(allocator: std.mem.Allocator, tc: std.json.ObjectMap) !SseEvent {
    var result: ToolCallDelta = .{
        .index = 0,
    };

    if (tc.get("index")) |idx| {
        if (idx == .integer) {
            result.index = @intCast(idx.integer);
        }
    }

    if (tc.get("id")) |id_val| {
        if (id_val == .string and id_val.string.len > 0) {
            result.id = try allocator.dupe(u8, id_val.string);
        }
    }

    if (tc.get("function")) |func_val| {
        if (func_val == .object) {
            if (func_val.object.get("name")) |name_val| {
                if (name_val == .string and name_val.string.len > 0) {
                    result.function_name = try allocator.dupe(u8, name_val.string);
                }
            }
            if (func_val.object.get("arguments")) |args_val| {
                if (args_val == .string and args_val.string.len > 0) {
                    result.function_arguments = try allocator.dupe(u8, args_val.string);
                }
            }
        }
    }

    return .{ .tool_call_delta = result };
}

/// Free any allocator-owned memory in a ToolCallDelta.
pub fn freeToolCallDelta(allocator: std.mem.Allocator, delta: ToolCallDelta) void {
    if (delta.id) |id| allocator.free(id);
    if (delta.function_name) |name| allocator.free(name);
    if (delta.function_arguments) |args| allocator.free(args);
}

/// Line reader for Zig 0.15 std.Io.Reader.
/// Buffers across chunk boundaries and yields complete lines.
pub const IoLineReader = struct {
    reader: *std.Io.Reader,

    pub fn init(reader: *std.Io.Reader) IoLineReader {
        return .{ .reader = reader };
    }

    /// Read the next complete line (without trailing \r\n).
    /// Returns null at EOF.
    pub fn nextLine(self: *IoLineReader, out_buf: []u8) !?[]const u8 {
        var out_pos: usize = 0;

        while (true) {
            // Check buffered data for newline
            const buf = self.reader.buffered();
            if (buf.len > 0) {
                if (std.mem.indexOfScalar(u8, buf, '\n')) |nl_idx| {
                    // Found newline — copy data up to it
                    const copy_len = @min(nl_idx, out_buf.len - out_pos);
                    @memcpy(out_buf[out_pos..][0..copy_len], buf[0..copy_len]);
                    out_pos += copy_len;
                    self.reader.toss(nl_idx + 1); // consume including \n

                    // Strip trailing \r
                    if (out_pos > 0 and out_buf[out_pos - 1] == '\r') {
                        return out_buf[0 .. out_pos - 1];
                    }
                    return out_buf[0..out_pos];
                } else {
                    // No newline in buffer — copy all and continue
                    const copy_len = @min(buf.len, out_buf.len - out_pos);
                    @memcpy(out_buf[out_pos..][0..copy_len], buf[0..copy_len]);
                    out_pos += copy_len;
                    self.reader.tossBuffered();
                }
            }

            // Fill more data from the stream
            self.reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    if (out_pos > 0) return out_buf[0..out_pos];
                    return null;
                },
                error.ReadFailed => {
                    if (out_pos > 0) return out_buf[0..out_pos];
                    return null;
                },
            };
        }
    }
};

test "parseSseLine: content delta" {
    const allocator = std.testing.allocator;
    const line = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}";
    const event = try parseSseLine(allocator, line);
    switch (event) {
        .content => |c| {
            defer allocator.free(c);
            try std.testing.expectEqualStrings("Hello", c);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseSseLine: done" {
    const allocator = std.testing.allocator;
    const event = try parseSseLine(allocator, "data: [DONE]");
    try std.testing.expect(event == .done);
}

test "parseSseLine: empty line" {
    const allocator = std.testing.allocator;
    const event = try parseSseLine(allocator, "");
    try std.testing.expect(event == .skip);
}

test "parseSseLine: finish_reason stop" {
    const allocator = std.testing.allocator;
    const line = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}";
    const event = try parseSseLine(allocator, line);
    try std.testing.expect(event == .done);
}

test "parseSseLine: finish_reason tool_calls" {
    const allocator = std.testing.allocator;
    const line = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}";
    const event = try parseSseLine(allocator, line);
    try std.testing.expect(event == .done);
}

test "parseSseLine: tool_call_delta with id and name" {
    const allocator = std.testing.allocator;
    const line = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]}}]}";
    const event = try parseSseLine(allocator, line);
    switch (event) {
        .tool_call_delta => |delta| {
            defer freeToolCallDelta(allocator, delta);
            try std.testing.expectEqual(@as(usize, 0), delta.index);
            try std.testing.expectEqualStrings("call_abc", delta.id.?);
            try std.testing.expectEqualStrings("read_file", delta.function_name.?);
            try std.testing.expect(delta.function_arguments == null); // empty string → null
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseSseLine: tool_call_delta argument fragment" {
    const allocator = std.testing.allocator;
    const line = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\"\"}}]}}]}";
    const event = try parseSseLine(allocator, line);
    switch (event) {
        .tool_call_delta => |delta| {
            defer freeToolCallDelta(allocator, delta);
            try std.testing.expectEqual(@as(usize, 0), delta.index);
            try std.testing.expect(delta.id == null);
            try std.testing.expect(delta.function_name == null);
            try std.testing.expectEqualStrings("{\"path\"", delta.function_arguments.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "IoLineReader: splits lines correctly" {
    const data = "line1\nline2\r\nline3\n";
    var reader = std.Io.Reader.fixed(data);
    var lr = IoLineReader.init(&reader);
    var buf: [256]u8 = undefined;

    const l1 = (try lr.nextLine(&buf)).?;
    try std.testing.expectEqualStrings("line1", l1);

    const l2 = (try lr.nextLine(&buf)).?;
    try std.testing.expectEqualStrings("line2", l2);

    const l3 = (try lr.nextLine(&buf)).?;
    try std.testing.expectEqualStrings("line3", l3);

    try std.testing.expect(try lr.nextLine(&buf) == null);
}
