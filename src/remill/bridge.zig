//! Zig side of the Remill shim (src/shim.h, src/shim.cpp).
//!
//! The extern structs below mirror the C structs field-for-field; the
//! `c layout matches` test cross-checks offsets via @cImport, so keep both
//! files in sync.

const std = @import("std");

pub const SymKind = enum(c_int) {
    unknown = 0,
    func = 1,
    data = 2,
};

pub const Func = extern struct {
    name: [*:0]const u8,
    addr: u64,
    size: u64,
    llvm_func: ?*anyopaque,
    kind: c_int,
    decode_ok: c_int,
    lifted: c_int,

    pub fn symKind(f: *const Func) SymKind {
        return if (f.kind >= 0 and f.kind <= 2) @enumFromInt(f.kind) else .unknown;
    }
};

pub const Import = extern struct {
    name: [*:0]const u8,
    addr: u64,
};

pub const Image = extern struct {
    llvm_ctx: ?*anyopaque,
    llvm_mod: ?*anyopaque,
    funcs: [*]Func,
    nfuncs: usize,
    imports: [*]Import,
    nimports: usize,
    image: [*]u8,
    image_size: usize,
    base: u64,
    entry: u64,
    code_start: u64,
    code_end: u64,
    mem_end: u64,
    priv: ?*anyopaque,
    @"error": ?[*:0]u8,

    pub fn funcSlice(img: *const Image) []Func {
        return img.funcs[0..img.nfuncs];
    }

    pub fn importSlice(img: *const Image) []Import {
        return img.imports[0..img.nimports];
    }

    pub fn byteSlice(img: *const Image) []u8 {
        return img.image[0..img.image_size];
    }

    pub fn errMsg(img: *const Image) ?[]const u8 {
        const e = img.@"error" orelse return null;
        return std.mem.span(e);
    }

    pub fn isStub(img: *const Image) bool {
        return img.llvm_mod == null;
    }

    pub fn funcByAddr(img: *Image, addr: u64) ?*Func {
        for (img.funcSlice()) |*f| {
            if (f.addr == addr) return f;
        }
        return null;
    }

    pub fn free(img: *Image) void {
        zffe_free(img);
    }
};

pub extern fn zffe_load(
    bin_path: [*:0]const u8,
    map_path: [*:0]const u8,
    os: ?[*:0]const u8,
    arch: ?[*:0]const u8,
) ?*Image;

pub extern fn zffe_lift(img: *Image, addr: u64) ?*anyopaque;
pub extern fn zffe_version() [*:0]const u8;
pub extern fn zffe_free(img: ?*Image) void;

pub const LoadError = error{ LoadFailed, OutOfMemory };

/// Load and return the image, or an error (message already in img on
/// LoadFailed paths is freed along with it; use zffe_load directly if you
/// need to read it).
pub fn load(
    bin_path: [:0]const u8,
    map_path: [:0]const u8,
    os: ?[:0]const u8,
    arch: ?[:0]const u8,
) LoadError!*Image {
    const img = zffe_load(
        bin_path.ptr,
        map_path.ptr,
        if (os) |o| o.ptr else null,
        if (arch) |a| a.ptr else null,
    ) orelse return error.OutOfMemory;
    errdefer zffe_free(img);
    if (img.errMsg() != null) return error.LoadFailed;
    return img;
}

// --- Tests ---

