//! Guest address-space reservation: one 4 GiB mmap, low guard PROT_NONE.
//!
//! Every 32-bit guest address `a` maps to host `H + a`. Virtual only:
//! MAP_NORESERVE means the OS backs just touched pages, so the 4 GiB costs
//! address space, not RAM. Fresh pages read as zero.

const std = @import("std");
const builtin = @import("builtin");

pub const SIZE: usize = 0x1_0000_0000; // 4 GiB: every u32 is a valid offset
pub const GUARD_SIZE: usize = 64 << 10; // low 64 KiB PROT_NONE (null/wild trap)

const PROT_NONE: c_int = 0;
const PROT_READ: c_int = 1;
const PROT_WRITE: c_int = 2;

// mmap(2) flags differ per OS.
const MAP = switch (builtin.os.tag) {
    .linux => struct {
        pub const PRIVATE: c_int = 0x02;
        pub const ANONYMOUS: c_int = 0x20;
        pub const NORESERVE: c_int = 0x4000;
    },
    .macos, .ios => struct {
        pub const PRIVATE: c_int = 0x02;
        pub const ANONYMOUS: c_int = 0x1000;
        pub const NORESERVE: c_int = 0x40;
    },
    else => @compileError("reservation mmap flags not defined for this OS"),
};

const c = struct {
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: c_long) ?*anyopaque;
    extern "c" fn mprotect(addr: *anyopaque, len: usize, prot: c_int) c_int;
    extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
};

const MAP_FAILED: usize = 0xFFFF_FFFF_FFFF_FFFF;

pub const Error = error{ ReserveFailed, GuardFailed };

/// Reserve 4 GiB (page-zeroed by the OS) and guard the low 64 KiB.
/// Returns H, the host base. Free with `release()`.
pub fn reserve() Error!usize {
    const p = c.mmap(null, SIZE, PROT_READ | PROT_WRITE, MAP.PRIVATE | MAP.ANONYMOUS | MAP.NORESERVE, -1, 0) orelse
        return Error.ReserveFailed;
    const base = @intFromPtr(p);
    if (base == MAP_FAILED) return Error.ReserveFailed;
    const g: *anyopaque = @ptrFromInt(base);
    if (c.mprotect(g, GUARD_SIZE, PROT_NONE) != 0) {
        _ = c.munmap(g, SIZE);
        return Error.GuardFailed;
    }
    return base;
}

pub fn release(base: usize) void {
    _ = c.munmap(@ptrFromInt(base), SIZE);
}

/// Host slice over guest `[addr, addr + len)`. The caller guarantees the
/// range is mapped (anything at/above GUARD_SIZE is).
pub fn slice(base: usize, addr: u64, len: usize) []u8 {
    const p: [*]u8 = @ptrFromInt(base + addr);
    return p[0..len];
}

const t = std.testing;

test "reserve maps 4GB zeroed with working high addresses" {
    const base = try reserve();
    defer release(base);
    try t.expectEqual(@as(u8, 0), slice(base, 0x10000, 1)[0]);
    const spots = [_]u64{ 0x10000, 0x400000, 0x700000, 0xFD800000, 0xFF000000, 0xFFFFFF00 };
    for (spots, 0..) |a, i| {
        slice(base, a, 1)[0] = @intCast(0xA0 + i);
    }
    for (spots, 0..) |a, i| {
        try t.expectEqual(@as(u8, @intCast(0xA0 + i)), slice(base, a, 1)[0]);
    }
}

// NOTE: the guard itself is untestable in-process (touching it faults by
// design). It is verified by inspection: mprotect(PROT_NONE) over [H, H+64K).
