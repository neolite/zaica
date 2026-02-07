const std = @import("std");
const http = std.http;
const message = @import("message.zig");
const sse = @import("sse.zig");

pub const StreamError = error{
    ConnectionFailed,
    RequestFailed,
    HttpError,
    ApiError,
};

/// Stream a chat completion response, calling `on_content` for each token.
/// Returns the full concatenated response text.
pub fn streamChatCompletion(
    allocator: std.mem.Allocator,
    completions_url: []const u8,
    api_key: ?[]const u8,
    request_body: []const u8,
    on_content: *const fn ([]const u8) void,
) ![]const u8 {
    const uri = std.Uri.parse(completions_url) catch {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error: Invalid URL: {s}\n", .{completions_url}) catch {};
        return StreamError.ConnectionFailed;
    };

    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Build authorization header value
    var auth_buf: [512]u8 = undefined;
    const auth_value: ?[]const u8 = if (api_key) |key| blk: {
        break :blk std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch null;
    } else null;

    // Server header buffer
    var server_header_buffer: [16 * 1024]u8 = undefined;

    var req = client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
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
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error: Failed to connect to {s}: {}\n", .{ completions_url, err }) catch {};
        return StreamError.ConnectionFailed;
    };
    defer req.deinit();

    // Send request body
    req.transfer_encoding = .{ .content_length = request_body.len };
    req.send() catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error: Failed to send request: {}\n", .{err}) catch {};
        return StreamError.RequestFailed;
    };
    req.writer().writeAll(request_body) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error: Failed to write request body: {}\n", .{err}) catch {};
        return StreamError.RequestFailed;
    };
    req.finish() catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error: Failed to finish request: {}\n", .{err}) catch {};
        return StreamError.RequestFailed;
    };
    req.wait() catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error: Failed to receive response: {}\n", .{err}) catch {};
        return StreamError.RequestFailed;
    };

    // Check HTTP status
    const status: u16 = @intFromEnum(req.response.status);
    if (status >= 400) {
        const stderr = std.io.getStdErr().writer();
        // Try to read error body
        const err_body = req.reader().readAllAlloc(allocator, 64 * 1024) catch null;
        defer if (err_body) |b| allocator.free(b);
        if (err_body) |body| {
            // Try to extract error message from JSON
            if (extractErrorMessage(allocator, body)) |msg| {
                defer allocator.free(msg);
                stderr.print("Error: HTTP {d} — {s}\n", .{ status, msg }) catch {};
            } else {
                stderr.print("Error: HTTP {d}\n{s}\n", .{ status, body }) catch {};
            }
        } else {
            stderr.print("Error: HTTP {d}\n", .{status}) catch {};
        }
        return StreamError.HttpError;
    }

    // Stream SSE response
    var response_buf = std.ArrayList(u8).init(allocator);
    errdefer response_buf.deinit();

    var line_reader = sse.LineReader(http.Client.Request.Reader).init(req.reader());
    var line_buf: [16 * 1024]u8 = undefined;

    // Some APIs return plain JSON errors with HTTP 200 (e.g. GLM rate limits).
    // Detect this: if first line starts with '{', it's not SSE.
    var first_line = true;

    while (try line_reader.nextLine(&line_buf)) |line| {
        if (first_line and line.len > 0 and line[0] == '{') {
            // Plain JSON response — likely an error
            const stderr = std.io.getStdErr().writer();
            if (extractErrorMessage(allocator, line)) |msg| {
                defer allocator.free(msg);
                stderr.print("Error: {s}\n", .{msg}) catch {};
            } else {
                stderr.print("Error: {s}\n", .{line}) catch {};
            }
            return StreamError.ApiError;
        }
        first_line = false;

        const event = sse.parseSseLine(allocator, line) catch continue;
        switch (event) {
            .content => |content| {
                defer allocator.free(content);
                on_content(content);
                try response_buf.appendSlice(content);
            },
            .done => break,
            .api_error => |err_msg| {
                defer allocator.free(err_msg);
                const stderr = std.io.getStdErr().writer();
                stderr.print("\nAPI Error: {s}\n", .{err_msg}) catch {};
                return StreamError.ApiError;
            },
            .skip => {},
        }
    }

    return response_buf.toOwnedSlice();
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
