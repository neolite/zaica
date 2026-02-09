const std = @import("std");
const message = @import("client/message.zig");
const io = @import("io.zig");

/// Session metadata written as the first JSONL line.
pub const SessionMeta = struct {
    id: []const u8,
    model: []const u8,
    provider: []const u8,
    created_at: i64,
};

/// Result of loading a session from disk.
pub const LoadedSession = struct {
    messages: []message.ChatMessage,
    summary: ?[]const u8,
    meta: ?SessionMeta,

    pub fn deinit(self: *LoadedSession, allocator: std.mem.Allocator) void {
        for (self.messages) |msg| {
            // Can't use message.freeMessage — it skips system content (assumes borrowed).
            // All loaded session messages are fully owned by the allocator.
            switch (msg) {
                .text => |tm| allocator.free(tm.content),
                .tool_use => |tu| {
                    for (tu.tool_calls) |tc| {
                        allocator.free(tc.id);
                        allocator.free(tc.function.name);
                        allocator.free(tc.function.arguments);
                    }
                    allocator.free(tu.tool_calls);
                },
                .tool_result => |tr| {
                    allocator.free(tr.tool_call_id);
                    allocator.free(tr.content);
                },
            }
        }
        allocator.free(self.messages);
        if (self.summary) |s| allocator.free(s);
        if (self.meta) |m| {
            allocator.free(m.id);
            allocator.free(m.model);
            allocator.free(m.provider);
        }
    }
};

/// Entry for listing sessions.
pub const SessionEntry = struct {
    id: []const u8,
    model: []const u8,
    summary: ?[]const u8,
    created_at: i64,
};

/// Generate a session ID from current timestamp: "20260209-143052".
pub fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_secs: u64 = @intCast(ts);
    const epoch_day = epoch_secs / 86400;
    const day_secs = epoch_secs % 86400;

    // Convert epoch days to Y/M/D (simplified civil_from_days)
    const z = epoch_day + 719468;
    const era: u64 = z / 146097;
    const doe: u64 = z - era * 146097;
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: u64 = yoe + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m_raw: u64 = if (mp < 10) mp + 3 else mp - 9;
    const y_final: u64 = if (m_raw <= 2) y + 1 else y;

    const hour = day_secs / 3600;
    const minute = (day_secs % 3600) / 60;
    const second = day_secs % 60;

    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        y_final, m_raw, d, hour, minute, second,
    });
}

/// Get sessions directory path (~/.config/zaica/sessions/).
fn getSessionsDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/zaica/sessions", .{home});
}

/// Get session file path for a given session ID.
fn getSessionPath(allocator: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    const dir = try getSessionsDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ dir, session_id });
}

/// Ensure the sessions directory exists.
fn ensureSessionsDir(allocator: std.mem.Allocator) !void {
    const dir = try getSessionsDir(allocator);
    defer allocator.free(dir);

    // Create parent (~/.config/zaica) first
    if (std.fs.path.dirname(dir)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Write session metadata as the first JSONL line.
pub fn writeMetadata(allocator: std.mem.Allocator, session_id: []const u8, meta: SessionMeta) !void {
    try ensureSessionsDir(allocator);
    const path = try getSessionPath(allocator, session_id);
    defer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\"type\":\"meta\",\"id\":\"");
    try message.writeEscaped(w, meta.id);
    try w.writeAll("\",\"model\":\"");
    try message.writeEscaped(w, meta.model);
    try w.writeAll("\",\"provider\":\"");
    try message.writeEscaped(w, meta.provider);
    try w.print("\",\"created_at\":{d}}}\n", .{meta.created_at});

    try file.writeAll(buf.items);
}

/// Append a single ChatMessage as one JSONL line to the session file.
pub fn appendMessage(allocator: std.mem.Allocator, session_id: []const u8, msg: message.ChatMessage) void {
    const line = serializeMessage(allocator, msg) catch return;
    defer allocator.free(line);

    const path = getSessionPath(allocator, session_id) catch return;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch {};
}

/// Serialize a ChatMessage to a JSONL line (with trailing newline).
fn serializeMessage(allocator: std.mem.Allocator, msg: message.ChatMessage) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    switch (msg) {
        .text => |tm| {
            try w.writeAll("{\"type\":\"text\",\"role\":\"");
            try w.writeAll(@tagName(tm.role));
            try w.writeAll("\",\"content\":\"");
            try message.writeEscaped(w, tm.content);
            try w.writeAll("\"}\n");
        },
        .tool_use => |tu| {
            try w.writeAll("{\"type\":\"tool_use\",\"tool_calls\":[");
            for (tu.tool_calls, 0..) |tc, i| {
                if (i > 0) try w.writeByte(',');
                try w.writeAll("{\"id\":\"");
                try message.writeEscaped(w, tc.id);
                try w.writeAll("\",\"function\":{\"name\":\"");
                try message.writeEscaped(w, tc.function.name);
                try w.writeAll("\",\"arguments\":\"");
                try message.writeEscaped(w, tc.function.arguments);
                try w.writeAll("\"}}");
            }
            try w.writeAll("]}\n");
        },
        .tool_result => |tr| {
            try w.writeAll("{\"type\":\"tool_result\",\"tool_call_id\":\"");
            try message.writeEscaped(w, tr.tool_call_id);
            try w.writeAll("\",\"content\":\"");
            try message.writeEscaped(w, tr.content);
            try w.writeAll("\"}\n");
        },
    }

    return buf.toOwnedSlice(allocator);
}

