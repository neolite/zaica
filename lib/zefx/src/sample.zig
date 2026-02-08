const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const event_mod = @import("event.zig");
const store_mod = @import("store.zig");
const shape_mod = @import("shape.zig");

fn resolveSourceType(comptime Source: type) type {
    if (shape_mod.isStoreShape(Source)) return shape_mod.SnapshotTypeOf(Source);
    const Child = @typeInfo(Source).pointer.child;
    if (@hasDecl(Child, "Value")) return Child.Value;
    if (@hasDecl(Child, "Payload")) return Child.Payload;
    @compileError("source must be *Store(T), *Event(T), or a shape struct of *Store");
}

fn FnReturnType(comptime F: type) type {
    const info = @typeInfo(F);
    if (info == .@"fn") return info.@"fn".return_type.?;
    if (info == .pointer) {
        const ci = @typeInfo(info.pointer.child);
        if (ci == .@"fn") return ci.@"fn".return_type.?;
    }
    @compileError("expected fn or *const fn");
}

fn isStorePtr(comptime T: type) bool {
    return shape_mod.isStorePtr(T);
}

/// Compute result value type (after fn_ transform).
fn ResultOf(comptime Opts: type) type {
    const has_fn = @hasField(Opts, "fn_");
    const has_source = @hasField(Opts, "source");
    if (has_fn) return FnReturnType(@FieldType(Opts, "fn_"));
    if (has_source) return resolveSourceType(@FieldType(Opts, "source"));
    // clock-only without fn: clock payload passes through
    return @typeInfo(@FieldType(Opts, "clock")).pointer.child.Payload;
}

/// Return type of sample():
///   - target provided → returns typeof(target)  (the target pointer itself)
///   - target absent   → returns *Event(ResultType)  (newly created)
fn SampleReturnType(comptime Opts: type) type {
    if (@hasField(Opts, "target")) {
        return @FieldType(Opts, "target");
    }
    return *event_mod.Event(ResultOf(Opts));
}

fn MakeWire(
    comptime SourceField: type,
    comptime FilterField: type,
    comptime FnField: type,
    comptime TargetField: type,
    comptime SourceType: type,
    comptime ClockType: type,
    comptime ResultType: type,
    comptime has_source: bool,
    comptime has_filter: bool,
    comptime has_fn: bool,
    comptime is_source_store: bool,
    comptime is_source_shape: bool,
    comptime is_target_store: bool,
) type {
    return struct {
        source: SourceField,
        filter: FilterField,
        fn_: FnField,
        target: TargetField,

        const Self = @This();

        pub fn run(self: *Self, _: ClockType) void {
            const src_val: SourceType = blk: {
                if (comptime !has_source) break :blk {};
                if (comptime is_source_shape) break :blk shape_mod.readSnapshot(self.source);
                if (comptime is_source_store) break :blk self.source.get();
                break :blk @as(SourceType, undefined);
            };

            if (comptime has_filter) {
                if (comptime isStorePtr(@TypeOf(self.filter))) {
                    if (!self.filter.get()) return;
                } else {
                    if (!@call(.auto, self.filter, .{src_val})) return;
                }
            }

            const result: ResultType = if (comptime has_fn)
                @call(.auto, self.fn_, .{src_val})
            else
                src_val;

            if (comptime is_target_store) {
                self.target.set(result);
            } else {
                self.target.emit(result);
            }
        }
    };
}

/// Track a heap allocation on the engine for cleanup at deinit.
fn track(eng: *Engine, comptime T: type, ptr: *T) void {
    eng.trackGraphAlloc(@ptrCast(ptr), &struct {
        fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
            a.destroy(@as(*T, @ptrCast(@alignCast(p))));
        }
    }.dtor);
}

// ─────────────────────────────────────────────
// sample() — full Effector semantics
// ─────────────────────────────────────────────
// • source: *Store | *Event | shape (struct/tuple of *Store)
// • clock  (optional): *Event — if absent, triggers on source updates
// • filter (optional): fn(S)->bool | *Store(bool)
// • fn_    (optional): fn(S)->R
// • target (optional): *Event(R) | *Store(R) — if absent, creates *Event(R)
//
// Returns: target (provided or created). Always a pointer to a unit.

