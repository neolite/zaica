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

        /// Create a derived event that transforms each payload with mapFn.
        pub fn map(self: *Self, comptime R: type, mapFn: *const fn (T) R) *Event(R) {
            return EventMapHelper(T, R).create(self, mapFn);
        }

        /// Create a derived event that only fires when filterFn returns true.
        pub fn filter(self: *Self, filterFn: *const fn (T) bool) *Self {
            return EventFilterHelper(T).create(self, filterFn);
        }

        pub fn deinit(self: *Self) void {
            self.watchers.deinit(self.eng.allocator);
            self.reducers.deinit(self.eng.allocator);
        }
    };
}

fn EventMapHelper(comptime T: type, comptime R: type) type {
    return struct {
        fn create(source: *Event(T), mapFn: *const fn (T) R) *Event(R) {
            const Derived = Event(R);
            const eng = source.eng;
            const derived = eng.allocator.create(Derived) catch @panic("OOM");
            derived.* = .{ .eng = eng };
            eng.trackGraphAlloc(@ptrCast(derived), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const e: *Derived = @ptrCast(@alignCast(p));
                    e.deinit();
                    a.destroy(e);
                }
            }.dtor);

            const MapCtx = struct {
                target: *Derived,
                mapFn: *const fn (T) R,
            };
            const ctx = eng.allocator.create(MapCtx) catch @panic("OOM");
            ctx.* = .{ .target = derived, .mapFn = mapFn };
            eng.trackGraphAlloc(@ptrCast(ctx), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const c: *MapCtx = @ptrCast(@alignCast(p));
                    a.destroy(c);
                }
            }.dtor);

            source.reducers.append(eng.allocator, .{
                .ctx = @ptrCast(ctx),
                .trigger = &struct {
                    fn trigger(raw: *anyopaque, payload_ptr: *const anyopaque) void {
                        const c: *MapCtx = @ptrCast(@alignCast(raw));
                        const payload: *const T = @ptrCast(@alignCast(payload_ptr));
                        c.target.emit(c.mapFn(payload.*));
                    }
                }.trigger,
            }) catch @panic("OOM");

            return derived;
        }
    };
}

fn EventFilterHelper(comptime T: type) type {
    return struct {
        fn create(source: *Event(T), filterFn: *const fn (T) bool) *Event(T) {
            const eng = source.eng;
            const derived = eng.allocator.create(Event(T)) catch @panic("OOM");
            derived.* = .{ .eng = eng };
            eng.trackGraphAlloc(@ptrCast(derived), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const e: *Event(T) = @ptrCast(@alignCast(p));
                    e.deinit();
                    a.destroy(e);
                }
            }.dtor);

            const FilterCtx = struct {
                target: *Event(T),
                filterFn: *const fn (T) bool,
            };
            const ctx = eng.allocator.create(FilterCtx) catch @panic("OOM");
            ctx.* = .{ .target = derived, .filterFn = filterFn };
            eng.trackGraphAlloc(@ptrCast(ctx), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const c: *FilterCtx = @ptrCast(@alignCast(p));
                    a.destroy(c);
                }
            }.dtor);

            source.reducers.append(eng.allocator, .{
                .ctx = @ptrCast(ctx),
                .trigger = &struct {
                    fn trigger(raw: *anyopaque, payload_ptr: *const anyopaque) void {
                        const c: *FilterCtx = @ptrCast(@alignCast(raw));
                        const payload: *const T = @ptrCast(@alignCast(payload_ptr));
                        if (c.filterFn(payload.*)) {
                            c.target.emit(payload.*);
                        }
                    }
                }.trigger,
            }) catch @panic("OOM");

            return derived;
        }
    };
}
