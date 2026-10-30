//! sentinel: disambiguate imports collapsed to address 0 by the link.
//!
//! `ld.lld --unresolved-symbols=ignore-all` resolves every undefined symbol
//! to 0, so calls to _abs and _C_DrawSprite are indistinguishable in the
//! image. This tool assigns each import a unique sentinel address,
//! patches relocation sites in a copy of the flat .bin, and rewrites the
//! map's `import` lines with addresses:
//!
//!   import _C_DrawSprite 0xff000000
//!
//! Patch rule (both R_386_32 and R_386_PC32, given the linker resolved the
//! symbol to 0): new_field = old_field + sentinel (mod 2^32).
//!
//! Usage: sentinel <input.elf> <input.bin> <input.map> <output.bin> <output.map>

const std = @import("std");
const elf32 = @import("elf32.zig");

pub const sentinel_base: u64 = 0xFF000000;

pub const Output = struct {
    bin: []u8,
    map: []u8,
    nimports: usize,
    patched: usize,

    pub fn deinit(o: *Output, alloc: std.mem.Allocator) void {
        alloc.free(o.bin);
        alloc.free(o.map);
    }
};

pub fn process(
    alloc: std.mem.Allocator,
    elf: []const u8,
    bin_in: []const u8,
    map_in: []const u8,
) !Output {
    if (elf.len < @sizeOf(elf32.Ehdr)) return error.TruncatedElf;
    const ehdr = std.mem.bytesToValue(elf32.Ehdr, elf[0..@sizeOf(elf32.Ehdr)]);
    if (!std.mem.eql(u8, ehdr.ident[0..4], "\x7fELF")) return error.NotAnElf;
    if (ehdr.ident[4] != 1) return error.Not32Bit;
    if (ehdr.ident[5] != 1) return error.NotLittleEndian;
    if (ehdr.machine != elf32.EM_386) return error.NotI386;
    if (ehdr.shentsize != @sizeOf(elf32.Shdr)) return error.BadShentsize;

    const shoff: usize = ehdr.shoff;
    const shnum: usize = ehdr.shnum;
    if (shoff + shnum * @sizeOf(elf32.Shdr) > elf.len) return error.TruncatedElf;
    const shdrs = try alloc.alloc(elf32.Shdr, shnum);
    defer alloc.free(shdrs);
    for (shdrs, 0..) |*s, i| {
        const off = shoff + i * @sizeOf(elf32.Shdr);
        s.* = std.mem.bytesToValue(elf32.Shdr, elf[off..][0..@sizeOf(elf32.Shdr)]);
    }

    var sym_sec: ?elf32.Shdr = null;
    for (shdrs) |s| {
        if (s.sh_type == elf32.SHT_SYMTAB) {
            sym_sec = s;
            break;
        }
    }
    const symtab = sym_sec orelse return error.NoSymtab;
    if (symtab.link >= shnum) return error.BadStrtab;
    const str_sec = shdrs[symtab.link];
    if (str_sec.offset + str_sec.size > elf.len) return error.TruncatedElf;
    const strtab = elf[str_sec.offset..][0..str_sec.size];
    if (symtab.offset + symtab.size > elf.len) return error.TruncatedElf;
    const sym_bytes = elf[symtab.offset..][0..symtab.size];
    if (sym_bytes.len % @sizeOf(elf32.Sym) != 0) return error.BadSymtab;
    const nsyms = sym_bytes.len / @sizeOf(elf32.Sym);

    // Imports: named undefined symbols, first-seen order.
    var import_names: std.ArrayList([]const u8) = .empty;
    defer import_names.deinit(alloc);
    var import_idx = std.StringHashMap(u32).init(alloc);
    defer import_idx.deinit();
    for (0..nsyms) |i| {
        const sym = std.mem.bytesToValue(elf32.Sym, sym_bytes[i * @sizeOf(elf32.Sym) ..][0..@sizeOf(elf32.Sym)]);
        if (sym.shndx != elf32.SHN_UNDEF) continue;
        const name = elf32.sectionName(strtab, sym.name);
        if (name.len == 0) continue;
        if (import_idx.contains(name)) continue;
        const idx: u32 = @intCast(import_names.items.len);
        try import_idx.put(name, idx);
        try import_names.append(alloc, name);
    }

    // Base maps VMA to flat-bin offset (objcopy -O binary layout).
    var base: u64 = std.math.maxInt(u64);
    for (shdrs) |s| {
        if (s.flags & elf32.SHF_ALLOC == 0) continue;
        if (s.size == 0) continue;
        base = @min(base, s.addr);
    }
    if (base == std.math.maxInt(u64)) return error.NoAllocSections;

    const bin = try alloc.dupe(u8, bin_in);
    errdefer alloc.free(bin);
    var patched: usize = 0;

    for (shdrs) |s| {
        if (s.sh_type == elf32.SHT_RELA) return error.RelaUnsupported;
        if (s.sh_type != elf32.SHT_REL) continue;
        if (s.offset + s.size > elf.len) return error.TruncatedElf;
        if (s.size % @sizeOf(elf32.Rel) != 0) return error.BadRel;
        const rel_bytes = elf[s.offset..][0..s.size];
        const nrel = rel_bytes.len / @sizeOf(elf32.Rel);
        for (0..nrel) |i| {
            const rel = std.mem.bytesToValue(elf32.Rel, rel_bytes[i * @sizeOf(elf32.Rel) ..][0..@sizeOf(elf32.Rel)]);
            const typ = elf32.relType(rel.info);
            if (typ == 0) continue; // R_386_NONE filler
            const sym_i = elf32.relSym(rel.info);
            if (sym_i >= nsyms) return error.BadRelSym;
            const sym = std.mem.bytesToValue(elf32.Sym, sym_bytes[sym_i * @sizeOf(elf32.Sym) ..][0..@sizeOf(elf32.Sym)]);
            if (sym.shndx != elf32.SHN_UNDEF) continue; // linker-resolved; leave
            const name = elf32.sectionName(strtab, sym.name);
            if (name.len == 0) return error.AnonImportReloc;
            const idx = import_idx.get(name) orelse return error.UnknownImport;
            if (typ != elf32.R_386_32 and typ != elf32.R_386_PC32)
                return error.UnsupportedRelocType;
            // Site must live in a backed (non-NOBITS) section.
            var backed = false;
            for (shdrs) |sec| {
                if (sec.flags & elf32.SHF_ALLOC == 0) continue;
                if (sec.sh_type == elf32.SHT_NOBITS) continue;
                if (rel.offset >= sec.addr and @as(u64, rel.offset) + 4 <= @as(u64, sec.addr) + sec.size) {
                    backed = true;
                    break;
                }
            }
            if (!backed) return error.SiteOutOfRange;
            const site_off = @as(u64, rel.offset) - base;
            if (site_off + 4 > bin.len) return error.SiteOutOfRange;
            const off: usize = @intCast(site_off);
            const old = std.mem.readInt(u32, bin[off..][0..4], .little);
            const sentinel: u32 = @truncate(sentinel_base + idx);
            std.mem.writeInt(u32, bin[off..][0..4], old +% sentinel, .little);
            patched += 1;
        }
    }

    // Rewrite the map, adding addresses to import lines.
    var map_out: std.ArrayList(u8) = .empty;
    errdefer map_out.deinit(alloc);
    const ends_nl = map_in.len > 0 and map_in[map_in.len - 1] == '\n';
    var lines = std.mem.splitScalar(u8, map_in, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0 and lines.index == null) break; // trailing "" past final \n
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "import ")) {
            var toks = std.mem.splitScalar(u8, line["import ".len..], ' ');
            const name = toks.next() orelse return error.BadImportLine;
            if (toks.next() != null) return error.MapAlreadyPatched;
            const idx = import_idx.get(name) orelse return error.UnknownImport;
            const out_line = try std.fmt.allocPrint(alloc, "import {s} 0x{x}\n", .{ name, sentinel_base + idx });
            defer alloc.free(out_line);
            try map_out.appendSlice(alloc, out_line);
        } else {
            try map_out.appendSlice(alloc, raw);
            try map_out.append(alloc, '\n');
        }
    }
    // If input lacked a trailing newline, drop the one we added.
    if (!ends_nl and map_out.items.len > 0) {
        _ = map_out.pop();
    }

    return .{
        .bin = bin,
        .map = try map_out.toOwnedSlice(alloc),
        .nimports = import_names.items.len,
        .patched = patched,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    if (!it.skip()) return error.BadArgs;
    const elf_path = it.next() orelse return error.BadArgs;
    const bin_path = it.next() orelse return error.BadArgs;
    const map_path = it.next() orelse return error.BadArgs;
    const out_bin_path = it.next() orelse return error.BadArgs;
    const out_map_path = it.next() orelse return error.BadArgs;

    const elf = try std.Io.Dir.cwd().readFileAlloc(io, elf_path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(elf);
    const bin = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bin);
    const map = try std.Io.Dir.cwd().readFileAlloc(io, map_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(map);

    var out = try process(allocator, elf, bin, map);
    defer out.deinit(allocator);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_bin_path, .data = out.bin });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_map_path, .data = out.map });
    // Stats go to stdout: build runners flag stderr output as failure.
    var stdout_buf: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("sentinel: {d} imports, {d} sites patched\n", .{ out.nimports, out.patched });
    try stdout.flush();
}

