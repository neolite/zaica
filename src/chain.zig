/// Chain orchestrator — multi-step LLM pipelines from .chain.md files.
///
/// A chain is a sequence of named steps, each with its own system prompt,
/// tool set, and iteration limit. Steps execute top-to-bottom, with
/// `{task}` (user input) and `{previous}` (prior step output) substituted
/// into each step's prompt.
const std = @import("std");
const config_types = @import("config/types.zig");
const message = @import("client/message.zig");
const tools_mod = @import("tools.zig");
const node = @import("node.zig");
const io = @import("io.zig");

/// A single step in a chain pipeline.
pub const ChainStep = struct {
    name: []const u8,
    prompt: []const u8,
    tools: ?[]const u8 = null,
    max_iterations: u16 = 10,
};

/// A parsed chain definition.
pub const Chain = struct {
    name: []const u8,
    steps: []const ChainStep,
};

pub const ParseError = error{
    EmptyChain,
    EmptyPrompt,
    OutOfMemory,
    InvalidConfig,
};

/// Parse a chain definition from markdown content.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) ParseError!Chain {
    var name: []const u8 = "unnamed";
    var body = content;

    // Parse frontmatter
    if (std.mem.startsWith(u8, content, "---")) {
        if (std.mem.indexOf(u8, content[3..], "---")) |end| {
            const fm = content[3 .. 3 + end];
            body = content[3 + end + 3 ..];
            // Extract name from frontmatter
            var fm_lines = std.mem.splitScalar(u8, fm, '\n');
            while (fm_lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "name:")) {
                    const val = std.mem.trim(u8, trimmed["name:".len..], " \t");
                    if (val.len > 0) name = val;
                }
            }
        }
    }

    // Split by "## " — each section is a step
    var steps_list: std.ArrayList(ChainStep) = .empty;

    // Strip leading whitespace so "## " at start is handled
    const trimmed_body = std.mem.trimLeft(u8, body, " \t\r\n");

    var sections = std.mem.splitSequence(u8, trimmed_body, "\n## ");
    // First element: either preamble (skip) or first step (if body starts with "## ")
    if (sections.next()) |first| {
        // If body started with "## ", first element is the step content (without "## " prefix)
        if (std.mem.startsWith(u8, trimmed_body, "## ")) {
            const step = try parseStep(first["## ".len..]);
            if (step.prompt.len == 0) return error.EmptyPrompt;
            steps_list.append(allocator, step) catch return error.OutOfMemory;
        }
        // Otherwise it's preamble text — skip
    }

    while (sections.next()) |section| {
        const step = try parseStep(section);
        if (step.prompt.len == 0) return error.EmptyPrompt;
        steps_list.append(allocator, step) catch return error.OutOfMemory;
    }

    if (steps_list.items.len == 0) return error.EmptyChain;

    return .{
        .name = name,
        .steps = steps_list.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// Parse a single step section (content after "## ").
fn parseStep(section: []const u8) ParseError!ChainStep {
    var step = ChainStep{ .name = "", .prompt = "" };

    var lines = std.mem.splitScalar(u8, section, '\n');

    // First line is the step name
    if (lines.next()) |name_line| {
        step.name = std.mem.trim(u8, name_line, " \t\r");
    }

    // Parse config lines until empty line
    var prompt_start: usize = 0;
    var found_empty = false;
    var offset: usize = 0;

    // Skip past the name line
    offset = step.name.len + 1; // +1 for \n

    var config_lines = std.mem.splitScalar(u8, section[offset..], '\n');
    var config_offset: usize = 0;
    while (config_lines.next()) |line| {
        config_offset += line.len + 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            found_empty = true;
            prompt_start = offset + config_offset;
            break;
        }
        // Try to parse as config key
        if (std.mem.startsWith(u8, trimmed, "tools:")) {
            const val = std.mem.trim(u8, trimmed["tools:".len..], " \t");
            if (val.len > 0) step.tools = val;
        } else if (std.mem.startsWith(u8, trimmed, "max_iterations:")) {
            const val = std.mem.trim(u8, trimmed["max_iterations:".len..], " \t");
            step.max_iterations = std.fmt.parseInt(u16, val, 10) catch 10;
        } else {
            // Not a config line — this IS the prompt start
            prompt_start = offset + config_offset - line.len - 1;
            found_empty = true;
            break;
        }
    }

    if (!found_empty) {
        // All lines were config, no prompt content
        prompt_start = section.len;
    }

    if (prompt_start < section.len) {
        step.prompt = std.mem.trim(u8, section[prompt_start..], " \t\r\n");
    }

    return step;
}

