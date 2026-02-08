const std = @import("std");
const event_mod = @import("event.zig");
const store_mod = @import("store.zig");
const sample_mod = @import("sample.zig");

pub const Engine = @import("engine.zig").Engine;
pub const Thunk = @import("engine.zig").Thunk;
pub const Subscription = @import("engine.zig").Subscription;
pub const Phase = @import("engine.zig").Phase;
pub const Event = event_mod.Event;
pub const Store = store_mod.Store;
pub const shape = @import("shape.zig");
pub const sample = sample_mod.sample;
pub const guard = sample_mod.guard;
pub const Domain = App;
pub const Runtime = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined,
    domain: Domain = undefined,

    pub fn init(self: *Runtime) void {
        self.gpa = .{};
        self.domain = createDomain(self.gpa.allocator());
    }

    pub fn deinit(self: *Runtime) void {
        self.domain.deinit();
        _ = self.gpa.deinit();
    }

    pub fn fx(self: *Runtime) BoundDomain {
        return bind(&self.domain);
    }
};

pub const BoundDomain = struct {
    domain: *Domain,

    pub fn event(self: BoundDomain, comptime T: type) *Event(T) {
        return allocEvent(&self.domain.eng, T);
    }

    pub fn createEvent(self: BoundDomain, comptime T: type) *Event(T) {
        return self.event(T);
    }

    pub fn store(self: BoundDomain, comptime T: type, initial: T) *Store(T) {
        return allocStore(&self.domain.eng, T, initial);
    }

    pub fn createStore(self: BoundDomain, comptime T: type, initial: T) *Store(T) {
        return self.store(T, initial);
    }

    pub fn sample(self: BoundDomain, opts: anytype) @TypeOf(sample_mod.sample(&self.domain.eng, opts)) {
        return sample_mod.sample(&self.domain.eng, opts);
    }

    pub fn guard(self: BoundDomain, opts: anytype) @TypeOf(sample_mod.guard(&self.domain.eng, opts)) {
        return sample_mod.guard(&self.domain.eng, opts);
    }

    pub fn forward(self: BoundDomain, from: anytype, to: anytype) @TypeOf(sample_mod.sample(&self.domain.eng, .{ .clock = from, .source = from, .target = to })) {
        return sample_mod.sample(&self.domain.eng, .{ .clock = from, .source = from, .target = to });
    }

    pub fn restore(self: BoundDomain, ev: anytype, initial: @typeInfo(@TypeOf(ev)).pointer.child.Payload) *Store(@typeInfo(@TypeOf(ev)).pointer.child.Payload) {
        const T = @typeInfo(@TypeOf(ev)).pointer.child.Payload;
        const st = allocStore(&self.domain.eng, T, initial);
        _ = st.on(ev, &struct {
            fn reduce(_: T, x: T) ?T {
                return x;
            }
        }.reduce);
        return st;
    }
};

fn allocEvent(eng: *Engine, comptime T: type) *Event(T) {
    const ev = eng.allocator.create(Event(T)) catch @panic("OOM");
    ev.* = .{ .eng = eng };
    eng.trackGraphAlloc(@ptrCast(ev), &struct {
        fn dtor(a: @import("std").mem.Allocator, p: *anyopaque) void {
            const e: *Event(T) = @ptrCast(@alignCast(p));
            e.deinit();
            a.destroy(e);
        }
    }.dtor);
    return ev;
}

fn allocStore(eng: *Engine, comptime T: type, initial: T) *Store(T) {
    const st = eng.allocator.create(Store(T)) catch @panic("OOM");
    st.* = .{ .eng = eng, .value = initial, .prev = initial };
    eng.trackGraphAlloc(@ptrCast(st), &struct {
        fn dtor(a: @import("std").mem.Allocator, p: *anyopaque) void {
            const s: *Store(T) = @ptrCast(@alignCast(p));
            s.deinit();
            a.destroy(s);
        }
    }.dtor);
    return st;
}

