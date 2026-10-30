//! ffe-info: load ffe.bin+ffe.map through the shim and print a summary.
//! Usage: ffe-info <ffe.bin> <ffe.map> [--lift] [--jit]
//! --jit implies --lift, then JIT-links the image and looks up the entry
//! trace (validating that every referenced external resolves).

const std = @import("std");
const bridge = @import("lifting").bridge;
const jit_mod = @import("lifting").jit;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    if (!it.skip()) return error.BadArgs;
    const bin_path = it.next() orelse return error.BadArgs;
    const map_path = it.next() orelse return error.BadArgs;
    var do_lift = false;
    var do_jit = false;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--lift")) do_lift = true;
        if (std.mem.eql(u8, a, "--jit")) {
            do_jit = true;
            do_lift = true;
        }
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
    std.debug.print("  code: 0x{x}..0x{x}  mem: 0x{x}..0x{x}\n", .{ img.code_start, img.code_end, img.base, img.mem_end });

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
    std.debug.print("imports: {}\n", .{img.nimports});
    for (img.importSlice()[0..@min(img.nimports, 3)]) |*im| {
        std.debug.print("  {s} 0x{x}\n", .{ std.mem.span(im.name), im.addr });
    }

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

    if (do_jit) {
        // Entry may lack a sym (liftAll in the engine covers it, but this
        // tool lifts map funcs only); lift first, since create() consumes
        // the lift session.
        if (img.funcByAddr(img.entry) == null and
            bridge.zffe_lift(img, img.entry) == null)
        {
            std.debug.print("entry lift failed: {s}\n", .{img.errMsg() orelse "?"});
            return error.LiftFailed;
        }
        const j = jit_mod.Jit.create(img) catch {
            std.debug.print("jit create failed: {s}\n", .{img.errMsg() orelse "?"});
            return error.JitFailed;
        };
        defer j.destroy();
        var name_buf: [32]u8 = undefined;
        const entry_name: [:0]const u8 = if (img.funcByAddr(img.entry)) |f|
            std.mem.span(f.name)
        else
            try std.fmt.bufPrintSentinel(&name_buf, "sub_{x}", .{img.entry}, 0);
        const addr = try j.lookup(img, entry_name);
        std.debug.print("jit: entry {s} at 0x{x}\n", .{ entry_name, @intFromPtr(addr) });
    }
}
