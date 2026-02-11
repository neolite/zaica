/// Sub-agent runtime for parallel task execution.
///
/// Each sub-agent runs an independent agentic loop (LLM calls + tool execution)
/// silently in a background thread. Results are returned as text for the main
/// agent to synthesize.
///
/// Now a thin wrapper over node.zig — the generic agentic loop.
const std = @import("std");
const config_types = @import("config/types.zig");
const message = @import("client/message.zig");
const tools = @import("tools.zig");
const node = @import("node.zig");

/// Default maximum iterations per sub-agent (overridden by config).
const DEFAULT_MAX_SUB_AGENT_ITERATIONS = 50;

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

/// Run a sub-agent to completion on the given task.
/// Always returns a valid SubAgentResult — errors are returned as descriptive text.
pub fn run(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    task: []const u8,
    permission: tools.PermissionLevel,
) SubAgentResult {
    // Build conversation history
    var history: std.ArrayList(message.ChatMessage) = .empty;
    defer {
        for (history.items[1..]) |msg| {
            message.freeMessage(allocator, msg);
        }
        history.deinit(allocator);
    }

    // System prompt (comptime string — not freed)
    history.append(allocator, .{
        .text = .{ .role = .system, .content = SUB_AGENT_SYSTEM_PROMPT },
    }) catch return errorResult(allocator, "Sub-agent error: out of memory");

    // User task
    const task_content = allocator.dupe(u8, task) catch
        return errorResult(allocator, "Sub-agent error: out of memory");
    history.append(allocator, .{
        .text = .{ .role = .user, .content = task_content },
    }) catch {
        allocator.free(task_content);
        return errorResult(allocator, "Sub-agent error: out of memory");
    };

    // Run the generic agentic loop (use config limit if available, else default)
    const max_iter = resolved.config.max_sub_agent_iterations;
    const result = node.run(allocator, resolved, .{
        .system_prompt = SUB_AGENT_SYSTEM_PROMPT,
        .tool_defs = tools.sub_agent_tools,
        .max_iterations = max_iter,
        .permission = permission,
        .silent = true,
    }, &history, .{});

    // Convert NodeResult to SubAgentResult
    const text = result.text orelse blk: {
        if (result.cancelled) {
            break :blk allocator.dupe(u8, "[Cancelled]") catch "";
        } else if (result.hit_limit) {
            break :blk allocator.dupe(u8, "Sub-agent reached iteration limit without producing a final response.") catch "";
        } else {
            break :blk allocator.dupe(u8, "Sub-agent error: no response") catch "";
        }
    };

    return .{
        .text = text,
        .total_prompt_tokens = result.prompt_tokens,
        .total_completion_tokens = result.completion_tokens,
    };
}

fn errorResult(allocator: std.mem.Allocator, msg: []const u8) SubAgentResult {
    return .{
        .text = allocator.dupe(u8, msg) catch "",
        .total_prompt_tokens = 0,
        .total_completion_tokens = 0,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

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
