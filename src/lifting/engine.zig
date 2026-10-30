//! Guest bring-up: reserve, load, place, init. Stops short of execution
//! (that needs the JIT runner); callers liftAll before invoking code.
//!
//! Layout (defaults; validated against the real map at init):
//!   [0, 64K)            guard (PROT_NONE, from reservation)
//!   [base, mem_end)     image bytes, copied from the shim's dense image
//!   [heap_base, +size)  guest heap (bump allocator via trampoline)
//!   [stack_top-size, stack_top)  guest stack, ESP starts 16-aligned at top-16
//!   [0xFF000000, +nimports)  import sentinels (call targets, never data)

const std = @import("std");
const bridge = @import("bridge.zig");
const jit_mod = @import("jit.zig");
const reservation = @import("reservation.zig");
const trampoline = @import("trampoline.zig");

extern fn zffe_mem_set_base(base: u64) void;
extern fn zffe_state_new(esp: u32, eip: u32) ?*anyopaque;
extern fn zffe_state_free(state: ?*anyopaque) void;
extern fn zffe_run_guarded(state: ?*anyopaque, entry: *const jit_mod.GuestFn, pc: u32, mem: ?*anyopaque) callconv(.c) ?*anyopaque;

pub const SENTINEL_BASE: u64 = 0xFF000000;

pub const Layout = struct {
    heap_base: u32 = 0x700000,
    heap_size: u32 = 64 << 20,
    stack_top: u32 = 0xFE000000,
    stack_size: u32 = 8 << 20,
};

pub const Guest = struct {
    base: usize, // H
    image: *bridge.Image,
    state: ?*anyopaque,
    layout: Layout,
    jit: ?jit_mod.Jit = null, // set after liftAll via jit.Jit.create
};

pub const InitError = error{
    ReserveFailed,
    LoadFailed,
    OutOfMemory,
    BadLayout,
    BadEntry,
    StateFailed,
};

