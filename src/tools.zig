const std = @import("std");
const message = @import("client/message.zig");
const io = @import("io.zig");
const skills = @import("skills.zig");

/// Tool risk level for permission control.
pub const ToolRisk = enum {
    safe,       // read_file, list_files, search_files — read-only
    write,      // write_file — modifies files
    dangerous,  // execute_bash — arbitrary code execution
};

/// Get the risk level of a tool by name.
pub fn toolRisk(name: []const u8) ToolRisk {
    if (std.mem.eql(u8, name, "execute_bash")) return .dangerous;
    if (std.mem.eql(u8, name, "dispatch_agent")) return .dangerous;
    if (std.mem.eql(u8, name, "write_file")) return .write;
    return .safe;
}

/// Permission level granted by the user.
pub const PermissionLevel = enum {
    all,        // all tools allowed
    safe_only,  // only read-only tools
    none,       // nothing allowed
};

/// Check if a tool is allowed under the given permission level.
pub fn isAllowed(name: []const u8, level: PermissionLevel) bool {
    return switch (level) {
        .all => true,
        .safe_only => toolRisk(name) == .safe,
        .none => false,
    };
}

/// Map internal tool names to CC-style display names.
pub fn displayToolName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "execute_bash")) return "Bash";
    if (std.mem.eql(u8, name, "read_file")) return "Read";
    if (std.mem.eql(u8, name, "write_file")) return "Write";
    if (std.mem.eql(u8, name, "list_files")) return "List";
    if (std.mem.eql(u8, name, "search_files")) return "Search";
    if (std.mem.eql(u8, name, "dispatch_agent")) return "Agent";
    if (std.mem.eql(u8, name, "load_skill")) return "Skill";
    return name;
}

/// Print a formatted list of available tools to stdout.
pub fn printToolList() void {
    io.writeText("\n") catch {};
    io.writeOut("\x1b[1mAvailable tools:\x1b[0m\r\n") catch {};
    io.writeOut("\r\n") catch {};
    for (all_tools) |tool| {
        const risk = toolRisk(tool.function.name);
        const color = switch (risk) {
            .safe => "\x1b[32m",      // green
            .write => "\x1b[33m",     // yellow
            .dangerous => "\x1b[31m", // red
        };
        const badge = switch (risk) {
            .safe => "safe",
            .write => "write",
            .dangerous => "dangerous",
        };
        io.writeOut("  ") catch {};
        io.writeOut(color) catch {};
        io.writeOut("\xe2\x9c\xa6 ") catch {}; // ✦
        io.writeOut(displayToolName(tool.function.name)) catch {};
        io.writeOut("\x1b[0m ") catch {};
        io.writeOut("\x1b[2m") catch {};
        io.writeOut(badge) catch {};
        io.writeOut("\x1b[0m\r\n") catch {};
        io.writeOut("    ") catch {};
        io.writeText(tool.function.description) catch {};
        io.writeOut("\r\n") catch {};
    }
    io.writeOut("\r\n") catch {};
}

/// All tool definitions stored in a fixed-size array.
/// First 5 are standard tools, [5] is dispatch_agent (excluded from sub-agent tools).
const tools_array = [7]message.ToolDef{
    .{ .function = .{
        .name = "execute_bash",
        .description = "Execute a bash command and return stdout+stderr. Has a 10-second timeout. Do NOT run interactive programs (editors, REPLs, servers) or 'zig build run' — they will be killed. Use for short commands: ls, cat, grep, git, zig build, etc.",
        .parameters =
        \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute (non-interactive, max 10s)"}},"required":["command"]}
        ,
    } },
    .{ .function = .{
        .name = "read_file",
        .description = "Read the contents of a file at the given path.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to read"}},"required":["path"]}
        ,
    } },
    .{ .function = .{
        .name = "write_file",
        .description = "Write content to a file at the given path, creating it if needed and overwriting if it exists.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to write"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"]}
        ,
    } },
    .{ .function = .{
        .name = "list_files",
        .description = "List files and directories at the given path.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Directory path to list (default: current directory)"}},"required":[]}
        ,
    } },
    .{ .function = .{
        .name = "search_files",
        .description = "Search for a pattern in files using grep. Returns matching lines with file paths and line numbers.",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern (grep regex)"},"path":{"type":"string","description":"Directory to search in (default: current directory)"}},"required":["pattern"]}
        ,
    } },
    .{ .function = .{
        .name = "dispatch_agent",
        .description = "Dispatch an autonomous sub-agent to work on a specific task in parallel. " ++
            "The sub-agent has access to file and bash tools and works independently. " ++
            "Use when you need to perform multiple independent tasks simultaneously. " ++
            "Each sub-agent runs its own tool loop and returns a text result.",
        .parameters =
        \\{"type":"object","properties":{"task":{"type":"string","description":"A clear, self-contained task description for the sub-agent"}},"required":["task"]}
        ,
    } },
    .{ .function = .{
        .name = "load_skill",
        .description = "Load a skill's full instructions by name. Use when you need specialized knowledge for a domain listed in the available-skills section of your system prompt.",
        .parameters =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name from the available-skills list"}},"required":["name"]}
        ,
    } },
};

