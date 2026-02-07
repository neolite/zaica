const std = @import("std");
pub const message = @import("message.zig");
pub const sse = @import("sse.zig");
pub const http_client = @import("http.zig");

const config_types = @import("../config/types.zig");

/// Send a prompt to the configured LLM provider and stream the response to stdout.
pub fn chat(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    prompt: []const u8,
) ![]const u8 {
    const messages = try allocator.alloc(message.ChatMessage, 2);
    defer allocator.free(messages);

    messages[0] = .{ .role = .system, .content = resolved.config.system_prompt };
    messages[1] = .{ .role = .user, .content = prompt };

    const body = try message.buildRequestBody(allocator, .{
        .model = resolved.resolved_model,
        .messages = messages,
        .max_tokens = resolved.config.max_tokens,
        .temperature = resolved.config.temperature,
        .stream = true,
    });
    defer allocator.free(body);

    const stdout = std.io.getStdOut().writer();

    const response = try http_client.streamChatCompletion(
        allocator,
        resolved.completions_url,
        resolved.auth.api_key,
        body,
        &struct {
            fn callback(content: []const u8) void {
                const out = std.io.getStdOut().writer();
                out.writeAll(content) catch {};
            }
        }.callback,
    );

    // Final newline after streamed content
    stdout.writeByte('\n') catch {};

    return response;
}

test {
    _ = @import("message.zig");
    _ = @import("sse.zig");
}