pub const App = struct {
    eng: Engine,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{ .eng = Engine.init(allocator) };
    }

    pub fn deinit(self: *App) void {
        self.eng.deinit();
    }

    pub fn event(self: *App, comptime T: type) *Event(T) {
        return allocEvent(&self.eng, T);
    }

    pub fn createEvent(self: *App, comptime T: type) *Event(T) {
        return allocEvent(&self.eng, T);
    }

    pub fn store(self: *App, comptime T: type, initial: T) *Store(T) {
        return allocStore(&self.eng, T, initial);
    }

    pub fn createStore(self: *App, comptime T: type, initial: T) *Store(T) {
        return allocStore(&self.eng, T, initial);
    }

    pub fn sample(self: *App, opts: anytype) @TypeOf(sample_mod.sample(&self.eng, opts)) {
        return sample_mod.sample(&self.eng, opts);
    }

    pub fn guard(self: *App, opts: anytype) @TypeOf(sample_mod.guard(&self.eng, opts)) {
        return sample_mod.guard(&self.eng, opts);
    }

    pub fn forward(self: *App, from: anytype, to: anytype) @TypeOf(sample_mod.sample(&self.eng, .{ .clock = from, .source = from, .target = to })) {
        return sample_mod.sample(&self.eng, .{ .clock = from, .source = from, .target = to });
    }

    pub fn restore(self: *App, ev: anytype, initial: @typeInfo(@TypeOf(ev)).pointer.child.Payload) *Store(@typeInfo(@TypeOf(ev)).pointer.child.Payload) {
        const T = @typeInfo(@TypeOf(ev)).pointer.child.Payload;
        const st = allocStore(&self.eng, T, initial);
        _ = st.on(ev, &struct {
            fn reduce(_: T, x: T) ?T {
                return x;
            }
        }.reduce);
        return st;
    }
};

// ─────────────────────────────────────────────
// Constructors (Effector-like)
// ─────────────────────────────────────────────

pub fn createApp(allocator: std.mem.Allocator) App {
    return App.init(allocator);
}

pub fn createDomain(allocator: std.mem.Allocator) Domain {
    return Domain.init(allocator);
}

pub fn bind(domain: *Domain) BoundDomain {
    return .{ .domain = domain };
}

pub fn createEvent(eng: *Engine, comptime T: type) *Event(T) {
    return allocEvent(eng, T);
}

pub fn createStore(eng: *Engine, comptime T: type, initial: T) *Store(T) {
    return allocStore(eng, T, initial);
}

// ─────────────────────────────────────────────
// forward(from, to) — sugar (deprecated in v23, use sample)
// ─────────────────────────────────────────────

pub fn forward(eng: *Engine, from: anytype, to: anytype) @TypeOf(to) {
    return sample(eng, .{ .clock = from, .source = from, .target = to });
}

// ─────────────────────────────────────────────
// restore(event, initial) → *Store(T)
// ─────────────────────────────────────────────

pub fn restore(eng: *Engine, ev: anytype, initial: @typeInfo(@TypeOf(ev)).pointer.child.Payload) *Store(@typeInfo(@TypeOf(ev)).pointer.child.Payload) {
    const T = @typeInfo(@TypeOf(ev)).pointer.child.Payload;
    const st = createStore(eng, T, initial);
    _ = st.on(ev, &struct {
        fn reduce(_: T, x: T) ?T {
            return x;
        }
    }.reduce);
    return st;
}

test "store.on applies reducer for each event emit" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    inc.emit(2);
    inc.emit(5);

    try std.testing.expectEqual(@as(i32, 7), count.get());
}

test "sample with clock/source/fn updates target store" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 1);
    const doubled = createStore(&eng, i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    _ = sample(&eng, .{
        .clock = inc,
        .source = count,
        .fn_ = &struct {
            fn map(v: i32) i32 {
                return v * 2;
            }
        }.map,
        .target = doubled,
    });

    inc.emit(3); // count: 4, doubled: 8
    inc.emit(1); // count: 5, doubled: 10

    try std.testing.expectEqual(@as(i32, 5), count.get());
    try std.testing.expectEqual(@as(i32, 10), doubled.get());
}