// --- Tests ---

const TestFixture = struct {
    elf: []u8,
    bin: []u8,
    map: []const u8,
    alloc: std.mem.Allocator,

    fn deinit(t: *TestFixture) void {
        t.alloc.free(t.elf);
        t.alloc.free(t.bin);
    }
};

const fixture_map =
    \\# fixture
    \\base 0x400100
    \\entry 0x400100
    \\code 0x400100 0x400110
    \\mem_end 0x400110
    \\sym FUNC_000020 0x400100 0x10 func
    \\import _C_Foo
    \\
;

fn buildFixture(alloc: std.mem.Allocator) !TestFixture {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    const append = struct {
        fn f(b: *std.ArrayList(u8), a: std.mem.Allocator, data: []const u8) !u32 {
            const off: u32 = @intCast(b.items.len);
            try b.appendSlice(a, data);
            return off;
        }
    }.f;

    const ehdr_off = try append(&bytes, alloc, std.mem.asBytes(&std.mem.zeroes(elf32.Ehdr)));
    _ = ehdr_off;
    const text_off = try append(&bytes, alloc, &.{ 0xE8, 0, 0, 0, 0, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 });

    var strtab: std.ArrayList(u8) = .empty;
    defer strtab.deinit(alloc);
    try strtab.append(alloc, 0);
    const n_func: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "FUNC_000020\x00");
    const n_imp: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "_C_Foo\x00");
    const strtab_off = try append(&bytes, alloc, strtab.items);

    var shstr: std.ArrayList(u8) = .empty;
    defer shstr.deinit(alloc);
    try shstr.append(alloc, 0);
    const s_text: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".text\x00");
    const s_rel: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".rel.text\x00");
    const s_symtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".symtab\x00");
    const s_strtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".strtab\x00");
    const s_shstrtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".shstrtab\x00");
    const shstr_off = try append(&bytes, alloc, shstr.items);

    // Relocs: PC32 + ABS32 against the import, ABS32 against defined (left).
    while (bytes.items.len % 4 != 0) try bytes.append(alloc, 0);
    const rel_off = try append(&bytes, alloc, std.mem.asBytes(&elf32.Rel{ .offset = 0x400100, .info = (2 << 8) | 2 }));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Rel{ .offset = 0x400104, .info = (2 << 8) | 1 }));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Rel{ .offset = 0x400108, .info = (1 << 8) | 1 }));
    const rel_size: u32 = 3 * @sizeOf(elf32.Rel);

    // Symtab: null, defined func, undefined import.
    while (bytes.items.len % 4 != 0) try bytes.append(alloc, 0);
    const symtab_off = try append(&bytes, alloc, std.mem.asBytes(&std.mem.zeroes(elf32.Sym)));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Sym{ .name = n_func, .value = 0x400100, .size = 12, .info = 0x10, .other = 0, .shndx = 1 }));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Sym{ .name = n_imp, .value = 0, .size = 0, .info = 0x10, .other = 0, .shndx = elf32.SHN_UNDEF }));
    const symtab_size: u32 = 3 * @sizeOf(elf32.Sym);

    while (bytes.items.len % 4 != 0) try bytes.append(alloc, 0);
    const shoff: u32 = @intCast(bytes.items.len);
    _ = try append(&bytes, alloc, std.mem.asBytes(&std.mem.zeroes(elf32.Shdr)));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Shdr{ .name = s_text, .sh_type = 1, .flags = elf32.SHF_ALLOC | elf32.SHF_EXECINSTR, .addr = 0x400100, .offset = text_off, .size = 16, .link = 0, .info = 0, .addralign = 16, .entsize = 0 }));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Shdr{ .name = s_rel, .sh_type = elf32.SHT_REL, .flags = 0, .addr = 0, .offset = rel_off, .size = rel_size, .link = 3, .info = 1, .addralign = 4, .entsize = @sizeOf(elf32.Rel) }));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Shdr{ .name = s_symtab, .sh_type = elf32.SHT_SYMTAB, .flags = 0, .addr = 0, .offset = symtab_off, .size = symtab_size, .link = 4, .info = 2, .addralign = 4, .entsize = @sizeOf(elf32.Sym) }));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Shdr{ .name = s_strtab, .sh_type = elf32.SHT_STRTAB, .flags = 0, .addr = 0, .offset = strtab_off, .size = @intCast(strtab.items.len), .link = 0, .info = 0, .addralign = 1, .entsize = 0 }));
    _ = try append(&bytes, alloc, std.mem.asBytes(&elf32.Shdr{ .name = s_shstrtab, .sh_type = elf32.SHT_STRTAB, .flags = 0, .addr = 0, .offset = shstr_off, .size = @intCast(shstr.items.len), .link = 0, .info = 0, .addralign = 1, .entsize = 0 }));

    var ehdr = std.mem.zeroes(elf32.Ehdr);
    ehdr.ident[0] = 0x7f;
    ehdr.ident[1] = 'E';
    ehdr.ident[2] = 'L';
    ehdr.ident[3] = 'F';
    ehdr.ident[4] = 1;
    ehdr.ident[5] = 1;
    ehdr.ident[6] = 1;
    ehdr.machine = elf32.EM_386;
    ehdr.version = 1;
    ehdr.entry = 0x400100;
    ehdr.shoff = shoff;
    ehdr.ehsize = @sizeOf(elf32.Ehdr);
    ehdr.shentsize = @sizeOf(elf32.Shdr);
    ehdr.shnum = 6;
    ehdr.shstrndx = 5;
    @memcpy(bytes.items[0..@sizeOf(elf32.Ehdr)], std.mem.asBytes(&ehdr));

    const bin = try alloc.alloc(u8, 16);
    @memset(bin, 0);
    std.mem.writeInt(u32, bin[8..][0..4], 0x12345678, .little); // defined-sym site stays

    return .{
        .elf = try bytes.toOwnedSlice(alloc),
        .bin = bin,
        .map = fixture_map,
        .alloc = alloc,
    };
}

