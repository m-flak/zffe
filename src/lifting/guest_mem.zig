//! Zig bindings and tests for the guest memory runtime (src/guest_mem.h/.cpp).
//! The runtime translates every guest access to host_base + addr.

const std = @import("std");

pub extern fn zffe_mem_set_base(base: u64) void;
pub extern fn zffe_mem_base() u64;

pub extern fn __remill_read_memory_8(mem: ?*anyopaque, addr: u32) u8;
pub extern fn __remill_read_memory_16(mem: ?*anyopaque, addr: u32) u16;
pub extern fn __remill_read_memory_32(mem: ?*anyopaque, addr: u32) u32;
pub extern fn __remill_read_memory_64(mem: ?*anyopaque, addr: u32) u64;
pub extern fn __remill_write_memory_8(mem: ?*anyopaque, addr: u32, val: u8) ?*anyopaque;
pub extern fn __remill_write_memory_16(mem: ?*anyopaque, addr: u32, val: u16) ?*anyopaque;
pub extern fn __remill_write_memory_32(mem: ?*anyopaque, addr: u32, val: u32) ?*anyopaque;
pub extern fn __remill_write_memory_64(mem: ?*anyopaque, addr: u32, val: u64) ?*anyopaque;

pub extern fn __remill_read_memory_f32(mem: ?*anyopaque, addr: u32) f32;
pub extern fn __remill_read_memory_f64(mem: ?*anyopaque, addr: u32) f64;
// Remill's own float128_t is double (see their TODO); mirror it exactly.
pub extern fn __remill_read_memory_f128(mem: ?*anyopaque, addr: u32) f64;
pub extern fn __remill_write_memory_f32(mem: ?*anyopaque, addr: u32, val: f32) ?*anyopaque;
pub extern fn __remill_write_memory_f64(mem: ?*anyopaque, addr: u32, val: f64) ?*anyopaque;
pub extern fn __remill_write_memory_f128(mem: ?*anyopaque, addr: u32, val: f64) ?*anyopaque;

pub const float80_t = extern struct {
    data: [10]u8,
};

pub extern fn __remill_read_memory_f80(mem: ?*anyopaque, addr: u32, out: *float80_t) ?*anyopaque;
pub extern fn __remill_write_memory_f80(mem: ?*anyopaque, addr: u32, val: *const float80_t) ?*anyopaque;

test "guest memory translation round trip" {
    const t = std.testing;
    const alloc = t.allocator;
    const size = 0x2000;
    const buf = try alloc.alloc(u8, size);
    defer alloc.free(buf);
    @memset(buf, 0xAA);

    // Map guest 0x400000 to buf[0]: a nonzero base proves translation
    // (identity mapping would fault or hit foreign bytes).
    const H: u64 = @intCast(@intFromPtr(buf.ptr) - 0x400000);
    zffe_mem_set_base(H);
    try t.expectEqual(H, zffe_mem_base());

    // Token threading: writes pass the token through untouched.
    var tok: u8 = 0;
    const tok_ptr: ?*anyopaque = @ptrCast(&tok);
    try t.expectEqual(tok_ptr, __remill_write_memory_8(tok_ptr, 0x400010, 0x42));
    try t.expect(__remill_write_memory_8(null, 0x400011, 0x43) == null);

    // Aligned and unaligned integer widths.
    _ = __remill_write_memory_32(null, 0x400100, 0xDEADBEEF);
    try t.expectEqual(@as(u32, 0xDEADBEEF), __remill_read_memory_32(null, 0x400100));
    try t.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, buf[0x100..][0..4], .little));
    _ = __remill_write_memory_16(null, 0x400103, 0x1234); // unaligned
    try t.expectEqual(@as(u16, 0x1234), __remill_read_memory_16(null, 0x400103));
    _ = __remill_write_memory_64(null, 0x400108, 0x1122334455667788);
    try t.expectEqual(@as(u64, 0x1122334455667788), __remill_read_memory_64(null, 0x400108));

    // Float bit patterns round-trip exactly.
    _ = __remill_write_memory_f32(null, 0x400110, @bitCast(@as(u32, 0x40490FDB)));
    try t.expectEqual(@as(u32, 0x40490FDB), @as(u32, @bitCast(__remill_read_memory_f32(null, 0x400110))));
    _ = __remill_write_memory_f64(null, 0x400118, @bitCast(@as(u64, 0x400921FB54442D18)));
    try t.expectEqual(@as(u64, 0x400921FB54442D18), @as(u64, @bitCast(__remill_read_memory_f64(null, 0x400118))));
    _ = __remill_write_memory_f128(null, 0x400130, @bitCast(@as(u64, 0xDEAD)));
    try t.expectEqual(@as(u64, 0xDEAD), @as(u64, @bitCast(__remill_read_memory_f128(null, 0x400130))));

    // 80-bit extended: 10 bytes preserved verbatim.
    var f80in = float80_t{ .data = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 } };
    _ = __remill_write_memory_f80(null, 0x400120, &f80in);
    var f80out = float80_t{ .data = @splat(0) };
    _ = __remill_read_memory_f80(null, 0x400120, &f80out);
    try t.expectEqualSlices(u8, &f80in.data, &f80out.data);

    // Neighbors untouched: no over/under-write.
    try t.expectEqual(@as(u8, 0xAA), buf[0]);
    try t.expectEqual(@as(u8, 0xAA), buf[0x1FFF]);
}
