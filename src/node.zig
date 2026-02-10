/// Generic AgentNode — unified agentic loop for both REPL and sub-agent modes.
///
/// Extracts the common LLM call → response → tool execution → loop pattern
/// from repl.zig and agent.zig. The caller provides hooks for UI/state side effects.
const std = @import("std");
const config_types = @import("config/types.zig");
const client = @import("client/mod.zig");
const http_client = @import("client/http.zig");
const message = client.message;
const tools = @import("tools.zig");
const io = @import("io.zig");
const agent = @import("agent.zig");

/// Default loop detection window size.
pub const LOOP_DETECTION_WINDOW = 10;

/// Result of running an agent node.
pub const NodeResult = struct {
    /// Final text response (caller owns this memory), or null if cancelled/error.
    text: ?[]const u8 = null,
    /// Accumulated prompt tokens across all LLM calls.
    prompt_tokens: u64 = 0,
    /// Accumulated completion tokens across all LLM calls.
    completion_tokens: u64 = 0,
    /// Whether the loop was cancelled via ESC.
    cancelled: bool = false,
    /// Whether the iteration limit was reached without a text response.
    hit_limit: bool = false,
};

/// Configuration for an agent node.
pub const NodeConfig = struct {
    /// System prompt for the conversation.
    system_prompt: []const u8,
    /// Tool definitions to send to the LLM.
    tool_defs: []const message.ToolDef,
    /// Maximum iterations before giving up.
    max_iterations: usize = 25,
    /// Current tool permission level.
    permission: tools.PermissionLevel = .none,
    /// Whether to use silent mode (no stdout output).
    silent: bool = false,
};

/// Hooks for side effects — the REPL provides these, sub-agents leave them null.
/// All hooks are optional; null means no-op.
pub const Hooks = struct {
    /// Called before each LLM call (e.g., start spinner, emit phase_changed).
    on_llm_start: ?*const fn () void = null,
    /// Called after each LLM call completes (e.g., stop spinner).
    on_llm_end: ?*const fn () void = null,
    /// Called with token usage after each LLM response.
    on_tokens: ?*const fn (usage: TokenUsage) void = null,
    /// Called after each iteration completes.
    on_iteration: ?*const fn () void = null,
    /// Called when a text response is received.
    on_text: ?*const fn (text: []const u8) void = null,
    /// Called before tool execution with the tool calls for display/permission.
    /// Returns the permission level to use (allows prompting user).
    on_tool_calls: ?*const fn (tcs: []const message.ToolCall) tools.PermissionLevel = null,
    /// Called with each tool result for display.
    on_tool_result: ?*const fn (tc: message.ToolCall, content: []const u8) void = null,
    /// Called when cancel is detected.
    on_cancel: ?*const fn () void = null,
    /// Called when an HTTP error occurs.
    on_http_error: ?*const fn (status: u16, msg: []const u8) void = null,
    /// Called when a loop is detected — should return a steering message or null.
    on_loop_detected: ?*const fn () ?[]const u8 = null,
    /// Called to check context compaction (prompt_tokens, history length).
    on_compaction_check: ?*const fn (history: *std.ArrayList(message.ChatMessage)) void = null,
    /// Called to persist a message to the session file.
    on_persist: ?*const fn (msg: message.ChatMessage) void = null,
    /// Get current permission level (may change after user prompt).
    get_permission: ?*const fn () tools.PermissionLevel = null,
};

pub const TokenUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    reasoning_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
};

/// Result of a single tool execution, used for parallel collection.
pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
    /// Token usage from sub-agent execution (null for regular tools).
    sub_agent_usage: ?struct { prompt_tokens: u64, completion_tokens: u64 } = null,
};

/// Context for tool execution threads.
pub const ToolExecContext = struct {
    allocator: std.mem.Allocator,
    tc: message.ToolCall,
    resolved: *const config_types.ResolvedConfig,
    permission: tools.PermissionLevel,
};

