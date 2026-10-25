//! Guest bring-up: reserve, load, place, init. Stops short of execution
//! (that needs Remill plus the JIT runner).
//!
//! Layout (defaults; validated against the real map at init):
//!   [0, 64K)            guard (PROT_NONE, from reservation)
//!   [base, mem_end)     image bytes, copied from the shim's dense image
//!   [heap_base, +size)  guest heap (bump allocator via trampoline)
//!   [stack_top-size, stack_top)  guest stack, ESP starts 16-aligned at top-16
//!   [0xFF000000, +nimports)  import sentinels (call targets, never data)

const std = @import("std");
const bridge = @import("bridge.zig");
const reservation = @import("reservation.zig");
const trampoline = @import("trampoline.zig");

extern fn zffe_mem_set_base(base: u64) void;
extern fn zffe_state_new(esp: u32, eip: u32) ?*anyopaque;
extern fn zffe_state_free(state: ?*anyopaque) void;

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
    zffe_state_free(g.state);
    g.image.free();
    reservation.release(g.base);
    g.* = undefined;
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
