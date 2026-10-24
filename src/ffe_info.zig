//! ffe-info: load ffe.bin+ffe.map through the shim and print a summary.
//! Usage: ffe-info <ffe.bin> <ffe.map> [--lift]

const std = @import("std");
const bridge = @import("bridge.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    if (!it.skip()) return error.BadArgs;
    const bin_path = it.next() orelse return error.BadArgs;
    const map_path = it.next() orelse return error.BadArgs;
    var do_lift = false;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--lift")) do_lift = true;
    }

    const img = bridge.zffe_load(bin_path, map_path, null, null) orelse {
        std.debug.print("out of memory\n", .{});
        return error.OutOfMemory;
    };
    defer img.free();
    if (img.errMsg()) |msg| {
        std.debug.print("load failed: {s}\n", .{msg});
        return error.LoadFailed;
    }

    std.debug.print("shim: {s}\n", .{std.mem.span(bridge.zffe_version())});
    std.debug.print("base: 0x{x}  entry: 0x{x}  image: {} bytes\n", .{ img.base, img.entry, img.image_size });
    for (img.sectionSlice()) |*s| {
        std.debug.print("  section {s}: vaddr 0x{x} off 0x{x} filesz 0x{x} memsz 0x{x} flags {c}{c}{c}\n", .{
            s.nameSlice(), s.vaddr, s.file_off, s.file_sz, s.mem_sz,
            if (s.flags & bridge.Sec.r != 0) @as(u8, 'r') else @as(u8, '-'),
            if (s.flags & bridge.Sec.w != 0) @as(u8, 'w') else @as(u8, '-'),
            if (s.flags & bridge.Sec.x != 0) @as(u8, 'x') else @as(u8, '-'),
        });
    }

    var nfunc: usize = 0;
    var ndata: usize = 0;
    var nunknown: usize = 0;
    for (img.funcSlice()) |*f| {
        switch (f.symKind()) {
            .func => nfunc += 1,
            .data => ndata += 1,
            .unknown => nunknown += 1,
        }
    }
    std.debug.print("syms: {} ({} func, {} data, {} unknown)\n", .{ img.nfuncs, nfunc, ndata, nunknown });

    const show = @min(img.nfuncs, 8);
    for (img.funcSlice()[0..show]) |*f| {
        std.debug.print("  {s} 0x{x} sz 0x{x} {s} llvm_func={} decode={} lifted={}\n", .{
            std.mem.span(f.name), f.addr, f.size, @tagName(f.symKind()),
            f.llvm_func != null, f.decode_ok, f.lifted,
        });
    }

    if (do_lift) {
        var ok: usize = 0;
        var fail: usize = 0;
        for (img.funcSlice()) |*f| {
            if (f.symKind() != .func) continue;
            if (bridge.zffe_lift(img, f.addr) != null) {
                ok += 1;
            } else {
                fail += 1;
                std.debug.print("  lift failed for {s} (0x{x}): {s}\n", .{
                    std.mem.span(f.name), f.addr, img.errMsg() orelse "?",
                });
            }
        }
        std.debug.print("lift: {} ok, {} failed\n", .{ ok, fail });
        if (fail > 0) return error.LiftFailed;
    }
}