/// Run an agentic loop to completion.
///
/// Takes an existing history (must contain at least system prompt + user message),
/// calls the LLM repeatedly until it produces a text response or hits the iteration limit.
/// Tool calls are executed (sequentially in silent mode, parallel otherwise).
pub fn run(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    config: NodeConfig,
    history: *std.ArrayList(message.ChatMessage),
    hooks: Hooks,
) NodeResult {
    return runInner(allocator, resolved, config, history, hooks) catch {
        return .{};
    };
}

fn runInner(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    config: NodeConfig,
    history: *std.ArrayList(message.ChatMessage),
    hooks: Hooks,
) !NodeResult {
    var total_prompt: u64 = 0;
    var total_completion: u64 = 0;

    // Steering queue — messages injected mid-loop (loop detection, etc.)
    var steering_queue: std.ArrayList([]const u8) = .empty;
    defer {
        for (steering_queue.items) |s| allocator.free(s);
        steering_queue.deinit(allocator);
    }

    // Loop detection ring buffer
    var loop_ring: [LOOP_DETECTION_WINDOW]u64 = undefined;
    @memset(&loop_ring, 0);
    var loop_ring_count: usize = 0;

    var iterations: usize = 0;
    while (iterations < config.max_iterations) : (iterations += 1) {
        // Check cancel before each iteration
        if (io.isCancelRequested()) {
            if (hooks.on_cancel) |cb| cb();
            return .{
                .prompt_tokens = total_prompt,
                .completion_tokens = total_completion,
                .cancelled = true,
            };
        }

        // Drain steering queue
        if (steering_queue.items.len > 0) {
            for (steering_queue.items) |steer_msg| {
                try history.append(allocator, .{
                    .text = .{ .role = .user, .content = steer_msg },
                });
            }
            steering_queue.clearRetainingCapacity();
        }

        // Notify: LLM call starting
        if (hooks.on_llm_start) |cb| cb();

        // LLM call with retry for transient errors
        const result = result_blk: {
            var llm_attempt: usize = 0;
            while (true) : (llm_attempt += 1) {
                const body = try message.buildRequestBody(allocator, .{
                    .model = resolved.resolved_model,
                    .messages = history.items,
                    .max_tokens = resolved.config.max_tokens,
                    .temperature = resolved.config.temperature,
                    .stream = true,
                    .tools = config.tool_defs,
                });
                defer allocator.free(body);

                const noop_cb = struct {
                    fn cb(_: []const u8) void {}
                }.cb;
                const stdout_cb = struct {
                    fn cb(content: []const u8) void {
                        io.writeText(content) catch {};
                    }
                }.cb;

                const r = try http_client.streamChatCompletion(
                    allocator,
                    resolved.completions_url,
                    resolved.auth.api_key,
                    body,
                    if (config.silent) &noop_cb else &stdout_cb,
                    config.silent,
                );

                switch (r.response) {
                    .http_error => |detail| {
                        const max_retries: usize = if (detail.status == 429) 3 else if (detail.status >= 500) 1 else 0;
                        if (llm_attempt < max_retries and !io.isCancelRequested()) {
                            const delay_ms: u64 = if (detail.status == 429)
                                @as(u64, 1000) << @intCast(llm_attempt)
                            else
                                500;
                            if (!config.silent) {
                                if (hooks.on_llm_end) |cb| cb();
                                io.printOut("\x1b[33m\xe2\x9c\xa6 HTTP {d} — retrying in {d}s...\x1b[0m\r\n", .{
                                    detail.status,
                                    delay_ms / 1000,
                                }) catch {};
                            }
                            allocator.free(detail.message);
                            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                            if (!config.silent) {
                                if (hooks.on_llm_start) |cb| cb();
                            }
                            continue;
                        }
                        break :result_blk r;
                    },
                    else => break :result_blk r,
                }
            }
        };

        // Track token usage
        if (result.usage) |usage| {
            total_prompt += usage.prompt_tokens;
            total_completion += usage.completion_tokens;
            if (hooks.on_tokens) |cb| cb(.{
                .prompt_tokens = usage.prompt_tokens,
                .completion_tokens = usage.completion_tokens,
                .reasoning_tokens = usage.reasoning_tokens,
                .cache_read_tokens = usage.cache_read_tokens,
                .cache_write_tokens = usage.cache_write_tokens,
            });
        }

        // Check cancel after LLM call
        if (io.isCancelRequested()) {
            if (hooks.on_llm_end) |cb| cb();
            if (hooks.on_cancel) |cb| cb();
            // Free partial result
            freeResponse(allocator, result.response);
            return .{
                .prompt_tokens = total_prompt,
                .completion_tokens = total_completion,
                .cancelled = true,
            };
        }

        // Notify: iteration completed
        if (hooks.on_iteration) |cb| cb();

        // Compaction check
        if (hooks.on_compaction_check) |cb| cb(history);

        switch (result.response) {
            .http_error => |detail| {
                if (hooks.on_llm_end) |cb| cb();
                if (hooks.on_http_error) |cb| cb(detail.status, detail.message);
                allocator.free(detail.message);
                // On first iteration HTTP error, remove the user message we just added
                if (iterations == 0) {
                    if (history.pop()) |removed| {
                        message.freeMessage(allocator, removed);
                    }
                }
                return .{
                    .prompt_tokens = total_prompt,
                    .completion_tokens = total_completion,
                };
            },
            .text => |text| {
                if (hooks.on_llm_end) |cb| cb();
                if (hooks.on_text) |cb| cb(text);
                try history.append(allocator, .{
                    .text = .{ .role = .assistant, .content = text },
                });
                if (hooks.on_persist) |cb| cb(.{ .text = .{ .role = .assistant, .content = text } });
                return .{
                    .text = text,
                    .prompt_tokens = total_prompt,
                    .completion_tokens = total_completion,
                };
            },
            .tool_calls => |tcs| {
                // Stop the "Thinking..." spinner before tool processing
                if (hooks.on_llm_end) |cb| cb();

                // Get effective permission (may prompt user in terminal mode)
                const effective_permission = if (hooks.on_tool_calls) |cb|
                    cb(tcs)
                else
                    config.permission;

                // Check cancel after permission prompt
                if (io.isCancelRequested()) {
                    if (hooks.on_cancel) |cb| cb();
                    for (tcs) |tc| {
                        allocator.free(tc.id);
                        allocator.free(tc.function.name);
                        allocator.free(tc.function.arguments);
                    }
                    allocator.free(tcs);
                    return .{
                        .prompt_tokens = total_prompt,
                        .completion_tokens = total_completion,
                        .cancelled = true,
                    };
                }

                // If permission is .none, deny all tools and continue loop
                if (effective_permission == .none) {
                    try history.append(allocator, .{
                        .tool_use = .{ .tool_calls = tcs },
                    });
                    for (tcs) |tc| {
                        const denied_id = try allocator.dupe(u8, tc.id);
                        const denied_msg = try allocator.dupe(u8, "Permission denied by user.");
                        try history.append(allocator, .{
                            .tool_result = .{
                                .tool_call_id = denied_id,
                                .content = denied_msg,
                            },
                        });
                    }
                    continue;
                }

                // Add assistant tool_use message to history
                try history.append(allocator, .{
                    .tool_use = .{ .tool_calls = tcs },
                });
                if (hooks.on_persist) |cb| cb(.{ .tool_use = .{ .tool_calls = tcs } });

                // Execute tools
                const tool_results = try allocator.alloc(ToolResult, tcs.len);
                defer allocator.free(tool_results);
                @memset(tool_results, .{ .tool_call_id = "", .content = "", .sub_agent_usage = null });

                if (config.silent) {
                    // Sequential execution for silent mode (no threads-inside-threads)
                    for (tcs, 0..) |tc, i| {
                        const raw_content = if (!tools.isAllowed(tc.function.name, effective_permission))
                            std.fmt.allocPrint(
                                allocator,
                                "Permission denied: {s} requires higher tool access.",
                                .{tc.function.name},
                            ) catch try allocator.dupe(u8, "Permission denied.")
                        else
                            tools.execute(allocator, tc);

                        const truncated = tools.truncateToolOutput(allocator, tc.function.name, raw_content);
                        const content = if (truncated.ptr != raw_content.ptr) blk: {
                            allocator.free(raw_content);
                            break :blk truncated;
                        } else raw_content;

                        tool_results[i] = .{
                            .tool_call_id = try allocator.dupe(u8, tc.id),
                            .content = content,
                        };
                    }
                } else {
                    // Parallel execution for terminal mode
                    try executeToolsParallel(allocator, resolved, tcs, tool_results, effective_permission, hooks);
                    // Stop spinner started by on_tool_calls hook
                    if (hooks.on_llm_end) |cb| cb();
                }

                // Check cancel after tool execution
                if (io.isCancelRequested()) {
                    if (hooks.on_cancel) |cb| cb();
                    // Still append results to history so LLM sees what happened
                    for (tool_results) |tr| {
                        if (tr.tool_call_id.len > 0) {
                            try history.append(allocator, .{
                                .tool_result = .{
                                    .tool_call_id = tr.tool_call_id,
                                    .content = tr.content,
                                },
                            });
                        }
                    }
                    return .{
                        .prompt_tokens = total_prompt,
                        .completion_tokens = total_completion,
                        .cancelled = true,
                    };
                }

                // Display tool results (terminal mode only)
                if (!config.silent) {
                    for (0..tcs.len) |i| {
                        if (hooks.on_tool_result) |cb| cb(tcs[i], tool_results[i].content);
                    }
                }

                // Emit sub-agent token usage
                if (hooks.on_tokens) |on_tok| {
                    for (tool_results) |tr| {
                        if (tr.sub_agent_usage) |usage| {
                            on_tok(.{
                                .prompt_tokens = @intCast(@min(usage.prompt_tokens, std.math.maxInt(u32))),
                                .completion_tokens = @intCast(@min(usage.completion_tokens, std.math.maxInt(u32))),
                            });
                        }
                    }
                }

                // Append results to history with truncation
                for (tool_results, 0..) |tr, i| {
                    const tool_name = if (i < tcs.len) tcs[i].function.name else "unknown";
                    const truncated = tools.truncateToolOutput(allocator, tool_name, tr.content);
                    const content = if (truncated.ptr != tr.content.ptr) blk: {
                        allocator.free(tr.content);
                        break :blk truncated;
                    } else tr.content;
                    try history.append(allocator, .{
                        .tool_result = .{
                            .tool_call_id = tr.tool_call_id,
                            .content = content,
                        },
                    });
                    if (hooks.on_persist) |cb| cb(.{
                        .tool_result = .{ .tool_call_id = tr.tool_call_id, .content = content },
                    });

                    // Record tool call hash for loop detection
                    const args = if (i < tcs.len) tcs[i].function.arguments else "";
                    loop_ring[loop_ring_count % LOOP_DETECTION_WINDOW] = hashToolSignature(tool_name, args);
                    loop_ring_count += 1;
                }

                // Loop detection
                if (detectLoop(&loop_ring, loop_ring_count)) {
                    if (hooks.on_loop_detected) |cb| {
                        if (cb()) |w| {
                            steering_queue.append(allocator, w) catch allocator.free(w);
                        }
                    } else {
                        // Default loop detection message
                        const warning = allocator.dupe(u8,
                            "[SYSTEM WARNING: You appear to be stuck in a loop, " ++
                            "repeating the same tool calls. Try a different approach, " ++
                            "read the error messages carefully, or ask the user for guidance.]",
                        ) catch null;
                        if (warning) |w| {
                            steering_queue.append(allocator, w) catch allocator.free(w);
                        }
                    }
                }
            },
        }
    }

    // Iteration limit reached
    return .{
        .prompt_tokens = total_prompt,
        .completion_tokens = total_completion,
        .hit_limit = true,
    };
}

