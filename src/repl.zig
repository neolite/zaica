const std = @import("std");
const posix = std.posix;

const config_types = @import("config/types.zig");
const client = @import("client/mod.zig");
const http_client = @import("client/http.zig");
const message = client.message;
const io = @import("io.zig");
const tools = @import("tools.zig");
const skills = @import("skills.zig");
const state = @import("state.zig");
const agent = @import("agent.zig");
const session = @import("session.zig");
const node = @import("node.zig");

/// Key event from terminal input.
const InputKey = union(enum) {
    char: []const u8,
    enter,
    tab,
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

    /// Enter streaming mode: OPOST for correct \n handling, but ECHO off
    /// to suppress stray input (e.g., trackpad scroll → ^[[A/^[[B).
    fn streamMode(self: *Repl) void {
        var tio = self.original_termios;
        tio.oflag.OPOST = true;
        tio.lflag.ECHO = false;
        tio.lflag.ICANON = false;
        posix.tcsetattr(self.fd, .FLUSH, tio) catch {};
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
            0x09 => .tab,
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
    /// Handles three forms:
    ///   - Simple: ESC [ A         → arrow keys
    ///   - Tilde:  ESC [ 3 ~       → delete, home, end
    ///   - CSI u:  ESC [ 97 ; 5 u  → Ctrl+key (kitty keyboard protocol)
    ///
    /// Accumulates numeric parameters separated by ';' until a final
    /// alphabetic byte or '~' terminates the sequence.
    fn readCsiSequence(self: *Repl) InputKey {
        // Accumulate up to 4 numeric parameters (covers all practical sequences)
        var params: [4]u32 = .{ 0, 0, 0, 0 };
        var param_count: usize = 0;
        var has_digits = false;

        while (true) {
            const byte = self.readByte() catch return .unknown;
            const c = byte orelse return .unknown;

            if (c >= '0' and c <= '9') {
                // Accumulate digit into current param
                if (param_count < params.len) {
                    params[param_count] = params[param_count] *% 10 +% (c - '0');
                    has_digits = true;
                }
            } else if (c == ';') {
                // Advance to next parameter slot
                if (has_digits and param_count < params.len) {
                    param_count += 1;
                } else if (!has_digits and param_count < params.len) {
                    param_count += 1; // empty param = 0
                }
                has_digits = false;
            } else {
                // Final byte — close last param if digits were seen
                if (has_digits and param_count < params.len) {
                    param_count += 1;
                }
                return dispatchCsiParams(params[0..param_count], c);
            }
        }
    }

    /// Route a parsed CSI sequence to an InputKey based on the final byte
    /// and accumulated parameters.
    fn dispatchCsiParams(params: []const u32, final: u8) InputKey {
        // CSI u: kitty keyboard protocol — ESC [ codepoint ; modifiers u
        if (final == 'u') {
            return parseCsiU(params);
        }

        // Tilde sequences: ESC [ N ~
        if (final == '~' and params.len >= 1) {
            return switch (params[0]) {
                1 => .home,
                3 => .delete,
                4 => .end,
                else => .unknown,
            };
        }

        // Simple letter sequences (no params or params ignored)
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => .unknown,
        };
    }

    /// Parse CSI u sequence: ESC [ codepoint ; modifiers u
    /// Extracts the Unicode codepoint and modifier flags, then maps to InputKey.
    /// For Ctrl+key (modifier bit 3), maps Latin and Cyrillic codepoints.
    fn parseCsiU(params: []const u32) InputKey {
        if (params.len < 1) return .unknown;
        const codepoint = params[0];
        // modifier flags: bit 2 = shift, bit 3 = alt, bit 4 = ctrl, bit 5 = super
        const modifiers: u32 = if (params.len >= 2) params[1] else 1;
        const is_ctrl = (modifiers & 4) != 0; // bit 3 set (modifier value has 1-based encoding: 5 = 1+4)

        if (is_ctrl) {
            // Latin lowercase → Ctrl+key
            if (codepoint >= 'a' and codepoint <= 'z') {
                return latinToCtrlKey(@intCast(codepoint));
            }
            // Latin uppercase → same Ctrl+key
            if (codepoint >= 'A' and codepoint <= 'Z') {
                return latinToCtrlKey(@intCast(codepoint + 32)); // lowercase
            }
            // Cyrillic → map to QWERTY equivalent → Ctrl+key
            return cyrillicToCtrlKey(codepoint);
        }

        return .unknown;
    }

    /// Map a Latin lowercase letter to the corresponding Ctrl+key InputKey.
    fn latinToCtrlKey(ch: u8) InputKey {
        return switch (ch) {
            'a' => .ctrl_a,
            'c' => .ctrl_c,
            'd' => .ctrl_d,
            'e' => .ctrl_e,
            'k' => .ctrl_k,
            'l' => .ctrl_l,
            'u' => .ctrl_u,
            'w' => .ctrl_w,
            else => .unknown,
        };
    }

    /// Map a Cyrillic Unicode codepoint (ЙЦУКЕН layout) to the QWERTY Ctrl+key.
    /// Only maps letters that have corresponding Ctrl+ bindings in the REPL.
    fn cyrillicToCtrlKey(codepoint: u32) InputKey {
        return switch (codepoint) {
            // ф/Ф (0x0444/0x0424) → A key → ctrl_a
            0x0444, 0x0424 => .ctrl_a,
            // с/С (0x0441/0x0421) → C key → ctrl_c (also used as interrupt)
            0x0441, 0x0421 => .ctrl_c,
            // в/В (0x0432/0x0412) → D key → ctrl_d
            0x0432, 0x0412 => .ctrl_d,
            // у/У (0x0443/0x0423) → E key → ctrl_e
            0x0443, 0x0423 => .ctrl_e,
            // л/Л (0x043B/0x041B) → K key → ctrl_k
            0x043B, 0x041B => .ctrl_k,
            // д/Д (0x0434/0x0414) → L key → ctrl_l
            0x0434, 0x0414 => .ctrl_l,
            // г/Г (0x0433/0x0413) → U key → ctrl_u
            0x0433, 0x0413 => .ctrl_u,
            // ц/Ц (0x0446/0x0426) → W key → ctrl_w
            0x0446, 0x0426 => .ctrl_w,
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

    /// Render the current line on the fixed input row (rows-2).
    fn renderLine(self: *Repl) void {
        const term = io.getTerminalSize();
        const input_row = term.rows - 2;
        const prompt = " \xc2\xbb "; // ·»· (left-padded)
        const prompt_display_width: usize = 3; // " » " = 3 columns
        const cursor_display = prompt_display_width + displayWidth(self.buf.items[0..self.cursor]);
        const cursor_col = cursor_display + 1; // 1-based
        io.printOut("\x1b[{d};1H\x1b[K", .{input_row}) catch {};
        io.writeOut("\x1b[95m" ++ prompt ++ "\x1b[0m") catch {};
        io.writeOut(self.buf.items) catch {};
        io.printOut("\x1b[{d};{d}H", .{ input_row, cursor_col }) catch {};
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

    // ── Tab completion ─────────────────────────────────────────────────

    /// Available slash commands for tab completion.
    const slash_commands = [_][]const u8{ "/compact", "/exit", "/help", "/quit", "/sessions", "/skills", "/tools", "/usage" };

    /// Attempt to complete a slash command from the current buffer prefix.
    /// If exactly one command matches, replaces buffer with it.
    /// If multiple match, completes to their longest common prefix.
    fn tryCompleteCommand(self: *Repl) void {
        const input = self.buf.items;
        if (input.len == 0 or input[0] != '/') return;

        // Find all commands that start with the current input
        var matches: [slash_commands.len]usize = undefined;
        var match_count: usize = 0;
        for (slash_commands, 0..) |cmd, i| {
            if (cmd.len >= input.len and std.mem.eql(u8, cmd[0..input.len], input)) {
                matches[match_count] = i;
                match_count += 1;
            }
        }

        if (match_count == 0) return;

        // Find longest common prefix among matches
        const first = slash_commands[matches[0]];
        var common_len: usize = first.len;
        for (matches[1..match_count]) |mi| {
            const other = slash_commands[mi];
            const limit = @min(common_len, other.len);
            var j: usize = 0;
            while (j < limit and first[j] == other[j]) : (j += 1) {}
            common_len = j;
        }

        if (common_len <= input.len) return; // nothing new to complete

        // Replace buffer with the common prefix
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.allocator, first[0..common_len]) catch return;
        self.cursor = self.buf.items.len;
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
        defer self.streamMode(); // OPOST on, ECHO off — suppresses trackpad scroll noise

        self.renderLine();

        while (true) {
            const key = try self.readKey();
            var needs_render = true;

            switch (key) {
                .enter => {
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
                .eof => return null,
                .ctrl_d => {
                    if (self.buf.items.len == 0) return null;
                    self.deleteCharAtCursor();
                },
                .ctrl_c => {
                    self.buf.clearRetainingCapacity();
                    self.cursor = 0;
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
                .tab => self.tryCompleteCommand(),
                .ctrl_w => self.deleteWordBackward(),
                .ctrl_l => {
                    // Clear screen and re-setup full layout
                    const ts = io.getTerminalSize();
                    io.writeOut("\x1b[2J\x1b[H") catch {};
                    io.setupScrollRegion(ts.rows);
                    io.renderSeparator(ts.rows - 3, ts.cols);
                    io.renderSeparator(ts.rows - 1, ts.cols);
                },
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
    /// Also accepts Cyrillic equivalents for ЙЦУКЕН layout:
    ///   н/Н (Y key) → all, ы/Ы (S key) → safe_only, т/Т (N key) → none,
    ///   д/Д (semantic "да") → all.
    pub fn readPermission(self: *Repl) !tools.PermissionLevel {
        self.uncook();
        defer self.streamMode();
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
                0x1b => {
                    // ESC — treat as deny + trigger cancel
                    io.writeOut("n\r\n") catch {};
                    io.setCancelFlag();
                    return .none;
                },
                // Cyrillic UTF-8: 2-byte sequences starting with 0xD0 or 0xD1
                0xD0, 0xD1 => {
                    const second = try self.readByte() orelse continue;
                    if (matchCyrillicPermission(byte, second)) |level| {
                        const label: []const u8 = switch (level) {
                            .all => "y",
                            .safe_only => "s",
                            .none => "n",
                        };
                        io.writeOut(label) catch {};
                        io.writeOut("\r\n") catch {};
                        return level;
                    }
                },
                else => {},
            }
        }
    }

    /// Match a 2-byte Cyrillic UTF-8 sequence to a permission level.
    /// Maps ЙЦУКЕН physical keys to their QWERTY equivalents:
    ///   н/Н (0xD0BD/0xD09D) → Y key → .all
    ///   ы/Ы (0xD18B/0xD0AB) → S key → .safe_only
    ///   т/Т (0xD182/0xD0A2) → N key → .none
    ///   д/Д (0xD0B4/0xD094) → semantic "да" (yes) → .all
    fn matchCyrillicPermission(first: u8, second: u8) ?tools.PermissionLevel {
        const pair: u16 = (@as(u16, first) << 8) | second;
        return switch (pair) {
            // н (lowercase) / Н (uppercase) — Y key on ЙЦУКЕН
            0xD0BD, 0xD09D => .all,
            // д (lowercase) / Д (uppercase) — semantic "да" (yes)
            0xD0B4, 0xD094 => .all,
            // ы (lowercase) / Ы (uppercase) — S key on ЙЦУКЕН
            0xD18B, 0xD0AB => .safe_only,
            // т (lowercase) / Т (uppercase) — N key on ЙЦУКЕН
            0xD182, 0xD0A2 => .none,
            else => null,
        };
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

    // ── Interactive session picker ────────────────────────────────────

    /// Show an interactive session picker. Returns selected entry index or null on cancel.
    /// Caller must be in uncook (raw) mode.
    fn pickSession(self: *Repl, entries: []const session.SessionEntry, current_sid: ?[]const u8) ?usize {
        if (entries.len == 0) return null;

        var selected: usize = 0;
        const count = entries.len;

        // Print header + all entries initially
        io.writeOut("\r\n\x1b[1mSessions:\x1b[0m  \x1b[2m(\xe2\x86\x91\xe2\x86\x93 navigate, Enter select, Esc cancel)\x1b[0m\r\n\r\n") catch {};
        for (entries, 0..) |e, i| {
            self.renderPickerLine(e, i, selected, current_sid);
            io.writeOut("\r\n") catch {};
        }

        // Move cursor up to first entry (we're one line past the last entry)
        io.printOut("\x1b[{d}A", .{count}) catch {};

        while (true) {
            const key = self.readKey() catch return null;
            const old = selected;
            switch (key) {
                .up => selected = if (selected == 0) count - 1 else selected - 1,
                .down => selected = if (selected == count - 1) 0 else selected + 1,
                .enter => {
                    // Move cursor past the list before returning
                    if (selected < count - 1) {
                        io.printOut("\x1b[{d}B", .{count - 1 - selected}) catch {};
                    }
                    io.writeOut("\r\n") catch {};
                    return selected;
                },
                .ctrl_c, .eof => {
                    if (selected < count - 1) {
                        io.printOut("\x1b[{d}B", .{count - 1 - selected}) catch {};
                    }
                    io.writeOut("\r\n") catch {};
                    return null;
                },
                .unknown => {
                    // ESC (bare) — cancel
                    if (selected < count - 1) {
                        io.printOut("\x1b[{d}B", .{count - 1 - selected}) catch {};
                    }
                    io.writeOut("\r\n") catch {};
                    return null;
                },
                .char => |ch| {
                    if (ch.len == 1 and (ch[0] == 'q' or ch[0] == 'Q')) {
                        if (selected < count - 1) {
                            io.printOut("\x1b[{d}B", .{count - 1 - selected}) catch {};
                        }
                        io.writeOut("\r\n") catch {};
                        return null;
                    }
                },
                else => {},
            }
            if (old != selected) {
                // Cursor is at line `old` — redraw it as deselected
                self.renderPickerLine(entries[old], old, selected, current_sid);
                // Move from `old` to `selected`
                if (selected < old) {
                    io.printOut("\x1b[{d}A", .{old - selected}) catch {};
                } else {
                    io.printOut("\x1b[{d}B", .{selected - old}) catch {};
                }
                // Redraw new selected line
                self.renderPickerLine(entries[selected], selected, selected, current_sid);
            }
        }
    }

    /// Render a single picker line (overwrites current terminal line).
    fn renderPickerLine(self: *Repl, entry: session.SessionEntry, idx: usize, selected: usize, current_sid: ?[]const u8) void {
        _ = self;
        const is_selected = (idx == selected);
        const is_current = if (current_sid) |sid| std.mem.eql(u8, entry.id, sid) else false;

        // Clear line and write
        io.writeOut("\r\x1b[2K") catch {};
        if (is_selected) {
            // ▸ bright magenta + bold entry
            io.writeOut("  \x1b[95m\xe2\x96\xb8\x1b[0m \x1b[1m") catch {};
        } else {
            io.writeOut("    \x1b[2m") catch {};
        }
        io.printOut("{s} ({s})", .{ entry.id, entry.model }) catch {};
        if (is_current) {
            io.writeOut(" \x1b[95m*\x1b[0m") catch {};
            if (!is_selected) io.writeOut("\x1b[2m") catch {};
        }
        if (entry.summary) |s| {
            // Truncate summary to ~50 chars
            const max_len: usize = 50;
            if (s.len > max_len) {
                io.writeOut(" — ") catch {};
                io.writeOut(s[0..max_len]) catch {};
                io.writeOut("…") catch {};
            } else {
                io.printOut(" — {s}", .{s}) catch {};
            }
        }
        io.writeOut("\x1b[0m") catch {};
    }
};

/// Free all allocator-owned memory in a ChatMessage.
/// Delegates to message.freeMessage (shared with agent.zig).
const freeMessage = message.freeMessage;

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
const SEPARATOR = "";

// StatusBar is now managed reactively via src/state.zig (zefx stores + watchers).

// ── File-level context for node.zig hooks ────────────────────────────

/// Context shared between the REPL and node.zig hook functions.
/// Set before each call to node.run() so hooks can access REPL state.
const ReplContext = struct {
    allocator: std.mem.Allocator,
    sess_state: *state.SessionState,
    current_session_id: ?[]const u8,
    repl: *Repl,
    resolved: *const config_types.ResolvedConfig,
    yolo: bool,
};

var repl_ctx: ReplContext = undefined;

fn hookLlmStart() void {
    repl_ctx.sess_state.events.phase_changed.emit(.streaming);
    state.syncStatus(repl_ctx.sess_state);
    io.startSpinner("Thinking...");
}

fn hookLlmEnd() void {
    io.stopSpinner();
}

fn hookTokens(usage: node.TokenUsage) void {
    repl_ctx.sess_state.events.tokens_received.emit(.{
        .prompt_tokens = usage.prompt_tokens,
        .completion_tokens = usage.completion_tokens,
        .reasoning_tokens = usage.reasoning_tokens,
        .cache_read_tokens = usage.cache_read_tokens,
        .cache_write_tokens = usage.cache_write_tokens,
    });

    // Context window warning at 80%
    const max_ctx = repl_ctx.resolved.config.max_context_tokens;
    if (max_ctx > 0 and usage.prompt_tokens > 0) {
        const pct = (@as(u64, usage.prompt_tokens) * 100) / @as(u64, max_ctx);
        if (pct >= 80 and pct < 90) {
            io.printOut("\x1b[33m[warning: {d}% context window used ({d}k/{d}k tokens)]\x1b[0m\r\n", .{
                pct,
                usage.prompt_tokens / 1000,
                max_ctx / 1000,
            }) catch {};
        }
    }
}

fn hookIteration() void {
    repl_ctx.sess_state.events.iteration_completed.emit({});
}

fn hookText(_: []const u8) void {
    io.writeOut("\r\n") catch {};
}

fn hookToolCalls(tcs: []const message.ToolCall) tools.PermissionLevel {
    const alloc = repl_ctx.allocator;
    const ss = repl_ctx.sess_state;

    // --yolo: auto-grant all permissions, skip prompt
    if (repl_ctx.yolo) {
        ss.events.permission_granted.emit(.all);
    }

    // Ask permission on first tool use in session
    if (!repl_ctx.yolo and ss.stores.permission.get() == .none) {
        ss.events.phase_changed.emit(.awaiting_permission);
        io.writeOut("\r\n") catch {};
        for (tcs) |tc| {
            const risk = tools.toolRisk(tc.function.name);
            const color: []const u8 = switch (risk) {
                .safe => "\x1b[32m",
                .write => "\x1b[33m",
                .dangerous => "\x1b[31m",
            };
            io.writeOut("  ") catch {};
            io.writeOut(color) catch {};
            io.writeOut("\xe2\x9c\xa6 ") catch {}; // ✦
            if (extractKeyArg(alloc, tc.function.name, tc.function.arguments)) |key_arg| {
                defer alloc.free(key_arg);
                io.printOut("{s}\x1b[0m\x1b[2m({s})\x1b[0m\r\n", .{ tools.displayToolName(tc.function.name), key_arg }) catch {};
            } else {
                io.printOut("{s}\x1b[0m\r\n", .{tools.displayToolName(tc.function.name)}) catch {};
            }
        }
        io.writeOut("Allow? [\x1b[32my\x1b[0m]es all / [\x1b[33ms\x1b[0m]afe only / [\x1b[31mn\x1b[0m]o ") catch {};

        const perm = repl_ctx.repl.readPermission() catch .none;
        ss.events.permission_granted.emit(perm);
        return ss.stores.permission.get();
    }

    // Effective permission: yolo always .all, otherwise read from store
    const eff_perm: tools.PermissionLevel = if (repl_ctx.yolo) .all else ss.stores.permission.get();

    // Display allowed tools with ✦ prefix
    for (tcs) |tc| {
        if (tools.isAllowed(tc.function.name, eff_perm)) {
            io.writeOut("  \x1b[95m\xe2\x9c\xa6\x1b[0m ") catch {}; // magenta ✦
            if (extractKeyArg(alloc, tc.function.name, tc.function.arguments)) |key_arg| {
                defer alloc.free(key_arg);
                io.printOut("\x1b[1m{s}\x1b[0m\x1b[2m({s})\x1b[0m\r\n", .{ tools.displayToolName(tc.function.name), key_arg }) catch {};
            } else {
                io.printOut("\x1b[1m{s}\x1b[0m\r\n", .{tools.displayToolName(tc.function.name)}) catch {};
            }
        } else {
            io.printOut("\x1b[31m  \xe2\x8a\x98 {s} (not allowed)\x1b[0m\r\n", .{tools.displayToolName(tc.function.name)}) catch {};
        }
    }

    // Start spinner for tool execution phase
    ss.events.phase_changed.emit(.executing_tools);

    // Build label from display names: "Read, Bash"
    var label_buf: [256]u8 = undefined;
    var label_pos: usize = 0;
    for (tcs) |tc| {
        if (tools.isAllowed(tc.function.name, eff_perm)) {
            const name = tools.displayToolName(tc.function.name);
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
    }
    if (label_pos > 0) {
        state.syncStatus(ss);
        io.startSpinner(label_buf[0..label_pos]);
    }

    // In yolo mode, always return .all regardless of store state (emit may be async)
    if (repl_ctx.yolo) return .all;
    return ss.stores.permission.get();
}

fn hookToolResult(_: message.ToolCall, content: []const u8) void {
    if (content.len == 0) return;
    const max_preview = 1024;
    const preview = if (content.len > max_preview) content[0..max_preview] else content;
    const color: []const u8 = if (isErrorOutput(content)) "\x1b[31m" else "\x1b[2m";
    io.writeOut("    \x1b[2m\xe2\x97\x87\x1b[0m ") catch {}; // dim ◇
    io.writeOut(color) catch {};
    io.writeText(preview) catch {};
    if (content.len > max_preview) {
        io.printOut("\r\n     ... ({d} bytes total)", .{content.len}) catch {};
    }
    io.writeOut("\x1b[0m\r\n") catch {};
}

fn hookCancel() void {
    io.stopSpinner();
    repl_ctx.sess_state.events.cancel_requested.emit(true);
    io.writeOut("\r\n\x1b[33m\xe2\x8a\x98 Cancelled\x1b[0m\r\n\r\n") catch {};
    repl_ctx.sess_state.events.phase_changed.emit(.idle);
}

fn hookHttpError(status_code: u16, msg: []const u8) void {
    io.stopSpinner();
    io.printOut("\r\n\x1b[31m\xe2\x9c\xa6 HTTP {d} — {s}\x1b[0m\r\n\r\n", .{ status_code, msg }) catch {};
}

fn hookLoopDetected() ?[]const u8 {
    io.writeOut("\x1b[33m[loop detected — injecting steering]\x1b[0m\r\n") catch {};
    return repl_ctx.allocator.dupe(u8,
        "[SYSTEM WARNING: You appear to be stuck in a loop, " ++
        "repeating the same tool calls. Try a different approach, " ++
        "read the error messages carefully, or ask the user for guidance.]",
    ) catch null;
}

fn hookCompactionCheck(history: *std.ArrayList(message.ChatMessage)) void {
    const max_ctx = repl_ctx.resolved.config.max_context_tokens;
    if (max_ctx == 0 or history.items.len <= 6) return;

    // Estimate current context size from history content (not cumulative tokens)
    var estimated: u64 = 0;
    for (history.items) |msg| {
        estimated += estimateMessageTokens(msg);
    }
    const pct = (estimated * 100) / @as(u64, max_ctx);
    if (pct >= 85) {
        // Keep only what fits in 70% of context (leave room for response + tools)
        const budget: u64 = (max_ctx * 70) / 100;
        // Scan from end to find how many recent messages fit
        var tokens: u64 = estimateMessageTokens(history.items[0]); // system prompt
        var keep_from: usize = history.items.len;
        var i: usize = history.items.len;
        while (i > 1) {
            i -= 1;
            const msg_tokens = estimateMessageTokens(history.items[i]);
            if (tokens + msg_tokens > budget) break;
            tokens += msg_tokens;
            keep_from = i;
        }
        // Advance to user message boundary
        while (keep_from < history.items.len) {
            switch (history.items[keep_from]) {
                .text => |tm| if (tm.role == .user) break,
                else => {},
            }
            keep_from += 1;
        }
        const safe_start = keep_from;
        if (safe_start <= 1 or safe_start >= history.items.len) return;

        const removed_count = safe_start - 1;
        for (history.items[1..safe_start]) |msg| {
            freeMessage(repl_ctx.allocator, msg);
        }
        const kept_tail = history.items.len - safe_start;
        std.mem.copyForwards(message.ChatMessage, history.items[1..], history.items[safe_start..]);
        history.shrinkRetainingCapacity(1 + kept_tail);
        io.printOut("\x1b[33m[context compacted: dropped {d} messages, kept {d} (~{d}k tokens)]\x1b[0m\r\n", .{ removed_count, kept_tail, tokens / 1000 }) catch {};
    }
}

fn hookPersist(msg: message.ChatMessage) void {
    if (repl_ctx.current_session_id) |sid| {
        session.appendMessage(repl_ctx.allocator, sid, msg);
    }
}

fn hookGetPermission() tools.PermissionLevel {
    return repl_ctx.sess_state.stores.permission.get();
}

fn printHelp() void {
    io.writeOut("\r\n\x1b[1mCommands:\x1b[0m\r\n") catch {};
    io.writeOut("  /compact  — summarize & compress context\r\n") catch {};
    io.writeOut("  /help     — show this help\r\n") catch {};
    io.writeOut("  /tools    — list available tools\r\n") catch {};
    io.writeOut("  /skills   — list available skills\r\n") catch {};
    io.writeOut("  /usage    — show session token usage\r\n") catch {};
    io.writeOut("  /sessions — pick & load a session\r\n") catch {};
    io.writeOut("  /exit     — quit (also /quit, /q)\r\n") catch {};
    io.writeOut("\r\n\x1b[1mTool permissions:\x1b[0m\r\n") catch {};
    io.writeOut("  y — allow all tools\r\n") catch {};
    io.writeOut("  s — safe only (read/list/search)\r\n") catch {};
    io.writeOut("  n — deny all tools\r\n") catch {};
    io.writeOut("\r\n") catch {};
}

/// /compact — summarize the current conversation via LLM and replace history.
fn compactSession(
    allocator: std.mem.Allocator,
    resolved: *const config_types.ResolvedConfig,
    history: *std.ArrayList(message.ChatMessage),
    sess_state: *state.SessionState,
    session_id: ?[]const u8,
) void {
    if (history.items.len <= 3) {
        io.writeOut("\r\n\x1b[2mNothing to compact (too few messages).\x1b[0m\r\n\r\n") catch {};
        return;
    }

    // Build a summary request: system prompt + all history as one user message
    var summary_buf: std.ArrayList(u8) = .empty;
    defer summary_buf.deinit(allocator);
    const w = summary_buf.writer(allocator);

    w.writeAll("Summarize this conversation concisely. Include:\n") catch return;
    w.writeAll("- Key decisions and conclusions reached\n") catch return;
    w.writeAll("- Important file paths, code changes, and tool results\n") catch return;
    w.writeAll("- Current state of the task (what's done, what's pending)\n") catch return;
    w.writeAll("- Any errors encountered and how they were resolved\n") catch return;
    w.writeAll("\nKeep the summary dense and factual. Use bullet points.\n\n") catch return;
    w.writeAll("--- CONVERSATION START ---\n") catch return;

    for (history.items[1..]) |msg| {
        switch (msg) {
            .text => |tm| {
                w.print("[{s}]: ", .{@tagName(tm.role)}) catch {};
                w.writeAll(tm.content) catch {};
                w.writeByte('\n') catch {};
            },
            .tool_use => |tu| {
                for (tu.tool_calls) |tc| {
                    w.print("[tool_call]: {s}({s})\n", .{ tc.function.name, tc.function.arguments }) catch {};
                }
            },
            .tool_result => |tr| {
                // Truncate long tool results in summary input
                const max_result = @min(tr.content.len, 500);
                w.print("[tool_result]: {s}", .{tr.content[0..max_result]}) catch {};
                if (tr.content.len > 500) w.writeAll("...[truncated]") catch {};
                w.writeByte('\n') catch {};
            },
        }
    }
    w.writeAll("--- CONVERSATION END ---\n") catch return;

    io.writeOut("\r\n\x1b[33m\xe2\x9c\xa7 Compacting...\x1b[0m") catch {};

    // Single LLM call for summary (no tools)
    const summary_prompt = summary_buf.items;
    var summary_messages = [_]message.ChatMessage{
        .{ .text = .{ .role = .system, .content = "You are a conversation summarizer. Produce a concise summary of the given conversation." } },
        .{ .text = .{ .role = .user, .content = summary_prompt } },
    };

    const body = message.buildRequestBody(allocator, .{
        .model = resolved.resolved_model,
        .messages = &summary_messages,
        .max_tokens = 4096,
        .temperature = 0.0,
        .stream = true,
    }) catch {
        io.writeOut(" \x1b[31mfailed\x1b[0m\r\n\r\n") catch {};
        return;
    };
    defer allocator.free(body);

    const noop_cb = struct {
        fn cb(_: []const u8) void {}
    }.cb;
    const result = http_client.streamChatCompletion(
        allocator,
        resolved.completions_url,
        resolved.auth.api_key,
        body,
        &noop_cb,
        true, // silent
    ) catch {
        io.writeOut(" \x1b[31mfailed\x1b[0m\r\n\r\n") catch {};
        return;
    };

    const summary_text = switch (result.response) {
        .text => |t| t,
        else => {
            io.writeOut(" \x1b[31mfailed\x1b[0m\r\n\r\n") catch {};
            return;
        },
    };
    defer allocator.free(summary_text);

    // Track tokens
    if (result.usage) |usage| {
        sess_state.events.tokens_received.emit(.{
            .prompt_tokens = usage.prompt_tokens,
            .completion_tokens = usage.completion_tokens,
            .reasoning_tokens = usage.reasoning_tokens,
            .cache_read_tokens = usage.cache_read_tokens,
            .cache_write_tokens = usage.cache_write_tokens,
        });
    }

    // Replace history: keep system prompt, add summary as assistant message
    const old_count = history.items.len - 1;
    for (history.items[1..]) |msg| {
        freeMessage(allocator, msg);
    }
    history.shrinkRetainingCapacity(1);

    // Add summary as context
    const summary_content = std.fmt.allocPrint(
        allocator,
        "[Previous conversation summary]\n{s}",
        .{summary_text},
    ) catch allocator.dupe(u8, summary_text) catch return;
    history.append(allocator, .{
        .text = .{ .role = .assistant, .content = summary_content },
    }) catch {
        allocator.free(summary_content);
        return;
    };

    // Save summary to session file
    if (session_id) |sid| {
        session.writeSummary(allocator, sid, summary_text);
    }

    const new_tokens = estimateTokens(summary_content);
    io.printOut(" \x1b[32mdone\x1b[0m ({d} messages → ~{d}k tokens)\r\n\r\n", .{ old_count, new_tokens / 1000 }) catch {};
}

// MAX_AGENT_ITERATIONS now comes from resolved.config.max_iterations

// Loop detection and tool hashing moved to node.zig — aliases for tests.
const LOOP_DETECTION_WINDOW = node.LOOP_DETECTION_WINDOW;
const hashToolSignature = node.hashToolSignature;
const detectLoop = node.detectLoop;

/// Atomic flag for SIGWINCH (terminal resize).
/// Print last N user/assistant text messages as a recap when resuming a session.
fn printRecentMessages(history: *std.ArrayList(message.ChatMessage)) void {
    const max_recap = 4;
    const items = history.items;

    // Collect indices of text messages (skip system, tool_use, tool_result)
    var indices: [max_recap]usize = undefined;
    var count: usize = 0;

    // Walk backwards to find last max_recap text messages
    var i: usize = items.len;
    while (i > 0 and count < max_recap) {
        i -= 1;
        switch (items[i]) {
            .text => |tm| {
                if (tm.role == .user or tm.role == .assistant) {
                    indices[count] = i;
                    count += 1;
                }
            },
            else => {},
        }
    }

    if (count == 0) return;

    // Print in chronological order (indices are reversed)
    var j: usize = count;
    while (j > 0) {
        j -= 1;
        const tm = items[indices[j]].text;
        const prefix: []const u8 = if (tm.role == .user) "you:" else "\xe2\x97\x87";
        const max_len: usize = 120;
        const content = tm.content;
        const truncated = if (content.len > max_len) content[0..max_len] else content;
        const ellipsis: []const u8 = if (content.len > max_len) "\xe2\x80\xa6" else "";

        // Replace newlines with spaces for single-line display
        var line_buf: [128]u8 = undefined;
        const display = blk: {
            if (truncated.len <= line_buf.len) {
                @memcpy(line_buf[0..truncated.len], truncated);
                const buf = line_buf[0..truncated.len];
                for (buf) |*c| {
                    if (c.* == '\n' or c.* == '\r') c.* = ' ';
                }
                break :blk buf;
            }
            break :blk truncated;
        };

        io.printOut("\x1b[2m  {s} {s}{s}\x1b[0m\r\n", .{ prefix, display, ellipsis }) catch {};
    }
    io.writeOut("\r\n") catch {};
}

var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// SIGWINCH signal handler — just sets the atomic flag.
fn sigwinchHandler(_: c_int) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

/// Main REPL entry point — called from main.zig.
pub fn run(allocator: std.mem.Allocator, resolved: *const config_types.ResolvedConfig, continue_last: bool, cli_session_id: ?[]const u8, yolo: bool, infinity: bool) !void {
    // Clear screen + cursor home — stay in main screen buffer so terminal scrollback works.
    // Unlike alternate screen (\x1b[?1049h), main buffer preserves content that scrolls
    // past the top of the scroll region, giving users mouse wheel + Shift+PgUp/PgDn for free.
    io.writeOut("\x1b[2J\x1b[H") catch {};

    // Set up terminal zones FIRST: scroll region + separator + input + status bar.
    // CSI r (DECSTBM) resets cursor to home (1,1) per VT100 spec, so we must
    // set up zones before printing anything — no save/restore across CSI r.
    const term = io.getTerminalSize();
    io.setupScrollRegion(term.rows);
    io.renderSeparator(term.rows - 3, term.cols); // top separator (above input)
    io.renderSeparator(term.rows - 1, term.cols); // bottom separator (below input)
    // Position cursor at bottom of scroll region — content grows upward like a real terminal
    io.printOut("\x1b[{d};1H", .{term.rows - 4}) catch {};

    // Print banner — scrolls up naturally from the bottom
    io.printText("\x1b[1mzaica\x1b[0m v0.3 \xc2\xb7 {s}/{s}\n", .{
        resolved.config.provider,
        resolved.resolved_model,
    }) catch {};
    io.writeText("\x1b[2mType /help for commands, /exit to quit.\x1b[0m\n\n") catch {};

    // ── Autonomous mode banners ──────────────────────────────────────
    if (yolo and infinity) {
        io.writeText("\x1b[33;1m\xe2\x9a\xa0\xe2\x88\x9e Full autonomous mode — all tools auto-approved, no limits\x1b[0m\n\n") catch {};
    } else if (yolo) {
        io.writeText("\x1b[33;1m\xe2\x9a\xa0 --yolo — all tools auto-approved\x1b[0m\n\n") catch {};
    } else if (infinity) {
        io.writeText("\x1b[36;1m\xe2\x88\x9e --infinity — no iteration or timeout limits\x1b[0m\n\n") catch {};
    }

    // Apply bash timeout from config
    tools.setBashTimeout(resolved.config.bash_timeout);

    // ── Skills scanning ────────────────────────────────────────────────
    const cwd_buf = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    const skill_list = skills.scan(allocator, cwd_buf);
    defer {
        if (skill_list.len > 0) skills.freeSkills(allocator, skill_list);
        if (cwd_buf) |b| allocator.free(b);
    }
    tools.setActiveSkills(skill_list);

    // Build enhanced system prompt with skills
    const skills_section = skills.buildPromptSection(allocator, skill_list);
    defer if (skills_section.len > 0) allocator.free(skills_section);

    const base_prompt = resolved.config.system_prompt;
    const autonomous_suffix: []const u8 = if (yolo) config_types.AUTONOMOUS_SYSTEM_PROMPT else "";
    const effective_system_prompt = if (skills_section.len > 0 or autonomous_suffix.len > 0)
        std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base_prompt, autonomous_suffix, skills_section }) catch base_prompt
    else
        base_prompt;
    defer if (effective_system_prompt.ptr != base_prompt.ptr) allocator.free(effective_system_prompt);

    var sess_state = state.init(allocator, resolved.resolved_model, resolved.config.max_context_tokens, term.rows, term.cols);
    state.bind(&sess_state); // Set stable pointer for watchers + initial render
    defer sess_state.deinit();

    // ── Session persistence setup ──────────────────────────────────────
    var current_session_id: ?[]const u8 = null;
    var resumed_session = false;

    // Resolve session: --continue or --session <id>
    if (cli_session_id) |sid| {
        current_session_id = allocator.dupe(u8, sid) catch null;
    } else if (continue_last) {
        current_session_id = session.findMostRecentSession(allocator) catch null;
    }

    // Generate new session ID if not resuming
    if (current_session_id == null) {
        current_session_id = session.generateSessionId(allocator) catch null;
    } else {
        resumed_session = true;
    }

    // Write metadata for new sessions
    if (current_session_id) |sid| {
        if (!resumed_session) {
            session.writeMetadata(allocator, sid, .{
                .id = sid,
                .model = resolved.resolved_model,
                .provider = resolved.config.provider,
                .created_at = std.time.timestamp(),
            }) catch {};
        }
    }

    defer {
        if (current_session_id) |sid| allocator.free(sid);
    }

    // Install SIGWINCH handler for terminal resize
    const sa = posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    var repl = try Repl.init(allocator);
    repl.streamMode(); // start in stream mode (ECHO off) to suppress stray input
    repl.loadHistory();
    defer {
        // Clean up terminal: reset scroll region, clear chrome, show cursor
        io.resetScrollRegion();
        const ts = io.getTerminalSize();
        io.printOut("\x1b[{d};1H", .{ts.rows -| 3}) catch {}; // position at first chrome row
        io.writeOut("\x1b[J") catch {}; // clear chrome (separator + input + separator + status)
        io.writeOut("\x1b[?25h") catch {}; // ensure cursor visible
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
        .text = .{ .role = .system, .content = effective_system_prompt },
    });

    // Load resumed session messages (skip system prompt — use current one)
    if (resumed_session) {
        if (current_session_id) |sid| {
            var loaded = session.loadSession(allocator, sid) catch |err| blk: {
                if (err == error.SessionNotFound) {
                    io.writeOut("\x1b[33mSession not found, starting new session.\x1b[0m\r\n") catch {};
                    // Fall back to new session
                    allocator.free(sid);
                    current_session_id = session.generateSessionId(allocator) catch null;
                    resumed_session = false;
                    if (current_session_id) |new_sid| {
                        session.writeMetadata(allocator, new_sid, .{
                            .id = new_sid,
                            .model = resolved.resolved_model,
                            .provider = resolved.config.provider,
                            .created_at = std.time.timestamp(),
                        }) catch {};
                    }
                }
                break :blk null;
            };
            if (loaded) |*l| {
                defer l.deinit(allocator);

                // Determine how many messages from the tail fit in context.
                // Reserve 20% of context for new conversation; use 80% for history.
                const max_ctx = resolved.config.max_context_tokens;
                const budget: u64 = if (max_ctx > 0) (max_ctx * 80) / 100 else 0;
                // Estimate system prompt tokens
                const sys_tokens = estimateTokens(effective_system_prompt);

                // Find the start index: scan backwards, accumulating token estimate.
                // Always start on a user message boundary for coherent context.
                var start_idx: usize = 0;
                if (budget > 0 and l.messages.len > 0) {
                    var tokens: u64 = sys_tokens;
                    var idx: usize = l.messages.len;
                    while (idx > 0) {
                        idx -= 1;
                        const msg = l.messages[idx];
                        // Skip system messages (we use current prompt)
                        switch (msg) {
                            .text => |tm| if (tm.role == .system) continue,
                            else => {},
                        }
                        tokens += estimateMessageTokens(msg);
                        if (tokens > budget) {
                            idx += 1; // this message doesn't fit
                            break;
                        }
                    }
                    // Advance to next user message boundary for clean context
                    while (idx < l.messages.len) {
                        switch (l.messages[idx]) {
                            .text => |tm| if (tm.role == .user) break,
                            else => {},
                        }
                        idx += 1;
                    }
                    start_idx = idx;
                }

                // Load messages from start_idx onwards
                for (l.messages[start_idx..]) |msg| {
                    switch (msg) {
                        .text => |tm| {
                            if (tm.role == .system) continue;
                            const content = allocator.dupe(u8, tm.content) catch continue;
                            history.append(allocator, .{ .text = .{ .role = tm.role, .content = content } }) catch {
                                allocator.free(content);
                                continue;
                            };
                        },
                        .tool_use => |tu| {
                            var tcs = allocator.alloc(message.ToolCall, tu.tool_calls.len) catch continue;
                            var ok: usize = 0;
                            for (tu.tool_calls) |tc| {
                                tcs[ok] = .{
                                    .id = allocator.dupe(u8, tc.id) catch break,
                                    .function = .{
                                        .name = allocator.dupe(u8, tc.function.name) catch break,
                                        .arguments = allocator.dupe(u8, tc.function.arguments) catch break,
                                    },
                                };
                                ok += 1;
                            }
                            if (ok == tu.tool_calls.len) {
                                history.append(allocator, .{ .tool_use = .{ .tool_calls = tcs } }) catch {};
                            }
                        },
                        .tool_result => |tr| {
                            const tcid = allocator.dupe(u8, tr.tool_call_id) catch continue;
                            const content = allocator.dupe(u8, tr.content) catch {
                                allocator.free(tcid);
                                continue;
                            };
                            history.append(allocator, .{ .tool_result = .{ .tool_call_id = tcid, .content = content } }) catch {
                                allocator.free(tcid);
                                allocator.free(content);
                            };
                        },
                    }
                }
                const msg_count = history.items.len - 1; // minus system prompt
                const total_msgs = l.messages.len;
                if (msg_count > 0) {
                    if (start_idx > 0) {
                        io.printOut("\x1b[2mResumed session {s} ({d}/{d} messages, trimmed to fit context)\x1b[0m\r\n\r\n", .{ sid, msg_count, total_msgs }) catch {};
                    } else {
                        io.printOut("\x1b[2mResumed session {s} ({d} messages)\x1b[0m\r\n\r\n", .{ sid, msg_count }) catch {};
                    }
                    printRecentMessages(&history);
                }
            }
        }
    }

    // Persist system prompt for new sessions
    if (!resumed_session) {
        if (current_session_id) |sid| {
            session.appendMessage(allocator, sid, .{
                .text = .{ .role = .system, .content = effective_system_prompt },
            });
        }
    }

    while (true) {
        // Check for terminal resize
        if (sigwinch_received.swap(false, .acquire)) {
            const ts = io.getTerminalSize();
            sess_state.events.terminal_resized.emit(.{ .rows = ts.rows, .cols = ts.cols });
        }

        // Show cursor (entering input mode) + save scroll region cursor
        io.writeOut("\x1b[?25h") catch {};
        io.writeOut("\x1b7") catch {};
        const maybe_line = try repl.readLine();
        // Clear input line and restore scroll region cursor
        {
            const ts = io.getTerminalSize();
            io.printOut("\x1b[{d};1H\x1b[K", .{ts.rows - 2}) catch {};
        }
        io.writeOut("\x1b8") catch {};
        io.writeOut("\x1b[?25l") catch {}; // hide cursor (leaving input mode)

        const line = maybe_line orelse break;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r ");
        if (trimmed.len == 0) continue;

        // Echo user input into scroll region
        io.writeOut("\x1b[95m\xc2\xbb \x1b[0m") catch {};
        io.writeText(trimmed) catch {};
        io.writeOut("\r\n") catch {};

        if (isExitCommand(trimmed)) break;
        if (std.mem.eql(u8, trimmed, "/tools")) {
            tools.printToolList();
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/help")) {
            printHelp();
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/sessions")) {
            const entries = session.listSessions(allocator, 20) catch &.{};
            defer if (entries.len > 0) session.freeSessionEntries(allocator, entries);
            if (entries.len == 0) {
                io.writeOut("\r\n\x1b[2mNo sessions found.\x1b[0m\r\n\r\n") catch {};
                continue;
            }
            repl.uncook();
            const picked = repl.pickSession(entries, current_session_id);
            repl.cook();
            if (picked) |idx| {
                const target = entries[idx];
                // Don't reload if it's already the current session
                if (current_session_id) |sid| {
                    if (std.mem.eql(u8, target.id, sid)) {
                        io.printOut("\x1b[2mAlready on session {s}\x1b[0m\r\n\r\n", .{sid}) catch {};
                        continue;
                    }
                }
                // Load selected session
                var loaded = session.loadSession(allocator, target.id) catch |err| blk: {
                    io.printOut("\x1b[31mFailed to load session: {}\x1b[0m\r\n\r\n", .{err}) catch {};
                    break :blk null;
                };
                if (loaded) |*l| {
                    defer l.deinit(allocator);
                    // Free existing history (skip [0] system prompt — borrowed from config)
                    for (history.items[1..]) |msg| freeMessage(allocator, msg);
                    history.shrinkRetainingCapacity(1);
                    // Dupe loaded messages into history (skip system messages)
                    for (l.messages) |msg| {
                        switch (msg) {
                            .text => |tm| {
                                if (tm.role == .system) continue;
                                const content = allocator.dupe(u8, tm.content) catch continue;
                                history.append(allocator, .{ .text = .{ .role = tm.role, .content = content } }) catch {
                                    allocator.free(content);
                                    continue;
                                };
                            },
                            .tool_use => |tu| {
                                var tcs = allocator.alloc(message.ToolCall, tu.tool_calls.len) catch continue;
                                var ok: usize = 0;
                                for (tu.tool_calls) |tc| {
                                    tcs[ok] = .{
                                        .id = allocator.dupe(u8, tc.id) catch break,
                                        .function = .{
                                            .name = allocator.dupe(u8, tc.function.name) catch break,
                                            .arguments = allocator.dupe(u8, tc.function.arguments) catch break,
                                        },
                                    };
                                    ok += 1;
                                }
                                if (ok == tu.tool_calls.len) {
                                    history.append(allocator, .{ .tool_use = .{ .tool_calls = tcs } }) catch {};
                                }
                            },
                            .tool_result => |tr| {
                                const tcid = allocator.dupe(u8, tr.tool_call_id) catch continue;
                                const content = allocator.dupe(u8, tr.content) catch {
                                    allocator.free(tcid);
                                    continue;
                                };
                                history.append(allocator, .{ .tool_result = .{ .tool_call_id = tcid, .content = content } }) catch {
                                    allocator.free(tcid);
                                    allocator.free(content);
                                };
                            },
                        }
                    }
                    // Update current session ID
                    if (current_session_id) |old| allocator.free(old);
                    current_session_id = allocator.dupe(u8, target.id) catch null;
                    const msg_count = history.items.len - 1;
                    io.printOut("\x1b[95m\xe2\x9c\xa6\x1b[0m Switched to session \x1b[1m{s}\x1b[0m ({d} messages)\r\n\r\n", .{ target.id, msg_count }) catch {};
                    printRecentMessages(&history);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/skills")) {
            skills.printSkillList(skill_list);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/compact")) {
            compactSession(allocator, resolved, &history, &sess_state, current_session_id);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/usage")) {
            io.writeOut("\r\n\x1b[1mSession token usage:\x1b[0m\r\n") catch {};
            io.printOut("  Prompt tokens:     {d}\r\n", .{sess_state.stores.prompt_tokens.get()}) catch {};
            io.printOut("  Completion tokens: {d}\r\n", .{sess_state.stores.completion_tokens.get()}) catch {};
            io.printOut("  Total tokens:      {d}\r\n", .{sess_state.stores.total_tokens.get()}) catch {};
            const reasoning = sess_state.stores.reasoning_tokens.get();
            if (reasoning > 0) {
                io.printOut("  Reasoning tokens:  {d}\r\n", .{reasoning}) catch {};
            }
            const cache_r = sess_state.stores.cache_read_tokens.get();
            const cache_w = sess_state.stores.cache_write_tokens.get();
            if (cache_r > 0 or cache_w > 0) {
                io.printOut("  Cache read:        {d}\r\n", .{cache_r}) catch {};
                io.printOut("  Cache write:       {d}\r\n", .{cache_w}) catch {};
            }
            io.printOut("  Context limit:     {d}\r\n\r\n", .{resolved.config.max_context_tokens}) catch {};
            continue;
        }

        const user_content = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(user_content);
        try history.append(allocator, .{ .text = .{ .role = .user, .content = user_content } });
        if (current_session_id) |sid| {
            session.appendMessage(allocator, sid, .{ .text = .{ .role = .user, .content = user_content } });
        }

        // Visual separator between input and output
        io.writeOut("\r\n") catch {};

        // Clear cancel flag at start of each user message
        io.clearCancelFlag();

        // Signal new user message — resets $iterations store
        sess_state.events.user_message_sent.emit({});

        // Set up file-level context for hook functions
        repl_ctx = .{
            .allocator = allocator,
            .sess_state = &sess_state,
            .current_session_id = current_session_id,
            .repl = &repl,
            .resolved = resolved,
            .yolo = yolo,
        };

        // Run the agentic loop via node.zig
        const node_result = node.run(allocator, resolved, .{
            .system_prompt = effective_system_prompt,
            .tool_defs = tools.all_tools,
            .max_iterations = resolved.config.max_iterations,
            .permission = sess_state.stores.permission.get(),
            .silent = false,
        }, &history, .{
            .on_llm_start = &hookLlmStart,
            .on_llm_end = &hookLlmEnd,
            .on_tokens = &hookTokens,
            .on_iteration = &hookIteration,
            .on_text = &hookText,
            .on_tool_calls = &hookToolCalls,
            .on_tool_result = &hookToolResult,
            .on_cancel = &hookCancel,
            .on_http_error = &hookHttpError,
            .on_loop_detected = &hookLoopDetected,
            .on_compaction_check = &hookCompactionCheck,
            .on_persist = &hookPersist,
            .get_permission = &hookGetPermission,
        });

        // Reset phase to idle when agentic loop exits
        sess_state.events.phase_changed.emit(.idle);

        // Free caller-owned text (history has its own copy)
        if (node_result.text) |text| allocator.free(text);

        if (node_result.hit_limit) {
            io.writeOut("\x1b[33m(agent loop limit reached)\x1b[0m\r\n") catch {};
        }
    }

    // Show session ID for easy resume
    if (current_session_id) |sid| {
        io.printOut("\r\n\x1b[2mSession: {s}\x1b[0m\r\n", .{sid}) catch {};
        io.printOut("\x1b[2mResume:  zc -c  or  zc --session {s}\x1b[0m\r\n", .{sid}) catch {};
    }
}

// ToolResult, ToolExecContext, executeToolThread, extractTask — moved to node.zig

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
    else if (std.mem.eql(u8, tool_name, "dispatch_agent"))
        "task"
    else if (std.mem.eql(u8, tool_name, "load_skill"))
        "name"
    else
        return null;

    const val = parsed.value.object.get(key) orelse return null;
    if (val != .string or val.string.len == 0) return null;
    const s = val.string;
    const max_len: usize = 80;
    return allocator.dupe(u8, if (s.len > max_len) s[0..max_len] else s) catch null;
}

/// Estimate token count from text length (~4 chars per token).
fn estimateTokens(text: []const u8) u64 {
    return (text.len + 3) / 4;
}

/// Estimate token count for a ChatMessage.
fn estimateMessageTokens(msg: message.ChatMessage) u64 {
    return switch (msg) {
        .text => |tm| estimateTokens(tm.content) + 4, // role overhead
        .tool_use => |tu| blk: {
            var total: u64 = 4;
            for (tu.tool_calls) |tc| {
                total += estimateTokens(tc.id) + estimateTokens(tc.function.name) + estimateTokens(tc.function.arguments);
            }
            break :blk total;
        },
        .tool_result => |tr| estimateTokens(tr.content) + estimateTokens(tr.tool_call_id) + 4,
    };
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

test "extractKeyArg: dispatch_agent returns task" {
    const allocator = std.testing.allocator;
    const result = extractKeyArg(allocator, "dispatch_agent", "{\"task\":\"read and summarize main.zig\"}");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("read and summarize main.zig", result.?);
}

test "extractKeyArg: unknown tool returns null" {
    const allocator = std.testing.allocator;
    try std.testing.expect(extractKeyArg(allocator, "unknown", "{}") == null);
}

test "extractKeyArg: invalid JSON returns null" {
    const allocator = std.testing.allocator;
    try std.testing.expect(extractKeyArg(allocator, "read_file", "not json") == null);
}

// extractTask tests moved to node.zig

test "detectLoop: no loop with few calls" {
    var ring: [LOOP_DETECTION_WINDOW]u64 = undefined;
    @memset(&ring, 0);
    try std.testing.expect(!detectLoop(&ring, 0));
    try std.testing.expect(!detectLoop(&ring, 3));
}

test "detectLoop: detects pattern length 1" {
    var ring: [LOOP_DETECTION_WINDOW]u64 = undefined;
    // Same hash repeated 10 times
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
        ring[i] = i * 7 + 13; // all different
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

test "isErrorOutput: detects errors" {
    try std.testing.expect(isErrorOutput("Error: file not found"));
    try std.testing.expect(isErrorOutput("Permission denied: read_file"));
    try std.testing.expect(!isErrorOutput("file contents here"));
    try std.testing.expect(!isErrorOutput(""));
}

test "slash_commands: unique match completes fully" {
    // "/he" → "/help" (only match)
    const commands = Repl.slash_commands;
    var match_count: usize = 0;
    const prefix = "/he";
    for (commands) |cmd| {
        if (cmd.len >= prefix.len and std.mem.eql(u8, cmd[0..prefix.len], prefix))
            match_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), match_count);
}

test "slash_commands: ambiguous prefix finds common prefix" {
    // "/e" matches "/exit" only
    const commands = Repl.slash_commands;
    var match_count: usize = 0;
    const prefix = "/e";
    for (commands) |cmd| {
        if (cmd.len >= prefix.len and std.mem.eql(u8, cmd[0..prefix.len], prefix))
            match_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), match_count);
}

test "slash_commands: no match for unknown prefix" {
    const commands = Repl.slash_commands;
    var match_count: usize = 0;
    const prefix = "/z";
    for (commands) |cmd| {
        if (cmd.len >= prefix.len and std.mem.eql(u8, cmd[0..prefix.len], prefix))
            match_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), match_count);
}

// ── Cyrillic permission mapping tests ────────────────────────────────

test "matchCyrillicPermission: н/Н maps to .all (Y key)" {
    // н = 0xD0 0xBD (lowercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD0, 0xBD), .all);
    // Н = 0xD0 0x9D (uppercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD0, 0x9D), .all);
}

test "matchCyrillicPermission: д/Д maps to .all (semantic да)" {
    // д = 0xD0 0xB4 (lowercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD0, 0xB4), .all);
    // Д = 0xD0 0x94 (uppercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD0, 0x94), .all);
}

test "matchCyrillicPermission: ы/Ы maps to .safe_only (S key)" {
    // ы = 0xD1 0x8B (lowercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD1, 0x8B), .safe_only);
    // Ы = 0xD0 0xAB (uppercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD0, 0xAB), .safe_only);
}

test "matchCyrillicPermission: т/Т maps to .none (N key)" {
    // т = 0xD1 0x82 (lowercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD1, 0x82), .none);
    // Т = 0xD0 0xA2 (uppercase)
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD0, 0xA2), .none);
}

test "matchCyrillicPermission: unrelated Cyrillic returns null" {
    // а = 0xD0 0xB0 — not a permission key
    try std.testing.expectEqual(Repl.matchCyrillicPermission(0xD0, 0xB0), null);
}

// ── CSI u / Cyrillic Ctrl+key mapping tests ──────────────────────────

test "cyrillicToCtrlKey: ф/Ф maps to ctrl_a (A key)" {
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0444), .ctrl_a); // ф
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0424), .ctrl_a); // Ф
}

