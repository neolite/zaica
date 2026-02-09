const std = @import("std");
const event_mod = @import("event.zig");
const store_mod = @import("store.zig");
const sample_mod = @import("sample.zig");
const effect_mod = @import("effect.zig");

pub const Engine = @import("engine.zig").Engine;
pub const Thunk = @import("engine.zig").Thunk;
pub const Subscription = @import("engine.zig").Subscription;
pub const Phase = @import("engine.zig").Phase;
pub const Event = event_mod.Event;
pub const Store = store_mod.Store;
pub const Effect = effect_mod.Effect;
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

    pub fn effect(self: BoundDomain, comptime Params: type, comptime Result: type, comptime ErrSet: type, handler: *const fn (Params) ErrSet!Result) *Effect(Params, Result, ErrSet) {
        return allocEffect(&self.domain.eng, Params, Result, ErrSet, handler);
    }

    pub fn createEffect(self: BoundDomain, comptime Params: type, comptime Result: type, comptime ErrSet: type, handler: *const fn (Params) ErrSet!Result) *Effect(Params, Result, ErrSet) {
        return self.effect(Params, Result, ErrSet, handler);
    }

    pub fn merge_(self: BoundDomain, sources: anytype) @TypeOf(merge(&self.domain.eng, sources)) {
        return merge(&self.domain.eng, sources);
    }

    pub fn split(self: BoundDomain, source: anytype, cases: anytype) @TypeOf(split_(&self.domain.eng, source, cases)) {
        return split_(&self.domain.eng, source, cases);
    }

    pub fn combine_(self: BoundDomain, stores: anytype, combineFn: anytype) @TypeOf(combine(&self.domain.eng, stores, combineFn)) {
        return combine(&self.domain.eng, stores, combineFn);
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
    st.* = .{ .eng = eng, .value = initial, .prev = initial, .initial = initial };
    eng.trackGraphAlloc(@ptrCast(st), &struct {
        fn dtor(a: @import("std").mem.Allocator, p: *anyopaque) void {
            const s: *Store(T) = @ptrCast(@alignCast(p));
            s.deinit();
            a.destroy(s);
        }
    }.dtor);
    return st;
}

