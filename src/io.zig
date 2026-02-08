/// I/O helpers for Zig 0.15 buffered writer API.
const std = @import("std");
const posix = std.posix;

pub const Writer = std.Io.Writer;

// ── Terminal size ─────────────────────────────────────────────────────

pub const TermSize = struct { cols: u16, rows: u16 };

/// Query terminal dimensions via ioctl(TIOCGWINSZ).
/// Returns 80x24 fallback if stdout is not a terminal or ioctl fails.
pub fn getTerminalSize() TermSize {
    const fd = std.fs.File.stdout().handle;
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(fd, std.c.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.row > 0 and ws.col > 0) {
        return .{ .cols = ws.col, .rows = ws.row };
    }
    return .{ .cols = 80, .rows = 24 };
}

// ── Scroll region + Status bar ────────────────────────────────────────

/// Set scroll region to rows 1..(rows-4), reserving the last 4 rows for
/// top separator, input line, bottom separator, and status bar.
/// Note: CSI r resets cursor to home (1,1) per VT100 spec.
pub fn setupScrollRegion(rows: u16) void {
    if (rows < 5) return;
    printOut("\x1b[1;{d}r", .{rows - 4}) catch {};
}

/// Render a dim horizontal separator (─) on the given row.
/// Cursor is left on the separator row — caller must reposition.
pub fn renderSeparator(row: u16, cols: u16) void {
    printOut("\x1b[{d};1H\x1b[2m", .{row}) catch {};
    // ─ (U+2500) = 3 bytes: \xe2\x94\x80
    var buf: [768]u8 = undefined;
    const n: usize = @min(@as(usize, cols), 256);
    for (0..n) |i| {
        buf[i * 3] = 0xe2;
        buf[i * 3 + 1] = 0x94;
        buf[i * 3 + 2] = 0x80;
    }
    writeOut(buf[0 .. n * 3]) catch {};
    writeOut("\x1b[0m") catch {};
}

/// Restore full-screen scroll region (no reserved rows).
pub fn resetScrollRegion() void {
    writeOut("\x1b[r") catch {};
}

/// Render content on the last terminal row (status bar position).
/// Uses cursor save/restore so normal scroll output is not disturbed.
pub fn renderStatusBar(rows: u16, content: []const u8) void {
    writeOut("\x1b7") catch {}; // save cursor
    printOut("\x1b[{d};1H", .{rows}) catch {}; // move to last row
    writeOut("\x1b[2m") catch {}; // dim text (no background fill)
    writeOut(content) catch {};
    writeOut("\x1b[K") catch {}; // clear rest of line
    writeOut("\x1b[0m") catch {}; // reset attributes
    writeOut("\x1b8") catch {}; // restore cursor
}

/// Print formatted text to stderr (unbuffered, never fails visibly).
/// Replacement for: `std.io.getStdErr().writer().print(fmt, args)`
pub fn printErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Write raw bytes to stdout (unbuffered).
/// Use for escape sequences and raw terminal manipulation.
/// For user-facing text, use writeText() instead.
pub fn writeOut(bytes: []const u8) !void {
    try std.fs.File.stdout().writeAll(bytes);
}

/// Write text to stdout, translating \n → \r\n for correct display
/// regardless of terminal OPOST setting. Use for all user-facing text.
pub fn writeText(bytes: []const u8) !void {
    const stdout = std.fs.File.stdout();
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b == '\n') {
            if (i > start) try stdout.writeAll(bytes[start..i]);
            try stdout.writeAll("\r\n");
            start = i + 1;
        }
    }
    if (start < bytes.len) try stdout.writeAll(bytes[start..]);
}

/// Write raw bytes to stderr (unbuffered).
pub fn writeErr(bytes: []const u8) void {
    std.fs.File.stderr().writeAll(bytes) catch {};
}

/// Print formatted text to stdout (unbuffered, raw — no \n translation).
/// For user-facing formatted text, use printText() instead.
pub fn printOut(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try std.fs.File.stdout().writeAll(text);
}

/// Print formatted text to stdout with \n → \r\n translation.
/// Use for all user-facing formatted output.
pub fn printText(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try writeText(text);
}

// ── Status bar spinner ────────────────────────────────────────────────
//
// The spinner thread renders the full status bar line (with animated
// spinner frame) on the reserved last terminal row. When idle, the main
// thread renders the static status bar without spinner animation.