pub fn init(bin_path: [:0]const u8, map_path: [:0]const u8, layout: Layout) InitError!Guest {
    const base = reservation.reserve() catch return error.ReserveFailed;
    errdefer reservation.release(base);

    const img = bridge.load(bin_path, map_path, null, null) catch |e| switch (e) {
        error.LoadFailed => return error.LoadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer img.free();

    // Placement vs the real image: heap past mem_end without wrapping.
    const hb: u64 = layout.heap_base;
    const hs: u64 = layout.heap_size;
    if (hs == 0 or img.mem_end > hb or hb + hs > 0x1_0000_0000) return error.BadLayout;

    // Entry must be inside the executable range.
    if (img.entry < img.code_start or img.entry >= img.code_end) return error.BadEntry;

    // Stack window [s_lo, s_top): in range, above the guard, clear of the
    // image, the heap, and the import sentinels.
    const s_top: u64 = layout.stack_top;
    const s_size: u64 = layout.stack_size;
    if (s_size == 0 or s_size > s_top) return error.BadLayout;
    const s_lo = s_top - s_size;
    if (s_lo < reservation.GUARD_SIZE) return error.BadLayout;
    if (s_lo < img.mem_end and s_top > img.base) return error.BadLayout;
    if (s_lo < hb + hs and s_top > hb) return error.BadLayout;
    if (s_lo < SENTINEL_BASE + img.nimports and s_top > SENTINEL_BASE) return error.BadLayout;

    // Place image bytes at guest addresses.
    const bytes = img.byteSlice();
    @memcpy(reservation.slice(base, img.base, bytes.len), bytes);

    // Wire the translation bases.
    zffe_mem_set_base(@intCast(base));
    trampoline.zffe_tramp_init(@intCast(base), layout.heap_base, layout.heap_size);

    // Clear the stack window.
    @memset(reservation.slice(base, s_lo, @intCast(s_size)), 0);

    // CPU state: ESP 16-aligned just under the top, EIP at the entry point.
    const esp: u32 = @intCast((s_top - 16) & ~@as(u64, 15));
    const state = zffe_state_new(esp, @intCast(img.entry)) orelse return error.StateFailed;
    errdefer zffe_state_free(state);

    return .{ .base = base, .image = img, .state = state, .layout = layout };
}

pub fn deinit(g: *Guest) void {
    // JIT first: dispatch borrows the image, and compiled code is only
    // callable while the reservation lives.
    if (g.jit) |j| j.destroy();
    zffe_state_free(g.state);
    g.image.free();
    reservation.release(g.base);
    g.* = undefined;
}

pub const LiftError = error{LiftFailed};

/// Lift every function trace, plus the entry point when no sym covers it
/// (as `sub_<hex>`). A failed lift is catastrophic: print the culprit and
/// abort. Returns the number of traces lifted.
pub fn liftAll(g: *Guest) LiftError!usize {
    var n: usize = 0;
    for (g.image.funcSlice()) |*f| {
        if (f.symKind() != .func) continue;
        if (bridge.zffe_lift(g.image, f.addr) == null) {
            std.debug.print("lift failed for {s} (0x{x}): {s}\n", .{
                std.mem.span(f.name), f.addr, g.image.errMsg() orelse "?",
            });
            return error.LiftFailed;
        }
        n += 1;
    }
    if (g.image.funcByAddr(g.image.entry) == null) {
        if (bridge.zffe_lift(g.image, g.image.entry) == null) {
            std.debug.print("lift failed for entry (0x{x}): {s}\n", .{
                g.image.entry, g.image.errMsg() orelse "?",
            });
            return error.LiftFailed;
        }
        n += 1;
    }
    const extra = bridge.zffe_lift_closure(g.image);
    if (extra < 0) {
        std.debug.print("lift closure failed: {s}\n", .{g.image.errMsg() orelse "?"});
        return error.LiftFailed;
    }
    return n + @as(usize, @intCast(extra));
}

pub const CallError = error{ JitMissing, UnknownSymbol, BadSymbol };

/// Guest pc for a callable name: a map sym's address, or the hex tail of a
/// `sub_<hex>` synthesized trace. Anything else is not callable by name.
fn pcForCall(img: *bridge.Image, name: []const u8) ?u32 {
    if (img.funcByName(name)) |f| return @truncate(f.addr);
    if (std.mem.startsWith(u8, name, "sub_")) {
        return std.fmt.parseInt(u32, name[4..], 16) catch null;
    }
    return null;
}

/// Invoke guest code by symbol name with cdecl arguments. Pushes a dummy
/// return address plus the args (so the callee sees args at [ESP+4] as a
/// real `call` would leave them), invokes the JIT'd trace, and returns EAX.
/// Traces run under zffe_run_guarded, so guest longjmp (IRET) abandons host
/// frames and resumes at its target instead of unwinding.
/// State.ESP is restored unconditionally: callee stack effects don't leak
/// into the caller. Float returns land in ST0 (see trampoline.state.x87_st0).
pub fn call(g: *Guest, name: [:0]const u8, args: []const u32) CallError!u32 {
    const j = g.jit orelse return error.JitMissing;
    const f = j.lookup(g.image, name) catch |err| switch (err) {
        error.UnknownSymbol => {
            std.debug.print("jit lookup failed for {s}: {s}\n", .{
                name, g.image.errMsg() orelse "?",
            });
            return error.UnknownSymbol;
        },
    };
    const pc = pcForCall(g.image, name) orelse return error.BadSymbol;

    const st: [*]u8 = @ptrCast(g.state.?);
    const esp_p: *align(1) u32 = @ptrCast(st + trampoline.state.gpr_rsp);
    const esp0 = esp_p.*;
    const esp1 = esp0 - 4 - 4 * @as(u32, @intCast(args.len));
    const frame = reservation.slice(g.base, esp1, 4 + 4 * args.len);
    // Dummy return slot: popped and discarded by the trace's terminal `ret`
    // (which lowers to a plain LLVM return), never executed.
    std.mem.writeInt(u32, frame[0..4], 0xDEADBEEF, .little);
    for (args, 0..) |a, i| {
        std.mem.writeInt(u32, frame[4 + 4 * i ..][0..4], a, .little);
    }
    esp_p.* = esp1;
    _ = zffe_run_guarded(g.state, f, pc, null);
    const eax: *align(1) const u32 = @ptrCast(st + trampoline.state.gpr_rax);
    const ret = eax.*;
    esp_p.* = esp0;
    return ret;
}

const t = std.testing;

const fixture_map =
    \\# fixture
    \\base 0x400000
    \\entry 0x401000
    \\code 0x401000 0x401010
    \\mem_end 0x403100
    \\sym FUNC_000020 0x401000 0x10 func
    \\sym DATA_0001 0x402000 0x8 data
    \\import _C_DrawSprite 0xff000000
    \\
;

const fixture_bad_entry =
    \\# fixture
    \\base 0x400000
    \\entry 0x500000
    \\code 0x401000 0x401010
    \\mem_end 0x403100
    \\sym FUNC_000020 0x401000 0x10 func
    \\
;

fn writeFixture(dir: std.Io.Dir, io: std.Io, map_text: []const u8) !void {
    var bin: [0x18]u8 = @splat(0x90);
    bin[0xf] = 0xc3;
    try dir.writeFile(io, .{ .sub_path = "ffe.bin", .data = &bin });
    try dir.writeFile(io, .{ .sub_path = "ffe.map", .data = map_text });
}

test "init wires reservation, image, heap, stack, state" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, io, fixture_map);

    var path_buf: [256]u8 = undefined;
    const bin_path = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}/ffe.bin", .{tmp.sub_path[0..]}, 0);
    const map_path = try std.fmt.bufPrintSentinel(path_buf[128..], ".zig-cache/tmp/{s}/ffe.map", .{tmp.sub_path[0..]}, 0);

    var g = try init(bin_path, map_path, .{});
    defer deinit(&g);

    // Image bytes landed at guest addresses.
    try t.expectEqual(@as(u8, 0x90), reservation.slice(g.base, 0x400000, 1)[0]);
    try t.expectEqual(@as(u8, 0xc3), reservation.slice(g.base, 0x40000f, 1)[0]);
    try t.expectEqual(@as(u8, 0), reservation.slice(g.base, 0x400100, 1)[0]);

    // Stack window cleared.
    try t.expectEqual(@as(u8, 0), reservation.slice(g.base, 0xFD800000, 1)[0]);
    try t.expectEqual(@as(u8, 0), reservation.slice(g.base, 0xFDFFFFFF, 1)[0]);

    // State ESP is where the trampolines read it (the C++ side asserts the
    // EIP/EFLAGS offsets; see zffe_state_new in shim.cpp).
    const esp: u32 = @as(*align(1) const u32, @ptrCast(@as([*]u8, @ptrCast(g.state.?)) + trampoline.state.gpr_rsp)).*;
    try t.expectEqual(@as(u32, 0xFDFFFFF0), esp);

    // The heap is live: malloc/free through a real adapter against the
    // reservation, tripwire watched via the stats export.
    const sp: *align(1) u32 = @ptrFromInt(g.base + 0xFDFFFFF0 + 4);
    sp.* = 100;
    trampoline.tramp_malloc(g.state, 0, null);
    const a: u32 = @as(*align(1) const u32, @ptrCast(@as([*]u8, @ptrCast(g.state.?)) + trampoline.state.gpr_rax)).*;
    try t.expectEqual(@as(u32, 0x700008), a);
    var alloc: u64 = 0;
    var freed: u64 = 0;
    var high: u64 = 0;
    trampoline.zffe_heap_stats(&alloc, &freed, &high);
    try t.expect(alloc >= 100 and freed == 0 and high >= 100);
    sp.* = a;
    trampoline.tramp_free(g.state, 0, null);
    trampoline.zffe_heap_stats(&alloc, &freed, &high);
    try t.expectEqual(alloc, freed);
}

