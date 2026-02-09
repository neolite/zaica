/// Sub-agent runtime for parallel task execution.
///
/// Each sub-agent runs an independent agentic loop (LLM calls + tool execution)
/// silently in a background thread. Results are returned as text for the main
/// agent to synthesize.
const std = @import("std");
const config_types = @import("config/types.zig");
const http_client = @import("client/http.zig");
const message = @import("client/message.zig");
const tools = @import("tools.zig");
const io = @import("io.zig");

/// Maximum number of iterations per sub-agent.
const MAX_SUB_AGENT_ITERATIONS = 10;

/// Result of a sub-agent execution.
pub const SubAgentResult = struct {
    /// Final text response (caller owns this memory).
    text: []const u8,
    /// Accumulated prompt tokens across all LLM calls.
    total_prompt_tokens: u64,
    /// Accumulated completion tokens across all LLM calls.
    total_completion_tokens: u64,
};

/// System prompt for sub-agents — focused and task-oriented.
const SUB_AGENT_SYSTEM_PROMPT =
    "You are a focused sub-agent working on a specific task. " ++
    "Complete the assigned task efficiently using the available tools. " ++
    "Be concise but complete in your final response. " ++
    "Do not ask clarifying questions — use your best judgment. " ++
    "When done, respond with your findings as plain text.";

/// No-op content callback — sub-agents accumulate content internally.
fn noopCallback(_: []const u8) void {}

/// Run a sub-agent to completion on the given task.
/// Always returns a valid SubAgentResult — errors are returned as descriptive text.
pub fn run(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    task: []const u8,
    permission: tools.PermissionLevel,
) SubAgentResult {
    return runInner(allocator, resolved, task, permission) catch |err| {
        return .{
            .text = std.fmt.allocPrint(allocator, "Sub-agent error: {}", .{err}) catch
                allocator.dupe(u8, "Sub-agent error: unknown") catch "",
            .total_prompt_tokens = 0,
            .total_completion_tokens = 0,
        };
    };
}

/// Inner implementation — can return errors, wrapped by run().
fn runInner(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    task: []const u8,
    permission: tools.PermissionLevel,
) !SubAgentResult {
    // Build conversation history
    var history: std.ArrayList(message.ChatMessage) = .empty;
    defer {
        // Free all messages except [0] (system prompt is comptime string)
        for (history.items[1..]) |msg| {
            message.freeMessage(allocator, msg);
        }
        history.deinit(allocator);
    }

    // System prompt (comptime string — not freed)
    try history.append(allocator, .{
        .text = .{ .role = .system, .content = SUB_AGENT_SYSTEM_PROMPT },
    });

    // User task
    const task_content = try allocator.dupe(u8, task);
    history.append(allocator, .{
        .text = .{ .role = .user, .content = task_content },
    }) catch |err| {
        allocator.free(task_content);
        return err;
    };

    var total_prompt: u64 = 0;
    var total_completion: u64 = 0;

    // Agentic loop
    var iteration: usize = 0;
    while (iteration < MAX_SUB_AGENT_ITERATIONS) : (iteration += 1) {
        // Check cancel before each iteration
        if (io.isCancelRequested()) {
            return .{
                .text = try allocator.dupe(u8, "[Cancelled]"),
                .total_prompt_tokens = total_prompt,
                .total_completion_tokens = total_completion,
            };
        }

        // Build request body
        const body = try message.buildRequestBody(allocator, .{
            .model = resolved.resolved_model,
            .messages = history.items,
            .max_tokens = resolved.config.max_tokens,
            .temperature = resolved.config.temperature,
            .stream = true,
            .tools = tools.sub_agent_tools,
        });
        defer allocator.free(body);

        // Silent LLM call with retry for transient errors
        const result = blk: {
            var attempt: usize = 0;
            while (true) : (attempt += 1) {
                const r = try http_client.streamChatCompletion(
                    allocator,
                    resolved.completions_url,
                    resolved.auth.api_key,
                    body,
                    &noopCallback,
                    true, // silent mode
                );
                switch (r.response) {
                    .http_error => |detail| {
                        const max_retries: usize = if (detail.status == 429) 3 else if (detail.status >= 500) 1 else 0;
                        if (attempt < max_retries) {
                            // Backoff: 429 → 1s, 2s, 4s; 5xx → 500ms
                            const delay_ms: u64 = if (detail.status == 429)
                                @as(u64, 1000) << @intCast(attempt)
                            else
                                500;
                            allocator.free(detail.message);
                            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                            if (io.isCancelRequested()) {
                                return .{
                                    .text = try allocator.dupe(u8, "[Cancelled]"),
                                    .total_prompt_tokens = total_prompt,
                                    .total_completion_tokens = total_completion,
                                };
                            }
                            continue;
                        }
                        break :blk r;
                    },
                    else => break :blk r,
                }
            }
        };

        // Accumulate token usage
        if (result.usage) |usage| {
            total_prompt += usage.prompt_tokens;
            total_completion += usage.completion_tokens;
        }

        switch (result.response) {
            .http_error => |detail| {
                const err_text = std.fmt.allocPrint(
                    allocator,
                    "Sub-agent error: HTTP {d} — {s}",
                    .{ detail.status, detail.message },
                ) catch try allocator.dupe(u8, "Sub-agent error: HTTP error");
                allocator.free(detail.message);
                return .{
                    .text = err_text,
                    .total_prompt_tokens = total_prompt,
                    .total_completion_tokens = total_completion,
                };
            },
            .text => |text| {
                // Done — return the final text (caller owns it)
                // Don't add to history since we're returning
                return .{
                    .text = text,
                    .total_prompt_tokens = total_prompt,
                    .total_completion_tokens = total_completion,
                };
            },
            .tool_calls => |tcs| {
                // Add assistant tool_use message
                try history.append(allocator, .{
                    .tool_use = .{ .tool_calls = tcs },
                });

                // Execute tools sequentially (no threads-inside-threads)
                for (tcs) |tc| {
                    const raw_content = if (!tools.isAllowed(tc.function.name, permission))
                        std.fmt.allocPrint(
                            allocator,
                            "Permission denied: {s} requires higher tool access.",
                            .{tc.function.name},
                        ) catch try allocator.dupe(u8, "Permission denied.")
                    else
                        tools.execute(allocator, tc);

                    // Apply LLM-facing truncation
                    const truncated = tools.truncateToolOutput(allocator, tc.function.name, raw_content);
                    const content = if (truncated.ptr != raw_content.ptr) blk: {
                        allocator.free(raw_content);
                        break :blk truncated;
                    } else raw_content;

                    const id = try allocator.dupe(u8, tc.id);
                    try history.append(allocator, .{
                        .tool_result = .{
                            .tool_call_id = id,
                            .content = content,
                        },
                    });
                }
            },
        }
    }

    // Iteration limit reached
    return .{
        .text = try allocator.dupe(u8, "Sub-agent reached iteration limit without producing a final response."),
        .total_prompt_tokens = total_prompt,
        .total_completion_tokens = total_completion,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "noopCallback: does not crash" {
    noopCallback("test content");
    noopCallback("");
}

test "SubAgentResult: zero-initialized" {
    const result = SubAgentResult{
        .text = "",
        .total_prompt_tokens = 0,
        .total_completion_tokens = 0,
    };
    try std.testing.expectEqual(@as(u64, 0), result.total_prompt_tokens);
    try std.testing.expectEqual(@as(u64, 0), result.total_completion_tokens);
    try std.testing.expectEqualStrings("", result.text);
}