/// Append a summary line to the session file.
pub fn writeSummary(allocator: std.mem.Allocator, session_id: []const u8, text: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"type\":\"summary\",\"text\":\"") catch return;
    message.writeEscaped(w, text) catch return;
    w.writeAll("\"}\n") catch return;

    const path = getSessionPath(allocator, session_id) catch return;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(buf.items) catch {};
}

/// Load a session from its JSONL file.
/// Skips corrupted lines. Returns messages and optional summary.
pub fn loadSession(allocator: std.mem.Allocator, session_id: []const u8) !LoadedSession {
    const path = try getSessionPath(allocator, session_id);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            io.printErr("Session not found: {s}\n", .{session_id});
            return error.SessionNotFound;
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(content);

    var messages: std.ArrayList(message.ChatMessage) = .empty;
    errdefer {
        for (messages.items) |msg| message.freeMessage(allocator, msg);
        messages.deinit(allocator);
    }
    var summary: ?[]const u8 = null;
    var meta: ?SessionMeta = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        parseLine(allocator, line, &messages, &summary, &meta) catch continue; // skip bad lines
    }

    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .summary = summary,
        .meta = meta,
    };
}

/// Parse a single JSONL line into the appropriate data.
fn parseLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    messages: *std.ArrayList(message.ChatMessage),
    summary: *?[]const u8,
    meta: *?SessionMeta,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidFormat;
    const obj = parsed.value.object;

    const type_val = obj.get("type") orelse return error.InvalidFormat;
    if (type_val != .string) return error.InvalidFormat;
    const line_type = type_val.string;

    if (std.mem.eql(u8, line_type, "meta")) {
        const id = obj.get("id") orelse return error.InvalidFormat;
        const model = obj.get("model") orelse return error.InvalidFormat;
        const provider = obj.get("provider") orelse return error.InvalidFormat;
        const created = obj.get("created_at") orelse return error.InvalidFormat;
        if (id != .string or model != .string or provider != .string or created != .integer)
            return error.InvalidFormat;
        meta.* = .{
            .id = try allocator.dupe(u8, id.string),
            .model = try allocator.dupe(u8, model.string),
            .provider = try allocator.dupe(u8, provider.string),
            .created_at = created.integer,
        };
    } else if (std.mem.eql(u8, line_type, "text")) {
        const role_val = obj.get("role") orelse return error.InvalidFormat;
        const content_val = obj.get("content") orelse return error.InvalidFormat;
        if (role_val != .string or content_val != .string) return error.InvalidFormat;

        const role: message.Role = if (std.mem.eql(u8, role_val.string, "system"))
            .system
        else if (std.mem.eql(u8, role_val.string, "user"))
            .user
        else if (std.mem.eql(u8, role_val.string, "assistant"))
            .assistant
        else
            return error.InvalidFormat;

        try messages.append(allocator, .{
            .text = .{
                .role = role,
                .content = try allocator.dupe(u8, content_val.string),
            },
        });
    } else if (std.mem.eql(u8, line_type, "tool_use")) {
        const tcs_val = obj.get("tool_calls") orelse return error.InvalidFormat;
        if (tcs_val != .array) return error.InvalidFormat;

        var tool_calls: std.ArrayList(message.ToolCall) = .empty;
        errdefer {
            for (tool_calls.items) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.function.name);
                allocator.free(tc.function.arguments);
            }
            tool_calls.deinit(allocator);
        }

        for (tcs_val.array.items) |tc_val| {
            if (tc_val != .object) continue;
            const tc_obj = tc_val.object;
            const id = tc_obj.get("id") orelse continue;
            const func = tc_obj.get("function") orelse continue;
            if (id != .string or func != .object) continue;
            const name = func.object.get("name") orelse continue;
            const args = func.object.get("arguments") orelse continue;
            if (name != .string or args != .string) continue;

            try tool_calls.append(allocator, .{
                .id = try allocator.dupe(u8, id.string),
                .function = .{
                    .name = try allocator.dupe(u8, name.string),
                    .arguments = try allocator.dupe(u8, args.string),
                },
            });
        }

        try messages.append(allocator, .{
            .tool_use = .{ .tool_calls = try tool_calls.toOwnedSlice(allocator) },
        });
    } else if (std.mem.eql(u8, line_type, "tool_result")) {
        const tcid = obj.get("tool_call_id") orelse return error.InvalidFormat;
        const content_val = obj.get("content") orelse return error.InvalidFormat;
        if (tcid != .string or content_val != .string) return error.InvalidFormat;

        try messages.append(allocator, .{
            .tool_result = .{
                .tool_call_id = try allocator.dupe(u8, tcid.string),
                .content = try allocator.dupe(u8, content_val.string),
            },
        });
    } else if (std.mem.eql(u8, line_type, "summary")) {
        const text_val = obj.get("text") orelse return error.InvalidFormat;
        if (text_val != .string) return error.InvalidFormat;
        if (summary.*) |old| allocator.free(old);
        summary.* = try allocator.dupe(u8, text_val.string);
    }
}