/// All tool definitions for the main agent (includes dispatch_agent + load_skill).
pub const all_tools: []const message.ToolDef = &tools_array;

/// Tool definitions for sub-agents — excludes dispatch_agent and load_skill.
pub const sub_agent_tools: []const message.ToolDef = tools_array[0..5];

/// Skill list pointer — set by the REPL at startup so load_skill can access it.
var active_skills: []const skills.SkillInfo = &.{};

/// Set the active skills list for load_skill tool execution.
pub fn setActiveSkills(skill_list: []const skills.SkillInfo) void {
    active_skills = skill_list;
}

/// Execute a tool call and return the result as a string.
/// Errors are returned as error description strings (so the LLM can handle them).
pub fn execute(allocator: std.mem.Allocator, tc: message.ToolCall) []const u8 {
    return executeInner(allocator, tc) catch |err| {
        return std.fmt.allocPrint(allocator, "Error executing {s}: {}", .{ tc.function.name, err }) catch "Error: out of memory";
    };
}

fn executeInner(allocator: std.mem.Allocator, tc: message.ToolCall) ![]const u8 {
    if (std.mem.eql(u8, tc.function.name, "execute_bash")) {
        return executeBash(allocator, tc.function.arguments);
    } else if (std.mem.eql(u8, tc.function.name, "read_file")) {
        return readFile(allocator, tc.function.arguments);
    } else if (std.mem.eql(u8, tc.function.name, "write_file")) {
        return writeFile(allocator, tc.function.arguments);
    } else if (std.mem.eql(u8, tc.function.name, "list_files")) {
        return listFiles(allocator, tc.function.arguments);
    } else if (std.mem.eql(u8, tc.function.name, "search_files")) {
        return searchFiles(allocator, tc.function.arguments);
    } else if (std.mem.eql(u8, tc.function.name, "load_skill")) {
        return executeLoadSkill(allocator, tc.function.arguments);
    } else {
        return std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tc.function.name});
    }
}

// ── Tool implementations ────────────────────────────────────────────

/// Timeout for bash commands in seconds. Set via setBashTimeout().
var bash_timeout_secs: u32 = 30;

/// Set the bash command timeout (called from repl.zig at startup).
pub fn setBashTimeout(secs: u32) void {
    bash_timeout_secs = secs;
}

fn executeBash(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const args = try parseArgs(allocator, args_json);
    defer args.deinit();
    const command = getStr(args, "command") orelse return try allocator.dupe(u8, "Error: missing 'command' argument");
    return runBashWithTimeout(allocator, command, bash_timeout_secs);
}

/// Run a bash command with a timeout. Exposed separately so tests can use short timeouts.
fn runBashWithTimeout(allocator: std.mem.Allocator, command: []const u8, timeout_secs: u32) ![]const u8 {
    // Wrap in a bash timeout with process tree kill and stdin closed:
    // - </dev/null: interactive programs get EOF on stdin and exit immediately
    // - pkill -9 -P: kills child processes (e.g. binary spawned by `zig build run`)
    // - kill -9 $PID: kills the top-level process
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "/bin/bash -c '( {s} ) </dev/null & PID=$!; (sleep {d} && pkill -9 -P $PID 2>/dev/null; kill -9 $PID 2>/dev/null) & TIMER=$!; wait $PID 2>/dev/null; STATUS=$?; kill $TIMER 2>/dev/null; wait $TIMER 2>/dev/null; exit $STATUS'",
        .{ command, timeout_secs },
    );
    defer allocator.free(wrapped);

    const result = try std.process.Child.run(.{
        .argv = &.{ "/bin/bash", "-c", wrapped },
        .allocator = allocator,
        .max_output_bytes = 1024 * 1024, // 1MB
    });
    defer allocator.free(result.stderr);

    // Check if killed by signal (exit code 137 = SIGKILL)
    const was_killed = switch (result.term) {
        .Signal => true,
        .Exited => |code| code == 137,
        else => false,
    };

    if (was_killed) {
        if (result.stdout.len > 0) {
            const combined = try std.fmt.allocPrint(
                allocator,
                "{s}\n--- TIMEOUT: command killed after {d}s ---",
                .{ result.stdout, timeout_secs },
            );
            allocator.free(result.stdout);
            return combined;
        }
        allocator.free(result.stdout);
        return try std.fmt.allocPrint(
            allocator,
            "Error: command timed out after {d} seconds and was killed.",
            .{timeout_secs},
        );
    }

    // Combine stdout and stderr
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0) {
            const combined = try std.fmt.allocPrint(allocator, "{s}\n--- stderr ---\n{s}", .{ result.stdout, result.stderr });
            allocator.free(result.stdout);
            return combined;
        }
        allocator.free(result.stdout);
        return try allocator.dupe(u8, result.stderr);
    }
    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return try allocator.dupe(u8, "(no output)");
    }
    return result.stdout;
}

