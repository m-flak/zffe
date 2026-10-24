//! elf2map: read the linked 32-bit ELF and emit the simple ffe.map text
//! format consumed by the Remill shim.
//!
//! Usage: elf2map <input.elf> <output.map>
//!
//! Map format (line-oriented, easy to sscanf from C++):
//!   base 0x00400000
//!   entry 0x00400000
//!   section <name> vaddr 0x... off 0x... filesz 0x... memsz 0x... flags r-x
//!   sym <name> 0x<addr> 0x<size> func|data
//!   import <name>
//!
//! Only function entries and data land in the map: in .text, the globals
//! (JUMP_* and other locals are intra-function labels); a FUNC_*-named
//! local is still kept as a backstop. All .data/.bss syms are kept.
//! `off` is the section's offset in the flat .bin produced by
//! `llvm-objcopy -O binary` (VMA order, gaps zero-padded, .bss as zeros).

const std = @import("std");

const Ehdr = extern struct {
    ident: [16]u8,
    e_type: u16,
    machine: u16,
    version: u32,
    entry: u32,
    phoff: u32,
    shoff: u32,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const Shdr = extern struct {
    name: u32,
    sh_type: u32,
    flags: u32,
    addr: u32,
    offset: u32,
    size: u32,
    link: u32,
    info: u32,
    addralign: u32,
    entsize: u32,
};

const Sym = extern struct {
    name: u32,
    value: u32,
    size: u32,
    info: u8,
    other: u8,
    shndx: u16,
};

const SHT_SYMTAB: u32 = 2;
const SHT_STRTAB: u32 = 3;
const SHT_NOBITS: u32 = 8;
const SHF_WRITE: u32 = 0x1;
const SHF_ALLOC: u32 = 0x2;
const SHF_EXECINSTR: u32 = 0x4;
const SHN_UNDEF: u16 = 0;
const EM_386: u16 = 3;

fn sectionName(shstr: []const u8, off: u32) []const u8 {
    if (off >= shstr.len) return "";
    const rest = shstr[off..];
    const len = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    return rest[0..len];
}

const SymKind = enum { func, data };

const SymEntry = struct {
    name: []const u8,
    addr: u64,
    size: u64,
    kind: SymKind,
};

fn isFuncName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "FUNC_") or std.mem.startsWith(u8, name, "_FUNC");
}

fn isDataName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "DATA_") or std.mem.startsWith(u8, name, "_DATA_");
}

// Classify a defined symbol, or null if it doesn't belong in the map.
fn classify(st_bind: u4, st_type: u4, sec_name: []const u8, sym_name: []const u8) ?SymKind {
    if (st_type == 2) return .func; // STT_FUNC
    if (st_type == 1) return .data; // STT_OBJECT
    if (std.mem.startsWith(u8, sec_name, ".text")) {
        // Entries are the globals; JUMP_* and other locals are
        // intra-function labels. The FUNC_ backstop keeps entries the
        // disassembler named but never globalized.
        if (st_bind != 0 or isFuncName(sym_name)) return .func;
        return null;
    }
    if (std.mem.startsWith(u8, sec_name, ".data")) return .data;
    if (std.mem.startsWith(u8, sec_name, ".bss")) return .data;
    if (std.mem.startsWith(u8, sec_name, ".rodata")) return .data;
    if (isFuncName(sym_name)) return .func;
    if (isDataName(sym_name)) return .data;
    return null;
}