/// Execute tools in parallel with spinner and cancel-aware join.
fn executeToolsParallel(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    tcs: []const message.ToolCall,
    tool_results: []ToolResult,
    permission: tools.PermissionLevel,
    hooks: Hooks,
) !void {
    // Indices of allowed tools that need execution
    const thread_indices = try allocator.alloc(usize, tcs.len);
    defer allocator.free(thread_indices);
    var thread_count: usize = 0;

    // First pass: check permissions, fill denied results
    for (tcs, 0..) |tc, i| {
        if (!tools.isAllowed(tc.function.name, permission)) {
            tool_results[i] = .{
                .tool_call_id = try allocator.dupe(u8, tc.id),
                .content = std.fmt.allocPrint(allocator, "Permission denied: {s} requires full tool access (safe-only mode active).", .{tc.function.name}) catch try allocator.dupe(u8, "Permission denied."),
            };
        } else {
            thread_indices[thread_count] = i;
            thread_count += 1;
        }
    }

    if (thread_count == 0) return;

    const threads = try allocator.alloc(?std.Thread, thread_count);
    defer allocator.free(threads);
    @memset(threads, null);

    const done_flags = try allocator.alloc(std.atomic.Value(bool), thread_count);
    defer allocator.free(done_flags);
    for (done_flags) |*f| f.* = std.atomic.Value(bool).init(false);

    for (thread_indices[0..thread_count], 0..) |idx, j| {
        threads[j] = std.Thread.spawn(.{}, executeToolThread, .{
            ToolExecContext{
                .allocator = allocator,
                .tc = tcs[idx],
                .resolved = resolved,
                .permission = permission,
            },
            &tool_results[idx],
            &done_flags[j],
        }) catch null;

        if (threads[j] == null) {
            executeToolThread(
                ToolExecContext{
                    .allocator = allocator,
                    .tc = tcs[idx],
                    .resolved = resolved,
                    .permission = permission,
                },
                &tool_results[idx],
                &done_flags[j],
            );
        }
    }

    // Cancel-aware join
    var all_done = false;
    while (!all_done) {
        all_done = true;
        for (done_flags[0..thread_count]) |*f| {
            if (!f.load(.acquire)) {
                all_done = false;
                break;
            }
        }
        if (!all_done) {
            if (io.isCancelRequested()) break;
            std.Thread.sleep(50_000_000); // 50ms
        }
    }

    // Join completed threads
    for (0..thread_count) |j| {
        if (done_flags[j].load(.acquire)) {
            if (threads[j]) |t| t.join();
        }
    }

    // Fill cancelled (incomplete) tool results
    if (!all_done) {
        for (thread_indices[0..thread_count], 0..) |idx, j| {
            if (!done_flags[j].load(.acquire)) {
                tool_results[idx] = .{
                    .tool_call_id = allocator.dupe(u8, tcs[idx].id) catch "",
                    .content = allocator.dupe(u8, "[Cancelled]") catch "",
                };
            }
        }
    }

    _ = hooks;
}