fn readFile(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const args = try parseArgs(allocator, args_json);
    defer args.deinit();
    const path = getStr(args, "path") orelse return try allocator.dupe(u8, "Error: missing 'path' argument");

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening {s}: {}", .{ path, err });
    };
    defer file.close();

    return file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        return std.fmt.allocPrint(allocator, "Error reading {s}: {}", .{ path, err });
    };
}

fn writeFile(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const args = try parseArgs(allocator, args_json);
    defer args.deinit();
    const path = getStr(args, "path") orelse return try allocator.dupe(u8, "Error: missing 'path' argument");
    const content = getStr(args, "content") orelse return try allocator.dupe(u8, "Error: missing 'content' argument");

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error creating {s}: {}", .{ path, err });
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return std.fmt.allocPrint(allocator, "Error writing {s}: {}", .{ path, err });
    };

    return std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ content.len, path });
}

fn listFiles(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const args = try parseArgs(allocator, args_json);
    defer args.deinit();
    const path = getStr(args, "path") orelse ".";

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening directory {s}: {}", .{ path, err });
    };
    defer dir.close();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (count > 0) try writer.writeByte('\n');
        try writer.writeAll(entry.name);
        if (entry.kind == .directory) try writer.writeByte('/');
        count += 1;
    }

    if (count == 0) {
        return try allocator.dupe(u8, "(empty directory)");
    }
    return try buf.toOwnedSlice(allocator);
}

fn searchFiles(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const args = try parseArgs(allocator, args_json);
    defer args.deinit();
    const pattern = getStr(args, "pattern") orelse return try allocator.dupe(u8, "Error: missing 'pattern' argument");
    const path = getStr(args, "path") orelse ".";

    const result = std.process.Child.run(.{
        .argv = &.{ "/usr/bin/grep", "-rn", "--include=*", pattern, path },
        .allocator = allocator,
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error running grep: {}", .{err});
    };
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return try allocator.dupe(u8, "No matches found.");
    }
    return result.stdout;
}

fn executeLoadSkill(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const args = try parseArgs(allocator, args_json);
    defer args.deinit();
    const name = getStr(args, "name") orelse return try allocator.dupe(u8, "Error: missing 'name' argument");

    if (skills.loadSkill(active_skills, name)) |content| {
        return try allocator.dupe(u8, content);
    }
    return std.fmt.allocPrint(allocator, "Skill not found: '{s}'. Check the available-skills list in your system prompt.", .{name});
}

// ── JSON arg parsing helpers ─────────────────────────────────────────