test "sentinel patches import sites and rewrites map" {
    const alloc = std.testing.allocator;
    var fx = try buildFixture(alloc);
    defer fx.deinit();

    var out = try process(alloc, fx.elf, fx.bin, fx.map);
    defer out.deinit(alloc);

    // Both import sites (PC32 at off 0, ABS32 at off 4) gain the sentinel.
    try std.testing.expectEqual(@as(u32, 0xFF000000), std.mem.readInt(u32, out.bin[0..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xFF000000), std.mem.readInt(u32, out.bin[4..][0..4], .little));
    // Defined-sym site untouched.
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, out.bin[8..][0..4], .little));

    const expected_map =
        \\# fixture
        \\base 0x400100
        \\entry 0x400100
        \\code 0x400100 0x400110
        \\mem_end 0x400110
        \\sym FUNC_000020 0x400100 0x10 func
        \\import _C_Foo 0xff000000
        \\
    ;
    try std.testing.expectEqualStrings(expected_map, out.map);
}

test "sentinel refuses an already-patched map" {
    const alloc = std.testing.allocator;
    var fx = try buildFixture(alloc);
    defer fx.deinit();

    var first = try process(alloc, fx.elf, fx.bin, fx.map);
    defer first.deinit(alloc);
    try std.testing.expectError(error.MapAlreadyPatched, process(alloc, fx.elf, first.bin, first.map));
}