/// Thread entry point for parallel tool execution.
fn executeToolThread(ctx: ToolExecContext, result: *ToolResult, done_flag: *std.atomic.Value(bool)) void {
    defer done_flag.store(true, .release);

    if (std.mem.eql(u8, ctx.tc.function.name, "dispatch_agent")) {
        const task_text = extractTask(ctx.allocator, ctx.tc.function.arguments) orelse {
            result.content = ctx.allocator.dupe(u8, "Error: missing or invalid 'task' argument") catch "";
            result.tool_call_id = ctx.allocator.dupe(u8, ctx.tc.id) catch "";
            return;
        };
        defer ctx.allocator.free(task_text);

        const sub_result = agent.run(ctx.allocator, ctx.resolved, task_text, ctx.permission);
        result.content = sub_result.text;
        result.sub_agent_usage = .{
            .prompt_tokens = sub_result.total_prompt_tokens,
            .completion_tokens = sub_result.total_completion_tokens,
        };
    } else {
        result.content = tools.execute(ctx.allocator, ctx.tc);
    }
    result.tool_call_id = ctx.allocator.dupe(u8, ctx.tc.id) catch "";
}

/// Extract the "task" string from dispatch_agent's JSON arguments.
pub fn extractTask(allocator: std.mem.Allocator, args_json: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get("task") orelse return null;
    if (val != .string or val.string.len == 0) return null;
    return allocator.dupe(u8, val.string) catch null;
}

