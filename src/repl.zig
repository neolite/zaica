const std = @import("std");
const posix = std.posix;

const config_types = @import("config/types.zig");
const client = @import("client/mod.zig");
const message = client.message;
const io = @import("io.zig");
const tools = @import("tools.zig");

/// Key event from terminal input.
const InputKey = union(enum) {
    char: []const u8,
    enter,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    ctrl_a,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_k,
    ctrl_l,
    ctrl_u,
    ctrl_w,
    eof,
    unknown,
};

/// Maximum number of history entries to persist.
const MAX_HISTORY_ENTRIES = 1000;

/// Interactive REPL with line editing.
///
/// Uses direct /dev/tty access with raw mode and manual escape sequence parsing.
/// Raw mode is toggled per-line: uncook for input, cook for LLM streaming.
pub const Repl = struct {
    /// Current line buffer (UTF-8 bytes).
    buf: std.ArrayList(u8),
    /// Cursor position within buf (byte offset, always at codepoint boundary).
    cursor: usize,
    /// Command history (owned strings).
    history: std.ArrayList([]const u8),
    /// Current position in history (null = editing new line).
    history_idx: ?usize,
    /// Saved new-line content when browsing history.
    saved_line: std.ArrayList(u8),
    /// Terminal fd (from /dev/tty).
    fd: posix.fd_t,
    /// Original terminal state (for cook/uncook).
    original_termios: posix.termios,
    /// Temp buffer for multi-byte UTF-8 characters.
    char_buf: [4]u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Repl {
        const fd = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
        const termios = try posix.tcgetattr(fd);

        // Force cooked mode at startup — previous crash may have left terminal raw
        var sane = termios;
        sane.oflag.OPOST = true;
        sane.lflag.ECHO = true;
        sane.lflag.ICANON = true;
        sane.lflag.ISIG = true;
        sane.iflag.ICRNL = true;
        posix.tcsetattr(fd, .FLUSH, sane) catch {};

        return .{
            .buf = .empty,
            .cursor = 0,
            .history = .empty,
            .history_idx = null,
            .saved_line = .empty,
            .fd = fd,
            .original_termios = termios,
            .char_buf = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.cook();
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
        self.buf.deinit(self.allocator);
        self.saved_line.deinit(self.allocator);
    }

    /// Enter raw mode for input.
    fn uncook(self: *Repl) void {
        var raw = self.original_termios;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(self.fd, .FLUSH, raw) catch {};
    }

    /// Restore terminal to cooked mode for normal output.
    fn cook(self: *Repl) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original_termios) catch {};
    }

    // ── Low-level byte reads ──────────────────────────────────────────

    /// Read a single byte, blocking until available.
    fn readByte(self: *Repl) !?u8 {
        var buf_: [1]u8 = undefined;
        const n = posix.read(self.fd, &buf_) catch |err| {
            if (err == error.EndOfStream) return null;
            return err;
        };
        if (n == 0) return null;
        return buf_[0];
    }

    /// Try to read a byte with a short timeout (~100ms).
    /// Used for escape sequence disambiguation: after ESC, if more bytes
    /// arrive quickly, it's an escape sequence; if not, it was literal Escape.
    fn readByteTimeout(self: *Repl) !?u8 {
        var tio = try posix.tcgetattr(self.fd);
        const saved_min = tio.cc[@intFromEnum(posix.V.MIN)];
        const saved_time = tio.cc[@intFromEnum(posix.V.TIME)];
        tio.cc[@intFromEnum(posix.V.MIN)] = 0;
        tio.cc[@intFromEnum(posix.V.TIME)] = 1; // 100ms
        try posix.tcsetattr(self.fd, .NOW, tio);
        defer {
            tio.cc[@intFromEnum(posix.V.MIN)] = saved_min;
            tio.cc[@intFromEnum(posix.V.TIME)] = saved_time;
            posix.tcsetattr(self.fd, .NOW, tio) catch {};
        }

        var buf_: [1]u8 = undefined;
        const n = posix.read(self.fd, &buf_) catch return null;
        if (n == 0) return null;
        return buf_[0];
    }

    // ── Input key reader ──────────────────────────────────────────────

    /// Read a complete key input (handles escape sequences and multi-byte UTF-8).
    fn readKey(self: *Repl) !InputKey {
        const byte = try self.readByte() orelse return .eof;

        // ESC — start of escape sequence or literal Escape
        if (byte == 0x1b) {
            const next = try self.readByteTimeout() orelse return .unknown;
            if (next == '[') return self.readCsiSequence();
            if (next == 'O') return self.readSs3Sequence();
            return .unknown;
        }

        // Control characters
        return switch (byte) {
            0x01 => .ctrl_a,
            0x03 => .ctrl_c,
            0x04 => .ctrl_d,
            0x05 => .ctrl_e,
            0x0B => .ctrl_k,
            0x0C => .ctrl_l,
            0x0D => .enter,
            0x15 => .ctrl_u,
            0x17 => .ctrl_w,
            0x7F => .backspace,
            else => if (byte >= 0x20) self.readUtf8Char(byte) else .unknown,
        };
    }

    /// Parse CSI sequence (ESC [ ...).
    fn readCsiSequence(self: *Repl) InputKey {
        const code = self.readByte() catch return .unknown;
        const c = code orelse return .unknown;
        return switch (c) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '3' => blk: {
                const tilde = self.readByte() catch break :blk .unknown;
                break :blk if ((tilde orelse 0) == '~') .delete else .unknown;
            },
            '1' => blk: {
                const next2 = self.readByte() catch break :blk .unknown;
                break :blk if ((next2 orelse 0) == '~') .home else .unknown;
            },
            '4' => blk: {
                const next2 = self.readByte() catch break :blk .unknown;
                break :blk if ((next2 orelse 0) == '~') .end else .unknown;
            },
            else => .unknown,
        };
    }

    /// Parse SS3 sequence (ESC O ...).
    fn readSs3Sequence(self: *Repl) InputKey {
        const code = self.readByte() catch return .unknown;
        const c = code orelse return .unknown;
        return switch (c) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => .unknown,
        };
    }

    /// Read a complete UTF-8 character starting with the given first byte.
    fn readUtf8Char(self: *Repl, first: u8) InputKey {
        const seq_len: usize = if (first < 0x80) 1
            else if (first & 0xE0 == 0xC0) 2
            else if (first & 0xF0 == 0xE0) 3
            else if (first & 0xF8 == 0xF0) 4
            else return .unknown;

        self.char_buf[0] = first;
        var i: usize = 1;
        while (i < seq_len) : (i += 1) {
            const b = self.readByte() catch return .unknown;
            self.char_buf[i] = b orelse return .unknown;
        }
        return .{ .char = self.char_buf[0..seq_len] };
    }

    // ── UTF-8 helpers ─────────────────────────────────────────────────

    /// Count display width (columns) of a UTF-8 byte slice.
    /// Assumes 1 column per codepoint (correct for Latin, Cyrillic, etc).
    fn displayWidth(bytes: []const u8) usize {
        var width: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            const cp_len: usize = if (b < 0x80) 1
                else if (b & 0xE0 == 0xC0) 2
                else if (b & 0xF0 == 0xE0) 3
                else if (b & 0xF8 == 0xF0) 4
                else 1; // invalid byte, count as 1
            i += cp_len;
            width += 1;
        }
        return width;
    }

    /// Move cursor left by one UTF-8 codepoint.
    fn cursorLeft(self: *Repl) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        while (self.cursor > 0 and (self.buf.items[self.cursor] & 0xC0) == 0x80) {
            self.cursor -= 1;
        }
    }

    /// Move cursor right by one UTF-8 codepoint.
    fn cursorRight(self: *Repl) void {
        if (self.cursor >= self.buf.items.len) return;
        self.cursor += 1;
        while (self.cursor < self.buf.items.len and (self.buf.items[self.cursor] & 0xC0) == 0x80) {
            self.cursor += 1;
        }
    }

    // ── Line rendering ────────────────────────────────────────────────

    /// Render the current line with prompt, clearing and repositioning cursor.
    fn renderLine(self: *Repl) void {
        const prompt = "> ";
        const cursor_display = prompt.len + displayWidth(self.buf.items[0..self.cursor]);
        io.writeOut("\r\x1b[K") catch {};
        io.writeOut(prompt) catch {};
        io.writeOut(self.buf.items) catch {};
        if (cursor_display == 0) {
            io.writeOut("\r") catch {};
        } else {
            io.printOut("\r\x1b[{d}C", .{cursor_display}) catch {};
        }
    }

    // ── Editing operations ────────────────────────────────────────────

    /// Delete the UTF-8 codepoint before cursor.
    fn deleteCharBeforeCursor(self: *Repl) void {
        if (self.cursor == 0) return;
        var start = self.cursor - 1;
        while (start > 0 and (self.buf.items[start] & 0xC0) == 0x80) {
            start -= 1;
        }
        self.removeBytes(start, self.cursor - start);
        self.cursor = start;
    }

    /// Delete the UTF-8 codepoint at cursor.
    fn deleteCharAtCursor(self: *Repl) void {
        if (self.cursor >= self.buf.items.len) return;
        var end_pos = self.cursor + 1;
        while (end_pos < self.buf.items.len and (self.buf.items[end_pos] & 0xC0) == 0x80) {
            end_pos += 1;
        }
        self.removeBytes(self.cursor, end_pos - self.cursor);
    }

    /// Remove `count` bytes starting at `pos` from buf.
    fn removeBytes(self: *Repl, pos: usize, count: usize) void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            _ = self.buf.orderedRemove(pos);
        }
    }

    fn deleteWordBackward(self: *Repl) void {
        var pos = self.cursor;
        while (pos > 0 and self.buf.items[pos - 1] == ' ') pos -= 1;
        while (pos > 0 and self.buf.items[pos - 1] != ' ') pos -= 1;
        if (pos < self.cursor) {
            self.removeBytes(pos, self.cursor - pos);
            self.cursor = pos;
        }
    }

    // ── History ───────────────────────────────────────────────────────

    fn historyPrev(self: *Repl) !void {
        if (self.history.items.len == 0) return;

        if (self.history_idx) |idx| {
            if (idx > 0) {
                self.history_idx = idx - 1;
                try self.loadHistoryEntry(idx - 1);
            }
        } else {
            self.saved_line.clearRetainingCapacity();
            try self.saved_line.appendSlice(self.allocator, self.buf.items);
            const last = self.history.items.len - 1;
            self.history_idx = last;
            try self.loadHistoryEntry(last);
        }
    }

    fn historyNext(self: *Repl) !void {
        const idx = self.history_idx orelse return;

        if (idx + 1 < self.history.items.len) {
            self.history_idx = idx + 1;
            try self.loadHistoryEntry(idx + 1);
        } else {
            self.history_idx = null;
            self.buf.clearRetainingCapacity();
            try self.buf.appendSlice(self.allocator, self.saved_line.items);
            self.cursor = self.buf.items.len;
        }
    }

    fn loadHistoryEntry(self: *Repl, idx: usize) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, self.history.items[idx]);
        self.cursor = self.buf.items.len;
    }

    // ── Main input loop ───────────────────────────────────────────────

    /// Read a line of input with full editing support.
    /// Returns owned slice (caller frees), or null on EOF.
    pub fn readLine(self: *Repl) !?[]const u8 {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.history_idx = null;
        self.saved_line.clearRetainingCapacity();

        self.uncook();
        defer self.cook();

        self.renderLine();

        while (true) {
            const key = try self.readKey();
            var needs_render = true;

            switch (key) {
                .enter => {
                    io.writeOut("\r\n") catch {};
                    const line = try self.allocator.dupe(u8, self.buf.items);
                    // Deduplicate: skip if same as last history entry
                    if (line.len > 0) {
                        const is_dup = self.history.items.len > 0 and
                            std.mem.eql(u8, self.history.items[self.history.items.len - 1], line);
                        if (!is_dup) {
                            try self.history.append(self.allocator, try self.allocator.dupe(u8, line));
                        }
                    }
                    return line;
                },
                .eof => {
                    io.writeOut("\r\n") catch {};
                    return null;
                },
                .ctrl_d => {
                    if (self.buf.items.len == 0) {
                        io.writeOut("\r\n") catch {};
                        return null;
                    }
                    self.deleteCharAtCursor();
                },
                .ctrl_c => {
                    self.buf.clearRetainingCapacity();
                    self.cursor = 0;
                    io.writeOut("^C\r\n") catch {};
                },
                .ctrl_a, .home => self.cursor = 0,
                .ctrl_e, .end => self.cursor = self.buf.items.len,
                .ctrl_k => self.buf.shrinkRetainingCapacity(self.cursor),
                .ctrl_u => {
                    if (self.cursor > 0) {
                        std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[self.cursor..]);
                        const new_len = self.buf.items.len - self.cursor;
                        self.buf.shrinkRetainingCapacity(new_len);
                        self.cursor = 0;
                    }
                },
                .ctrl_w => self.deleteWordBackward(),
                .ctrl_l => io.writeOut("\x1b[2J\x1b[H") catch {},
                .left => self.cursorLeft(),
                .right => self.cursorRight(),
                .up => try self.historyPrev(),
                .down => try self.historyNext(),
                .backspace => self.deleteCharBeforeCursor(),
                .delete => self.deleteCharAtCursor(),
                .char => |text| {
                    try self.buf.insertSlice(self.allocator, self.cursor, text);
                    self.cursor += text.len;
                },
                .unknown => needs_render = false,
            }

            if (needs_render) self.renderLine();
        }
    }

    /// Read a permission choice from the terminal (y/s/n).
    /// y = allow all tools, s = safe only (read/search), n = deny all.
    pub fn readPermission(self: *Repl) !tools.PermissionLevel {
        self.uncook();
        defer self.cook();
        while (true) {
            const byte = try self.readByte() orelse return .none;
            switch (byte) {
                'y', 'Y' => {
                    io.writeOut("y\r\n") catch {};
                    return .all;
                },
                's', 'S' => {
                    io.writeOut("s\r\n") catch {};
                    return .safe_only;
                },
                'n', 'N', 0x03 => {
                    io.writeOut("n\r\n") catch {};
                    return .none;
                },
                else => {},
            }
        }
    }

    // ── Persistent history ────────────────────────────────────────────

    /// Get the history file path (~/.config/zaica/history).
    fn getHistoryPath(allocator: std.mem.Allocator) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.allocPrint(allocator, "{s}/.config/zaica/history", .{home}) catch null;
    }

    /// Load history from disk. Silently ignores errors.
    pub fn loadHistory(self: *Repl) void {
        const path = getHistoryPath(self.allocator) orelse return;
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            const duped = self.allocator.dupe(u8, line) catch continue;
            self.history.append(self.allocator, duped) catch {
                self.allocator.free(duped);
                continue;
            };
        }
    }

    /// Save history to disk. Silently ignores errors.
    pub fn saveHistory(self: *Repl) void {
        const path = getHistoryPath(self.allocator) orelse return;
        defer self.allocator.free(path);

        // Ensure config directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return,
            };
        }

        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();

        // Write last MAX_HISTORY_ENTRIES entries
        const items = self.history.items;
        const start = if (items.len > MAX_HISTORY_ENTRIES) items.len - MAX_HISTORY_ENTRIES else 0;
        for (items[start..]) |entry| {
            file.writeAll(entry) catch return;
            file.writeAll("\n") catch return;
        }
    }
};