test "cyrillicToCtrlKey: с/С maps to ctrl_c (C key)" {
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0441), .ctrl_c); // с
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0421), .ctrl_c); // С
}

test "cyrillicToCtrlKey: в/В maps to ctrl_d (D key)" {
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0432), .ctrl_d); // в
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0412), .ctrl_d); // В
}

test "cyrillicToCtrlKey: у/У maps to ctrl_e (E key)" {
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0443), .ctrl_e); // у
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0423), .ctrl_e); // У
}

test "cyrillicToCtrlKey: ц/Ц maps to ctrl_w (W key)" {
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0446), .ctrl_w); // ц
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0426), .ctrl_w); // Ц
}

test "cyrillicToCtrlKey: unrelated codepoint returns unknown" {
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0430), .unknown); // а
    try std.testing.expectEqual(Repl.cyrillicToCtrlKey(0x0041), .unknown); // Latin A
}

// ── CSI dispatch tests ───────────────────────────────────────────────

test "dispatchCsiParams: simple arrow keys" {
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{}, 'A'), .up);
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{}, 'B'), .down);
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{}, 'C'), .right);
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{}, 'D'), .left);
}

test "dispatchCsiParams: tilde sequences" {
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{3}, '~'), .delete);
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{1}, '~'), .home);
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{4}, '~'), .end);
}

