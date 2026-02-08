const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const Thunk = eng_mod.Thunk;
const Subscription = eng_mod.Subscription;
const StoreNotifier = eng_mod.StoreNotifier;
const event_mod = @import("event.zig");

pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        pub const WatcherFn = *const fn (T) void;
        const CleanupSlot = struct {
            ptr: *anyopaque,
            destroyFn: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) void,
        };

        eng: *Engine,
        name_: []const u8 = "",
        value: T,
        prev: T,
        dirty: bool = false,
        last_dirty_tick: u32 = 0,
        store_index: ?usize = null,
        watchers: std.ArrayListUnmanaged(?WatcherFn) = .{},
        reducer_cleanups: std.ArrayListUnmanaged(CleanupSlot) = .{},
        updates_event: ?*event_mod.Event(T) = null,

        // --- fluent builder ---

        pub fn name(self: *Self, n: []const u8) *Self {
            self.name_ = n;
            return self;
        }

        pub fn get(self: *const Self) T {
            return self.value;
        }

        /// JS-like alias for get().
        pub fn getState(self: *const Self) T {
            return self.get();
        }

        /// Imperatively set a new value. Marks dirty and flushes if idle.
        pub fn set(self: *Self, val: T) void {
            self.prev = self.value;
            self.value = val;
            self.markDirty();
            if (self.eng.phase == .idle) {
                self.eng.flush();
            }
        }

        /// JS-like alias for set().
        pub fn setState(self: *Self, val: T) void {
            self.set(val);
        }

        pub fn watch(self: *Self, cb: WatcherFn) Subscription {
            self.ensureRegistered();
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

        /// Returns an Event(T) that fires whenever this store updates.
        pub fn updates(self: *Self) *event_mod.Event(T) {
            if (self.updates_event) |ev| return ev;
            const ev = self.eng.allocator.create(event_mod.Event(T)) catch @panic("OOM");
            ev.* = .{ .eng = self.eng };
            self.updates_event = ev;
            return ev;
        }

        /// Subscribe this store to an event with a reducer.
        /// Reducer: fn(state: T, payload: E) ?T — return null to skip update.
        pub fn on(
            self: *Self,
            ev: anytype, // *Event(SomePayload)
            reduce: *const fn (T, @TypeOf(ev.*).Payload) ?T,
        ) *Self {
            self.ensureRegistered();

            const EvPayload = @TypeOf(ev.*).Payload;

            const ReducerCtx = struct {
                store: *Self,
                reducer: *const fn (T, EvPayload) ?T,
            };

            const ctx = self.eng.allocator.create(ReducerCtx) catch @panic("OOM");
            ctx.* = .{ .store = self, .reducer = reduce };

            // Track for cleanup
            self.reducer_cleanups.append(self.eng.allocator, .{
                .ptr = @ptrCast(ctx),
                .destroyFn = &struct {
                    fn destroy(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                        const typed: *ReducerCtx = @ptrCast(@alignCast(ptr));
                        alloc.destroy(typed);
                    }
                }.destroy,
            }) catch @panic("OOM");

            ev.reducers.append(self.eng.allocator, .{
                .ctx = @ptrCast(ctx),
                .trigger = &struct {
                    fn trigger(raw_ctx: *anyopaque, payload_ptr: *const anyopaque) void {
                        const c: *ReducerCtx = @ptrCast(@alignCast(raw_ctx));
                        const payload: *const EvPayload = @ptrCast(@alignCast(payload_ptr));
                        if (c.reducer(c.store.value, payload.*)) |new_val| {
                            c.store.prev = c.store.value;
                            c.store.value = new_val;
                            c.store.markDirty();
                        }
                    }
                }.trigger,
            }) catch @panic("OOM");

            return self;
        }

        fn ensureRegistered(self: *Self) void {
            if (self.store_index != null) return;
            self.store_index = self.eng.registerStore(.{
                .ctx = @ptrCast(self),
                .notifyFn = &struct {
                    fn notify(raw: *anyopaque) void {
                        const s: *Self = @ptrCast(@alignCast(raw));
                        s.notifyIfDirty();
                    }
                }.notify,
            });
        }

        fn markDirty(self: *Self) void {
            if (self.last_dirty_tick == self.eng.tick_id) return; // dedup
            self.last_dirty_tick = self.eng.tick_id;
            self.dirty = true;
            if (self.store_index) |idx| {
                self.eng.markDirty(idx);
            }
        }

        /// Called by engine during effects phase.
        pub fn notifyIfDirty(self: *Self) void {
            if (!self.dirty) return;
            self.dirty = false;
            for (self.watchers.items) |maybe_cb| {
                if (maybe_cb) |cb| cb(self.value);
            }
            // Fire updates event
            if (self.updates_event) |ev| {
                ev.emit(self.value);
            }
        }

        pub fn deinit(self: *Self) void {
            self.watchers.deinit(self.eng.allocator);
            for (self.reducer_cleanups.items) |slot| {
                slot.destroyFn(self.eng.allocator, slot.ptr);
            }
            self.reducer_cleanups.deinit(self.eng.allocator);
            if (self.updates_event) |ev| {
                ev.deinit();
                self.eng.allocator.destroy(ev);
            }
        }
    };
}