pub fn generate(allocator: std.mem.Allocator, elf: []const u8, input_name: []const u8, out: anytype) !void {
    if (elf.len < @sizeOf(Ehdr)) return error.TruncatedElf;
    const ehdr = std.mem.bytesToValue(Ehdr, elf[0..@sizeOf(Ehdr)]);
    if (!std.mem.eql(u8, ehdr.ident[0..4], "\x7fELF")) return error.NotAnElf;
    if (ehdr.ident[4] != 1) return error.Not32Bit; // ELFCLASS32
    if (ehdr.ident[5] != 1) return error.NotLittleEndian; // ELFDATA2LSB
    if (ehdr.machine != EM_386) return error.NotI386;
    if (ehdr.shentsize != @sizeOf(Shdr)) return error.BadShentsize;

    const shoff: usize = ehdr.shoff;
    const shnum: usize = ehdr.shnum;
    if (shoff + shnum * @sizeOf(Shdr) > elf.len) return error.TruncatedElf;

    const shdrs = try allocator.alloc(Shdr, shnum);
    defer allocator.free(shdrs);
    for (shdrs, 0..) |*s, i| {
        const off = shoff + i * @sizeOf(Shdr);
        s.* = std.mem.bytesToValue(Shdr, elf[off..][0..@sizeOf(Shdr)]);
    }

    if (ehdr.shstrndx >= shnum) return error.BadShstrndx;
    const shstr_sec = shdrs[ehdr.shstrndx];
    if (shstr_sec.offset + shstr_sec.size > elf.len) return error.TruncatedElf;
    const shstr = elf[shstr_sec.offset..][0..shstr_sec.size];

    // Find the symbol table and its string table.
    var symtab: ?Shdr = null;
    for (shdrs) |s| {
        if (s.sh_type == SHT_SYMTAB) {
            symtab = s;
            break;
        }
    }
    const sym_sec = symtab orelse return error.NoSymtab;
    if (sym_sec.link >= shnum) return error.BadStrtab;
    const str_sec = shdrs[sym_sec.link];
    if (str_sec.offset + str_sec.size > elf.len) return error.TruncatedElf;
    const strtab = elf[str_sec.offset..][0..str_sec.size];
    if (sym_sec.offset + sym_sec.size > elf.len) return error.TruncatedElf;
    const sym_bytes = elf[sym_sec.offset..][0..sym_sec.size];
    if (sym_bytes.len % @sizeOf(Sym) != 0) return error.BadSymtab;
    const nsyms = sym_bytes.len / @sizeOf(Sym);

    // Base = lowest VMA among allocated sections.
    var base: u64 = std.math.maxInt(u64);
    for (shdrs) |s| {
        if (s.flags & SHF_ALLOC == 0) continue;
        if (s.size == 0) continue;
        base = @min(base, s.addr);
    }
    if (base == std.math.maxInt(u64)) return error.NoAllocSections;

    try out.print("# generated by elf2map from {s} — do not edit\n", .{input_name});
    try out.print("base 0x{x}\n", .{base});
    try out.print("entry 0x{x}\n", .{ehdr.entry});

    for (shdrs) |s| {
        if (s.flags & SHF_ALLOC == 0) continue;
        if (s.size == 0) continue;
        const name = sectionName(shstr, s.name);
        const is_bss = s.sh_type == SHT_NOBITS;
        const filesz: u64 = if (is_bss) 0 else s.size;
        const w: u8 = if (s.flags & SHF_WRITE != 0) 'w' else '-';
        const x: u8 = if (s.flags & SHF_EXECINSTR != 0) 'x' else '-';
        try out.print("section {s} vaddr 0x{x} off 0x{x} filesz 0x{x} memsz 0x{x} flags r{c}{c}\n", .{
            name, s.addr, @as(u64, s.addr) - base, filesz, @as(u64, s.size), w, x,
        });
    }

    var syms: std.ArrayList(SymEntry) = .empty;
    defer syms.deinit(allocator);
    var imports = std.StringHashMap(void).init(allocator);
    defer imports.deinit();
    var import_order: std.ArrayList([]const u8) = .empty;
    defer import_order.deinit(allocator);

    for (0..nsyms) |i| {
        const sym = std.mem.bytesToValue(Sym, sym_bytes[i * @sizeOf(Sym) ..][0..@sizeOf(Sym)]);
        const name = sectionName(strtab, sym.name);
        if (name.len == 0) continue;
        if (sym.shndx == SHN_UNDEF) {
            if (!imports.contains(name)) {
                try imports.put(name, {});
                try import_order.append(allocator, name);
            }
            continue;
        }
        const st_type: u4 = @truncate(sym.info & 0xf);
        if (st_type == 4) continue; // STT_FILE: source path markers, not symbols
        const st_bind: u4 = @truncate(sym.info >> 4);
        const sec_name: []const u8 = if (sym.shndx < shnum)
            sectionName(shstr, shdrs[sym.shndx].name)
        else
            "";
        const kind = classify(st_bind, st_type, sec_name, name) orelse {
            // Globals are expected to survive; warn so a dropped entry
            // is never silent. ffe_entry is our own linker-script symbol
            // (its address is already in the `entry` line).
            if (st_bind != 0 and !std.mem.eql(u8, name, "ffe_entry"))
                std.debug.print("elf2map: warning: dropping global symbol {s} (0x{x})\n", .{ name, sym.value });
            continue;
        };
        try syms.append(allocator, .{
            .name = name,
            .addr = sym.value,
            .size = sym.size,
            .kind = kind,
        });
    }

    std.mem.sort(SymEntry, syms.items, {}, struct {
        fn lessThan(_: void, a: SymEntry, b: SymEntry) bool {
            if (a.addr != b.addr) return a.addr < b.addr;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (syms.items) |s| {
        try out.print("sym {s} 0x{x} 0x{x} {s}\n", .{ s.name, s.addr, s.size, @tagName(s.kind) });
    }
    for (import_order.items) |name| {
        try out.print("import {s}\n", .{name});
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    if (!it.skip()) return error.BadArgs;
    const elf_path = it.next() orelse return error.BadArgs;
    const map_path = it.next() orelse return error.BadArgs;

    const elf = try std.Io.Dir.cwd().readFileAlloc(io, elf_path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(elf);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try generate(allocator, elf, elf_path, &aw.writer);
    const bytes = try aw.toOwnedSlice();
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = map_path, .data = bytes });
}

// --- Tests: build a synthetic ELF32 in memory, no toolchain needed. ---

const TestBuilder = struct {
    bytes: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) TestBuilder {
        return .{ .bytes = .empty, .alloc = alloc };
    }
    fn append(tv: *TestBuilder, data: []const u8) !u32 {
        const off: u32 = @intCast(tv.bytes.items.len);
        try tv.bytes.appendSlice(tv.alloc, data);
        return off;
    }
    fn appendValue(tv: *TestBuilder, v: anytype) !u32 {
        return tv.append(std.mem.asBytes(&v));
    }
    fn alignTo(tv: *TestBuilder, a: u32) !void {
        while (tv.bytes.items.len % a != 0) try tv.bytes.append(tv.alloc, 0);
    }
};

test "generate map from synthetic elf32" {
    const alloc = std.testing.allocator;
    var tv = TestBuilder.init(alloc);
    defer tv.bytes.deinit(alloc);

    // Reserve space for ehdr, fill in at the end.
    const ehdr_off = try tv.appendValue(std.mem.zeroes(Ehdr));
    _ = ehdr_off;

    // .text bytes.
    const text_off = try tv.append(&.{ 0x90, 0x90, 0xc3, 0x90 });
    // .data bytes.
    const data_off = try tv.append(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    // strtab.
    var strtab = std.ArrayList(u8).empty;
    defer strtab.deinit(alloc);
    try strtab.append(alloc, 0);
    const n_func: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "FUNC_000020\x00");
    const n_data: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "DATA_0001\x00");
    const n_imp: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "_C_DrawSprite\x00");
    const n_jump: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "JUMP_000999\x00");
    const n_clocal: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "CustomLocal\x00");
    const n_custom: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "CustomEntry\x00");
    const n_ldata: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(alloc, "localdata\x00");
    const strtab_off = try tv.append(strtab.items);

    // shstrtab.
    var shstr = std.ArrayList(u8).empty;
    defer shstr.deinit(alloc);
    try shstr.append(alloc, 0);
    const s_text: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".text\x00");
    const s_data: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".data\x00");
    const s_symtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".symtab\x00");
    const s_strtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".strtab\x00");
    const s_shstrtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(alloc, ".shstrtab\x00");
    const shstr_off = try tv.append(shstr.items);

    // symtab: null, func, data, import.
    try tv.alignTo(4);
    const symtab_off = try tv.appendValue(std.mem.zeroes(Sym));
    _ = try tv.appendValue(Sym{ .name = n_func, .value = 0x400100, .size = 16, .info = 0x10, .other = 0, .shndx = 1 });
    _ = try tv.appendValue(Sym{ .name = n_data, .value = 0x402000, .size = 8, .info = 0x11, .other = 0, .shndx = 2 });
    _ = try tv.appendValue(Sym{ .name = n_imp, .value = 0, .size = 0, .info = 0x10, .other = 0, .shndx = SHN_UNDEF });
    _ = try tv.appendValue(Sym{ .name = n_jump, .value = 0x400200, .size = 4, .info = 0x00, .other = 0, .shndx = 1 });
    _ = try tv.appendValue(Sym{ .name = n_clocal, .value = 0x400300, .size = 4, .info = 0x00, .other = 0, .shndx = 1 });
    _ = try tv.appendValue(Sym{ .name = n_custom, .value = 0x400104, .size = 32, .info = 0x10, .other = 0, .shndx = 1 });
    _ = try tv.appendValue(Sym{ .name = n_ldata, .value = 0x402008, .size = 4, .info = 0x01, .other = 0, .shndx = 2 });
    const symtab_size: u32 = 8 * @sizeOf(Sym);

    // Section headers: null, .text, .data, .symtab, .strtab, .shstrtab.
    try tv.alignTo(4);
    const shoff: u32 = @intCast(tv.bytes.items.len);
    _ = try tv.appendValue(std.mem.zeroes(Shdr));
    _ = try tv.appendValue(Shdr{ .name = s_text, .sh_type = 1, .flags = SHF_ALLOC | SHF_EXECINSTR, .addr = 0x400100, .offset = text_off, .size = 4, .link = 0, .info = 0, .addralign = 16, .entsize = 0 });
    _ = try tv.appendValue(Shdr{ .name = s_data, .sh_type = 1, .flags = SHF_ALLOC | SHF_WRITE, .addr = 0x402000, .offset = data_off, .size = 8, .link = 0, .info = 0, .addralign = 4, .entsize = 0 });
    _ = try tv.appendValue(Shdr{ .name = s_symtab, .sh_type = SHT_SYMTAB, .flags = 0, .addr = 0, .offset = symtab_off, .size = symtab_size, .link = 4, .info = 3, .addralign = 4, .entsize = @sizeOf(Sym) });
    _ = try tv.appendValue(Shdr{ .name = s_strtab, .sh_type = SHT_STRTAB, .flags = 0, .addr = 0, .offset = strtab_off, .size = @intCast(strtab.items.len), .link = 0, .info = 0, .addralign = 1, .entsize = 0 });
    _ = try tv.appendValue(Shdr{ .name = s_shstrtab, .sh_type = SHT_STRTAB, .flags = 0, .addr = 0, .offset = shstr_off, .size = @intCast(shstr.items.len), .link = 0, .info = 0, .addralign = 1, .entsize = 0 });

    var ehdr = std.mem.zeroes(Ehdr);
    ehdr.ident[0] = 0x7f;
    ehdr.ident[1] = 'E';
    ehdr.ident[2] = 'L';
    ehdr.ident[3] = 'F';
    ehdr.ident[4] = 1;
    ehdr.ident[5] = 1;
    ehdr.ident[6] = 1;
    ehdr.machine = EM_386;
    ehdr.version = 1;
    ehdr.entry = 0x400100;
    ehdr.shoff = shoff;
    ehdr.ehsize = @sizeOf(Ehdr);
    ehdr.shentsize = @sizeOf(Shdr);
    ehdr.shnum = 6;
    ehdr.shstrndx = 5;
    @memcpy(tv.bytes.items[0..@sizeOf(Ehdr)], std.mem.asBytes(&ehdr));

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try generate(alloc, tv.bytes.items, "test.elf", &aw.writer);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);

    const expected =
        \\# generated by elf2map from test.elf — do not edit
        \\base 0x400100
        \\entry 0x400100
        \\section .text vaddr 0x400100 off 0x0 filesz 0x4 memsz 0x4 flags r-x
        \\section .data vaddr 0x402000 off 0x1f00 filesz 0x8 memsz 0x8 flags rw-
        \\sym FUNC_000020 0x400100 0x10 func
        \\sym CustomEntry 0x400104 0x20 func
        \\sym DATA_0001 0x402000 0x8 data
        \\sym localdata 0x402008 0x4 data
        \\import _C_DrawSprite
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}