test "liftAll lifts funcs and skips data" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, io, fixture_map);

    var path_buf: [256]u8 = undefined;
    const bin_path = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}/ffe.bin", .{tmp.sub_path[0..]}, 0);
    const map_path = try std.fmt.bufPrintSentinel(path_buf[128..], ".zig-cache/tmp/{s}/ffe.map", .{tmp.sub_path[0..]}, 0);

    var g = try init(bin_path, map_path, .{});
    defer deinit(&g);

    const n = try liftAll(&g);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(c_int, 1), g.image.funcSlice()[0].lifted);
}

fn writeBinMap(dir: std.Io.Dir, io: std.Io, bin: []const u8, map_text: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = "ffe.bin", .data = bin });
    try dir.writeFile(io, .{ .sub_path = "ffe.map", .data = map_text });
}

/// Full bring-up for call tests: init, liftAll, JIT. The caller owns the
/// guest (defer deinit) and the tmp dir.
fn callGuest(tmp: *std.testing.TmpDir, io: std.Io, bin: []const u8, map_text: []const u8, path_buf: *[256]u8) !Guest {
    try writeBinMap(tmp.dir, io, bin, map_text);
    const bin_path = try std.fmt.bufPrintSentinel(path_buf, ".zig-cache/tmp/{s}/ffe.bin", .{tmp.sub_path[0..]}, 0);
    const map_path = try std.fmt.bufPrintSentinel(path_buf[128..], ".zig-cache/tmp/{s}/ffe.map", .{tmp.sub_path[0..]}, 0);
    var g = try init(bin_path, map_path, .{});
    errdefer deinit(&g);
    _ = try liftAll(&g);
    g.jit = try jit_mod.Jit.create(g.image);
    return g;
}

fn stateEsp(g: *const Guest) u32 {
    return @as(*align(1) const u32, @ptrCast(@as([*]u8, @ptrCast(g.state.?)) + trampoline.state.gpr_rsp)).*;
}