fn allocEffect(eng: *Engine, comptime Params: type, comptime Result: type, comptime ErrSet: type, handler: *const fn (Params) ErrSet!Result) *Effect(Params, Result, ErrSet) {
    const E = Effect(Params, Result, ErrSet);
    const DoneData = E.DoneData;
    const FailData = E.FailData;

    const fx = eng.allocator.create(E) catch @panic("OOM");
    const done = allocEvent(eng, DoneData);
    const fail = allocEvent(eng, FailData);
    const finally_ = allocEvent(eng, E.FinallyData);
    const pending = allocStore(eng, bool, false);

    // pending = false on done or fail
    _ = pending.on(done, &struct {
        fn reduce(_: bool, _: DoneData) ?bool {
            return false;
        }
    }.reduce);
    _ = pending.on(fail, &struct {
        fn reduce(_: bool, _: FailData) ?bool {
            return false;
        }
    }.reduce);

    fx.* = .{
        .eng = eng,
        .handler = handler,
        .done = done,
        .fail = fail,
        .finally_ = finally_,
        .pending = pending,
    };

    eng.trackGraphAlloc(@ptrCast(fx), &struct {
        fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
            const e: *E = @ptrCast(@alignCast(p));
            e.deinit();
            a.destroy(e);
        }
    }.dtor);
    return fx;
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

    pub fn effect(self: *App, comptime Params: type, comptime Result: type, comptime ErrSet: type, handler: *const fn (Params) ErrSet!Result) *Effect(Params, Result, ErrSet) {
        return allocEffect(&self.eng, Params, Result, ErrSet, handler);
    }

    pub fn createEffect(self: *App, comptime Params: type, comptime Result: type, comptime ErrSet: type, handler: *const fn (Params) ErrSet!Result) *Effect(Params, Result, ErrSet) {
        return self.effect(Params, Result, ErrSet, handler);
    }

    pub fn merge_(self: *App, sources: anytype) @TypeOf(merge(&self.eng, sources)) {
        return merge(&self.eng, sources);
    }

    pub fn split(self: *App, source: anytype, cases: anytype) @TypeOf(split_(&self.eng, source, cases)) {
        return split_(&self.eng, source, cases);
    }

    pub fn combine_(self: *App, stores: anytype, combineFn: anytype) @TypeOf(combine(&self.eng, stores, combineFn)) {
        return combine(&self.eng, stores, combineFn);
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

pub fn createEffect_(eng: *Engine, comptime Params: type, comptime Result: type, comptime ErrSet: type, handler: *const fn (Params) ErrSet!Result) *Effect(Params, Result, ErrSet) {
    return allocEffect(eng, Params, Result, ErrSet, handler);
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

// ─────────────────────────────────────────────
// merge(.{ev1, ev2, ...}) → *Event(T)
// ─────────────────────────────────────────────

pub fn merge(eng: *Engine, sources: anytype) *Event(@typeInfo(@typeInfo(@TypeOf(sources)).@"struct".fields[0].type).pointer.child.Payload) {
    const T = @typeInfo(@typeInfo(@TypeOf(sources)).@"struct".fields[0].type).pointer.child.Payload;
    const target = allocEvent(eng, T);
    const fields = @typeInfo(@TypeOf(sources)).@"struct".fields;
    inline for (fields) |f| {
        const src = @field(sources, f.name);
        const FwdCtx = struct { tgt: *Event(T) };
        const ctx = eng.allocator.create(FwdCtx) catch @panic("OOM");
        ctx.* = .{ .tgt = target };
        eng.trackGraphAlloc(@ptrCast(ctx), &struct {
            fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *FwdCtx = @ptrCast(@alignCast(p));
                a.destroy(c);
            }
        }.dtor);
        src.reducers.append(eng.allocator, .{
            .ctx = @ptrCast(ctx),
            .trigger = &struct {
                fn trigger(raw: *anyopaque, payload_ptr: *const anyopaque) void {
                    const c: *FwdCtx = @ptrCast(@alignCast(raw));
                    const payload: *const T = @ptrCast(@alignCast(payload_ptr));
                    c.tgt.emit(payload.*);
                }
            }.trigger,
        }) catch @panic("OOM");
    }
    return target;
}

// ─────────────────────────────────────────────
// split(source, .{.case = filterFn, ...}) → .{.case = *Event(T), ...}
// ─────────────────────────────────────────────

pub fn split_(eng: *Engine, source: anytype, cases: anytype) SplitResult(@TypeOf(source.*).Payload, @TypeOf(cases)) {
    return SplitHelper(@TypeOf(source.*).Payload, @TypeOf(cases)).create(eng, source, cases);
}

fn SplitHelper(comptime T: type, comptime Cases: type) type {
    return struct {
        const Result = SplitResult(T, Cases);
        const case_fields = @typeInfo(Cases).@"struct".fields;

        const SplitCtx = struct {
            result: Result,
            cases: Cases,
        };

        fn create(eng: *Engine, source: anytype, cases: Cases) Result {
            var result: Result = undefined;
            inline for (case_fields) |f| {
                @field(result, f.name) = allocEvent(eng, T);
            }

            const ctx = eng.allocator.create(SplitCtx) catch @panic("OOM");
            ctx.* = .{ .result = result, .cases = cases };
            eng.trackGraphAlloc(@ptrCast(ctx), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const c: *SplitCtx = @ptrCast(@alignCast(p));
                    a.destroy(c);
                }
            }.dtor);

            source.reducers.append(eng.allocator, .{
                .ctx = @ptrCast(ctx),
                .trigger = &triggerFn,
            }) catch @panic("OOM");

            return result;
        }

        fn triggerFn(raw: *anyopaque, payload_ptr: *const anyopaque) void {
            const c: *SplitCtx = @ptrCast(@alignCast(raw));
            const payload: *const T = @ptrCast(@alignCast(payload_ptr));
            inline for (case_fields) |f| {
                const filterFn = @field(c.cases, f.name);
                if (filterFn(payload.*)) {
                    @field(c.result, f.name).emit(payload.*);
                }
            }
        }
    };
}