/// Atomic flag to signal spinner thread to stop.
var spinner_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Handle to the background spinner thread (null when not running).
var spinner_thread: ?std.Thread = null;
/// Fixed buffer for spinner label (thread-safe via atomic length).
var spinner_label: [256]u8 = undefined;
/// Atomic length of the current spinner label.
var spinner_label_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
/// Pre-formatted static portion of the status bar (right side: model│tokens│perm│time).
/// Set by the main thread before starting the spinner.
var status_static: [512]u8 = undefined;
/// Atomic length of the static status bar portion.
var status_static_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
/// Terminal row count, used by spinner thread to position the status bar.
var status_rows: std.atomic.Value(u16) = std.atomic.Value(u16).init(24);

/// Update the static portion of the status bar (thread-safe).
/// Called from the main thread when tokens/permission/phase changes.
pub fn setStatusStatic(content: []const u8) void {
    const len = @min(content.len, status_static.len);
    @memcpy(status_static[0..len], content[0..len]);
    status_static_len.store(len, .release);
}

/// Update the terminal rows for status bar positioning (thread-safe).
pub fn setStatusRows(rows: u16) void {
    status_rows.store(rows, .release);
}

/// Start animated spinner in a background thread with a context label.
/// The spinner renders into the status bar's reserved last row.
pub fn startSpinner(label: []const u8) void {
    const len = @min(label.len, spinner_label.len);
    @memcpy(spinner_label[0..len], label[0..len]);
    spinner_label_len.store(len, .release);
    spinner_stop.store(false, .release);
    spinner_thread = std.Thread.spawn(.{}, spinnerLoop, .{}) catch null;
}

/// Check if the spinner is currently active (thread running).
pub fn isSpinnerActive() bool {
    return spinner_thread != null;
}

/// Stop the spinner and clear its line in the scroll region. Safe to call even if not running.
pub fn stopSpinner() void {
    if (spinner_thread) |t| {
        spinner_stop.store(true, .release);
        t.join();
        spinner_thread = null;
        // Clear spinner line in scroll region
        writeOut("\r\x1b[K") catch {};
    }
}

/// Braille spinner frames (each is 3 bytes UTF-8).
const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Background spinner loop — renders animated spinner in the scroll region.
/// Uses \r to overwrite the current line in-place.
fn spinnerLoop() void {
    var i: usize = 0;
    while (!spinner_stop.load(.acquire)) {
        const label_len = spinner_label_len.load(.acquire);

        // Build: "\r\x1b[K \x1b[95m⠋\x1b[0m \x1b[2mLabel\x1b[0m"
        var buf: [300]u8 = undefined;
        var pos: usize = 0;

        // Return to line start + clear + leading space
        const prefix = "\r\x1b[K ";
        @memcpy(buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;

        // Spinner frame in magenta
        const color_on = "\x1b[95m";
        @memcpy(buf[pos..][0..color_on.len], color_on);
        pos += color_on.len;

        const frame = spinner_frames[i % spinner_frames.len];
        @memcpy(buf[pos..][0..frame.len], frame);
        pos += frame.len;

        const color_off = "\x1b[0m ";
        @memcpy(buf[pos..][0..color_off.len], color_off);
        pos += color_off.len;

        // Label in dim
        if (label_len > 0) {
            const dim_on = "\x1b[2m";
            @memcpy(buf[pos..][0..dim_on.len], dim_on);
            pos += dim_on.len;

            const copy = @min(label_len, buf.len - pos - 4);
            @memcpy(buf[pos..][0..copy], spinner_label[0..copy]);
            pos += copy;
        }

        // Reset
        const reset = "\x1b[0m";
        @memcpy(buf[pos..][0..reset.len], reset);
        pos += reset.len;

        writeOut(buf[0..pos]) catch {};

        std.Thread.sleep(80_000_000); // 80ms
        i +%= 1;
    }
}

/// Render the status bar in idle state (no spinner animation).
fn renderStatusBarIdle() void {
    const rows = status_rows.load(.acquire);
    const static_len = status_static_len.load(.acquire);
    if (static_len == 0) return;

    var buf: [520]u8 = undefined;
    buf[0] = ' ';
    @memcpy(buf[1..][0..static_len], status_static[0..static_len]);
    renderStatusBar(rows, buf[0 .. static_len + 1]);
}

/// Get a buffered stdout writer for streaming output.
pub fn stdoutWriter(buf: []u8) std.fs.File.Writer {
    return std.fs.File.stdout().writer(buf);
}