/// Parse a chain from a file path.
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Chain {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    return parse(allocator, content);
}

/// Substitute `{task}` and `{previous}` in a template string.
pub fn substituteVars(
    allocator: std.mem.Allocator,
    template: []const u8,
    task: []const u8,
    previous: []const u8,
) ![]const u8 {
    // Count output size
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (i + 6 <= template.len and std.mem.eql(u8, template[i .. i + 6], "{task}")) {
            result.appendSlice(allocator, task) catch return error.OutOfMemory;
            i += 6;
        } else if (i + 10 <= template.len and std.mem.eql(u8, template[i .. i + 10], "{previous}")) {
            result.appendSlice(allocator, previous) catch return error.OutOfMemory;
            i += 10;
        } else {
            result.append(allocator, template[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Resolve a comma-separated tool list into filtered ToolDefs.
/// Returns null (= use all tools) if tools_str is null.
pub fn resolveTools(tools_str: ?[]const u8) []const message.ToolDef {
    const str = tools_str orelse return tools_mod.all_tools;

    // Filter all_tools to only include named ones
    // Use a static buffer since tool count is small and fixed
    const S = struct {
        var filtered: [6]message.ToolDef = undefined;
    };
    var count: usize = 0;

    for (tools_mod.all_tools) |tool| {
        // Check if this tool name appears in the comma-separated list
        var names = std.mem.splitScalar(u8, str, ',');
        while (names.next()) |name_raw| {
            const name = std.mem.trim(u8, name_raw, " \t");
            if (std.mem.eql(u8, tool.function.name, name)) {
                S.filtered[count] = tool;
                count += 1;
                break;
            }
        }
    }

    return S.filtered[0..count];
}

/// Determine the highest risk level across all chain steps (for permission prompt).
pub fn chainMaxRisk(chain: Chain) tools_mod.ToolRisk {
    var max_risk: tools_mod.ToolRisk = .safe;
    for (chain.steps) |step| {
        const step_tools = resolveTools(step.tools);
        for (step_tools) |tool| {
            const risk = tools_mod.toolRisk(tool.function.name);
            switch (risk) {
                .dangerous => return .dangerous,
                .write => max_risk = .write,
                .safe => {},
            }
        }
    }
    return max_risk;
}

/// Execute a chain pipeline.
pub fn execute(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    chain: Chain,
    task: []const u8,
    permission: tools_mod.PermissionLevel,
) !?[]const u8 {
    const step_count = chain.steps.len;

    // Print chain header
    io.printOut("\x1b[95m\xe2\x9c\xa6\x1b[0m Chain: \x1b[1m{s}\x1b[0m ({d} step{s})\r\n\r\n", .{
        chain.name,
        step_count,
        if (step_count != 1) "s" else "",
    }) catch {};

    var previous: []const u8 = "";
    var total_prompt: u64 = 0;
    var total_completion: u64 = 0;

    for (chain.steps, 0..) |step, i| {
        if (io.isCancelRequested()) break;

        // Print step header
        io.printOut("\x1b[1m\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81 {s} ({d}/{d}) \xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\x1b[0m\r\n", .{
            step.name,
            i + 1,
            step_count,
        }) catch {};

        // Substitute variables in prompt
        const prompt = try substituteVars(allocator, step.prompt, task, previous);
        defer allocator.free(prompt);

        // Resolve tool set for this step
        const step_tools = resolveTools(step.tools);

        // Build history for this step
        var history: std.ArrayList(message.ChatMessage) = .empty;
        defer {
            for (history.items) |msg| {
                // Don't free system prompt (it's the substituted prompt, freed by defer above)
                if (msg == .text and msg.text.role == .system) continue;
                // Don't free the user task message (it's the original task slice)
                if (msg == .text and msg.text.role == .user and std.mem.eql(u8, msg.text.content, task)) continue;
                message.freeMessage(allocator, msg);
            }
            history.deinit(allocator);
        }

        // System prompt = substituted step prompt
        try history.append(allocator, .{
            .text = .{ .role = .system, .content = prompt },
        });
        // User message = original task
        try history.append(allocator, .{
            .text = .{ .role = .user, .content = task },
        });

        // Run the agentic loop with basic hooks for spinner management
        const result = node.run(allocator, resolved, .{
            .system_prompt = prompt,
            .tool_defs = step_tools,
            .max_iterations = step.max_iterations,
            .permission = permission,
            .silent = false,
        }, &history, .{
            .on_llm_start = &chainLlmStart,
            .on_llm_end = &chainLlmEnd,
        });

        total_prompt += result.prompt_tokens;
        total_completion += result.completion_tokens;

        if (result.errored) {
            io.printOut("\r\n\x1b[31m\xe2\x9c\xa6 Step '{s}' encountered an internal error \xe2\x80\x94 aborting chain\x1b[0m\r\n", .{step.name}) catch {};
            if (previous.len > 0) allocator.free(previous);
            return null;
        }

        if (result.cancelled) {
            io.printOut("\r\n\x1b[31m\xe2\x8a\x98 Chain cancelled\x1b[0m\r\n", .{}) catch {};
            return null;
        }

        if (result.text) |text| {
            io.printOut("\r\n", .{}) catch {};
            // Free previous step output (if allocated)
            if (previous.len > 0) allocator.free(previous);
            previous = text;
        } else if (result.hit_limit) {
            // Iteration limit reached — try to extract last assistant text from history
            const fallback = blk: {
                if (extractLastAssistantText(&history)) |text| {
                    break :blk allocator.dupe(u8, text) catch null;
                }
                break :blk collectToolResults(allocator, &history);
            };
            if (fallback) |text| {
                io.printOut("\r\n\x1b[33m\xe2\x9c\xa6 Step '{s}' hit iteration limit, using partial output\x1b[0m\r\n", .{step.name}) catch {};
                if (previous.len > 0) allocator.free(previous);
                previous = text;
            } else {
                io.printOut("\r\n\x1b[33m\xe2\x9c\xa6 Step '{s}' produced no output — aborting chain\x1b[0m\r\n", .{step.name}) catch {};
                if (previous.len > 0) allocator.free(previous);
                return null;
            }
        } else {
            // No output and no hit_limit — abort chain
            io.printOut("\r\n\x1b[33m\xe2\x9c\xa6 Step '{s}' produced no output — aborting chain\x1b[0m\r\n", .{step.name}) catch {};
            if (previous.len > 0) allocator.free(previous);
            return null;
        }
    }

    // Print completion summary
    const total_tokens = total_prompt + total_completion;
    io.printOut("\x1b[95m\xe2\x97\x87\x1b[0m Chain complete ({d}/{d} steps, ", .{ chain.steps.len, chain.steps.len }) catch {};
    if (total_tokens > 1000) {
        io.printOut("{d}.{d}k", .{ total_tokens / 1000, (total_tokens % 1000) / 100 }) catch {};
    } else {
        io.printOut("{d}", .{total_tokens}) catch {};
    }
    io.printOut(" tokens)\r\n", .{}) catch {};

    return previous;
}

/// Print a dry-run summary of a chain.
pub fn printDryRun(chain: Chain) void {
    io.printOut("Chain: \x1b[1m{s}\x1b[0m ({d} step{s})\r\n", .{
        chain.name,
        chain.steps.len,
        if (chain.steps.len != 1) "s" else "",
    }) catch {};

    for (chain.steps, 0..) |step, i| {
        io.printOut("  {d}. \x1b[1m{s}\x1b[0m", .{ i + 1, step.name }) catch {};

        // Tool list
        if (step.tools) |t| {
            io.printOut("  [{s}]", .{t}) catch {};
        } else {
            io.printOut("  [all tools]", .{}) catch {};
        }

        io.printOut("  max_iter={d}\r\n", .{step.max_iterations}) catch {};
    }
}

// ── Chain hooks ──────────────────────────────────────────────────────

fn chainLlmStart() void {
    io.startSpinner("Thinking...");
}

fn chainLlmEnd() void {
    io.stopSpinner();
}

/// Walk history backwards to find the last assistant text message.
fn extractLastAssistantText(history: *const std.ArrayList(message.ChatMessage)) ?[]const u8 {
    var i: usize = history.items.len;
    while (i > 0) {
        i -= 1;
        const msg = history.items[i];
        if (msg == .text and msg.text.role == .assistant and msg.text.content.len > 0) {
            return msg.text.content;
        }
    }
    return null;
}

/// Collect tool results from history as a concatenated summary.
/// Used as fallback when hit_limit is reached but no assistant text was produced
/// (e.g., scout step that spent all iterations gathering data via tools).
/// Caller owns the returned slice.
fn collectToolResults(allocator: std.mem.Allocator, history: *const std.ArrayList(message.ChatMessage)) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (history.items) |msg| {
        if (msg == .tool_result and msg.tool_result.content.len > 0) {
            if (buf.items.len > 0) {
                buf.appendSlice(allocator, "\n\n") catch return null;
            }
            buf.appendSlice(allocator, msg.tool_result.content) catch return null;
        }
    }
    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

// ── Tests ────────────────────────────────────────────────────────────

test "parse: single step" {
    const content =
        \\## scout
        \\
        \\Analyze the codebase for {task}.
    ;
    const parsed = try parse(std.testing.allocator, content);
    defer std.testing.allocator.free(parsed.steps);
    try std.testing.expectEqual(@as(usize, 1), parsed.steps.len);
    try std.testing.expectEqualStrings("scout", parsed.steps[0].name);
    try std.testing.expectEqualStrings("unnamed", parsed.name);
    try std.testing.expect(parsed.steps[0].tools == null);
    try std.testing.expectEqual(@as(u16, 10), parsed.steps[0].max_iterations);
    // Prompt should contain the template variable
    try std.testing.expect(std.mem.indexOf(u8, parsed.steps[0].prompt, "{task}") != null);
}

test "parse: full chain" {
    const content =
        \\---
        \\name: code-review
        \\---
        \\
        \\## scout
        \\tools: read_file, search_files
        \\max_iterations: 5
        \\
        \\Analyze the codebase for {task}.
        \\
        \\## planner
        \\max_iterations: 3
        \\
        \\Based on: {previous}
        \\Plan for: {task}
        \\
        \\## coder
        \\
        \\Implement: {previous}
    ;
    const parsed = try parse(std.testing.allocator, content);
    defer std.testing.allocator.free(parsed.steps);
    try std.testing.expectEqualStrings("code-review", parsed.name);
    try std.testing.expectEqual(@as(usize, 3), parsed.steps.len);
    try std.testing.expectEqualStrings("scout", parsed.steps[0].name);
    try std.testing.expectEqualStrings("planner", parsed.steps[1].name);
    try std.testing.expectEqualStrings("coder", parsed.steps[2].name);
}

test "parse: config keys" {
    const content =
        \\## step1
        \\tools: read_file, search_files, list_files
        \\max_iterations: 5
        \\
        \\Do something.
    ;
    const parsed = try parse(std.testing.allocator, content);
    defer std.testing.allocator.free(parsed.steps);
    try std.testing.expectEqualStrings("read_file, search_files, list_files", parsed.steps[0].tools.?);
    try std.testing.expectEqual(@as(u16, 5), parsed.steps[0].max_iterations);
}

test "parse: empty prompt error" {
    const content =
        \\## empty_step
        \\tools: read_file
    ;
    const result = parse(std.testing.allocator, content);
    try std.testing.expectError(error.EmptyPrompt, result);
}

test "substituteVars: task and previous" {
    const alloc = std.testing.allocator;
    const result = try substituteVars(alloc, "Do {task}. Based on: {previous}.", "add logging", "found 3 files");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Do add logging. Based on: found 3 files.", result);
}

test "substituteVars: no vars" {
    const alloc = std.testing.allocator;
    const result = try substituteVars(alloc, "plain text", "task", "prev");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

test "substituteVars: empty previous" {
    const alloc = std.testing.allocator;
    const result = try substituteVars(alloc, "Do {task}. Prev: {previous}.", "test", "");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Do test. Prev: .", result);
}

test "resolveTools: null returns all" {
    const resolved = resolveTools(null);
    try std.testing.expectEqual(@as(usize, 6), resolved.len);
}

test "resolveTools: filters correctly" {
    const resolved = resolveTools("read_file, search_files");
    try std.testing.expectEqual(@as(usize, 2), resolved.len);
    try std.testing.expectEqualStrings("read_file", resolved[0].function.name);
    try std.testing.expectEqualStrings("search_files", resolved[1].function.name);
}

test "parse: empty chain error" {
    const result = parse(std.testing.allocator, "just some text without steps");
    try std.testing.expectError(error.EmptyChain, result);
}
