const std = @import("std");
const config = @import("config/mod.zig");
const client = @import("client/mod.zig");
const io = @import("io.zig");
const repl = @import("repl.zig");

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

    if (result.prompt) |prompt| {
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

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("config/mod.zig");
    _ = @import("client/mod.zig");
    _ = @import("repl.zig");
    _ = @import("state.zig");
    _ = @import("tools.zig");
    _ = @import("agent.zig");
    _ = @import("session.zig");
}