test "call by name returns EAX and restores ESP" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // T0: mov eax, 42; ret
    const bin = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    var path_buf: [256]u8 = undefined;
    var g = try callGuest(&tmp, io, &bin,
        \\# call fixture
        \\base 0x400000
        \\entry 0x400000
        \\code 0x400000 0x400040
        \\mem_end 0x403100
        \\sym T0 0x400000 0x6 func
        \\
    , &path_buf);
    defer deinit(&g);

    try t.expectEqual(@as(u32, 42), try call(&g, "T0", &.{}));
    try t.expectEqual(@as(u32, 0xFDFFFFF0), stateEsp(&g));
}

test "call marshals cdecl args" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // ADD2: mov eax, [esp+4]; add eax, [esp+8]; ret
    const bin = [_]u8{ 0x8B, 0x44, 0x24, 0x04, 0x03, 0x44, 0x24, 0x08, 0xC3 };
    var path_buf: [256]u8 = undefined;
    var g = try callGuest(&tmp, io, &bin,
        \\# call fixture
        \\base 0x400000
        \\entry 0x400000
        \\code 0x400000 0x400040
        \\mem_end 0x403100
        \\sym ADD2 0x400000 0x9 func
        \\
    , &path_buf);
    defer deinit(&g);

    try t.expectEqual(@as(u32, 42), try call(&g, "ADD2", &.{ 10, 32 }));
    try t.expectEqual(@as(u32, 0xFDFFFFF0), stateEsp(&g));
}

test "indirect jump dispatches and lifts its target on demand" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // DISPATCH @0x400000: mov eax, 0x400010; jmp eax
    // TARGET   @0x400010 (no sym): mov eax, 40; add eax, 2; ret.
    // The ADD forces flag-helper references through the miss module,
    // exercising the cross-module link to the base semantics.
    var bin: [0x19]u8 = @splat(0x90);
    bin[0..5].* = .{ 0xB8, 0x10, 0x00, 0x40, 0x00 };
    bin[5..7].* = .{ 0xFF, 0xE0 };
    bin[0x10..][0..9].* = .{ 0xB8, 0x28, 0x00, 0x00, 0x00, 0x83, 0xC0, 0x02, 0xC3 };
    var path_buf: [256]u8 = undefined;
    var g = try callGuest(&tmp, io, &bin,
        \\# call fixture
        \\base 0x400000
        \\entry 0x400000
        \\code 0x400000 0x400020
        \\mem_end 0x403100
        \\sym DISPATCH 0x400000 0x7 func
        \\
    , &path_buf);
    defer deinit(&g);

    try t.expectEqual(@as(u32, 42), try call(&g, "DISPATCH", &.{}));
    try t.expectEqual(@as(u32, 0xFDFFFFF0), stateEsp(&g));
}

test "memory-indirect jump (jump table) dispatches per index" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // SW @0x400000: mov eax, [esp+4]; jmp [0x402000+eax*4]
    // C0 @0x400020: mov eax, 10; ret
    // C1 @0x400030: mov eax, 20; ret
    // TABLE @0x402000: [0x400020, 0x400030]
    var bin: [0x2008]u8 = @splat(0);
    bin[0..4].* = .{ 0x8B, 0x44, 0x24, 0x04 };
    bin[4..11].* = .{ 0xFF, 0x24, 0x85, 0x00, 0x20, 0x40, 0x00 };
    bin[0x20..][0..6].* = .{ 0xB8, 0x0A, 0x00, 0x00, 0x00, 0xC3 };
    bin[0x30..][0..6].* = .{ 0xB8, 0x14, 0x00, 0x00, 0x00, 0xC3 };
    bin[0x2000..][0..8].* = .{ 0x20, 0x00, 0x40, 0x00, 0x30, 0x00, 0x40, 0x00 };
    var path_buf: [256]u8 = undefined;
    var g = try callGuest(&tmp, io, &bin,
        \\# call fixture
        \\base 0x400000
        \\entry 0x400000
        \\code 0x400000 0x400040
        \\mem_end 0x403100
        \\sym SW 0x400000 0xb func
        \\
    , &path_buf);
    defer deinit(&g);

    try t.expectEqual(@as(u32, 10), try call(&g, "SW", &.{0}));
    try t.expectEqual(@as(u32, 20), try call(&g, "SW", &.{1}));
    try t.expectEqual(@as(u32, 0xFDFFFFF0), stateEsp(&g));
}