const ParsedArgs = std.json.Parsed(std.json.Value);

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !ParsedArgs {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn getStr(parsed: ParsedArgs, key: []const u8) ?[]const u8 {
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

// ── Output truncation (Attractor-spec aligned) ──────────────────────

/// Per-tool output limits for LLM context (Attractor coding-agent-loop-spec defaults).
const OutputLimits = struct {
    max_chars: usize,
    max_lines: usize,
};

/// Get output limits for a tool by name.
fn outputLimits(name: []const u8) OutputLimits {
    if (std.mem.eql(u8, name, "read_file")) return .{ .max_chars = 50_000, .max_lines = 0 };
    if (std.mem.eql(u8, name, "execute_bash")) return .{ .max_chars = 30_000, .max_lines = 256 };
    if (std.mem.eql(u8, name, "search_files")) return .{ .max_chars = 20_000, .max_lines = 200 };
    if (std.mem.eql(u8, name, "list_files")) return .{ .max_chars = 20_000, .max_lines = 500 };
    if (std.mem.eql(u8, name, "write_file")) return .{ .max_chars = 1_000, .max_lines = 0 };
    if (std.mem.eql(u8, name, "dispatch_agent")) return .{ .max_chars = 50_000, .max_lines = 0 };
    if (std.mem.eql(u8, name, "load_skill")) return .{ .max_chars = 50_000, .max_lines = 0 };
    return .{ .max_chars = 30_000, .max_lines = 0 };
}

/// Truncate tool output using head/tail strategy, then line-limit.
/// Returns original slice if within limits, or an allocator-owned truncated copy.
/// The caller must free the result ONLY if it differs from the input.
pub fn truncateToolOutput(allocator: std.mem.Allocator, tool_name: []const u8, output: []const u8) []const u8 {
    if (output.len == 0) return output;
    const limits = outputLimits(tool_name);

    // Step 1: Character truncation (head/tail)
    var working = output;
    var char_truncated = false;
    if (working.len > limits.max_chars) {
        const half = limits.max_chars / 2;
        const head = working[0..half];
        const tail = working[working.len - half ..];
        const removed = working.len - limits.max_chars;
        const result = std.fmt.allocPrint(
            allocator,
            "{s}\n\n[WARNING: output truncated — {d} characters removed from middle]\n\n{s}",
            .{ head, removed, tail },
        ) catch return output;
        working = result;
        char_truncated = true;
    }

    // Step 2: Line truncation
    if (limits.max_lines > 0) {
        var line_count: usize = 0;
        for (working) |c| {
            if (c == '\n') line_count += 1;
        }
        if (line_count > limits.max_lines) {
            const half_lines = limits.max_lines / 2;
            // Find end of first half_lines lines
            var head_end: usize = 0;
            var count: usize = 0;
            for (working, 0..) |c, idx| {
                if (c == '\n') {
                    count += 1;
                    if (count == half_lines) {
                        head_end = idx + 1;
                        break;
                    }
                }
            }
            // Find start of last half_lines lines
            var tail_start: usize = working.len;
            count = 0;
            var j: usize = working.len;
            while (j > 0) {
                j -= 1;
                if (working[j] == '\n') {
                    count += 1;
                    if (count == half_lines) {
                        tail_start = j + 1;
                        break;
                    }
                }
            }
            if (head_end < tail_start) {
                const removed_lines = line_count - limits.max_lines;
                const result = std.fmt.allocPrint(
                    allocator,
                    "{s}\n[WARNING: {d} lines removed from middle]\n{s}",
                    .{ working[0..head_end], removed_lines, working[tail_start..] },
                ) catch return working;
                if (char_truncated) allocator.free(working);
                return result;
            }
        }
    }

    return working;
}

// ── Tests ────────────────────────────────────────────────────────────

test "execute: unknown tool" {
    const allocator = std.testing.allocator;
    const tc = message.ToolCall{
        .id = "call_1",
        .function = .{ .name = "nonexistent", .arguments = "{}" },
    };
    const result = execute(allocator, tc);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "Unknown tool:"));
}

test "execute: execute_bash echo" {
    const allocator = std.testing.allocator;
    const tc = message.ToolCall{
        .id = "call_2",
        .function = .{ .name = "execute_bash", .arguments = "{\"command\":\"echo hello\"}" },
    };
    const result = execute(allocator, tc);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\n", result);
}

test "execute: list_files current dir" {
    const allocator = std.testing.allocator;
    const tc = message.ToolCall{
        .id = "call_3",
        .function = .{ .name = "list_files", .arguments = "{}" },
    };
    const result = execute(allocator, tc);
    defer allocator.free(result);
    // Should contain something (we're in a project dir)
    try std.testing.expect(result.len > 0);
}

test "execute: read_file nonexistent" {
    const allocator = std.testing.allocator;
    const tc = message.ToolCall{
        .id = "call_4",
        .function = .{ .name = "read_file", .arguments = "{\"path\":\"/tmp/zaica_nonexistent_test_file\"}" },
    };
    const result = execute(allocator, tc);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "Error opening"));
}

test "bash timeout: fast command completes normally" {
    const allocator = std.testing.allocator;
    const result = try runBashWithTimeout(allocator, "echo fast", 2);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("fast\n", result);
}

test "bash timeout: slow command is killed" {
    const allocator = std.testing.allocator;
    // sleep 60 will be killed after 2 seconds
    const result = try runBashWithTimeout(allocator, "sleep 60", 2);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "timed out") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2 seconds") != null);
}

