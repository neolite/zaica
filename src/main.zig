const std = @import("std");
const config = @import("config/mod.zig");
const client = @import("client/mod.zig");

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
        const stdout = std.io.getStdOut().writer();
        result.writeJson(stdout) catch |err| {
            std.debug.print("Failed to write config: {}\n", .{err});
            std.process.exit(1);
        };
        stdout.writeByte('\n') catch {};
        std.process.exit(0);
    }

    // Must have a prompt to proceed
    if (result.prompt == null) {
        const stderr = std.io.getStdErr().writer();
        stderr.writeAll("Error: No prompt provided.\nUsage: zagent [OPTIONS] <prompt...>\nTry 'zagent --help' for more information.\n") catch {};
        std.process.exit(1);
    }

    // Send prompt to LLM provider
    const response = client.chat(allocator, &result.resolved, result.prompt.?) catch {
        // client.chat prints user-friendly errors to stderr
        std.process.exit(1);
    };
    defer allocator.free(response);
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("config/mod.zig");
    _ = @import("client/mod.zig");
}
