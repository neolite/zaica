const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const Thunk = eng_mod.Thunk;
const Subscription = eng_mod.Subscription;

pub fn Event(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Payload = T;
        pub const WatcherFn = *const fn (T) void;

        eng: *Engine,
        name_: []const u8 = "",
        watchers: std.ArrayListUnmanaged(?WatcherFn) = .{},
        /// Store reducers subscribed via store.on(event, reducer).
        reducers: std.ArrayListUnmanaged(ReducerSlot) = .{},

        pub const ReducerSlot = struct {
            ctx: *anyopaque,
            trigger: *const fn (ctx: *anyopaque, payload_ptr: *const anyopaque) void,
        };

        // --- fluent builder ---

        pub fn name(self: *Self, n: []const u8) *Self {
            self.name_ = n;
            return self;
        }

        pub fn watch(self: *Self, cb: WatcherFn) Subscription {
            const idx = self.watchers.items.len;
            self.watchers.append(self.eng.allocator, cb) catch @panic("OOM");
            return .{ .index = idx };
        }

        /// JS-like alias for watch().
        pub fn subscribe(self: *Self, cb: WatcherFn) Subscription {
            return self.watch(cb);
        }

        pub fn unwatch(self: *Self, sub: Subscription) void {
            if (sub.index < self.watchers.items.len) {
                self.watchers.items[sub.index] = null;
            }
        }

        /// JS-like alias for unwatch().
        pub fn unsubscribe(self: *Self, sub: Subscription) void {
            self.unwatch(sub);
        }

        /// Fire the event. Schedules pure (reducers) and effect (watchers) thunks.
        pub fn emit(self: *Self, payload: T) void {
            const tick_alloc = self.eng.tickAllocator();

            // Schedule reducer calls (pure phase)
            for (self.reducers.items) |slot| {
                const Ctx = struct {
                    slot: ReducerSlot,
                    payload: T,
                };
                const ctx = tick_alloc.create(Ctx) catch @panic("OOM");
                ctx.* = .{ .slot = slot, .payload = payload };

                self.eng.schedulePure(.{
                    .ctx = @ptrCast(ctx),
                    .call = &struct {
                        fn thunk(raw: *anyopaque) void {
                            const c: *Ctx = @ptrCast(@alignCast(raw));
                            const payload_opaque: *const anyopaque = @ptrCast(&c.payload);
                            c.slot.trigger(c.slot.ctx, payload_opaque);
                        }
                    }.thunk,
                });
            }

            // Schedule watcher calls (effects phase)
            if (self.watchers.items.len > 0) {
                const WCtx = struct {
                    watchers_ptr: *std.ArrayListUnmanaged(?WatcherFn),
                    payload: T,
                };
                const wctx = tick_alloc.create(WCtx) catch @panic("OOM");
                wctx.* = .{ .watchers_ptr = &self.watchers, .payload = payload };

                self.eng.scheduleEffect(.{
                    .ctx = @ptrCast(wctx),
                    .call = &struct {
                        fn thunk(raw: *anyopaque) void {
                            const c: *WCtx = @ptrCast(@alignCast(raw));
                            for (c.watchers_ptr.items) |maybe_cb| {
                                if (maybe_cb) |cb| cb(c.payload);
                            }
                        }
                    }.thunk,
                });
            }

            // Auto-flush if engine is idle (top-level emit)
            if (self.eng.phase == .idle) {
                self.eng.flush();
            }
        }

        pub fn deinit(self: *Self) void {
            self.watchers.deinit(self.eng.allocator);
            self.reducers.deinit(self.eng.allocator);
        }
    };
}