/// Free a CompletionResult response variant.
fn freeResponse(allocator: std.mem.Allocator, response: http_client.CompletionResult.ResponseKind) void {
    switch (response) {
        .text => |t| allocator.free(t),
        .tool_calls => |tcs| {
            for (tcs) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.function.name);
                allocator.free(tc.function.arguments);
            }
            allocator.free(tcs);
        },
        .http_error => |detail| allocator.free(detail.message),
    }
}

/// Hash a tool call signature (name + args) for loop detection.
pub fn hashToolSignature(name: []const u8, args: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    hasher.update("|");
    hasher.update(args);
    return hasher.final();
}

/// Detect repeating patterns in a ring buffer of tool call hashes.
pub fn detectLoop(ring: []const u64, count: usize) bool {
    const window = @min(count, LOOP_DETECTION_WINDOW);
    if (window < 4) return false;

    const ring_len = ring.len;

    var recent: [LOOP_DETECTION_WINDOW]u64 = undefined;
    var i: usize = 0;
    while (i < window) : (i += 1) {
        const idx = (count - window + i) % ring_len;
        recent[i] = ring[idx];
    }

    for ([_]usize{ 1, 2, 3 }) |pattern_len| {
        if (window % pattern_len != 0) continue;
        if (window / pattern_len < 2) continue;

        const pattern = recent[0..pattern_len];
        var all_match = true;
        var chunk: usize = pattern_len;
        while (chunk < window) : (chunk += pattern_len) {
            for (0..pattern_len) |k| {
                if (recent[chunk + k] != pattern[k]) {
                    all_match = false;
                    break;
                }
            }
            if (!all_match) break;
        }
        if (all_match) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────

test "detectLoop: no loop with few calls" {
    var ring: [LOOP_DETECTION_WINDOW]u64 = undefined;
    @memset(&ring, 0);
    try std.testing.expect(!detectLoop(&ring, 0));
    try std.testing.expect(!detectLoop(&ring, 3));
}

test "detectLoop: detects pattern length 1" {
    var ring: [LOOP_DETECTION_WINDOW]u64 = undefined;
    @memset(&ring, 42);
    try std.testing.expect(detectLoop(&ring, 10));
}

test "detectLoop: detects pattern length 2" {
    var ring: [LOOP_DETECTION_WINDOW]u64 = undefined;
    var i: usize = 0;
    while (i < LOOP_DETECTION_WINDOW) : (i += 1) {
        ring[i] = if (i % 2 == 0) 100 else 200;
    }
    try std.testing.expect(detectLoop(&ring, 10));
}

test "detectLoop: no loop with varied calls" {
    var ring: [LOOP_DETECTION_WINDOW]u64 = undefined;
    var i: usize = 0;
    while (i < LOOP_DETECTION_WINDOW) : (i += 1) {
        ring[i] = i * 7 + 13;
    }
    try std.testing.expect(!detectLoop(&ring, 10));
}

test "hashToolSignature: deterministic" {
    const h1 = hashToolSignature("read_file", "{\"path\":\"foo.zig\"}");
    const h2 = hashToolSignature("read_file", "{\"path\":\"foo.zig\"}");
    const h3 = hashToolSignature("read_file", "{\"path\":\"bar.zig\"}");
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "extractTask: valid JSON" {
    const alloc = std.testing.allocator;
    const result = extractTask(alloc, "{\"task\":\"analyze this file\"}");
    try std.testing.expect(result != null);
    defer alloc.free(result.?);
    try std.testing.expectEqualStrings("analyze this file", result.?);
}

test "extractTask: missing task key" {
    const alloc = std.testing.allocator;
    try std.testing.expect(extractTask(alloc, "{\"other\":\"value\"}") == null);
}

test "extractTask: invalid JSON" {
    const alloc = std.testing.allocator;
    try std.testing.expect(extractTask(alloc, "not json") == null);
}

test "extractTask: empty task" {
    const alloc = std.testing.allocator;
    try std.testing.expect(extractTask(alloc, "{\"task\":\"\"}") == null);
}

test "NodeResult: default values" {
    const result = NodeResult{};
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(u64, 0), result.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 0), result.completion_tokens);
    try std.testing.expect(!result.cancelled);
    try std.testing.expect(!result.hit_limit);
}