/// Free all allocator-owned memory in a ChatMessage.
fn freeMessage(allocator: std.mem.Allocator, msg: message.ChatMessage) void {
    switch (msg) {
        .text => |tm| {
            // System message content is borrowed from config — don't free
            if (tm.role != .system) {
                allocator.free(tm.content);
            }
        },
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

/// Check if the input is an exit/quit command.
/// Supports English, Russian words, and QWERTY→ЙЦУКЕН layout mistype mappings.
fn isExitCommand(input: []const u8) bool {
    const exit_commands = [_][]const u8{
        // English
        "/exit",
        "/quit",
        "/q",
        // Russian words
        "/выход",
        "/выйти",
        "/в",
        // QWERTY keys typed on ЙЦУКЕН layout: /exit → /учше, /quit → /йгше, /q → /й
        "/учше",
        "/йгше",
        "/й",
    };
    for (&exit_commands) |cmd| {
        if (std.mem.eql(u8, input, cmd)) return true;
    }
    return false;
}

/// Visual separator between input and output.
const SEPARATOR = "\x1b[2m────────────────────────────────────────\x1b[0m";

fn printHelp() void {
    io.writeOut("\r\n\x1b[1mCommands:\x1b[0m\r\n") catch {};
    io.writeOut("  /help   — show this help\r\n") catch {};
    io.writeOut("  /tools  — list available tools\r\n") catch {};
    io.writeOut("  /usage  — show session token usage\r\n") catch {};
    io.writeOut("  /exit   — quit (also /quit, /q)\r\n") catch {};
    io.writeOut("\r\n\x1b[1mTool permissions:\x1b[0m\r\n") catch {};
    io.writeOut("  y — allow all tools\r\n") catch {};
    io.writeOut("  s — safe only (read/list/search)\r\n") catch {};
    io.writeOut("  n — deny all tools\r\n") catch {};
    io.writeOut("\r\n") catch {};
}

/// Maximum number of agent iterations per user message.
const MAX_AGENT_ITERATIONS = 25;

/// Main REPL entry point — called from main.zig.
pub fn run(allocator: std.mem.Allocator, resolved: *const config_types.ResolvedConfig) !void {
    io.printText("zaica v0.1 — {s}/{s}\n", .{
        resolved.config.provider,
        resolved.resolved_model,
    }) catch {};
    io.writeText("Type /help for commands, /exit to quit.\n\n") catch {};

    var repl = try Repl.init(allocator);
    repl.loadHistory();
    defer {
        repl.saveHistory();
        repl.deinit();
    }

    // Conversation history (ChatMessage union)
    var history: std.ArrayList(message.ChatMessage) = .empty;
    defer {
        // Skip [0] (system message) — its content is borrowed from config
        for (history.items[1..]) |msg| {
            freeMessage(allocator, msg);
        }
        history.deinit(allocator);
    }

    try history.append(allocator, .{
        .text = .{ .role = .system, .content = resolved.config.system_prompt },
    });

    // Session-level tool permission
    var permission_level: tools.PermissionLevel = .none;

    // Session token counters
    var session_prompt_tokens: u64 = 0;
    var session_completion_tokens: u64 = 0;

    while (true) {
        const maybe_line = try repl.readLine();
        const line = maybe_line orelse break;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r ");
        if (trimmed.len == 0) continue;

        if (isExitCommand(trimmed)) break;
        if (std.mem.eql(u8, trimmed, "/tools")) {
            tools.printToolList();
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/help")) {
            printHelp();
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/usage")) {
            io.writeOut("\r\n\x1b[1mSession token usage:\x1b[0m\r\n") catch {};
            io.printOut("  Prompt tokens:     {d}\r\n", .{session_prompt_tokens}) catch {};
            io.printOut("  Completion tokens: {d}\r\n", .{session_completion_tokens}) catch {};
            io.printOut("  Total tokens:      {d}\r\n", .{session_prompt_tokens + session_completion_tokens}) catch {};
            io.printOut("  Context limit:     {d}\r\n\r\n", .{resolved.config.max_context_tokens}) catch {};
            continue;
        }

        const user_content = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(user_content);
        try history.append(allocator, .{ .text = .{ .role = .user, .content = user_content } });

        // Visual separator between input and output
        io.writeOut(SEPARATOR ++ "\r\n") catch {};

        // Agentic loop: keep calling LLM until we get a text response
        var iterations: usize = 0;
        while (iterations < MAX_AGENT_ITERATIONS) : (iterations += 1) {
            // Terminal is in cooked mode here — streaming works normally
            io.startSpinner("Thinking...");
            const result = client.chatMessages(
                allocator,
                resolved,
                history.items,
                tools.all_tools,
            ) catch {
                if (iterations == 0) {
                    // First call failed — remove user message
                    if (history.pop()) |removed| {
                        freeMessage(allocator, removed);
                    }
                }
                break;
            };

            // Track token usage
            if (result.usage) |usage| {
                session_prompt_tokens += usage.prompt_tokens;
                session_completion_tokens += usage.completion_tokens;
                io.printOut("\x1b[2m[tokens: {d} prompt + {d} completion = {d} | session: {d}]\x1b[0m\r\n", .{
                    usage.prompt_tokens,
                    usage.completion_tokens,
                    usage.total_tokens,
                    session_prompt_tokens + session_completion_tokens,
                }) catch {};

                // Context window warnings and compaction
                const max_ctx = resolved.config.max_context_tokens;
                if (max_ctx > 0 and usage.prompt_tokens > 0) {
                    const pct = (@as(u64, usage.prompt_tokens) * 100) / @as(u64, max_ctx);
                    if (pct >= 90 and history.items.len > 5) {
                        // Compact: keep system prompt [0] + last 4 messages
                        const keep_tail: usize = 4;
                        const remove_end = history.items.len - keep_tail;
                        if (remove_end > 1) {
                            const removed_count = remove_end - 1;
                            for (history.items[1..remove_end]) |msg| {
                                freeMessage(allocator, msg);
                            }
                            std.mem.copyForwards(message.ChatMessage, history.items[1..], history.items[remove_end..]);
                            history.shrinkRetainingCapacity(1 + keep_tail);
                            io.printOut("\x1b[33m[context compacted: dropped {d} old messages]\x1b[0m\r\n", .{removed_count}) catch {};
                        }
                    } else if (pct >= 80) {
                        io.printOut("\x1b[33m[warning: {d}% context window used ({d}k/{d}k tokens)]\x1b[0m\r\n", .{
                            pct,
                            usage.prompt_tokens / 1000,
                            max_ctx / 1000,
                        }) catch {};
                    }
                }
            }

            switch (result.response) {
                .text => |text| {
                    io.writeOut("\r\n") catch {};
                    try history.append(allocator, .{
                        .text = .{ .role = .assistant, .content = text },
                    });
                    break;
                },
                .tool_calls => |tcs| {
                    // Ask permission on first tool use in session
                    if (permission_level == .none) {
                        io.writeOut("\r\n\x1b[1;33mThe assistant wants to use tools:\x1b[0m\r\n") catch {};
                        for (tcs) |tc| {
                            const risk = tools.toolRisk(tc.function.name);
                            const color: []const u8 = switch (risk) {
                                .safe => "\x1b[32m",
                                .write => "\x1b[33m",
                                .dangerous => "\x1b[31m",
                            };
                            io.writeOut("  ") catch {};
                            io.writeOut(color) catch {};
                            io.printOut("{s}\x1b[0m({s})\r\n", .{ tc.function.name, truncateArgs(tc.function.arguments) }) catch {};
                        }
                        io.writeOut("\x1b[1;33mAllow? [y]es all / [s]afe only / [n]o\x1b[0m ") catch {};

                        permission_level = repl.readPermission() catch .none;
                        if (permission_level == .none) {
                            // Deny all tools
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
                    }

                    // Add assistant tool_use message to history
                    try history.append(allocator, .{
                        .tool_use = .{ .tool_calls = tcs },
                    });

                    // Execute tools, checking per-tool permissions.
                    // Multiple allowed tools run in parallel via std.Thread.
                    const tool_results = try allocator.alloc(ToolResult, tcs.len);
                    defer allocator.free(tool_results);
                    @memset(tool_results, .{ .tool_call_id = "", .content = "" });

                    // Indices of allowed tools that need execution
                    const thread_indices = try allocator.alloc(usize, tcs.len);
                    defer allocator.free(thread_indices);
                    var thread_count: usize = 0;

                    // First pass: check permissions, print status, fill denied results
                    for (tcs, 0..) |tc, i| {
                        if (!tools.isAllowed(tc.function.name, permission_level)) {
                            io.printOut("\x1b[33m  x {s} (not allowed)\x1b[0m\r\n", .{tc.function.name}) catch {};
                            tool_results[i] = .{
                                .tool_call_id = try allocator.dupe(u8, tc.id),
                                .content = std.fmt.allocPrint(allocator, "Permission denied: {s} requires full tool access (safe-only mode active).", .{tc.function.name}) catch try allocator.dupe(u8, "Permission denied."),
                            };
                        } else {
                            // Show tool name + key arg
                            if (extractKeyArg(allocator, tc.function.name, tc.function.arguments)) |key_arg| {
                                defer allocator.free(key_arg);
                                io.printOut("\x1b[2m  → {s} \x1b[2;3m{s}\x1b[0m\r\n", .{ tc.function.name, key_arg }) catch {};
                            } else {
                                io.printOut("\x1b[2m  → {s}\x1b[0m\r\n", .{tc.function.name}) catch {};
                            }
                            thread_indices[thread_count] = i;
                            thread_count += 1;
                        }
                    }

                    // Execute allowed tools in background threads with spinner
                    if (thread_count > 0) {
                        // Build label from tool names: "read_file, execute_bash"
                        var label_buf: [256]u8 = undefined;
                        var label_pos: usize = 0;
                        for (thread_indices[0..thread_count]) |idx| {
                            const name = tcs[idx].function.name;
                            if (label_pos > 0) {
                                if (label_pos + 2 <= label_buf.len) {
                                    @memcpy(label_buf[label_pos..][0..2], ", ");
                                    label_pos += 2;
                                }
                            }
                            const copy_len = @min(name.len, label_buf.len - label_pos);
                            if (copy_len > 0) {
                                @memcpy(label_buf[label_pos..][0..copy_len], name[0..copy_len]);
                                label_pos += copy_len;
                            }
                        }
                        io.startSpinner(label_buf[0..label_pos]);

                        const threads = try allocator.alloc(?std.Thread, thread_count);
                        defer allocator.free(threads);
                        @memset(threads, null);

                        for (thread_indices[0..thread_count], 0..) |idx, j| {
                            threads[j] = std.Thread.spawn(.{}, executeToolThread, .{
                                allocator, tcs[idx], &tool_results[idx],
                            }) catch null;
                        }

                        for (thread_indices[0..thread_count], 0..) |idx, j| {
                            if (threads[j]) |t| {
                                t.join();
                            } else {
                                tool_results[idx] = .{
                                    .tool_call_id = allocator.dupe(u8, tcs[idx].id) catch "",
                                    .content = tools.execute(allocator, tcs[idx]),
                                };
                            }
                        }

                        io.stopSpinner();
                    }

                    // Print tool results so the user can see what happened
                    for (tcs, 0..) |tc, i| {
                        const content = tool_results[i].content;
                        if (content.len == 0) continue;
                        // Tool name header with key arg
                        if (extractKeyArg(allocator, tc.function.name, tc.function.arguments)) |key_arg| {
                            defer allocator.free(key_arg);
                            io.printOut("\x1b[2m  ┌ {s} \x1b[2;3m{s}\x1b[0m\r\n", .{ tc.function.name, key_arg }) catch {};
                        } else {
                            io.printOut("\x1b[2m  ┌ {s}\x1b[0m\r\n", .{tc.function.name}) catch {};
                        }
                        // Truncate long output
                        const max_preview = 1024;
                        const preview = if (content.len > max_preview) content[0..max_preview] else content;
                        const color: []const u8 = if (isErrorOutput(content)) "\x1b[31m" else "\x1b[2m";
                        io.writeOut(color) catch {};
                        io.writeText(preview) catch {};
                        if (content.len > max_preview) {
                            io.printOut("\r\n  ... ({d} bytes total)", .{content.len}) catch {};
                        }
                        io.writeOut("\x1b[0m\r\n") catch {};
                    }

                    // Append all results to history in order
                    for (tool_results) |tr| {
                        try history.append(allocator, .{
                            .tool_result = .{
                                .tool_call_id = tr.tool_call_id,
                                .content = tr.content,
                            },
                        });
                    }
                },
            }
        }

        if (iterations >= MAX_AGENT_ITERATIONS) {
            io.writeOut("\x1b[33m(agent loop limit reached)\x1b[0m\r\n") catch {};
        }
    }
}

/// Result of a single tool execution, used for parallel collection.
const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
};

/// Thread entry point for parallel tool execution.
/// Each thread writes to its own slot in the results array.
fn executeToolThread(
    allocator: std.mem.Allocator,
    tc: message.ToolCall,
    result: *ToolResult,
) void {
    result.content = tools.execute(allocator, tc);
    result.tool_call_id = allocator.dupe(u8, tc.id) catch "";
}

/// Truncate tool arguments for display (max 80 chars).
fn truncateArgs(args: []const u8) []const u8 {
    if (args.len <= 80) return args;
    return args[0..80];
}

/// Extract the primary argument from a tool call's JSON args for display.
/// Returns a short string like "src/main.zig" or "echo hello", truncated at 80 chars.
fn extractKeyArg(allocator: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    // Map tool names to their primary argument key
    const key = if (std.mem.eql(u8, tool_name, "execute_bash"))
        "command"
    else if (std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "list_files"))
        "path"
    else if (std.mem.eql(u8, tool_name, "search_files"))
        "pattern"
    else
        return null;

    const val = parsed.value.object.get(key) orelse return null;
    if (val != .string or val.string.len == 0) return null;
    const s = val.string;
    const max_len: usize = 80;
    return allocator.dupe(u8, if (s.len > max_len) s[0..max_len] else s) catch null;
}

/// Check if tool output looks like an error.
fn isErrorOutput(content: []const u8) bool {
    return std.mem.startsWith(u8, content, "Error") or
        std.mem.startsWith(u8, content, "Permission denied");
}

test {
    _ = Repl;
}

test "isExitCommand: english commands" {
    try std.testing.expect(isExitCommand("/exit"));
    try std.testing.expect(isExitCommand("/quit"));
    try std.testing.expect(isExitCommand("/q"));
}

test "isExitCommand: russian word commands" {
    try std.testing.expect(isExitCommand("/выход"));
    try std.testing.expect(isExitCommand("/выйти"));
    try std.testing.expect(isExitCommand("/в"));
}

test "isExitCommand: QWERTY typed on ЙЦУКЕН layout" {
    // /exit keys on Russian layout → /учше
    try std.testing.expect(isExitCommand("/учше"));
    // /quit keys on Russian layout → /йгше
    try std.testing.expect(isExitCommand("/йгше"));
    // /q key on Russian layout → /й
    try std.testing.expect(isExitCommand("/й"));
}

test "isExitCommand: non-exit input" {
    try std.testing.expect(!isExitCommand("hello"));
    try std.testing.expect(!isExitCommand("/help"));
    try std.testing.expect(!isExitCommand("exit"));
    try std.testing.expect(!isExitCommand(""));
    try std.testing.expect(!isExitCommand("/привет"));
}

test "extractKeyArg: read_file returns path" {
    const allocator = std.testing.allocator;
    const result = extractKeyArg(allocator, "read_file", "{\"path\":\"src/main.zig\"}");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("src/main.zig", result.?);
}

test "extractKeyArg: execute_bash returns command" {
    const allocator = std.testing.allocator;
    const result = extractKeyArg(allocator, "execute_bash", "{\"command\":\"echo hello\"}");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("echo hello", result.?);
}

test "extractKeyArg: unknown tool returns null" {
    const allocator = std.testing.allocator;
    try std.testing.expect(extractKeyArg(allocator, "unknown", "{}") == null);
}

test "extractKeyArg: invalid JSON returns null" {
    const allocator = std.testing.allocator;
    try std.testing.expect(extractKeyArg(allocator, "read_file", "not json") == null);
}

test "isErrorOutput: detects errors" {
    try std.testing.expect(isErrorOutput("Error: file not found"));
    try std.testing.expect(isErrorOutput("Permission denied: read_file"));
    try std.testing.expect(!isErrorOutput("file contents here"));
    try std.testing.expect(!isErrorOutput(""));
}
