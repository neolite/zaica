const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const Thunk = eng_mod.Thunk;
const event_mod = @import("event.zig");
const store_mod = @import("store.zig");

pub fn Effect(comptime Params: type, comptime Result: type, comptime ErrSet: type) type {
    return struct {
        const Self = @This();

        pub const DoneData = struct { params: Params, result: Result };
        pub const FailData = struct { params: Params, err: ErrSet };
        pub const FinallyData = union(enum) { done: DoneData, fail: FailData };
        pub const HandlerFn = *const fn (Params) ErrSet!Result;

        eng: *Engine,
        handler: HandlerFn,
        done: *event_mod.Event(DoneData),
        fail: *event_mod.Event(FailData),
        finally_: *event_mod.Event(FinallyData),
        pending: *store_mod.Store(bool),
        name_: []const u8 = "",

        pub fn name(self: *Self, n: []const u8) *Self {
            self.name_ = n;
            return self;
        }

        pub fn run(self: *Self, params: Params) void {
            const tick_alloc = self.eng.tickAllocator();

            const Ctx = struct {
                self_ptr: *Self,
                params: Params,
            };
            const ctx = tick_alloc.create(Ctx) catch @panic("OOM");
            ctx.* = .{ .self_ptr = self, .params = params };

            // Set pending = true immediately (pure phase)
            self.eng.schedulePure(.{
                .ctx = @ptrCast(ctx),
                .call = &struct {
                    fn thunk(raw: *anyopaque) void {
                        const c: *Ctx = @ptrCast(@alignCast(raw));
                        c.self_ptr.pending.set(true);
                    }
                }.thunk,
            });

            // Schedule the actual handler in effects phase
            self.eng.scheduleEffect(.{
                .ctx = @ptrCast(ctx),
                .call = &struct {
                    fn thunk(raw: *anyopaque) void {
                        const c: *Ctx = @ptrCast(@alignCast(raw));
                        const self_ = c.self_ptr;
                        if (self_.handler(c.params)) |result| {
                            const done_data = DoneData{ .params = c.params, .result = result };
                            self_.done.emit(done_data);
                            self_.finally_.emit(.{ .done = done_data });
                        } else |err| {
                            const fail_data = FailData{ .params = c.params, .err = err };
                            self_.fail.emit(fail_data);
                            self_.finally_.emit(.{ .fail = fail_data });
                        }
                    }
                }.thunk,
            });

            // Auto-flush if engine is idle
            if (self.eng.phase == .idle) {
                self.eng.flush();
            }
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            // Sub-units (done, fail, finally_, pending) are tracked
            // individually in graph_cleanups — nothing extra to free here.
        }
    };
}
