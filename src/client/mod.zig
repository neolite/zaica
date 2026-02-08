const std = @import("std");
pub const message = @import("message.zig");
pub const sse = @import("sse.zig");
pub const http_client = @import("http.zig");

const config_types = @import("../config/types.zig");
const io = @import("../io.zig");

/// Re-export CompletionResult for callers.
pub const CompletionResult = http_client.CompletionResult;

/// Send a full message array to the LLM and stream the response to stdout.
/// Returns either text content or tool calls (caller owns the memory).
pub fn chatMessages(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    messages: []const message.ChatMessage,
    tools: ?[]const message.ToolDef,
) !CompletionResult {
    const body = try message.buildRequestBody(allocator, .{
        .model = resolved.resolved_model,
        .messages = messages,
        .max_tokens = resolved.config.max_tokens,
        .temperature = resolved.config.temperature,
        .stream = true,
        .tools = tools,
    });
    defer allocator.free(body);

    return try http_client.streamChatCompletion(
        allocator,
        resolved.completions_url,
        resolved.auth.api_key,
        body,
        &struct {
            fn callback(content: []const u8) void {
                io.writeText(content) catch {};
            }
        }.callback,
    );
}

/// Send a single prompt to the configured LLM provider and stream the response to stdout.
/// Simple single-shot mode — no tool calling support.
pub fn chat(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    prompt: []const u8,
) ![]const u8 {
    const messages = [_]message.ChatMessage{
        .{ .text = .{ .role = .system, .content = resolved.config.system_prompt } },
        .{ .text = .{ .role = .user, .content = prompt } },
    };

    const result = try chatMessages(allocator, resolved, &messages, null);

    // Final newline after streamed content
    io.writeOut("\r\n") catch {};

    switch (result) {
        .text => |t| return t,
        .tool_calls => |tcs| {
            // Single-shot mode shouldn't get tool calls (no tools sent)
            for (tcs) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.function.name);
                allocator.free(tc.function.arguments);
            }
            allocator.free(tcs);
            return error.ApiError;
        },
    }
}

test {
    _ = @import("message.zig");
    _ = @import("sse.zig");
}