test "guard only forwards values that pass filter" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 0);
    const filtered = createStore(&eng, i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    _ = guard(&eng, .{
        .clock = inc,
        .source = count,
        .filter = &struct {
            fn allow(v: i32) bool {
                return v > 5;
            }
        }.allow,
        .target = filtered,
    });

    inc.emit(2); // blocked
    inc.emit(2); // blocked
    inc.emit(3); // passes with 7

    try std.testing.expectEqual(@as(i32, 7), count.get());
    try std.testing.expectEqual(@as(i32, 7), filtered.get());
}

test "forward pipes event payload to target event" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const source = createEvent(&eng, i32);
    const target = createEvent(&eng, i32);
    const last = restore(&eng, target, 0);

    _ = forward(&eng, source, target);

    source.emit(9);
    source.emit(4);

    try std.testing.expectEqual(@as(i32, 4), last.get());
}

test "sample without target returns auto-created event" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 0);
    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    const squared = sample(&eng, .{
        .clock = inc,
        .source = count,
        .fn_ = &struct {
            fn map(v: i32) i32 {
                return v * v;
            }
        }.map,
    });
    const last_squared = restore(&eng, squared, -1);

    inc.emit(2); // 4
    inc.emit(1); // 9

    try std.testing.expectEqual(@as(i32, 3), count.get());
    try std.testing.expectEqual(@as(i32, 9), last_squared.get());
}

test "sample supports shape source snapshot" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const tick = createEvent(&eng, i32);
    const a = createStore(&eng, i32, 1);
    const b = createStore(&eng, i32, 2);
    const sum = createStore(&eng, i32, 0);

    _ = sample(&eng, .{
        .clock = tick,
        .source = .{ .a = a, .b = b },
        .fn_ = &struct {
            fn map(snap: shape.SnapshotTypeOf(struct { a: *Store(i32), b: *Store(i32) })) i32 {
                return snap.a + snap.b;
            }
        }.map,
        .target = sum,
    });

    a.set(3);
    b.set(4);
    tick.emit(0);
    try std.testing.expectEqual(@as(i32, 7), sum.get());

    b.set(10);
    tick.emit(0);
    try std.testing.expectEqual(@as(i32, 13), sum.get());
}

test "store watcher runs once per tick even with multiple reducers" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 0);

    const Tracker = struct {
        var calls: usize = 0;
        var last: i32 = 0;
        fn onCount(v: i32) void {
            calls += 1;
            last = v;
        }
    };
    Tracker.calls = 0;
    Tracker.last = 0;

    _ = count.on(inc, &struct {
        fn plusPayload(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.plusPayload);
    _ = count.on(inc, &struct {
        fn plusOne(state: i32, _: i32) ?i32 {
            return state + 1;
        }
    }.plusOne);
    _ = count.watch(&Tracker.onCount);

    inc.emit(5);

    try std.testing.expectEqual(@as(i32, 6), count.get());
    try std.testing.expectEqual(@as(usize, 1), Tracker.calls);
    try std.testing.expectEqual(@as(i32, 6), Tracker.last);
}

test "effects phase sees final derived state from pure phase" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 0);
    const tripled = createStore(&eng, i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    _ = sample(&eng, .{
        .clock = inc,
        .source = count,
        .fn_ = &struct {
            fn map(v: i32) i32 {
                return v * 3;
            }
        }.map,
        .target = tripled,
    });

    const PhaseCheck = struct {
        var seen_tripled: i32 = -1;
        var tripled_ptr: ?*Store(i32) = null;
        fn onCount(_: i32) void {
            seen_tripled = tripled_ptr.?.get();
        }
    };
    PhaseCheck.seen_tripled = -1;
    PhaseCheck.tripled_ptr = tripled;
    _ = count.watch(&PhaseCheck.onCount);

    inc.emit(2);

    try std.testing.expectEqual(@as(i32, 2), count.get());
    try std.testing.expectEqual(@as(i32, 6), tripled.get());
    try std.testing.expectEqual(@as(i32, 6), PhaseCheck.seen_tripled);
}