pub fn sample(eng: *Engine, opts: anytype) SampleReturnType(@TypeOf(opts)) {
    const Opts = @TypeOf(opts);
    const has_source = @hasField(Opts, "source");
    const has_clock = @hasField(Opts, "clock");
    const has_filter = @hasField(Opts, "filter");
    const has_fn = @hasField(Opts, "fn_");
    const has_target = @hasField(Opts, "target");

    if (!has_source and !has_clock) @compileError("sample requires at least `source` or `clock`");

    const SourceType = if (has_source) resolveSourceType(@TypeOf(opts.source)) else void;
    const ClockType = if (has_clock) @typeInfo(@TypeOf(opts.clock)).pointer.child.Payload else void;
    const ResultType = comptime ResultOf(Opts);

    const is_source_store = comptime has_source and isStorePtr(@TypeOf(opts.source));
    const is_source_shape = comptime has_source and shape_mod.isStoreShape(@TypeOf(opts.source));

    // Resolve or create target
    const target = if (has_target) opts.target else blk: {
        const EvType = event_mod.Event(ResultType);
        const ev = eng.allocator.create(EvType) catch @panic("OOM");
        ev.* = .{ .eng = eng };
        // Track with deinit (frees internal ArrayLists) before destroy
        eng.trackGraphAlloc(@ptrCast(ev), &struct {
            fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                const e: *EvType = @ptrCast(@alignCast(p));
                e.deinit();
                a.destroy(e);
            }
        }.dtor);
        break :blk ev;
    };

    const TargetType = @TypeOf(target);
    const TargetChild = @typeInfo(TargetType).pointer.child;
    const is_target_store = comptime @hasDecl(TargetChild, "Value") and !@hasDecl(TargetChild, "Payload");

    const SourceField = if (has_source) @TypeOf(opts.source) else void;
    const FilterField = if (has_filter) @TypeOf(opts.filter) else void;
    const FnField = if (has_fn) @TypeOf(opts.fn_) else void;

    const WireCtx = MakeWire(
        SourceField, FilterField, FnField, TargetType,
        SourceType, ClockType, ResultType,
        has_source, has_filter, has_fn,
        is_source_store, is_source_shape, is_target_store,
    );

    const wire = eng.allocator.create(WireCtx) catch @panic("OOM");
    wire.* = .{
        .source = if (has_source) opts.source else {},
        .filter = if (has_filter) opts.filter else {},
        .fn_ = if (has_fn) opts.fn_ else {},
        .target = target,
    };
    track(eng, WireCtx, wire);

    // Wire to clock or source
    if (has_clock) {
        const W = struct { wire: *WireCtx };
        const ww = eng.allocator.create(W) catch @panic("OOM");
        ww.* = .{ .wire = wire };
        track(eng, W, ww);

        opts.clock.reducers.append(eng.allocator, .{
            .ctx = @ptrCast(ww),
            .trigger = &struct {
                fn trig(raw: *anyopaque, pp: *const anyopaque) void {
                    const c: *W = @ptrCast(@alignCast(raw));
                    const cv: *const ClockType = @ptrCast(@alignCast(pp));
                    c.wire.run(cv.*);
                }
            }.trig,
        }) catch @panic("OOM");
    } else if (has_source and is_source_store) {
        const upd = opts.source.updates();
        const W2 = struct { wire: *WireCtx };
        const ww2 = eng.allocator.create(W2) catch @panic("OOM");
        ww2.* = .{ .wire = wire };
        track(eng, W2, ww2);

        upd.reducers.append(eng.allocator, .{
            .ctx = @ptrCast(ww2),
            .trigger = &struct {
                fn trig(raw: *anyopaque, _: *const anyopaque) void {
                    const c: *W2 = @ptrCast(@alignCast(raw));
                    c.wire.run(@as(ClockType, undefined));
                }
            }.trig,
        }) catch @panic("OOM");
    }

    return target;
}

// ─────────────────────────────────────────────
// guard() — sample + filter sugar (deprecated in effector v23)
// ─────────────────────────────────────────────

pub fn guard(eng: *Engine, opts: anytype) SampleReturnType(@TypeOf(opts)) {
    const Opts = @TypeOf(opts);
    if (!@hasField(Opts, "filter")) @compileError("guard(): missing 'filter'");
    return sample(eng, opts);
}
