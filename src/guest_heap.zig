//! Guest heap: bump allocator with tripwire accounting over a guest range.
//!
//! Backed by a host slice (a window into the reservation); hands out guest
//! addresses. Each block carries an 8-byte size header so free() knows the
//! size and a future free-list upgrade can reuse the layout. free() never
//! reclaims: watch allocs/frees/high_water — matched churn with a growing
//! high-water mark means the game needs a real free-list.

const std = @import("std");

pub const FreeResult = enum {
    ok,
    null_free, // free(0): legal no-op
    out_of_range, // outside the carved region (or corrupted header)
};

pub const Heap = struct {
    mem: []u8, // host view of [start, start + mem.len)
    start: u64, // guest address of mem[0]
    bump_off: usize, // next free offset
    bytes_allocated: u64,
    bytes_freed: u64,
    allocs: u64,
    frees: u64,

    const header_size = 8;

    pub fn init(mem: []u8, guest_start: u64) Heap {
        std.debug.assert(mem.len > header_size);
        return .{
            .mem = mem,
            .start = guest_start,
            .bump_off = 0,
            .bytes_allocated = 0,
            .bytes_freed = 0,
            .allocs = 0,
            .frees = 0,
        };
    }

    pub fn highWater(h: *const Heap) usize {
        return h.bump_off;
    }

    /// Live estimate for the tripwire. Saturates: bump cannot detect
    /// double-free, so treat small negatives as zero.
    pub fn liveBytes(h: *const Heap) u64 {
        return h.bytes_allocated -| h.bytes_freed;
    }

    /// Returns the guest address, or 0 on OOM (0-size counts as OOM).
    pub fn malloc(h: *Heap, n: usize) u64 {
        if (n == 0) return 0;
        const nn: u64 = n;
        const aligned = (nn +| 7) & ~@as(u64, 7);
        const total = aligned +| header_size;
        const new_bump_u64: u64 = @as(u64, h.bump_off) +| total;
        if (new_bump_u64 > @as(u64, h.mem.len)) return 0;
        const new_bump: usize = @intCast(new_bump_u64);
        std.mem.writeInt(u64, h.mem[h.bump_off..][0..8], aligned, .little);
        const addr = h.start + @as(u64, h.bump_off) + header_size;
        h.bump_off = new_bump;
        h.bytes_allocated += aligned;
        h.allocs += 1;
        return addr;
    }

    pub fn free(h: *Heap, addr: u64) FreeResult {
        if (addr == 0) return .null_free;
        if (addr < header_size) return .out_of_range;
        const client_off = addr - header_size;
        if (client_off < h.start) return .out_of_range;
        const hdr_off = client_off - h.start;
        if (hdr_off > h.bump_off) return .out_of_range;
        const hdr: usize = @intCast(hdr_off);
        if (hdr + header_size > h.bump_off) return .out_of_range;
        const size = std.mem.readInt(u64, h.mem[hdr..][0..8], .little);
        if (size > @as(u64, h.bump_off - hdr - header_size)) return .out_of_range;
        h.bytes_freed += size;
        h.frees += 1;
        return .ok;
    }
};

test "bump allocation ascends and aligns" {
    const t = std.testing;
    var backing: [256]u8 = @splat(0);
    var heap = Heap.init(&backing, 0x700000);

    const a = heap.malloc(1);
    const b = heap.malloc(16);
    const c = heap.malloc(7);
    try t.expect(a != 0 and b != 0 and c != 0);
    try t.expectEqual(@as(u64, 0x700008), a);
    try t.expect(a % 8 == 0 and b % 8 == 0 and c % 8 == 0);
    try t.expect(b > a and c > b);
    // Headers hold aligned sizes.
    try t.expectEqual(@as(u64, 8), std.mem.readInt(u64, backing[0..][0..8], .little));
    try t.expectEqual(@as(u64, 16), std.mem.readInt(u64, backing[16..][0..8], .little));
    try t.expectEqual(@as(usize, 8 + 8 + 8 + 16 + 8 + 8), heap.highWater());
    try t.expectEqual(@as(u64, 8 + 16 + 8), heap.bytes_allocated);
    try t.expectEqual(@as(u64, 3), heap.allocs);
}

test "oom and zero-size fail null" {
    const t = std.testing;
    var backing: [32]u8 = @splat(0);
    var heap = Heap.init(&backing, 0x700000);
    try t.expectEqual(@as(u64, 0), heap.malloc(0));
    try t.expect(heap.malloc(8) != 0);
    try t.expectEqual(@as(u64, 0), heap.malloc(64));
    try t.expectEqual(@as(u64, 0), heap.malloc(std.math.maxInt(usize)));
}

test "free accounting and validation" {
    const t = std.testing;
    var backing: [128]u8 = @splat(0);
    var heap = Heap.init(&backing, 0x700000);
    const a = heap.malloc(16);
    const b = heap.malloc(16);
    _ = b;
    try t.expectEqual(FreeResult.ok, heap.free(a));
    try t.expectEqual(@as(u64, 16), heap.bytes_freed);
    try t.expectEqual(@as(u64, 1), heap.frees);
    try t.expectEqual(@as(u64, 16), heap.liveBytes());
    try t.expectEqual(FreeResult.null_free, heap.free(0));
    try t.expectEqual(FreeResult.out_of_range, heap.free(0x100));
    try t.expectEqual(FreeResult.out_of_range, heap.free(0x800000));
}