// The C ABI contract (LP64): these exact offsets are static_asserted on the
// C++ side too (see the ABI block at the end of shim.cpp). If you change
// shim.h, update both.
test "c layout matches" {
    const t = std.testing;
    try t.expectEqual(0, @offsetOf(Func, "name"));
    try t.expectEqual(8, @offsetOf(Func, "addr"));
    try t.expectEqual(16, @offsetOf(Func, "size"));
    try t.expectEqual(24, @offsetOf(Func, "llvm_func"));
    try t.expectEqual(32, @offsetOf(Func, "kind"));
    try t.expectEqual(36, @offsetOf(Func, "decode_ok"));
    try t.expectEqual(40, @offsetOf(Func, "lifted"));
    try t.expectEqual(48, @sizeOf(Func));
    try t.expectEqual(8, @offsetOf(Import, "addr"));
    try t.expectEqual(16, @sizeOf(Import));
    try t.expectEqual(0, @offsetOf(Image, "llvm_ctx"));
    try t.expectEqual(8, @offsetOf(Image, "llvm_mod"));
    try t.expectEqual(16, @offsetOf(Image, "funcs"));
    try t.expectEqual(24, @offsetOf(Image, "nfuncs"));
    try t.expectEqual(32, @offsetOf(Image, "imports"));
    try t.expectEqual(40, @offsetOf(Image, "nimports"));
    try t.expectEqual(48, @offsetOf(Image, "image"));
    try t.expectEqual(56, @offsetOf(Image, "image_size"));
    try t.expectEqual(64, @offsetOf(Image, "base"));
    try t.expectEqual(72, @offsetOf(Image, "entry"));
    try t.expectEqual(80, @offsetOf(Image, "code_start"));
    try t.expectEqual(88, @offsetOf(Image, "code_end"));
    try t.expectEqual(96, @offsetOf(Image, "mem_end"));
    try t.expectEqual(104, @offsetOf(Image, "priv"));
    try t.expectEqual(112, @offsetOf(Image, "error"));
    try t.expectEqual(120, @sizeOf(Image));
    try t.expectEqual(1, @intFromEnum(SymKind.func));
    try t.expectEqual(2, @intFromEnum(SymKind.data));
}

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

test "load/free round trip through the C shim" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    var bin: [0x18]u8 = @splat(0x90);
    bin[0xf] = 0xc3; // ret at end of .text
    try tmp.dir.writeFile(io, .{ .sub_path = "ffe.bin", .data = &bin });
    try tmp.dir.writeFile(io, .{ .sub_path = "ffe.map", .data = fixture_map });

    var path_buf: [256]u8 = undefined;
    const bin_path = try std.fmt.bufPrintSentinel(
        &path_buf,
        ".zig-cache/tmp/{s}/ffe.bin",
        .{tmp.sub_path[0..]},
        0,
    );
    const map_path = try std.fmt.bufPrintSentinel(
        path_buf[128..],
        ".zig-cache/tmp/{s}/ffe.map",
        .{tmp.sub_path[0..]},
        0,
    );

    const img = try load(bin_path, map_path, null, null);
    defer img.free();

    try t.expectEqualStrings("stub", std.mem.span(zffe_version()));
    try t.expect(img.isStub());
    try t.expectEqual(@as(u64, 0x400000), img.base);
    try t.expectEqual(@as(u64, 0x401000), img.entry);
    try t.expectEqual(@as(u64, 0x401000), img.code_start);
    try t.expectEqual(@as(u64, 0x401010), img.code_end);
    try t.expectEqual(@as(u64, 0x403100), img.mem_end);
    try t.expectEqual(@as(usize, 2), img.nfuncs);
    try t.expectEqual(@as(usize, 0x3100), img.image_size);
    try t.expectEqual(@as(usize, 1), img.nimports);
    const imps = img.importSlice();
    try t.expectEqualStrings("_C_DrawSprite", std.mem.span(imps[0].name));
    try t.expectEqual(@as(u64, 0xff000000), imps[0].addr);

    // Dense zero-filled image: file bytes at the start, zeros past EOF.
    const bytes = img.byteSlice();
    try t.expectEqual(@as(u8, 0x90), bytes[0]);
    try t.expectEqual(@as(u8, 0xc3), bytes[0xf]);
    try t.expectEqual(@as(u8, 0), bytes[0x100]);

    const funcs = img.funcSlice();
    try t.expectEqualStrings("FUNC_000020", std.mem.span(funcs[0].name));
    try t.expectEqual(@as(u64, 0x401000), funcs[0].addr);
    try t.expectEqual(SymKind.func, funcs[0].symKind());
    try t.expect(funcs[0].llvm_func != null); // stub sentinel
    try t.expectEqual(@as(c_int, -1), funcs[0].decode_ok);
    try t.expectEqual(SymKind.data, funcs[1].symKind());

    // Stub lift marks the record and returns the sentinel.
    const fn_ptr = zffe_lift(img, 0x401000);
    try t.expect(fn_ptr != null);
    try t.expectEqual(@as(c_int, 1), funcs[0].lifted);

    // Unknown address fails with a message.
    try t.expect(zffe_lift(img, 0xdead) == null);
    try t.expect(img.errMsg() != null);
}

test "load of missing files reports an error" {
    const img = zffe_load("/nonexistent/ffe.bin", "/nonexistent/ffe.map", null, null);
    try std.testing.expect(img != null);
    defer zffe_free(img);
    try std.testing.expect(img.?.errMsg() != null);
}
