const std = @import("std");
const http = std.http;
const io = @import("../io.zig");
const message = @import("message.zig");
const sse = @import("sse.zig");

pub const StreamError = error{
    ConnectionFailed,
    RequestFailed,
    HttpError,
    ApiError,
};

/// Result of a streaming chat completion.
pub const CompletionResult = struct {
    response: ResponseKind,
    usage: ?sse.TokenUsage = null,

    pub const ResponseKind = union(enum) {
        text: []const u8,
        tool_calls: []const message.ToolCall,
    };
};

/// In-progress tool call being accumulated from deltas.
const ToolCallAccumulator = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),

    fn init() ToolCallAccumulator {
        return .{
            .id = .empty,
            .name = .empty,
            .arguments = .empty,
        };
    }

    fn toToolCall(self: *ToolCallAccumulator, allocator: std.mem.Allocator) !message.ToolCall {
        return .{
            .id = try self.id.toOwnedSlice(allocator),
            .function = .{
                .name = try self.name.toOwnedSlice(allocator),
                .arguments = try self.arguments.toOwnedSlice(allocator),
            },
        };
    }

    fn deinit(self: *ToolCallAccumulator, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

/// Stream a chat completion response, calling `on_content` for each token.
/// Returns either full text or accumulated tool calls.
pub fn streamChatCompletion(
    allocator: std.mem.Allocator,
    completions_url: []const u8,
    api_key: ?[]const u8,
    request_body: []const u8,
    on_content: *const fn ([]const u8) void,
) !CompletionResult {
    const uri = std.Uri.parse(completions_url) catch {
        io.printErr("Error: Invalid URL: {s}\n", .{completions_url});
        return StreamError.ConnectionFailed;
    };

    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Build authorization header value
    var auth_buf: [512]u8 = undefined;
    const auth_value: ?[]const u8 = if (api_key) |key| blk: {
        break :blk std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch null;
    } else null;

    // Open request (Zig 0.15 API)
    var req = client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = if (auth_value) |v| .{ .override = v } else .default,
            // Disable compression for SSE — we need raw byte stream
            .accept_encoding = .omit,
        },
        .extra_headers = &.{
            .{ .name = "accept", .value = "text/event-stream" },
        },
    }) catch |err| {
        io.printErr("Error: Failed to connect to {s}: {}\n", .{ completions_url, err });
        return StreamError.ConnectionFailed;
    };
    defer req.deinit();

    // Send request body
    req.transfer_encoding = .{ .content_length = request_body.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
        io.printErr("Error: Failed to send request: {}\n", .{err});
        return StreamError.RequestFailed;
    };
    body_writer.writer.writeAll(request_body) catch |err| {
        io.printErr("Error: Failed to write request body: {}\n", .{err});
        return StreamError.RequestFailed;
    };
    body_writer.end() catch |err| {
        io.printErr("Error: Failed to finish request: {}\n", .{err});
        return StreamError.RequestFailed;
    };
    if (req.connection) |conn| {
        conn.flush() catch |err| {
            io.printErr("Error: Failed to flush request: {}\n", .{err});
            return StreamError.RequestFailed;
        };
    }

    // Receive response headers
    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        io.printErr("Error: Failed to receive response: {}\n", .{err});
        return StreamError.RequestFailed;
    };

    // Check HTTP status
    const status: u16 = @intFromEnum(response.head.status);
    if (status >= 400) {
        // Try to read error body
        var transfer_buf: [4096]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const err_body = body_reader.allocRemaining(allocator, .limited(64 * 1024)) catch null;
        defer if (err_body) |b| allocator.free(b);
        if (err_body) |body| {
            if (extractErrorMessage(allocator, body)) |msg| {
                defer allocator.free(msg);
                io.printErr("Error: HTTP {d} — {s}\n", .{ status, msg });
            } else {
                io.printErr("Error: HTTP {d}\n{s}\n", .{ status, body });
            }
        } else {
            io.printErr("Error: HTTP {d}\n", .{status});
        }
        return StreamError.HttpError;
    }

    // Stream SSE response
    var response_buf: std.ArrayList(u8) = .empty;
    errdefer response_buf.deinit(allocator);

    // Tool call accumulators
    var tc_accumulators: std.ArrayList(ToolCallAccumulator) = .empty;
    defer {
        for (tc_accumulators.items) |*acc| acc.deinit(allocator);
        tc_accumulators.deinit(allocator);
    }

    var transfer_buf: [16 * 1024]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var line_reader = sse.IoLineReader.init(body_reader);
    var line_buf: [16 * 1024]u8 = undefined;

    // Some APIs return plain JSON errors with HTTP 200 (e.g. GLM rate limits).
    // Detect this: if first line starts with '{', it's not SSE.
    var first_line = true;
    var in_reasoning = false;
    var final_usage: ?sse.TokenUsage = null;

    while (try line_reader.nextLine(&line_buf)) |line| {
        if (first_line and line.len > 0 and line[0] == '{') {
            // Plain JSON response — likely an error
            if (extractErrorMessage(allocator, line)) |msg| {
                defer allocator.free(msg);
                io.printErr("Error: {s}\n", .{msg});
            } else {
                io.printErr("Error: {s}\n", .{line});
            }
            return StreamError.ApiError;
        }
        first_line = false;

        const event = sse.parseSseLine(allocator, line) catch continue;
        switch (event) {
            .reasoning => |text| {
                defer allocator.free(text);
                io.stopSpinner();
                if (!in_reasoning) {
                    io.writeOut("\x1b[2;3m<thinking>\x1b[0m\r\n\x1b[2m") catch {};
                    in_reasoning = true;
                }
                io.writeText(text) catch {};
            },
            .content => |content| {
                defer allocator.free(content);
                io.stopSpinner();
                if (in_reasoning) {
                    io.writeOut("\r\n\x1b[2;3m</thinking>\x1b[0m\r\n\r\n") catch {};
                    in_reasoning = false;
                }
                on_content(content);
                try response_buf.appendSlice(allocator, content);
            },
            .tool_call_delta => |delta| {
                defer sse.freeToolCallDelta(allocator, delta);
                io.stopSpinner();
                if (in_reasoning) {
                    io.writeOut("\r\n\x1b[2;3m</thinking>\x1b[0m\r\n\r\n") catch {};
                    in_reasoning = false;
                }

                // New tool call starting (has id)
                if (delta.id != null) {
                    var acc = ToolCallAccumulator.init();
                    if (delta.id) |id| try acc.id.appendSlice(allocator, id);
                    if (delta.function_name) |name| {
                        try acc.name.appendSlice(allocator, name);
                        // Show tool call name as it arrives (dim)
                        io.writeOut("\x1b[2m[tool: ") catch {};
                        io.writeOut(name) catch {};
                        io.writeOut("]\x1b[0m\r\n") catch {};
                    }
                    if (delta.function_arguments) |args| try acc.arguments.appendSlice(allocator, args);
                    try tc_accumulators.append(allocator, acc);
                } else if (tc_accumulators.items.len > 0) {
                    // Append to current (last) accumulator
                    var current = &tc_accumulators.items[tc_accumulators.items.len - 1];
                    if (delta.function_arguments) |args| {
                        try current.arguments.appendSlice(allocator, args);
                    }
                }
            },
            .done => |usage| {
                if (usage) |u| final_usage = u;
                if (in_reasoning) {
                    io.writeOut("\r\n\x1b[2;3m</thinking>\x1b[0m\r\n") catch {};
                }
                break;
            },
            .api_error => |err_msg| {
                defer allocator.free(err_msg);
                io.stopSpinner();
                if (in_reasoning) {
                    io.writeOut("\x1b[0m") catch {};
                }
                io.printErr("\nAPI Error: {s}\n", .{err_msg});
                return StreamError.ApiError;
            },
            .skip => {},
        }
    }

    // If we accumulated tool calls, return those instead of text
    if (tc_accumulators.items.len > 0) {
        var tool_calls: std.ArrayList(message.ToolCall) = .empty;
        errdefer {
            for (tool_calls.items) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.function.name);
                allocator.free(tc.function.arguments);
            }
            tool_calls.deinit(allocator);
        }
        for (tc_accumulators.items) |*acc| {
            try tool_calls.append(allocator, try acc.toToolCall(allocator));
        }
        response_buf.deinit(allocator);
        // Clear accumulators so defer doesn't double-free
        for (tc_accumulators.items) |*acc| {
            acc.id = .empty;
            acc.name = .empty;
            acc.arguments = .empty;
        }
        return .{ .response = .{ .tool_calls = try tool_calls.toOwnedSlice(allocator) }, .usage = final_usage };
    }

    return .{ .response = .{ .text = try response_buf.toOwnedSlice(allocator) }, .usage = final_usage };
}

/// Try to extract error.message from a JSON error response.
fn extractErrorMessage(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const err_obj = parsed.value.object.get("error") orelse return null;
    if (err_obj != .object) return null;
    const msg = err_obj.object.get("message") orelse return null;
    if (msg != .string) return null;
    return allocator.dupe(u8, msg.string) catch null;
}
