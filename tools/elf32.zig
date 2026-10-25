//! Minimal ELF32 reader shared by the ffe tools (elf2map, sentinel).

const std = @import("std");

pub const Ehdr = extern struct {
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

pub const Shdr = extern struct {
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

pub const Sym = extern struct {
    name: u32,
    value: u32,
    size: u32,
    info: u8,
    other: u8,
    shndx: u16,
};

pub const Rel = extern struct {
    offset: u32, // VMA of the 4-byte field to relocate
    info: u32, // (sym << 8) | type
};

pub const SHT_SYMTAB: u32 = 2;
pub const SHT_STRTAB: u32 = 3;
pub const SHT_RELA: u32 = 4;
pub const SHT_NOBITS: u32 = 8;
pub const SHT_REL: u32 = 9;
pub const SHF_WRITE: u32 = 0x1;
pub const SHF_ALLOC: u32 = 0x2;
pub const SHF_EXECINSTR: u32 = 0x4;
pub const SHN_UNDEF: u16 = 0;
pub const EM_386: u16 = 3;
pub const R_386_32: u8 = 1;
pub const R_386_PC32: u8 = 2;

pub fn sectionName(strtab: []const u8, off: u32) []const u8 {
    if (off >= strtab.len) return "";
    const rest = strtab[off..];
    const len = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    return rest[0..len];
}

pub fn relSym(info: u32) u32 {
    return info >> 8;
}

pub fn relType(info: u32) u8 {
    return @truncate(info & 0xff);
}