test "bash timeout: partial output before timeout" {
    const allocator = std.testing.allocator;
    // Print something then hang — should get partial output + timeout message
    const result = try runBashWithTimeout(allocator, "echo partial; sleep 60", 2);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "partial\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "TIMEOUT") != null);
}

test "bash timeout: stderr is captured" {
    const allocator = std.testing.allocator;
    const result = try runBashWithTimeout(allocator, "echo err >&2", 2);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("err\n", result);
}

test "bash timeout: stdout + stderr combined" {
    const allocator = std.testing.allocator;
    const result = try runBashWithTimeout(allocator, "echo out; echo err >&2", 2);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "out\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "stderr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "err\n") != null);
}

test "bash timeout: no output" {
    const allocator = std.testing.allocator;
    const result = try runBashWithTimeout(allocator, "true", 2);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("(no output)", result);
}

test "bash timeout: non-zero exit code" {
    const allocator = std.testing.allocator;
    const result = try runBashWithTimeout(allocator, "echo fail >&2; exit 1", 2);
    defer allocator.free(result);
    // Should still get the stderr output
    try std.testing.expectEqualStrings("fail\n", result);
}

test "toolRisk: correct risk levels" {
    try std.testing.expectEqual(ToolRisk.dangerous, toolRisk("execute_bash"));
    try std.testing.expectEqual(ToolRisk.dangerous, toolRisk("dispatch_agent"));
    try std.testing.expectEqual(ToolRisk.write, toolRisk("write_file"));
    try std.testing.expectEqual(ToolRisk.safe, toolRisk("read_file"));
    try std.testing.expectEqual(ToolRisk.safe, toolRisk("list_files"));
    try std.testing.expectEqual(ToolRisk.safe, toolRisk("search_files"));
    try std.testing.expectEqual(ToolRisk.safe, toolRisk("unknown_tool"));
}

test "displayToolName: dispatch_agent maps to Agent" {
    try std.testing.expectEqualStrings("Agent", displayToolName("dispatch_agent"));
    try std.testing.expectEqualStrings("Bash", displayToolName("execute_bash"));
}

test "sub_agent_tools: excludes dispatch_agent and load_skill" {
    for (sub_agent_tools) |tool| {
        try std.testing.expect(!std.mem.eql(u8, tool.function.name, "dispatch_agent"));
        try std.testing.expect(!std.mem.eql(u8, tool.function.name, "load_skill"));
    }
    try std.testing.expectEqual(@as(usize, 5), sub_agent_tools.len);
}

test "isAllowed: all permission" {
    try std.testing.expect(isAllowed("execute_bash", .all));
    try std.testing.expect(isAllowed("write_file", .all));
    try std.testing.expect(isAllowed("read_file", .all));
}

test "isAllowed: safe_only blocks write and dangerous" {
    try std.testing.expect(!isAllowed("execute_bash", .safe_only));
    try std.testing.expect(!isAllowed("write_file", .safe_only));
    try std.testing.expect(isAllowed("read_file", .safe_only));
    try std.testing.expect(isAllowed("list_files", .safe_only));
    try std.testing.expect(isAllowed("search_files", .safe_only));
}

test "isAllowed: none blocks everything" {
    try std.testing.expect(!isAllowed("execute_bash", .none));
    try std.testing.expect(!isAllowed("read_file", .none));
    try std.testing.expect(!isAllowed("list_files", .none));
}

test "truncateToolOutput: small output unchanged" {
    const allocator = std.testing.allocator;
    const input = "hello world";
    const result = truncateToolOutput(allocator, "read_file", input);
    // Should return same slice (no allocation)
    try std.testing.expectEqual(input.ptr, result.ptr);
}

test "truncateToolOutput: large output gets head/tail" {
    const allocator = std.testing.allocator;
    // Create output larger than write_file limit (1000 chars)
    const big = try allocator.alloc(u8, 2000);
    defer allocator.free(big);
    @memset(big, 'x');
    const result = truncateToolOutput(allocator, "write_file", big);
    defer if (result.ptr != big.ptr) allocator.free(result);
    try std.testing.expect(result.ptr != big.ptr); // was truncated
    try std.testing.expect(std.mem.indexOf(u8, result, "[WARNING: output truncated") != null);
}

test "truncateToolOutput: empty output" {
    const allocator = std.testing.allocator;
    const result = truncateToolOutput(allocator, "read_file", "");
    try std.testing.expectEqualStrings("", result);
}
