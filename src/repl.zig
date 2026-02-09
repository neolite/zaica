const std = @import("std");
const posix = std.posix;

const config_types = @import("config/types.zig");
const client = @import("client/mod.zig");
const message = client.message;
const io = @import("io.zig");
const tools = @import("tools.zig");
const state = @import("state.zig");
const agent = @import("agent.zig");

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
    const slash_commands = [_][]const u8{ "/exit", "/help", "/quit", "/tools", "/usage" };

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

/// Atomic flag for SIGWINCH (terminal resize).
var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// SIGWINCH signal handler — just sets the atomic flag.
fn sigwinchHandler(_: c_int) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

/// Main REPL entry point — called from main.zig.
pub fn run(allocator: std.mem.Allocator, resolved: *const config_types.ResolvedConfig) !void {
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

    var session = state.init(allocator, resolved.resolved_model, resolved.config.max_context_tokens, term.rows, term.cols);
    state.bind(&session); // Set stable pointer for watchers + initial render
    defer session.deinit();

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
        .text = .{ .role = .system, .content = resolved.config.system_prompt },
    });

    // Session-level tool permission
    var permission_level: tools.PermissionLevel = .none;

    while (true) {
        // Check for terminal resize
        if (sigwinch_received.swap(false, .acquire)) {
            const ts = io.getTerminalSize();
            session.events.terminal_resized.emit(.{ .rows = ts.rows, .cols = ts.cols });
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
        if (std.mem.eql(u8, trimmed, "/usage")) {
            io.writeOut("\r\n\x1b[1mSession token usage:\x1b[0m\r\n") catch {};
            io.printOut("  Prompt tokens:     {d}\r\n", .{session.stores.prompt_tokens.get()}) catch {};
            io.printOut("  Completion tokens: {d}\r\n", .{session.stores.completion_tokens.get()}) catch {};
            io.printOut("  Total tokens:      {d}\r\n", .{session.stores.total_tokens.get()}) catch {};
            io.printOut("  Context limit:     {d}\r\n\r\n", .{resolved.config.max_context_tokens}) catch {};
            continue;
        }

        const user_content = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(user_content);
        try history.append(allocator, .{ .text = .{ .role = .user, .content = user_content } });

        // Visual separator between input and output
        io.writeOut("\r\n") catch {};

        // Clear cancel flag at start of each user message
        io.clearCancelFlag();

        // Agentic loop: keep calling LLM until we get a text response
        var iterations: usize = 0;
        while (iterations < MAX_AGENT_ITERATIONS) : (iterations += 1) {
            // Terminal is in cooked mode here — streaming works normally
            session.events.phase_changed.emit(.streaming);
            state.syncStatus(&session);
            io.startSpinner("Thinking...");
            const result = client.chatMessages(
                allocator,
                resolved,
                history.items,
                tools.all_tools,
            ) catch {
                io.stopSpinner();
                if (iterations == 0) {
                    // First call failed — remove user message
                    if (history.pop()) |removed| {
                        freeMessage(allocator, removed);
                    }
                }
                break;
            };

            // Check cancel after LLM call returns
            if (io.isCancelRequested()) {
                io.stopSpinner();
                session.events.cancel_requested.emit(true);
                io.writeOut("\r\n\x1b[33m\xe2\x8a\x98 Cancelled\x1b[0m\r\n\r\n") catch {};
                // Free partial result
                switch (result.response) {
                    .text => |t| allocator.free(t),
                    .tool_calls => |tcs| {
                        for (tcs) |tc| {
                            allocator.free(tc.id);
                            allocator.free(tc.function.name);
                            allocator.free(tc.function.arguments);
                        }
                        allocator.free(tcs);
                    },
                }
                session.events.phase_changed.emit(.idle);
                break;
            }

            // Track token usage
            if (result.usage) |usage| {
                session.events.tokens_received.emit(.{
                    .prompt_tokens = usage.prompt_tokens,
                    .completion_tokens = usage.completion_tokens,
                });

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
                        session.events.phase_changed.emit(.awaiting_permission);
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
                            if (extractKeyArg(allocator, tc.function.name, tc.function.arguments)) |key_arg| {
                                defer allocator.free(key_arg);
                                io.printOut("{s}\x1b[0m\x1b[2m({s})\x1b[0m\r\n", .{ tools.displayToolName(tc.function.name), key_arg }) catch {};
                            } else {
                                io.printOut("{s}\x1b[0m\r\n", .{tools.displayToolName(tc.function.name)}) catch {};
                            }
                        }
                        io.writeOut("Allow? [\x1b[32my\x1b[0m]es all / [\x1b[33ms\x1b[0m]afe only / [\x1b[31mn\x1b[0m]o ") catch {};

                        permission_level = repl.readPermission() catch .none;
                        session.events.permission_granted.emit(permission_level);

                        // Check if ESC triggered cancel during permission prompt
                        if (io.isCancelRequested()) {
                            session.events.cancel_requested.emit(true);
                            io.writeOut("\x1b[33m\xe2\x8a\x98 Cancelled\x1b[0m\r\n\r\n") catch {};
                            // Free tool calls
                            for (tcs) |tc| {
                                allocator.free(tc.id);
                                allocator.free(tc.function.name);
                                allocator.free(tc.function.arguments);
                            }
                            allocator.free(tcs);
                            session.events.phase_changed.emit(.idle);
                            break;
                        }

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
                    @memset(tool_results, .{ .tool_call_id = "", .content = "", .sub_agent_usage = null });

                    // Indices of allowed tools that need execution
                    const thread_indices = try allocator.alloc(usize, tcs.len);
                    defer allocator.free(thread_indices);
                    var thread_count: usize = 0;

                    // First pass: check permissions, print status, fill denied results
                    for (tcs, 0..) |tc, i| {
                        if (!tools.isAllowed(tc.function.name, permission_level)) {
                            io.printOut("\x1b[31m  \xe2\x8a\x98 {s} (not allowed)\x1b[0m\r\n", .{tools.displayToolName(tc.function.name)}) catch {};
                            tool_results[i] = .{
                                .tool_call_id = try allocator.dupe(u8, tc.id),
                                .content = std.fmt.allocPrint(allocator, "Permission denied: {s} requires full tool access (safe-only mode active).", .{tc.function.name}) catch try allocator.dupe(u8, "Permission denied."),
                            };
                        } else {
                            thread_indices[thread_count] = i;
                            thread_count += 1;
                        }
                    }

                    // Display allowed tools with ✦ prefix
                    if (thread_count > 0) {
                        for (thread_indices[0..thread_count]) |idx| {
                            const tc_disp = tcs[idx];
                            io.writeOut("  \x1b[95m\xe2\x9c\xa6\x1b[0m ") catch {}; // magenta ✦
                            if (extractKeyArg(allocator, tc_disp.function.name, tc_disp.function.arguments)) |key_arg| {
                                defer allocator.free(key_arg);
                                io.printOut("\x1b[1m{s}\x1b[0m\x1b[2m({s})\x1b[0m\r\n", .{ tools.displayToolName(tc_disp.function.name), key_arg }) catch {};
                            } else {
                                io.printOut("\x1b[1m{s}\x1b[0m\r\n", .{tools.displayToolName(tc_disp.function.name)}) catch {};
                            }
                        }
                    }

                    // Execute allowed tools in background threads with spinner
                    if (thread_count > 0) {
                        session.events.phase_changed.emit(.executing_tools);

                        // Build label from display names: "Read, Bash"
                        var label_buf: [256]u8 = undefined;
                        var label_pos: usize = 0;
                        for (thread_indices[0..thread_count]) |idx| {
                            const name = tools.displayToolName(tcs[idx].function.name);
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
                        state.syncStatus(&session);
                        io.startSpinner(label_buf[0..label_pos]);

                        const threads = try allocator.alloc(?std.Thread, thread_count);
                        defer allocator.free(threads);
                        @memset(threads, null);

                        // Atomic done flags for cancel-aware join
                        const done_flags = try allocator.alloc(std.atomic.Value(bool), thread_count);
                        defer allocator.free(done_flags);
                        for (done_flags) |*f| f.* = std.atomic.Value(bool).init(false);

                        for (thread_indices[0..thread_count], 0..) |idx, j| {
                            threads[j] = std.Thread.spawn(.{}, executeToolThread, .{
                                ToolExecContext{
                                    .allocator = allocator,
                                    .tc = tcs[idx],
                                    .resolved = resolved,
                                    .permission = permission_level,
                                },
                                &tool_results[idx],
                                &done_flags[j],
                            }) catch null;

                            // If spawn failed, run synchronously (done_flag already false)
                            if (threads[j] == null) {
                                executeToolThread(
                                    ToolExecContext{
                                        .allocator = allocator,
                                        .tc = tcs[idx],
                                        .resolved = resolved,
                                        .permission = permission_level,
                                    },
                                    &tool_results[idx],
                                    &done_flags[j],
                                );
                            }
                        }

                        // Cancel-aware join: poll done flags + cancel flag
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

                        // Join all completed threads
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

                        io.stopSpinner();

                        // Emit accumulated sub-agent token usage to zefx
                        for (tool_results) |tr| {
                            if (tr.sub_agent_usage) |usage| {
                                session.events.tokens_received.emit(.{
                                    .prompt_tokens = usage.prompt_tokens,
                                    .completion_tokens = usage.completion_tokens,
                                });
                            }
                        }
                    }

                    // Check cancel after tool execution
                    if (io.isCancelRequested()) {
                        session.events.cancel_requested.emit(true);
                        io.writeOut("\r\n\x1b[33m\xe2\x8a\x98 Cancelled\x1b[0m\r\n\r\n") catch {};
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
                        session.events.phase_changed.emit(.idle);
                        break;
                    }

                    // Print tool results with ◇ prefix
                    for (0..tcs.len) |i| {
                        const content = tool_results[i].content;
                        if (content.len == 0) continue;
                        // Truncate long output
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

        // Reset phase to idle when agentic loop exits
        session.events.phase_changed.emit(.idle);

        if (iterations >= MAX_AGENT_ITERATIONS) {
            io.writeOut("\x1b[33m(agent loop limit reached)\x1b[0m\r\n") catch {};
        }
    }
}

/// Result of a single tool execution, used for parallel collection.
const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
    /// Token usage from sub-agent execution (null for regular tools).
    sub_agent_usage: ?struct { prompt_tokens: u64, completion_tokens: u64 } = null,
};

/// Context for tool execution threads — bundles all data needed by the thread.
const ToolExecContext = struct {
    allocator: std.mem.Allocator,
    tc: message.ToolCall,
    resolved: *const config_types.ResolvedConfig,
    permission: tools.PermissionLevel,
};

/// Thread entry point for parallel tool execution.
/// Routes dispatch_agent to the sub-agent runtime, all others to tools.execute.
/// Sets done_flag when finished so the main thread can poll for completion.
fn executeToolThread(ctx: ToolExecContext, result: *ToolResult, done_flag: *std.atomic.Value(bool)) void {
    defer done_flag.store(true, .release);

    if (std.mem.eql(u8, ctx.tc.function.name, "dispatch_agent")) {
        // Extract "task" from JSON arguments
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
fn extractTask(allocator: std.mem.Allocator, args_json: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get("task") orelse return null;
    if (val != .string or val.string.len == 0) return null;
    return allocator.dupe(u8, val.string) catch null;
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
    else if (std.mem.eql(u8, tool_name, "dispatch_agent"))
        "task"
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

test "extractTask: valid JSON" {
    const allocator = std.testing.allocator;
    const result = extractTask(allocator, "{\"task\":\"analyze this file\"}");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("analyze this file", result.?);
}

test "extractTask: missing task key" {
    const allocator = std.testing.allocator;
    try std.testing.expect(extractTask(allocator, "{\"other\":\"value\"}") == null);
}

test "extractTask: invalid JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expect(extractTask(allocator, "not json") == null);
}

test "extractTask: empty task" {
    const allocator = std.testing.allocator;
    try std.testing.expect(extractTask(allocator, "{\"task\":\"\"}") == null);
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