test "stress: many emits keep logic stable" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        inc.emit(1);
    }

    try std.testing.expectEqual(@as(i32, 10_000), count.get());
}

test "app facade exposes sample and operators in JS-like style" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const inc = app.event(i32);
    const count = app.store(i32, 0);
    const doubled = app.store(i32, 0);
    const forwarded = app.event(i32);
    const last_forwarded = app.restore(forwarded, -1);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    _ = app.sample(.{
        .clock = inc,
        .source = count,
        .fn_ = &struct {
            fn map(v: i32) i32 {
                return v * 2;
            }
        }.map,
        .target = doubled,
    });

    _ = app.forward(inc, forwarded);

    inc.emit(2);
    inc.emit(3);

    try std.testing.expectEqual(@as(i32, 5), count.getState());
    try std.testing.expectEqual(@as(i32, 10), doubled.getState());
    try std.testing.expectEqual(@as(i32, 3), last_forwarded.getState());
}

test "store and event JS-like aliases work" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const ev = app.event(i32);
    const st = app.store(i32, 0);

    _ = st.on(ev, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    const WatchProbe = struct {
        var calls: usize = 0;
        var last: i32 = -1;
        fn onValue(v: i32) void {
            calls += 1;
            last = v;
        }
    };
    WatchProbe.calls = 0;
    WatchProbe.last = -1;

    const sub_store = st.subscribe(&WatchProbe.onValue);
    const sub_event = ev.subscribe(&struct {
        fn ignore(_: i32) void {}
    }.ignore);

    ev.emit(2);
    st.setState(5);
    st.unsubscribe(sub_store);
    ev.unsubscribe(sub_event);

    try std.testing.expectEqual(@as(i32, 5), st.getState());
    try std.testing.expectEqual(@as(usize, 2), WatchProbe.calls);
    try std.testing.expectEqual(@as(i32, 5), WatchProbe.last);
}

test "createDomain is an alias for createApp style API" {
    var domain = createDomain(std.testing.allocator);
    defer domain.deinit();

    const inc = domain.createEvent(i32);
    const count = domain.createStore(i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    inc.emit(7);
    try std.testing.expectEqual(@as(i32, 7), count.getState());
}

test "bound domain facade works without explicit domain pointer in calls" {
    var domain = createDomain(std.testing.allocator);
    defer domain.deinit();
    const fx = bind(&domain);

    const inc = fx.createEvent(i32);
    const count = fx.createStore(i32, 0);
    const doubled = fx.createStore(i32, 0);
    const last_inc = fx.restore(inc, -1);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    _ = fx.sample(.{
        .clock = inc,
        .source = count,
        .fn_ = &struct {
            fn map(v: i32) i32 {
                return v * 2;
            }
        }.map,
        .target = doubled,
    });

    inc.emit(2);
    inc.emit(3);

    try std.testing.expectEqual(@as(i32, 5), count.getState());
    try std.testing.expectEqual(@as(i32, 10), doubled.getState());
    try std.testing.expectEqual(@as(i32, 3), last_inc.getState());
}

test "runtime wrapper supports counter flow" {
    var rt: Runtime = undefined;
    rt.init();
    defer rt.deinit();

    const fx = rt.fx();
    const inc = fx.createEvent(i32);
    const count = fx.createStore(i32, 0);

    const Probe = struct {
        var calls: usize = 0;
        var last: i32 = -1;
        fn watch(v: i32) void {
            calls += 1;
            last = v;
        }
    };
    Probe.calls = 0;
    Probe.last = -1;

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);
    _ = count.subscribe(&Probe.watch);

    inc.emit(5);
    inc.emit(3);

    try std.testing.expectEqual(@as(i32, 8), count.getState());
    try std.testing.expectEqual(@as(usize, 2), Probe.calls);
    try std.testing.expectEqual(@as(i32, 8), Probe.last);
}
