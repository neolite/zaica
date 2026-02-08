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

/// "Thinking..." indicator state — cleared on first streamed output.
var thinking_active: bool = false;

/// Show a dim thinking indicator (cleared automatically on first output).
pub fn showThinking() void {
    thinking_active = true;
    writeOut("\x1b[2m...\x1b[0m") catch {};
}

/// Clear the thinking indicator if active.
pub fn clearThinking() void {
    if (thinking_active) {
        writeOut("\r\x1b[K") catch {};
        thinking_active = false;
    }
}

/// Get a buffered stdout writer for streaming output.
pub fn stdoutWriter(buf: []u8) std.fs.File.Writer {
    return std.fs.File.stdout().writer(buf);
}
