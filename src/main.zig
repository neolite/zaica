const std = @import("std");
const config = @import("config/mod.zig");
const client = @import("client/mod.zig");
const io = @import("io.zig");
const repl = @import("repl.zig");
const chain = @import("chain.zig");
const tools = @import("tools.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = config.load(allocator) catch |err| {
        // Config module prints user-friendly errors to stderr
        if (err == error.HelpRequested or err == error.InitCompleted) {
            std.process.exit(0);
        }
        std.process.exit(1);
    };
    defer result.deinit();

    // --dump-config: print resolved config and exit
    if (result.dump_config) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        result.writeJson(buf.writer(allocator)) catch |err| {
            std.debug.print("Failed to write config: {}\n", .{err});
            std.process.exit(1);
        };
        io.writeOut(buf.items) catch {};
        io.writeOut("\n") catch {};
        std.process.exit(0);
    }

    if (result.chain_path) |chain_path| {
        // Chain mode
        const parsed = chain.parseFile(allocator, chain_path) catch |err| {
            io.printErr("Failed to parse chain file '{s}': {}\n", .{ chain_path, err });
            std.process.exit(1);
        };

        if (result.dry_run) {
            chain.printDryRun(parsed);
            std.process.exit(0);
        }

        const task = result.prompt orelse {
            io.writeErr("Error: --chain requires a task prompt (positional argument)\n");
            std.process.exit(1);
        };

        // Single permission prompt based on max risk across all steps
        const max_risk = chain.chainMaxRisk(parsed);
        const risk_label = switch (max_risk) {
            .dangerous => "\x1b[31m", // red
            .write => "\x1b[33m",     // yellow
            .safe => "\x1b[32m",      // green
        };
        io.printOut("{s}\xe2\x9c\xa6\x1b[0m Grant tool access for chain? (y=all, s=safe-only, n=none): ", .{risk_label}) catch {};

        const permission = readPermission();
        if (permission == .none) {
            io.writeErr("Chain execution denied.\n");
            std.process.exit(0);
        }

        const final = chain.execute(allocator, &result.resolved, parsed, task, permission) catch |err| {
            io.printErr("Chain execution error: {}\n", .{err});
            std.process.exit(1);
        };
        if (final) |text| {
            allocator.free(text);
        }
    } else if (result.prompt) |prompt| {
        // Single-shot mode: send prompt and exit
        const response = client.chat(allocator, &result.resolved, prompt) catch {
            std.process.exit(1);
        };
        defer allocator.free(response);
    } else {
        // Interactive REPL mode
        repl.run(allocator, &result.resolved, result.continue_last, result.session_id) catch |err| {
            io.printErr("REPL error: {}\n", .{err});
            std.process.exit(1);
        };
    }
}

/// Simple permission prompt for non-REPL modes (chain execution).
/// Reads a single character from /dev/tty (raw mode).
fn readPermission() tools.PermissionLevel {
    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) catch return .none;
    defer tty.close();

    // Save terminal state and switch to raw mode
    const original = std.posix.tcgetattr(tty.handle) catch return .none;
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(tty.handle, .NOW, raw) catch return .none;
    defer std.posix.tcsetattr(tty.handle, .NOW, original) catch {};

    var buf: [1]u8 = undefined;
    const n = tty.read(&buf) catch return .none;
    if (n == 0) return .none;

    io.writeOut("\r\n") catch {};

    return switch (buf[0]) {
        'y', 'Y' => .all,
        's', 'S' => .safe_only,
        else => .none,
    };
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("config/mod.zig");
    _ = @import("client/mod.zig");
    _ = @import("repl.zig");
    _ = @import("state.zig");
    _ = @import("tools.zig");
    _ = @import("agent.zig");
    _ = @import("session.zig");
    _ = @import("chain.zig");
}
