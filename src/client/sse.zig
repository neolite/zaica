const std = @import("std");

/// Parsed SSE event from a streaming chat/completions response.
pub const SseEvent = union(enum) {
    /// A content delta token to display.
    content: []const u8,
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

    // Navigate: choices[0].delta.content
    const choices = parsed.value.object.get("choices") orelse return .skip;
    if (choices != .array or choices.array.items.len == 0) return .skip;

    const first_choice = choices.array.items[0];
    if (first_choice != .object) return .skip;

    const delta = first_choice.object.get("delta") orelse return .skip;
    if (delta != .object) return .skip;

    // Check finish_reason
    if (first_choice.object.get("finish_reason")) |fr| {
        if (fr == .string and std.mem.eql(u8, fr.string, "stop")) {
            // May still have content in same chunk
            if (delta.object.get("content")) |content| {
                if (content == .string and content.string.len > 0) {
                    return .{ .content = try allocator.dupe(u8, content.string) };
                }
            }
            return .done;
        }
    }

    const content = delta.object.get("content") orelse return .skip;
    if (content != .string or content.string.len == 0) return .skip;

    return .{ .content = try allocator.dupe(u8, content.string) };
}

/// Line reader that buffers across chunk boundaries.
/// Wraps any std.io.Reader and yields complete lines.
pub fn LineReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        reader: ReaderType,
        buf: [8192]u8 = undefined,
        pos: usize = 0,
        len: usize = 0,
        eof: bool = false,

        pub fn init(reader: ReaderType) Self {
            return .{ .reader = reader };
        }

        /// Read the next complete line (without trailing \r\n).
        /// Returns null at EOF.
        pub fn nextLine(self: *Self, out_buf: []u8) !?[]const u8 {
            var out_pos: usize = 0;

            while (true) {
                // Search for newline in buffered data
                if (self.pos < self.len) {
                    const remaining = self.buf[self.pos..self.len];
                    if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_idx| {
                        const line_data = remaining[0..nl_idx];
                        const copy_len = @min(line_data.len, out_buf.len - out_pos);
                        @memcpy(out_buf[out_pos..][0..copy_len], line_data[0..copy_len]);
                        out_pos += copy_len;
                        self.pos += nl_idx + 1; // skip past \n

                        // Strip trailing \r
                        const result = out_buf[0..out_pos];
                        if (out_pos > 0 and result[out_pos - 1] == '\r') {
                            return result[0 .. out_pos - 1];
                        }
                        return result;
                    } else {
                        // No newline found — copy all buffered data to output
                        const copy_len = @min(remaining.len, out_buf.len - out_pos);
                        @memcpy(out_buf[out_pos..][0..copy_len], remaining[0..copy_len]);
                        out_pos += copy_len;
                        self.pos = self.len; // consumed all
                    }
                }

                // Refill buffer
                if (self.eof) {
                    // Return remaining data as last line if any
                    if (out_pos > 0) {
                        const result = out_buf[0..out_pos];
                        out_pos = 0;
                        return result;
                    }
                    return null;
                }

                const n = self.reader.read(&self.buf) catch |err| {
                    if (out_pos > 0) return out_buf[0..out_pos];
                    return err;
                };
                if (n == 0) {
                    self.eof = true;
                    if (out_pos > 0) return out_buf[0..out_pos];
                    return null;
                }
                self.pos = 0;
                self.len = n;
            }
        }
    };
}

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

test "LineReader: splits lines correctly" {
    const data = "line1\nline2\r\nline3\n";
    var stream = std.io.fixedBufferStream(data);
    var lr = LineReader(@TypeOf(stream.reader())).init(stream.reader());
    var buf: [256]u8 = undefined;

    const l1 = (try lr.nextLine(&buf)).?;
    try std.testing.expectEqualStrings("line1", l1);

    const l2 = (try lr.nextLine(&buf)).?;
    try std.testing.expectEqualStrings("line2", l2);

    const l3 = (try lr.nextLine(&buf)).?;
    try std.testing.expectEqualStrings("line3", l3);

    try std.testing.expect(try lr.nextLine(&buf) == null);
}
