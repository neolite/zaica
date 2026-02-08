const std = @import("std");
const zefx = @import("zefx");

// ─── watchers (side effects) ───

fn renderCount(v: i32) void {
    std.debug.print("  [render] $count = {d}\n", .{v});
}
fn renderDoubled(v: i32) void {
    std.debug.print("  [sample] doubled = {d}\n", .{v});
}
fn renderTripled(v: i32) void {
    std.debug.print("  [sample→store] $tripled = {d}\n", .{v});
}
fn renderGuard(v: i32) void {
    std.debug.print("  [guard] big value = {d}\n", .{v});
}
fn renderShape(v: i32) void {
    std.debug.print("  [shape] a + b = {d}\n", .{v});
}
fn renderNoTarget(v: i32) void {
    std.debug.print("  [auto-target] squared = {d}\n", .{v});
}
fn renderForward(v: i32) void {
    std.debug.print("  [forward] received = {d}\n", .{v});
}
fn renderRestore(v: i32) void {
    std.debug.print("  [restore] $lastInc = {d}\n", .{v});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var eng = zefx.Engine.init(alloc);
    defer eng.deinit();

    // ─── events ───
    var inc = zefx.Event(i32){ .eng = &eng };
    defer inc.deinit();
    var dec = zefx.Event(i32){ .eng = &eng };
    defer dec.deinit();

    // ─── stores ───
    var count = zefx.Store(i32){ .eng = &eng, .value = 0, .prev = 0 };
    defer count.deinit();
    _ = count.on(&inc, &struct {
        fn r(s: i32, x: i32) ?i32 { return s + x; }
    }.r);
    _ = count.on(&dec, &struct {
        fn r(s: i32, x: i32) ?i32 { return s - x; }
    }.r);
    _ = count.watch(&renderCount);

    // ─── 1. sample: clock + source + fn → explicit target Event ───
    var doubled_ev = zefx.Event(i32){ .eng = &eng };
    defer doubled_ev.deinit();
    _ = doubled_ev.watch(&renderDoubled);

    _ = zefx.sample(&eng, .{
        .source = &count,
        .clock = &inc,
        .fn_ = &struct {
            fn f(src: i32) i32 { return src * 2; }
        }.f,
        .target = &doubled_ev,
    });

    // ─── 2. sample: clock + source + fn → target Store ───
    var tripled = zefx.Store(i32){ .eng = &eng, .value = 0, .prev = 0 };
    defer tripled.deinit();
    _ = tripled.watch(&renderTripled);

    _ = zefx.sample(&eng, .{
        .source = &count,
        .clock = &inc,
        .fn_ = &struct {
            fn f(src: i32) i32 { return src * 3; }
        }.f,
        .target = &tripled,
    });

    // ─── 3. guard: filter (only big values pass) ───
    var big_ev = zefx.Event(i32){ .eng = &eng };
    defer big_ev.deinit();
    _ = big_ev.watch(&renderGuard);

    _ = zefx.guard(&eng, .{
        .source = &count,
        .clock = &inc,
        .filter = &struct {
            fn f(v: i32) bool { return v > 5; }
        }.f,
        .target = &big_ev,
    });

    // ─── 4. sample: shape source (struct of *Store) ───
    var other = zefx.Store(i32){ .eng = &eng, .value = 10, .prev = 10 };
    defer other.deinit();
    var shape_ev = zefx.Event(i32){ .eng = &eng };
    defer shape_ev.deinit();
    _ = shape_ev.watch(&renderShape);

    _ = zefx.sample(&eng, .{
        .source = .{ .a = &count, .b = &other },
        .clock = &inc,
        .fn_ = &struct {
            fn f(snap: zefx.shape.SnapshotTypeOf(struct { a: *zefx.Store(i32), b: *zefx.Store(i32) })) i32 {
                return snap.a + snap.b;
            }
        }.f,
        .target = &shape_ev,
    });

    // ─── 5. sample: NO target → auto-creates *Event(R) ───
    const squared = zefx.sample(&eng, .{
        .source = &count,
        .clock = &inc,
        .fn_ = &struct {
            fn f(src: i32) i32 { return src * src; }
        }.f,
    });
    _ = squared.watch(&renderNoTarget);

    // ─── 6. forward: inc → fwd_ev ───
    var fwd_ev = zefx.Event(i32){ .eng = &eng };
    defer fwd_ev.deinit();
    _ = fwd_ev.watch(&renderForward);

    _ = zefx.forward(&eng, &inc, &fwd_ev);

    // ─── 7. restore: inc → $lastInc ───
    const lastInc = zefx.restore(&eng, &inc, 0);
    _ = lastInc.watch(&renderRestore);

    // ═══════════════ RUN ═══════════════

    std.debug.print("═══ inc(5) ═══\n", .{});
    inc.emit(5);

    std.debug.print("\n═══ inc(3) ═══\n", .{});
    inc.emit(3);

    std.debug.print("\n═══ dec(2) ═══\n", .{});
    dec.emit(2);

    std.debug.print("\n═══ count.set(100) ═══\n", .{});
    count.set(100);

    std.debug.print("\n─── final state ───\n", .{});
    std.debug.print("$count    = {d}\n", .{count.get()});
    std.debug.print("$tripled  = {d}\n", .{tripled.get()});
    std.debug.print("$lastInc  = {d}\n", .{lastInc.get()});
}
