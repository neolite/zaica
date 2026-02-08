/// I/O helpers for Zig 0.15 buffered writer API.
const std = @import("std");

pub const Writer = std.Io.Writer;

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

/// Atomic flag to signal spinner thread to stop.
var spinner_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Handle to the background spinner thread (null when not running).
var spinner_thread: ?std.Thread = null;

/// Start animated spinner in a background thread.
/// The spinner cycles through braille frames at 80ms intervals.
/// Call stopSpinner() to halt and clear the spinner line.
pub fn startSpinner() void {
    spinner_stop.store(false, .release);
    spinner_thread = std.Thread.spawn(.{}, spinnerLoop, .{}) catch null;
}

/// Stop the spinner and clear the line. Safe to call even if not running.
/// Blocks until the spinner thread has fully exited.
pub fn stopSpinner() void {
    if (spinner_thread) |t| {
        spinner_stop.store(true, .release);
        t.join();
        spinner_thread = null;
    }
}

/// Background spinner loop — writes braille animation frames to stdout.
fn spinnerLoop() void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var i: usize = 0;
    while (!spinner_stop.load(.acquire)) {
        writeOut("\r\x1b[2m") catch {};
        writeOut(frames[i % frames.len]) catch {};
        writeOut(" \x1b[0m") catch {};
        std.Thread.sleep(80_000_000); // 80ms
        i +%= 1;
    }
    writeOut("\r\x1b[K") catch {}; // clear spinner line
}

/// Get a buffered stdout writer for streaming output.
pub fn stdoutWriter(buf: []u8) std.fs.File.Writer {
    return std.fs.File.stdout().writer(buf);
}