fn SplitResult(comptime T: type, comptime Cases: type) type {
    const case_fields = @typeInfo(Cases).@"struct".fields;
    var fields: [case_fields.len]std.builtin.Type.StructField = undefined;
    inline for (case_fields, 0..) |f, i| {
        fields[i] = .{
            .name = f.name,
            .type = *Event(T),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(*Event(T)),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

// ─────────────────────────────────────────────
// combine(.{.a = $a, .b = $b}, combineFn) → *Store(R)
// ─────────────────────────────────────────────

pub fn combine(eng: *Engine, stores: anytype, combineFn: anytype) *Store(CombineResultType(@TypeOf(combineFn))) {
    return CombineHelper(@TypeOf(stores), @TypeOf(combineFn)).create(eng, stores, combineFn);
}

fn CombineResultType(comptime FnType: type) type {
    const fn_info = @typeInfo(@typeInfo(FnType).pointer.child).@"fn";
    return fn_info.return_type.?;
}

fn CombineHelper(comptime Shape: type, comptime FnType: type) type {
    const R = CombineResultType(FnType);
    return struct {
        const CombineCtx = struct {
            derived_store: *Store(R),
            shape_stores: Shape,
            combineFn: FnType,
        };

        fn create(eng: *Engine, stores: Shape, combineFn: FnType) *Store(R) {
            const snap = shape.readSnapshot(stores);
            const init_val = combineFn(snap);
            const derived = allocStore(eng, R, init_val);
            derived.ensureRegistered();

            const store_fields = @typeInfo(Shape).@"struct".fields;
            inline for (store_fields) |f| {
                const src_store = @field(stores, f.name);
                src_store.ensureRegistered();

                const ctx = eng.allocator.create(CombineCtx) catch @panic("OOM");
                ctx.* = .{ .derived_store = derived, .shape_stores = stores, .combineFn = combineFn };
                eng.trackGraphAlloc(@ptrCast(ctx), &struct {
                    fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                        const c: *CombineCtx = @ptrCast(@alignCast(p));
                        a.destroy(c);
                    }
                }.dtor);

                src_store.updates().reducers.append(eng.allocator, .{
                    .ctx = @ptrCast(ctx),
                    .trigger = &triggerFn,
                }) catch @panic("OOM");
            }

            return derived;
        }

        fn triggerFn(raw: *anyopaque, _: *const anyopaque) void {
            const c: *CombineCtx = @ptrCast(@alignCast(raw));
            const new_snap = shape.readSnapshot(c.shape_stores);
            const new_val = c.combineFn(new_snap);
            c.derived_store.prev = c.derived_store.value;
            c.derived_store.value = new_val;
            c.derived_store.markDirty();
        }
    };
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

test "emit from watcher during effects is applied in same tick" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const inc = createEvent(&eng, i32);
    const mirrored_ev = createEvent(&eng, i32);
    const count = createStore(&eng, i32, 0);
    const mirrored = createStore(&eng, i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);
    _ = mirrored.on(mirrored_ev, &struct {
        fn reduce(_: i32, payload: i32) ?i32 {
            return payload;
        }
    }.reduce);

    const Relay = struct {
        var ev_ptr: ?*Event(i32) = null;
        fn onCount(v: i32) void {
            ev_ptr.?.emit(v);
        }
    };
    Relay.ev_ptr = mirrored_ev;
    _ = count.watch(&Relay.onCount);

    inc.emit(1);
    try std.testing.expectEqual(@as(i32, 1), count.getState());
    try std.testing.expectEqual(@as(i32, 1), mirrored.getState());

    inc.emit(2);
    try std.testing.expectEqual(@as(i32, 3), count.getState());
    try std.testing.expectEqual(@as(i32, 3), mirrored.getState());
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

test "effect success path emits done and sets pending" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const FxErr = error{Boom};
    const fetchFx = app.effect(i32, i32, FxErr, &struct {
        fn handler(params: i32) FxErr!i32 {
            return params * 10;
        }
    }.handler);

    const DoneProbe = struct {
        var last_result: i32 = -1;
        var last_params: i32 = -1;
        fn watch(d: Effect(i32, i32, FxErr).DoneData) void {
            last_result = d.result;
            last_params = d.params;
        }
    };
    DoneProbe.last_result = -1;
    DoneProbe.last_params = -1;
    _ = fetchFx.done.watch(&DoneProbe.watch);

    fetchFx.run(5);

    try std.testing.expectEqual(@as(i32, 50), DoneProbe.last_result);
    try std.testing.expectEqual(@as(i32, 5), DoneProbe.last_params);
    try std.testing.expectEqual(false, fetchFx.pending.get());
}

test "effect error path emits fail" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const FxErr = error{Boom};
    const fetchFx = app.effect(i32, i32, FxErr, &struct {
        fn handler(_: i32) FxErr!i32 {
            return error.Boom;
        }
    }.handler);

    const FailProbe = struct {
        var got_err: bool = false;
        var last_params: i32 = -1;
        fn watch(d: Effect(i32, i32, FxErr).FailData) void {
            got_err = (d.err == error.Boom);
            last_params = d.params;
        }
    };
    FailProbe.got_err = false;
    FailProbe.last_params = -1;
    _ = fetchFx.fail.watch(&FailProbe.watch);

    fetchFx.run(3);

    try std.testing.expect(FailProbe.got_err);
    try std.testing.expectEqual(@as(i32, 3), FailProbe.last_params);
    try std.testing.expectEqual(false, fetchFx.pending.get());
}

test "effect pending store is false after completion" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const FxErr = error{Oops};
    const fx = app.effect(i32, i32, FxErr, &struct {
        fn handler(p: i32) FxErr!i32 {
            return p;
        }
    }.handler);

    // Before run, pending is false
    try std.testing.expectEqual(false, fx.pending.get());

    fx.run(1);

    // After synchronous effect completes, pending settles to false
    try std.testing.expectEqual(false, fx.pending.get());
}