test "entry without a sym lifts as sub_<hex> and calls by synthesized name" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // No sym lines at all: entry 0x400000 holds mov eax, 42; ret.
    const bin = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    var path_buf: [256]u8 = undefined;
    var g = try callGuest(&tmp, io, &bin,
        \\# call fixture
        \\base 0x400000
        \\entry 0x400000
        \\code 0x400000 0x400040
        \\mem_end 0x403100
        \\
    , &path_buf);
    defer deinit(&g);

    try t.expect(g.image.funcByAddr(0x400000) == null);
    try t.expectEqual(@as(u32, 42), try call(&g, "sub_400000", &.{}));
}

test "guest longjmp (iret) abandons host frames and resumes" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // F @0x400000: call G; mov eax, 0xBAD; ret (fall-through must NOT run).
    // PAD @0x400010: mov eax, 42; ret (the longjmp target).
    // G @0x400020: push eflags/cs/eip for PAD; iret.
    var bin: [0x31]u8 = @splat(0x90);
    bin[0..5].* = .{ 0xE8, 0x1B, 0x00, 0x00, 0x00 };
    bin[5..11].* = .{ 0xB8, 0xAD, 0x0B, 0x00, 0x00, 0xC3 };
    bin[0x10..][0..6].* = .{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    bin[0x20..][0..16].* = .{ 0x68, 0x02, 0x02, 0x00, 0x00, 0x68, 0x23, 0x00, 0x00, 0x00, 0x68, 0x10, 0x00, 0x40, 0x00, 0xCF };
    bin[0x30] = 0xC3;
    var path_buf: [256]u8 = undefined;
    var g = try callGuest(&tmp, io, &bin,
        \\# call fixture
        \\base 0x400000
        \\entry 0x400000
        \\code 0x400000 0x400040
        \\mem_end 0x403100
        \\sym F 0x400000 0xb func
        \\sym PAD 0x400010 0x6 func
        \\sym G 0x400020 0x11 func
        \\
    , &path_buf);
    defer deinit(&g);

    try t.expectEqual(@as(u32, 42), try call(&g, "F", &.{}));
    try t.expectEqual(@as(u32, 0xFDFFFFF0), stateEsp(&g));
}

test "call errors: missing jit, unknown symbol" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bin = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    try writeBinMap(tmp.dir, io, &bin,
        \\# call fixture
        \\base 0x400000
        \\entry 0x400000
        \\code 0x400000 0x400040
        \\mem_end 0x403100
        \\sym T0 0x400000 0x6 func
        \\
    );
    var path_buf: [256]u8 = undefined;
    const bin_path = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}/ffe.bin", .{tmp.sub_path[0..]}, 0);
    const map_path = try std.fmt.bufPrintSentinel(path_buf[128..], ".zig-cache/tmp/{s}/ffe.map", .{tmp.sub_path[0..]}, 0);
    var g = try init(bin_path, map_path, .{});
    defer deinit(&g);
    _ = try liftAll(&g);

    try t.expectError(error.JitMissing, call(&g, "T0", &.{}));
    g.jit = try jit_mod.Jit.create(g.image);
    try t.expectError(error.UnknownSymbol, call(&g, "NOPE", &.{}));
}

test "init rejects bad layout, bad entry, missing files" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, io, fixture_map);

    var path_buf: [256]u8 = undefined;
    const bin_path = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}/ffe.bin", .{tmp.sub_path[0..]}, 0);
    const map_path = try std.fmt.bufPrintSentinel(path_buf[128..], ".zig-cache/tmp/{s}/ffe.map", .{tmp.sub_path[0..]}, 0);

    // Heap below mem_end.
    try t.expectError(error.BadLayout, init(bin_path, map_path, .{ .heap_base = 0x1000 }));
    // Stack overlapping the sentinels.
    try t.expectError(error.BadLayout, init(bin_path, map_path, .{ .stack_top = 0xFF000010, .stack_size = 0x1000 }));
    // Missing files.
    try t.expectError(error.LoadFailed, init("/tmp/zffe_nope_missing.bin", "/tmp/zffe_nope_missing.map", .{}));

    // Entry outside the code range.
    var tmp2 = t.tmpDir(.{});
    defer tmp2.cleanup();
    try writeFixture(tmp2.dir, io, fixture_bad_entry);
    var path_buf2: [256]u8 = undefined;
    const bin2 = try std.fmt.bufPrintSentinel(&path_buf2, ".zig-cache/tmp/{s}/ffe.bin", .{tmp2.sub_path[0..]}, 0);
    const map2 = try std.fmt.bufPrintSentinel(path_buf2[128..], ".zig-cache/tmp/{s}/ffe.map", .{tmp2.sub_path[0..]}, 0);
    try t.expectError(error.BadEntry, init(bin2, map2, .{}));
}