/// Find the most recent session by scanning the sessions directory.
pub fn findMostRecentSession(allocator: std.mem.Allocator) !?[]const u8 {
    const dir_path = getSessionsDir(allocator) catch return null;
    defer allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_name: ?[]const u8 = null;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const name = entry.name[0 .. entry.name.len - 6]; // strip .jsonl

        if (best_name) |current| {
            // Lexicographic comparison works because IDs are timestamp-based
            if (std.mem.order(u8, name, current) == .gt) {
                allocator.free(current);
                best_name = try allocator.dupe(u8, name);
            }
        } else {
            best_name = try allocator.dupe(u8, name);
        }
    }

    return best_name;
}

/// List recent sessions (up to `limit`), sorted newest first.
pub fn listSessions(allocator: std.mem.Allocator, limit: usize) ![]SessionEntry {
    const dir_path = try getSessionsDir(allocator);
    defer allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    // Collect all session file names
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name[0 .. entry.name.len - 6]));
    }

    // Sort descending (newest first) — lexicographic works for timestamp IDs
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt; // reverse order
        }
    }.lessThan);

    const count = @min(names.items.len, limit);
    var entries = try allocator.alloc(SessionEntry, count);
    var filled: usize = 0;

    for (names.items[0..count]) |session_id| {
        // Quick-parse just meta + summary from the file
        const path = getSessionPath(allocator, session_id) catch continue;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 50 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        var entry = SessionEntry{
            .id = try allocator.dupe(u8, session_id),
            .model = try allocator.dupe(u8, "unknown"),
            .summary = null,
            .created_at = 0,
        };

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const type_val = obj.get("type") orelse continue;
            if (type_val != .string) continue;

            if (std.mem.eql(u8, type_val.string, "meta")) {
                if (obj.get("model")) |m| {
                    if (m == .string) {
                        allocator.free(entry.model);
                        entry.model = allocator.dupe(u8, m.string) catch continue;
                    }
                }
                if (obj.get("created_at")) |c| {
                    if (c == .integer) entry.created_at = c.integer;
                }
            } else if (std.mem.eql(u8, type_val.string, "summary")) {
                if (obj.get("text")) |t| {
                    if (t == .string) {
                        if (entry.summary) |old| allocator.free(old);
                        entry.summary = allocator.dupe(u8, t.string) catch null;
                    }
                }
            }
        }

        entries[filled] = entry;
        filled += 1;
    }

    if (filled < entries.len) {
        const result = try allocator.alloc(SessionEntry, filled);
        @memcpy(result, entries[0..filled]);
        allocator.free(entries);
        return result;
    }
    return entries;
}

/// Free a list of SessionEntry.
pub fn freeSessionEntries(allocator: std.mem.Allocator, entries: []const SessionEntry) void {
    for (entries) |e| {
        allocator.free(e.id);
        allocator.free(e.model);
        if (e.summary) |s| allocator.free(s);
    }
    allocator.free(entries);
}

// ── Tests ────────────────────────────────────────────────────────────

test "generateSessionId: format" {
    const allocator = std.testing.allocator;
    const id = try generateSessionId(allocator);
    defer allocator.free(id);
    // Should be "YYYYMMDD-HHMMSS" = 15 chars
    try std.testing.expectEqual(@as(usize, 15), id.len);
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
}

test "serializeMessage: text message" {
    const allocator = std.testing.allocator;
    const line = try serializeMessage(allocator, .{
        .text = .{ .role = .user, .content = "hello" },
    });
    defer allocator.free(line);
    // Should be valid JSON + newline
    try std.testing.expect(line.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    // Parse to verify
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("text", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("user", parsed.value.object.get("role").?.string);
    try std.testing.expectEqualStrings("hello", parsed.value.object.get("content").?.string);
}

test "serializeMessage: tool_use message" {
    const allocator = std.testing.allocator;
    const tcs = [_]message.ToolCall{.{
        .id = "tc_1",
        .function = .{ .name = "read_file", .arguments = "{\"path\":\"foo\"}" },
    }};
    const line = try serializeMessage(allocator, .{
        .tool_use = .{ .tool_calls = &tcs },
    });
    defer allocator.free(line);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tool_use", parsed.value.object.get("type").?.string);
}

test "serializeMessage: tool_result message" {
    const allocator = std.testing.allocator;
    const line = try serializeMessage(allocator, .{
        .tool_result = .{ .tool_call_id = "tc_1", .content = "file content" },
    });
    defer allocator.free(line);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tool_result", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("tc_1", parsed.value.object.get("tool_call_id").?.string);
}