test "dispatchCsiParams: CSI u Latin Ctrl+a (97;5u)" {
    // 97 = 'a', 5 = 1 + Ctrl(4)
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{ 97, 5 }, 'u'), .ctrl_a);
}

test "dispatchCsiParams: CSI u Cyrillic Ctrl+ф (1092;5u → ctrl_a)" {
    // 1092 = 0x0444 = ф, 5 = Ctrl
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{ 1092, 5 }, 'u'), .ctrl_a);
}

test "dispatchCsiParams: CSI u Cyrillic Ctrl+ц (1094;5u → ctrl_w)" {
    // 1094 = 0x0446 = ц (W key on ЙЦУКЕН), 5 = Ctrl
    try std.testing.expectEqual(Repl.dispatchCsiParams(&.{ 1094, 5 }, 'u'), .ctrl_w);
}

test "parseCsiU: no params returns unknown" {
    try std.testing.expectEqual(Repl.parseCsiU(&.{}), .unknown);
}

test "parseCsiU: codepoint without Ctrl modifier returns unknown" {
    // 97 with modifier 1 (no modifiers) → not Ctrl
    try std.testing.expectEqual(Repl.parseCsiU(&.{ 97, 1 }), .unknown);
}

test "latinToCtrlKey: maps all supported keys" {
    try std.testing.expectEqual(Repl.latinToCtrlKey('a'), .ctrl_a);
    try std.testing.expectEqual(Repl.latinToCtrlKey('c'), .ctrl_c);
    try std.testing.expectEqual(Repl.latinToCtrlKey('d'), .ctrl_d);
    try std.testing.expectEqual(Repl.latinToCtrlKey('e'), .ctrl_e);
    try std.testing.expectEqual(Repl.latinToCtrlKey('k'), .ctrl_k);
    try std.testing.expectEqual(Repl.latinToCtrlKey('l'), .ctrl_l);
    try std.testing.expectEqual(Repl.latinToCtrlKey('u'), .ctrl_u);
    try std.testing.expectEqual(Repl.latinToCtrlKey('w'), .ctrl_w);
}

test "latinToCtrlKey: unsupported key returns unknown" {
    try std.testing.expectEqual(Repl.latinToCtrlKey('z'), .unknown);
    try std.testing.expectEqual(Repl.latinToCtrlKey('b'), .unknown);
}