test "sample with effect.done as clock" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const FxErr = error{Nope};
    const fetchFx = app.effect(i32, i32, FxErr, &struct {
        fn handler(p: i32) FxErr!i32 {
            return p + 1;
        }
    }.handler);

    const results = app.store(i32, 0);
    _ = results.on(fetchFx.done, &struct {
        fn reduce(_: i32, d: Effect(i32, i32, FxErr).DoneData) ?i32 {
            return d.result;
        }
    }.reduce);

    fetchFx.run(9);
    try std.testing.expectEqual(@as(i32, 10), results.get());

    fetchFx.run(19);
    try std.testing.expectEqual(@as(i32, 20), results.get());
}

// ─────────────────────────────────────────────
// Tests for new operators
// ─────────────────────────────────────────────

test "store.reset restores initial value on event" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const inc = app.event(i32);
    const rst = app.event(void);
    const count = app.store(i32, 0);

    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);
    _ = count.reset(rst);

    inc.emit(5);
    inc.emit(3);
    try std.testing.expectEqual(@as(i32, 8), count.get());

    rst.emit({});
    try std.testing.expectEqual(@as(i32, 0), count.get());

    inc.emit(2);
    try std.testing.expectEqual(@as(i32, 2), count.get());
}

test "store.map derives a new store" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const inc = app.event(i32);
    const count = app.store(i32, 1);
    _ = count.on(inc, &struct {
        fn reduce(state: i32, payload: i32) ?i32 {
            return state + payload;
        }
    }.reduce);

    const doubled = count.map(i32, &struct {
        fn m(v: i32) i32 {
            return v * 2;
        }
    }.m);

    try std.testing.expectEqual(@as(i32, 2), doubled.get()); // initial mapped

    inc.emit(4); // count=5, doubled=10
    try std.testing.expectEqual(@as(i32, 5), count.get());
    try std.testing.expectEqual(@as(i32, 10), doubled.get());
}

test "event.map transforms payload" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const src = app.event(i32);
    const doubled = src.map(i32, &struct {
        fn m(v: i32) i32 {
            return v * 2;
        }
    }.m);

    const last = restore(&app.eng, doubled, 0);

    src.emit(5);
    try std.testing.expectEqual(@as(i32, 10), last.get());

    src.emit(3);
    try std.testing.expectEqual(@as(i32, 6), last.get());
}

test "event.filter only passes matching payloads" {
    var app = createApp(std.testing.allocator);
    defer app.deinit();

    const src = app.event(i32);
    const positive = src.filter(&struct {
        fn f(v: i32) bool {
            return v > 0;
        }
    }.f);

    const last = restore(&app.eng, positive, 0);

    src.emit(-1);
    try std.testing.expectEqual(@as(i32, 0), last.get());

    src.emit(5);
    try std.testing.expectEqual(@as(i32, 5), last.get());

    src.emit(-3);
    try std.testing.expectEqual(@as(i32, 5), last.get());
}

test "merge combines multiple events into one" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const a = createEvent(&eng, i32);
    const b = createEvent(&eng, i32);
    const c = createEvent(&eng, i32);

    const merged = merge(&eng, .{ a, b, c });
    const last = restore(&eng, merged, 0);

    a.emit(1);
    try std.testing.expectEqual(@as(i32, 1), last.get());

    b.emit(2);
    try std.testing.expectEqual(@as(i32, 2), last.get());

    c.emit(3);
    try std.testing.expectEqual(@as(i32, 3), last.get());
}

test "split routes event to matching cases" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const src = createEvent(&eng, i32);
    const cases = split_(&eng, src, .{
        .positive = &struct {
            fn f(v: i32) bool {
                return v > 0;
            }
        }.f,
        .negative = &struct {
            fn f(v: i32) bool {
                return v < 0;
            }
        }.f,
    });

    const last_pos = restore(&eng, cases.positive, 0);
    const last_neg = restore(&eng, cases.negative, 0);

    src.emit(5);
    try std.testing.expectEqual(@as(i32, 5), last_pos.get());
    try std.testing.expectEqual(@as(i32, 0), last_neg.get());

    src.emit(-3);
    try std.testing.expectEqual(@as(i32, 5), last_pos.get());
    try std.testing.expectEqual(@as(i32, -3), last_neg.get());
}

test "combine derives store from multiple source stores" {
    var eng = Engine.init(std.testing.allocator);
    defer eng.deinit();

    const a = createStore(&eng, i32, 1);
    const b = createStore(&eng, i32, 2);

    const sum = combine(&eng, .{ .a = a, .b = b }, &struct {
        fn calc(snap: shape.SnapshotTypeOf(struct { a: *Store(i32), b: *Store(i32) })) i32 {
            return snap.a + snap.b;
        }
    }.calc);

    try std.testing.expectEqual(@as(i32, 3), sum.get()); // initial

    a.set(5);
    try std.testing.expectEqual(@as(i32, 7), sum.get());

    b.set(10);
    try std.testing.expectEqual(@as(i32, 15), sum.get());
}
