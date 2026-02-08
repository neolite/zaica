const std = @import("std");

pub const Subscription = struct { index: usize };
pub const Phase = enum { idle, pure, effects };

pub const Thunk = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,
    pub fn invoke(self: Thunk) void {
        self.call(self.ctx);
    }
};

pub const StoreNotifier = struct {
    ctx: *anyopaque,
    notifyFn: *const fn (ctx: *anyopaque) void,
};

pub const Engine = struct {
    pub const CleanupFn = *const fn (std.mem.Allocator, *anyopaque) void;
    pub const CleanupEntry = struct { ptr: *anyopaque, dtor: CleanupFn };

    allocator: std.mem.Allocator,
    tick_arena: std.heap.ArenaAllocator,
    phase: Phase = .idle,
    tick_id: u32 = 1,
    pure_queue: std.ArrayListUnmanaged(Thunk) = .{},
    effect_queue: std.ArrayListUnmanaged(Thunk) = .{},
    store_notifiers: std.ArrayListUnmanaged(StoreNotifier) = .{},
    dirty_indices: std.ArrayListUnmanaged(usize) = .{},
    graph_cleanups: std.ArrayListUnmanaged(CleanupEntry) = .{},

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .tick_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.graph_cleanups.items) |entry| {
            entry.dtor(self.allocator, entry.ptr);
        }
        self.graph_cleanups.deinit(self.allocator);
        self.tick_arena.deinit();
        self.pure_queue.deinit(self.allocator);
        self.effect_queue.deinit(self.allocator);
        self.store_notifiers.deinit(self.allocator);
        self.dirty_indices.deinit(self.allocator);
    }

    pub fn tickAllocator(self: *Engine) std.mem.Allocator {
        return self.tick_arena.allocator();
    }

    pub fn registerStore(self: *Engine, notifier: StoreNotifier) usize {
        const idx = self.store_notifiers.items.len;
        self.store_notifiers.append(self.allocator, notifier) catch @panic("OOM");
        return idx;
    }

    pub fn markDirty(self: *Engine, store_index: usize) void {
        // Dedup: avoid double-marking in same flush
        for (self.dirty_indices.items) |idx| {
            if (idx == store_index) return;
        }
        self.dirty_indices.append(self.allocator, store_index) catch @panic("OOM");
    }

    pub fn flush(self: *Engine) void {
        // Phase 1: pure — drain reducers (may enqueue more)
        self.phase = .pure;
        while (self.pure_queue.items.len > 0) {
            const len = self.pure_queue.items.len;
            const copy = self.allocator.alloc(Thunk, len) catch @panic("OOM");
            defer self.allocator.free(copy);
            @memcpy(copy, self.pure_queue.items[0..len]);
            self.pure_queue.items.len = 0;
            for (copy) |t| t.invoke();
        }

        // Phase 2: effects
        self.phase = .effects;
        // 2a: dirty store watchers
        for (self.dirty_indices.items) |idx| {
            const n = self.store_notifiers.items[idx];
            n.notifyFn(n.ctx);
        }
        self.dirty_indices.clearRetainingCapacity();

        // 2b: event watchers / scheduled effects
        while (self.effect_queue.items.len > 0) {
            const len = self.effect_queue.items.len;
            const copy = self.allocator.alloc(Thunk, len) catch @panic("OOM");
            defer self.allocator.free(copy);
            @memcpy(copy, self.effect_queue.items[0..len]);
            self.effect_queue.items.len = 0;
            for (copy) |t| t.invoke();
        }

        // Reset per-tick arena, advance tick
        _ = self.tick_arena.reset(.retain_capacity);
        self.tick_id +%= 1;
        if (self.tick_id == 0) self.tick_id = 1;
        self.phase = .idle;
    }

    pub fn trackGraphAlloc(self: *Engine, ptr: *anyopaque, dtor: CleanupFn) void {
        self.graph_cleanups.append(self.allocator, .{ .ptr = ptr, .dtor = dtor }) catch @panic("OOM");
    }

    pub fn schedulePure(self: *Engine, thunk: Thunk) void {
        self.pure_queue.append(self.allocator, thunk) catch @panic("OOM");
    }

    pub fn scheduleEffect(self: *Engine, thunk: Thunk) void {
        self.effect_queue.append(self.allocator, thunk) catch @panic("OOM");
    }
};
