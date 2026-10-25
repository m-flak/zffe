//! Trampolines: native implementations of the guest's libc imports.
//!
//! Each lifted `call <sentinel>` becomes a call to a declared `import_<sym>`
//! function. The engine resolves that name with `zffe_tramp_resolve()` and
//! links the returned adapter. Adapters run on the host with the Remill
//! signature `(State*, PC, Memory*)`, unpack guest args from `H + ESP`, and
//! write results back to `EAX` / `ST0`.
//!
//! Philosophy: wrappers where wrappable, reimplementation where necessary.
//! Fixed-arity C89 functions call straight through to host libc: translate
//! the guest pointer (`H + addr`), call, marshal the result back to 32 bits
//! (comparisons normalize to MSVC-style -1/0/1; the strtol family clamps to
//! the guest's 32-bit `long`). One-line adapters over `std` (strlen, spans,
//! ctype, abs) stay: already minimal, and locale-proof where host libc is not.
//!
//! What can't be wrappers is implemented here: the printf family and sscanf
//! (varargs can't be forwarded), malloc/free (the guest heap hands out
//! 32-bit addresses), atexit (guest code pointers), and rand (exact MSVC
//! LCG). Files go through raw fds, not stdio, so no buffering layer sits
//! between guest and host.
//!
//! State offsets below are for Remill's X86 SSE state (no AVX/AVX512); the
//! 1995 guest has no vector extensions. If Remill ever lifts with AVX state
//! these offsets shift and the first libc call faults loudly (garbage ESP),
//! it cannot silently corrupt.
//!
//! Guest `long` is 32 bits; adapters use `i32`/`u32`, never host `long`.

const std = @import("std");
const builtin = @import("builtin");
const heap_mod = @import("guest_heap.zig");

/// Byte offsets into Remill's X86 `State` struct (SSE variant), verified
/// against Remill's `Arch/X86/Runtime/State.h`: each GPR `Reg` is 8 bytes
/// (u64 value + volatile guard), ordered rax,rcx,rdx,rbx,rsp,rbp,...;
/// ST0 is the first 10 bytes of the x87 stack area.
pub const state = struct {
    pub const gpr_rax: usize = 3576;
    pub const gpr_rsp: usize = 3608;
    pub const x87_st0: usize = 2496;
};

/// Adapter signature: exactly Remill's lifted-call ABI.
pub const TrampFn = fn (state_ptr: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void;

/// Host base H of the 4 GiB guest reservation. Set once at startup; every
/// guest address `a` maps to host `H + a`.
var host_base: usize = 0;

/// Guest heap backing `_malloc`/`_free`. Configured by `zffe_tramp_init`.
var gheap: ?heap_mod.Heap = null;

/// MSVC-compatible `rand()` state (a=214013 c=2531011, >>16 & 0x7FFF).
var rand_seed: u32 = 1;

/// `atexit()` registrations. Never invoked: process exit ends the guest too.
var atexit_fns: [32]u32 = @splat(0);
var atexit_len: usize = 0;

export fn zffe_tramp_set_base(h: u64) void {
    host_base = @intCast(h);
}

/// `heap_base`/`heap_size` delimit the guest heap window inside the 4 GiB
/// reservation (must not overlap `[base, mem_end)`).
export fn zffe_tramp_init(h: u64, heap_base: u32, heap_size: u32) void {
    host_base = @intCast(h);
    const mem: [*]u8 = @ptrFromInt(@as(usize, @intCast(h)) + heap_base);
    gheap = heap_mod.Heap.init(mem[0..heap_size], heap_base);
}

// ---------------------------------------------------------------------------
// Framework: state access, guest reads/writes
// ---------------------------------------------------------------------------

fn stateBytes(s: ?*anyopaque) [*]u8 {
    return @ptrCast(s.?);
}

fn readGpr32(s: ?*anyopaque, off: usize) u32 {
    const p: *align(1) const u32 = @ptrCast(stateBytes(s) + off);
    return p.*;
}

fn writeGpr32(s: ?*anyopaque, off: usize, v: u32) void {
    const p: *align(1) u32 = @ptrCast(stateBytes(s) + off);
    p.* = v;
}

/// Guest ESP (low 32 bits of RSP).
fn guestEsp(s: ?*anyopaque) u32 {
    return readGpr32(s, state.gpr_rsp);
}

/// i-th cdecl arg: u32 at `H + ESP + 4 + 4*i`.
fn arg(s: ?*anyopaque, i: usize) u32 {
    const esp: usize = guestEsp(s);
    const p: *align(1) const u32 = @ptrFromInt(host_base + esp + 4 + 4 * i);
    return p.*;
}

/// Write the u32 return value to EAX.
fn ret(s: ?*anyopaque, v: u32) void {
    writeGpr32(s, state.gpr_rax, v);
}

/// Write an f64 return value to x87 ST0 (low 8 bytes, rest zeroed).
fn retF64(s: ?*anyopaque, v: f64) void {
    const st0: *[10]u8 = @ptrCast(stateBytes(s) + state.x87_st0);
    const bits: u64 = @bitCast(v);
    std.mem.writeInt(u64, st0[0..8], bits, .little);
    st0[8] = 0;
    st0[9] = 0;
}

/// Host slice over `len` guest bytes at `addr`.
fn gslice(addr: u32, len: usize) []u8 {
    return @as([*]u8, @ptrFromInt(host_base + addr))[0..len];
}

/// Host slice over `len` guest bytes at `addr` (read-only).
fn gsliceConst(addr: u32, len: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(host_base + addr))[0..len];
}

/// NUL-terminated guest string as a host slice (unbounded scan; the whole
/// reservation past the arg is mapped, so this always terminates).
fn gstr(addr: u32) []const u8 {
    var len: usize = 0;
    const base: [*]const u8 = @ptrFromInt(host_base + addr);
    while (base[len] != 0) : (len += 1) {}
    return base[0..len];
}

/// Guest string arg as a host C string (no copy; guest memory stays put).
fn cstr(addr: u32) [*:0]const u8 {
    return @ptrFromInt(host_base + addr);
}

/// Host pointer inside the reservation, back to a 32-bit guest address.
fn guestAddr(p: anytype) u32 {
    return @intCast(@intFromPtr(p) - host_base);
}

/// libc comparison result, normalized to MSVC-style -1/0/1 (host libcs
/// return arbitrary nonzero magnitudes; only the sign is specified).
fn normCmp(r: c_int) u32 {
    const v: i32 = if (r < 0) -1 else if (r > 0) 1 else 0;
    return @bitCast(v);
}

// ---------------------------------------------------------------------------
// Memory adapters
// ---------------------------------------------------------------------------

export fn tramp_memmove(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const dst = arg(s, 0);
    const d: [*]u8 = @ptrFromInt(host_base + dst);
    const sr: [*]const u8 = @ptrFromInt(host_base + arg(s, 1));
    _ = c.memmove(d, sr, arg(s, 2));
    ret(s, dst);
}

export fn tramp_memcpy(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const dst, const src, const n = .{ arg(s, 0), arg(s, 1), arg(s, 2) };
    @memcpy(gslice(dst, n), gsliceConst(src, n));
    ret(s, dst);
}

export fn tramp_memset(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const dst, const ch, const n = .{ arg(s, 0), arg(s, 1), arg(s, 2) };
    @memset(gslice(dst, n), @truncate(ch));
    ret(s, dst);
}

export fn tramp_memcmp(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const a: [*]const u8 = @ptrFromInt(host_base + arg(s, 0));
    const b: [*]const u8 = @ptrFromInt(host_base + arg(s, 1));
    ret(s, normCmp(c.memcmp(a, b, arg(s, 2))));
}

// ---------------------------------------------------------------------------
// String adapters
// ---------------------------------------------------------------------------

export fn tramp_strlen(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    ret(s, @intCast(gstr(arg(s, 0)).len));
}

export fn tramp_strcpy(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const dst = arg(s, 0);
    const d: [*]u8 = @ptrFromInt(host_base + dst);
    _ = c.strcpy(d, cstr(arg(s, 1)));
    ret(s, dst);
}

export fn tramp_strncpy(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const dst = arg(s, 0);
    const d: [*]u8 = @ptrFromInt(host_base + dst);
    const sr: [*]const u8 = @ptrFromInt(host_base + arg(s, 1));
    _ = c.strncpy(d, sr, arg(s, 2));
    ret(s, dst);
}

export fn tramp_strcat(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const dst = arg(s, 0);
    const d: [*]u8 = @ptrFromInt(host_base + dst);
    _ = c.strcat(d, cstr(arg(s, 1)));
    ret(s, dst);
}

export fn tramp_strcmp(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    ret(s, normCmp(c.strcmp(cstr(arg(s, 0)), cstr(arg(s, 1)))));
}

export fn tramp_strncmp(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const a: [*]const u8 = @ptrFromInt(host_base + arg(s, 0));
    const b: [*]const u8 = @ptrFromInt(host_base + arg(s, 1));
    ret(s, normCmp(c.strncmp(a, b, arg(s, 2))));
}

export fn tramp_strchr(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const r = c.strchr(cstr(arg(s, 0)), @bitCast(arg(s, 1)));
    ret(s, if (r) |p| guestAddr(p) else 0);
}

export fn tramp_strrchr(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const r = c.strrchr(cstr(arg(s, 0)), @bitCast(arg(s, 1)));
    ret(s, if (r) |p| guestAddr(p) else 0);
}

export fn tramp_strspn(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str = gstr(arg(s, 0));
    const accept = gstr(arg(s, 1));
    ret(s, @intCast(std.mem.indexOfNone(u8, str, accept) orelse str.len));
}

export fn tramp_strcspn(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str = gstr(arg(s, 0));
    const reject = gstr(arg(s, 1));
    ret(s, @intCast(std.mem.indexOfAny(u8, str, reject) orelse str.len));
}

export fn tramp_strpbrk(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str_addr = arg(s, 0);
    const str = gstr(str_addr);
    const accept = gstr(arg(s, 1));
    if (std.mem.indexOfAny(u8, str, accept)) |i| {
        ret(s, str_addr +% @as(u32, @intCast(i)));
    } else {
        ret(s, 0);
    }
}

// ---------------------------------------------------------------------------
// Conversion adapters
// ---------------------------------------------------------------------------

const StrtolResult = struct {
    value: i32,
    end_off: usize, // offset of first unconsumed byte
};

/// Integer parser shared by the strtol-family adapters and the scanf engine
/// (which needs mid-string end offsets a host call can't provide). Guest
/// `long` is 32 bits, so results clamp to i32/u32, unlike host `long`.
fn parseStrtol(str: []const u8, base_in: u32) StrtolResult {
    return parseStrtolInner(str, base_in, false);
}

fn parseStrtoulInner(str: []const u8, base_in: u32) StrtolResult {
    return parseStrtolInner(str, base_in, true);
}

fn parseStrtolInner(str: []const u8, base_in: u32, unsigned: bool) StrtolResult {
    var i: usize = 0;
    while (i < str.len and (str[i] == ' ' or str[i] == '\t' or str[i] == '\n' or
        str[i] == '\r' or str[i] == '\x0b' or str[i] == '\x0c')) : (i += 1) {}
    var neg = false;
    if (i < str.len and (str[i] == '+' or str[i] == '-')) {
        neg = str[i] == '-';
        i += 1;
    }
    var base = base_in;
    if (base == 0) {
        base = 10;
        if (i < str.len and str[i] == '0') {
            base = 8;
            if (i + 1 < str.len and (str[i + 1] == 'x' or str[i + 1] == 'X')) {
                base = 16;
                i += 2;
            }
        }
    } else if (base == 16 and i + 1 < str.len and str[i] == '0' and
        (str[i + 1] == 'x' or str[i + 1] == 'X'))
    {
        i += 2;
    }
    var acc: u64 = 0;
    const start = i;
    while (i < str.len) : (i += 1) {
        const ch = str[i];
        const d: u64 = if (ch >= '0' and ch <= '9')
            ch - '0'
        else if (ch >= 'a' and ch <= 'z')
            ch - 'a' + 10
        else if (ch >= 'A' and ch <= 'Z')
            ch - 'A' + 10
        else
            break;
        if (d >= base) break;
        acc = acc * base + d;
        if (acc > 0xFFFFFFFF) {
            acc = 0xFFFFFFFF;
            // Keep consuming valid digits so endptr is right.
            i += 1;
            while (i < str.len) : (i += 1) {
                const c2 = str[i];
                const d2: u64 = if (c2 >= '0' and c2 <= '9')
                    c2 - '0'
                else if (c2 >= 'a' and c2 <= 'z')
                    c2 - 'a' + 10
                else if (c2 >= 'A' and c2 <= 'Z')
                    c2 - 'A' + 10
                else
                    break;
                if (d2 >= base) break;
            }
            break;
        }
    }
    if (i == start) return .{ .value = 0, .end_off = start };
    if (unsigned) {
        // acc already capped at 0xFFFFFFFF above; negation wraps mod 2^32.
    } else {
        if (!neg and acc > std.math.maxInt(i32)) acc = std.math.maxInt(i32);
        if (neg and acc > 0x80000000) acc = 0x80000000;
    }
    var u: u32 = @truncate(acc);
    if (neg) u = @as(u32, 0) -% u; // wrapping: INT_MIN negates to itself
    return .{ .value = @bitCast(u), .end_off = i };
}

fn writeEndptr(s: ?*anyopaque, arg_idx: usize, str_addr: u32, end_off: usize) void {
    const endptr = arg(s, arg_idx);
    if (endptr != 0) {
        const p: *align(1) u32 = @ptrFromInt(host_base + endptr);
        p.* = str_addr +% @as(u32, @intCast(end_off));
    }
}

export fn tramp_strtol(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str_addr = arg(s, 0);
    const r = parseStrtol(gstr(str_addr), arg(s, 2));
    writeEndptr(s, 1, str_addr, r.end_off);
    ret(s, @bitCast(r.value));
}

export fn tramp_strtoul(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str_addr = arg(s, 0);
    const r = parseStrtoulInner(gstr(str_addr), arg(s, 2));
    writeEndptr(s, 1, str_addr, r.end_off);
    ret(s, @bitCast(r.value));
}

export fn tramp_atoi(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    ret(s, @bitCast(parseStrtol(gstr(arg(s, 0)), 10).value));
}

export fn tramp_atol(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    // Guest long is 32 bits: atol == atoi.
    ret(s, @bitCast(parseStrtol(gstr(arg(s, 0)), 10).value));
}

/// Scan the longest prefix that `std.fmt.parseFloat` would accept.
fn floatPrefixLen(str: []const u8) usize {
    var i: usize = 0;
    while (i < str.len and (str[i] == ' ' or str[i] == '\t' or str[i] == '\n' or
        str[i] == '\r' or str[i] == '\x0b' or str[i] == '\x0c')) : (i += 1) {}
    if (i < str.len and (str[i] == '+' or str[i] == '-')) i += 1;
    // inf/infinity/nan (case-insensitive)
    if (i < str.len and (str[i] == 'i' or str[i] == 'I' or str[i] == 'n' or str[i] == 'N')) {
        const rest = str[i..];
        if (std.ascii.startsWithIgnoreCase(rest, "infinity")) return i + 8;
        if (std.ascii.startsWithIgnoreCase(rest, "inf")) return i + 3;
        if (std.ascii.startsWithIgnoreCase(rest, "nan")) return i + 3;
        return i;
    }
    const digits_start = i;
    while (i < str.len and str[i] >= '0' and str[i] <= '9') : (i += 1) {}
    const have_int = i > digits_start;
    if (i < str.len and str[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < str.len and str[i] >= '0' and str[i] <= '9') : (i += 1) {}
        if (!have_int and i == frac_start) return digits_start; // lone '.'
    } else if (!have_int) {
        return digits_start;
    }
    if (i < str.len and (str[i] == 'e' or str[i] == 'E')) {
        var j = i + 1;
        if (j < str.len and (str[j] == '+' or str[j] == '-')) j += 1;
        if (j < str.len and str[j] >= '0' and str[j] <= '9') {
            while (j < str.len and str[j] >= '0' and str[j] <= '9') : (j += 1) {}
            i = j;
        }
    }
    return i;
}

export fn tramp_strtod(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str_addr = arg(s, 0);
    const str = gstr(str_addr);
    const len = floatPrefixLen(str);
    writeEndptr(s, 1, str_addr, len);
    const v: f64 = if (len == 0)
        0
    else
        std.fmt.parseFloat(f64, str[0..len]) catch 0;
    retF64(s, v);
}

export fn tramp_atof(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str = gstr(arg(s, 0));
    const len = floatPrefixLen(str);
    const v: f64 = if (len == 0)
        0
    else
        std.fmt.parseFloat(f64, str[0..len]) catch 0;
    retF64(s, v);
}

// ---------------------------------------------------------------------------
// stdlib / process adapters
// ---------------------------------------------------------------------------

export fn tramp_rand(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    // MSVC's exact generator: seed = seed*214013 + 2531011, return >>16 & 0x7FFF.
    rand_seed = rand_seed *% 214013 +% 2531011;
    ret(s, (rand_seed >> 16) & 0x7FFF);
}

export fn tramp_malloc(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const hp = &(gheap orelse @panic("malloc before zffe_tramp_init"));
    ret(s, @truncate(hp.malloc(arg(s, 0))));
}

export fn tramp_free(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const hp = &(gheap orelse return); // free before init: nothing to account
    _ = hp.free(arg(s, 0));
}

export fn tramp_exit(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const code: i32 = @bitCast(arg(s, 0));
    std.process.exit(if (code < 0 or code > 255) 1 else @intCast(code));
}

export fn tramp_atexit(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    // Record-only: process exit ends the guest; handlers never run.
    if (atexit_len < atexit_fns.len) {
        atexit_fns[atexit_len] = arg(s, 0);
        atexit_len += 1;
        ret(s, 0);
    } else {
        ret(s, @bitCast(@as(i32, -1)));
    }
}

export fn tramp_abs(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const v: i32 = @bitCast(arg(s, 0));
    // abs(INT_MIN) is UB in C; wrap like the hardware does.
    ret(s, if (v == std.math.minInt(i32)) @bitCast(v) else @abs(v));
}

export fn tramp_sqrt(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const p: *align(1) const u64 = @ptrFromInt(host_base + guestEsp(s) + 4);
    const x: f64 = @bitCast(p.*);
    retF64(s, @sqrt(x)); // sqrt(negative) = NaN, matching libm
}

export fn tramp_tolower(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    ret(s, std.ascii.toLower(@truncate(arg(s, 0))));
}

export fn tramp_toupper(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    ret(s, std.ascii.toUpper(@truncate(arg(s, 0))));
}

export fn tramp_clock(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    // Wall milliseconds; the guest uses it for frame pacing, not profiling.
    var ts: Timespec = undefined;
    if (c.clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        ret(s, 0);
        return;
    }
    const ms: u64 = @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
    ret(s, @truncate(ms));
}

// ---------------------------------------------------------------------------
// libc fd layer (the guest's files are host fds, not std.Io objects)
// ---------------------------------------------------------------------------
//
// Trampolines deliberately bypass Zig's threaded-Io context: raw libc fds
// keep every adapter a pure function of (State*, guest memory).

const Timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};
const CLOCK_REALTIME: c_int = 0; // 0 on Linux and macOS

const c = struct {
    extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn lseek(fd: c_int, off: c_long, whence: c_int) c_long;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*]u8;
    extern "c" fn dup(fd: c_int) c_int;
    extern "c" fn dup2(old: c_int, new: c_int) c_int;
    extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
    extern "c" fn memmove(dst: [*]u8, src: [*]const u8, n: usize) ?[*]u8;
    extern "c" fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) c_int;
    extern "c" fn strcpy(dst: [*]u8, src: [*:0]const u8) ?[*]u8;
    extern "c" fn strncpy(dst: [*]u8, src: [*]const u8, n: usize) ?[*]u8;
    extern "c" fn strcat(dst: [*]u8, src: [*:0]const u8) ?[*]u8;
    extern "c" fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int;
    extern "c" fn strncmp(a: [*]const u8, b: [*]const u8, n: usize) c_int;
    extern "c" fn strchr(s: [*:0]const u8, ch: c_int) ?[*:0]u8;
    extern "c" fn strrchr(s: [*:0]const u8, ch: c_int) ?[*:0]u8;
};

// open(2) flags differ per OS; SEEK_* are 0/1/2 everywhere (POSIX).
const O = switch (builtin.os.tag) {
    .linux => struct {
        pub const RDONLY: c_int = 0;
        pub const WRONLY: c_int = 1;
        pub const RDWR: c_int = 2;
        pub const CREAT: c_int = 0o100;
        pub const TRUNC: c_int = 0o1000;
        pub const APPEND: c_int = 0o2000;
    },
    .macos, .ios => struct {
        pub const RDONLY: c_int = 0;
        pub const WRONLY: c_int = 1;
        pub const RDWR: c_int = 2;
        pub const CREAT: c_int = 0x200;
        pub const TRUNC: c_int = 0x400;
        pub const APPEND: c_int = 0x8;
    },
    else => @compileError("trampoline open() flags not defined for this OS"),
};

const SEEK_SET: c_int = 0;
const SEEK_CUR: c_int = 1;
const SEEK_END: c_int = 2;

fn writeAllFd(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

// ---------------------------------------------------------------------------
// FILE* handle table + file adapters
// ---------------------------------------------------------------------------
//
// Guest FILE* values are small indices (1-based; 0 is NULL), never host
// pointers. Handles 1..3 are stdin/stdout/stderr; the rest are real files.

const FileEntry = struct {
    in_use: bool = false,
    fd: c_int = -1,
};

var files: [64]FileEntry = @splat(.{});
var files_init: bool = false;

fn fileTable() *[64]FileEntry {
    if (!files_init) {
        files[1] = .{ .in_use = true, .fd = 0 };
        files[2] = .{ .in_use = true, .fd = 1 };
        files[3] = .{ .in_use = true, .fd = 2 };
        files_init = true;
    }
    return &files;
}

fn lookupFile(handle: u32) ?*FileEntry {
    if (handle == 0 or handle >= fileTable().len) return null;
    const e = &fileTable()[handle];
    return if (e.in_use) e else null;
}

fn allocFile(fd: c_int) u32 {
    for (fileTable()[4..], 4..) |*e, i| {
        if (!e.in_use) {
            e.* = .{ .in_use = true, .fd = fd };
            return @intCast(i);
        }
    }
    _ = c.close(fd);
    return 0; // table full
}

export fn tramp_fopen(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const cpath: [*:0]const u8 = @ptrFromInt(host_base + arg(s, 0));
    const mode = gstr(arg(s, 1));
    if (mode.len == 0) {
        ret(s, 0);
        return;
    }
    const plus = std.mem.indexOfScalar(u8, mode, '+') != null;
    // 'b'/'t' ignored (POSIX has no text/binary distinction).
    const flags: c_int = switch (mode[0]) {
        'r' => if (plus) O.RDWR else O.RDONLY,
        'w' => (if (plus) O.RDWR else O.WRONLY) | O.CREAT | O.TRUNC,
        'a' => (if (plus) O.RDWR else O.WRONLY) | O.CREAT | O.APPEND,
        else => {
            ret(s, 0);
            return;
        },
    };
    const fd = c.open(cpath, flags, @as(c_uint, 0o666));
    if (fd < 0) {
        ret(s, 0);
        return;
    }
    ret(s, allocFile(fd));
}

export fn tramp_fclose(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const handle = arg(s, 0);
    if (lookupFile(handle)) |e| {
        if (handle >= 4) _ = c.close(e.fd); // never close stdio
        e.in_use = false;
        ret(s, 0);
    } else {
        ret(s, @bitCast(@as(i32, -1))); // EOF
    }
}

export fn tramp_fread(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const buf_addr, const size, const count, const handle = .{ arg(s, 0), arg(s, 1), arg(s, 2), arg(s, 3) };
    const e = lookupFile(handle) orelse {
        ret(s, 0);
        return;
    };
    if (size == 0 or count == 0) {
        ret(s, 0);
        return;
    }
    const total: usize = @as(usize, size) * count;
    const d = gslice(buf_addr, total);
    var got: usize = 0;
    while (got < total) {
        const n = c.read(e.fd, d.ptr + got, total - got);
        if (n <= 0) break; // EOF (0) or error (-1)
        got += @intCast(n);
    }
    ret(s, @intCast(got / size)); // whole items
}

export fn tramp_fwrite(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const buf_addr, const size, const count, const handle = .{ arg(s, 0), arg(s, 1), arg(s, 2), arg(s, 3) };
    const e = lookupFile(handle) orelse {
        ret(s, 0);
        return;
    };
    if (size == 0 or count == 0) {
        ret(s, 0);
        return;
    }
    const total: usize = @as(usize, size) * count;
    const d = gsliceConst(buf_addr, total);
    var wrote: usize = 0;
    while (wrote < total) {
        const n = c.write(e.fd, d.ptr + wrote, total - wrote);
        if (n <= 0) break;
        wrote += @intCast(n);
    }
    ret(s, @intCast(wrote / size)); // whole items
}

export fn tramp_fseek(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    // fseek(stream, offset, whence)
    const e = lookupFile(arg(s, 0)) orelse {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    };
    const off: i32 = @bitCast(arg(s, 1));
    const whence: c_int = @intCast(arg(s, 2));
    if (whence != SEEK_SET and whence != SEEK_CUR and whence != SEEK_END) {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    }
    if (whence == SEEK_SET and off < 0) {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    }
    const r = c.lseek(e.fd, off, whence);
    ret(s, if (r < 0) @bitCast(@as(i32, -1)) else 0);
}

export fn tramp_ftell(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const e = lookupFile(arg(s, 0)) orelse {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    };
    const r = c.lseek(e.fd, 0, SEEK_CUR);
    ret(s, if (r < 0) @bitCast(@as(i32, -1)) else @truncate(@as(u64, @intCast(r))));
}

export fn tramp_rewind(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    if (lookupFile(arg(s, 0))) |e| {
        _ = c.lseek(e.fd, 0, SEEK_SET);
    }
}

export fn tramp_fputs(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str = gstr(arg(s, 0));
    const e = lookupFile(arg(s, 1)) orelse {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    };
    ret(s, if (writeAllFd(e.fd, str)) 1 else @bitCast(@as(i32, -1)));
}

fn putcImpl(s: ?*anyopaque) void {
    const ch: u8 = @truncate(arg(s, 0));
    const e = lookupFile(arg(s, 1)) orelse {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    };
    ret(s, if (writeAllFd(e.fd, &[_]u8{ch})) ch else @bitCast(@as(i32, -1)));
}

export fn tramp_putc(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    putcImpl(s);
}

export fn tramp_fputc(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    putcImpl(s); // identical semantics to putc here (no macros involved)
}

export fn tramp_fflush(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    // No userspace buffering in the fd layer: nothing to flush.
    ret(s, 0);
}

export fn tramp_putchar(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const ch: u8 = @truncate(arg(s, 0));
    ret(s, if (writeAllFd(1, &[_]u8{ch})) ch else @bitCast(@as(i32, -1)));
}

export fn tramp_puts(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const str = gstr(arg(s, 0));
    if (!writeAllFd(1, str) or !writeAllFd(1, "\n")) {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    }
    ret(s, 1); // non-negative on success
}

export fn tramp_remove(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const cpath: [*:0]const u8 = @ptrFromInt(host_base + arg(s, 0));
    ret(s, if (c.unlink(cpath) == 0) 0 else @bitCast(@as(i32, -1)));
}

export fn tramp_unlink(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    // Same handling as remove() on hosted platforms.
    const cpath: [*:0]const u8 = @ptrFromInt(host_base + arg(s, 0));
    ret(s, if (c.unlink(cpath) == 0) 0 else @bitCast(@as(i32, -1)));
}

export fn tramp_getcwd(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const buf_addr, const size = .{ arg(s, 0), arg(s, 1) };
    if (size == 0) {
        ret(s, 0);
        return;
    }
    const d = gslice(buf_addr, size);
    if (c.getcwd(d.ptr, size) == null) {
        ret(s, 0); // ERANGE or error
        return;
    }
    ret(s, buf_addr);
}

// ---------------------------------------------------------------------------
// printf family
// ---------------------------------------------------------------------------

/// Guest varargs: consecutive u32 stack words. Doubles consume two words.
const VaList = struct {
    words: [*]align(1) const u32,
    idx: usize = 0,

    fn next(v: *VaList) u32 {
        const w = v.words[v.idx];
        v.idx += 1;
        return w;
    }

    fn nextF64(v: *VaList) f64 {
        const p: *align(1) const u64 = @ptrCast(v.words + v.idx);
        v.idx += 2;
        return @bitCast(p.*);
    }
};

fn guestVa(s: ?*anyopaque, first_arg: usize) VaList {
    const esp: usize = guestEsp(s);
    return .{ .words = @ptrFromInt(host_base + esp + 4 + 4 * first_arg) };
}

/// Output cursor tracking both clamped bytes and the unclamped total
/// (printf returns the total even when the buffer truncates).
const Emit = struct {
    out: []u8,
    pos: usize = 0,
    total: usize = 0,

    fn write(e: *Emit, bytes: []const u8) void {
        e.total += bytes.len;
        const room = e.out.len -| e.pos;
        const n = @min(room, bytes.len);
        @memcpy(e.out[e.pos..][0..n], bytes[0..n]);
        e.pos += n;
    }

    fn byte(e: *Emit, ch: u8) void {
        e.write(&[_]u8{ch});
    }

    fn padded(e: *Emit, piece: []const u8, left: bool, pad: u8, width: usize) void {
        if (piece.len >= width) {
            e.write(piece);
            return;
        }
        const n = width - piece.len;
        if (!left) {
            var i: usize = 0;
            while (i < n) : (i += 1) e.byte(pad);
        }
        e.write(piece);
        if (left) {
            var i: usize = 0;
            while (i < n) : (i += 1) e.byte(' ');
        }
    }
};

/// Render `v` with `%f` semantics and precision `p` into `tmp`.
/// Correct for game-range magnitudes; huge values fall back to shortest.
fn renderFixed(tmp: []u8, v: f64, p: usize) []u8 {
    if (std.math.isNan(v)) return std.fmt.bufPrint(tmp, "nan", .{}) catch tmp[0..0];
    if (std.math.isInf(v)) {
        return std.fmt.bufPrint(tmp, "{s}inf", .{if (v < 0) "-" else ""}) catch tmp[0..0];
    }
    const prec = @min(p, 18);
    var mult: f64 = 1;
    var i: usize = 0;
    while (i < prec) : (i += 1) mult *= 10;
    const a = @abs(v);
    if (a > 1e18 / mult) {
        // Out of fixed-point range: shortest round-trip instead.
        return std.fmt.bufPrint(tmp, "{d}", .{v}) catch tmp[0..0];
    }
    const scaled: u64 = @intFromFloat(@round(a * mult));
    const m: u64 = @intFromFloat(mult);
    const intpart = scaled / m;
    const fracpart = scaled % m;
    var pos: usize = 0;
    if (v < 0 and scaled != 0) {
        tmp[pos] = '-';
        pos += 1;
    }
    const ip = std.fmt.bufPrint(tmp[pos..], "{d}", .{intpart}) catch return tmp[0..0];
    pos += ip.len;
    if (prec > 0) {
        tmp[pos] = '.';
        pos += 1;
        // Zero-padded fraction, exactly `prec` digits.
        var div: u64 = m / 10;
        var k: usize = 0;
        while (k < prec) : (k += 1) {
            const digit: u8 = if (div == 0) 0 else @truncate((fracpart / div) % 10);
            tmp[pos] = '0' + digit;
            pos += 1;
            if (div > 0) div /= 10;
        }
    }
    return tmp[0..pos];
}

/// Render `v` with `%e` semantics (glibc style: 2-digit exponent).
fn renderScientific(tmp: []u8, v: f64, p: usize) []u8 {
    if (std.math.isNan(v)) return std.fmt.bufPrint(tmp, "nan", .{}) catch tmp[0..0];
    if (std.math.isInf(v)) {
        return std.fmt.bufPrint(tmp, "{s}inf", .{if (v < 0) "-" else ""}) catch tmp[0..0];
    }
    if (v == 0) {
        var pos: usize = 0;
        if (std.math.signbit(v)) {
            tmp[pos] = '-';
            pos += 1;
        }
        tmp[pos] = '0';
        pos += 1;
        if (p > 0) {
            tmp[pos] = '.';
            pos += 1;
            var k: usize = 0;
            while (k < p) : (k += 1) {
                tmp[pos] = '0';
                pos += 1;
            }
        }
        @memcpy(tmp[pos..][0..4], "e+00");
        return tmp[0 .. pos + 4];
    }
    var a = @abs(v);
    var exp: i32 = 0;
    while (a >= 10) : (exp += 1) a /= 10;
    while (a < 1) : (exp -= 1) a *= 10;
    var mant: [64]u8 = undefined;
    const ms = renderFixed(&mant, if (v < 0) -a else a, p);
    @memcpy(tmp[0..ms.len], ms);
    var pos = ms.len;
    tmp[pos] = 'e';
    pos += 1;
    tmp[pos] = if (exp < 0) '-' else '+';
    pos += 1;
    const ae: u32 = @abs(exp);
    if (ae < 10) {
        tmp[pos] = '0';
        pos += 1;
    }
    const ed = std.fmt.bufPrint(tmp[pos..], "{d}", .{ae}) catch return tmp[0..0];
    return tmp[0 .. pos + ed.len];
}

fn vformat(out: []u8, fmt: []const u8, va: *VaList) Emit {
    var e = Emit{ .out = out };
    var tmp: [128]u8 = undefined;
    var i: usize = 0;
    while (i < fmt.len) {
        const ch = fmt[i];
        if (ch != '%') {
            e.byte(ch);
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            e.byte('%');
            i += 1;
            continue;
        }
        var left = false;
        var zero = false;
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '0' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '#')) : (i += 1) {
            if (fmt[i] == '-') left = true;
            if (fmt[i] == '0') zero = true;
            // '+', ' ', '#' accepted and ignored (guest logging rarely needs them).
        }
        var width: usize = 0;
        if (i < fmt.len and fmt[i] == '*') {
            const w_arg: i32 = @bitCast(va.next());
            width = if (w_arg < 0) blk: {
                left = true;
                break :blk @intCast(-w_arg);
            } else @intCast(w_arg);
            i += 1;
        } else {
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                width = width * 10 + (fmt[i] - '0');
            }
        }
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                const p_arg: i32 = @bitCast(va.next());
                prec = if (p_arg < 0) null else @intCast(p_arg);
                i += 1;
            } else {
                var p: usize = 0;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                    p = p * 10 + (fmt[i] - '0');
                }
                prec = p;
            }
        }
        while (i < fmt.len and (fmt[i] == 'l' or fmt[i] == 'h' or fmt[i] == 'L' or fmt[i] == 'z' or fmt[i] == 't')) : (i += 1) {}
        if (i >= fmt.len) break; // trailing '%'
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            'd', 'i' => {
                const v: i32 = @bitCast(va.next());
                const neg = v < 0;
                const mag: u32 = if (neg) @as(u32, @bitCast(-(v +% 1))) +% 1 else @bitCast(v);
                var digits = std.fmt.bufPrint(&tmp, "{d}", .{mag}) catch tmp[0..0];
                if (prec) |pr| {
                    if (pr == 0 and mag == 0) {
                        digits = tmp[0..0];
                    } else if (digits.len < pr) {
                        // Zero-pad to precision (shifts digits right in tmp).
                        const n = pr - digits.len;
                        std.mem.copyBackwards(u8, tmp[n..][0..pr], digits);
                        @memset(tmp[0..n], '0');
                        digits = tmp[0..pr];
                    }
                }
                if (neg or (zero and !left and prec == null)) {
                    // Sign (or zero-pad) goes before the digits.
                    if (neg) e.byte('-');
                    e.padded(digits, left, if (zero and prec == null) '0' else ' ', if (neg) width -| 1 else width);
                } else {
                    e.padded(digits, left, ' ', width);
                }
            },
            'u', 'o', 'x', 'X' => {
                const v = va.next();
                var digits: []u8 = switch (spec) {
                    'u' => std.fmt.bufPrint(&tmp, "{d}", .{v}) catch tmp[0..0],
                    'o' => std.fmt.bufPrint(&tmp, "{o}", .{v}) catch tmp[0..0],
                    'x' => std.fmt.bufPrint(&tmp, "{x}", .{v}) catch tmp[0..0],
                    else => std.fmt.bufPrint(&tmp, "{X}", .{v}) catch tmp[0..0],
                };
                if (prec) |pr| {
                    if (pr == 0 and v == 0) {
                        digits = tmp[0..0];
                    } else if (digits.len < pr) {
                        const n = pr - digits.len;
                        std.mem.copyBackwards(u8, tmp[n..][0..pr], digits);
                        @memset(tmp[0..n], '0');
                        digits = tmp[0..pr];
                    }
                }
                e.padded(digits, left, if (zero and prec == null) '0' else ' ', width);
            },
            'c' => {
                const ch_arg: u8 = @truncate(va.next());
                e.padded(([_]u8{ch_arg})[0..], left, ' ', width);
            },
            's' => {
                const p = va.next();
                var str: []const u8 = if (p == 0) "(null)" else gstr(p);
                if (prec) |pr| {
                    if (str.len > pr) str = str[0..pr];
                }
                e.padded(str, left, ' ', width);
            },
            'p' => {
                const digits = std.fmt.bufPrint(&tmp, "0x{x:0>8}", .{va.next()}) catch tmp[0..0];
                e.padded(digits, left, ' ', width);
            },
            'f', 'F' => {
                const digits = renderFixed(&tmp, va.nextF64(), prec orelse 6);
                e.padded(digits, left, if (zero) '0' else ' ', width);
            },
            'e', 'E' => {
                const digits = renderScientific(&tmp, va.nextF64(), prec orelse 6);
                e.padded(digits, left, if (zero) '0' else ' ', width);
            },
            'g', 'G' => {
                // Approximation: shortest round-trip (no %e crossover).
                const digits = std.fmt.bufPrint(&tmp, "{d}", .{va.nextF64()}) catch tmp[0..0];
                e.padded(digits, left, if (zero) '0' else ' ', width);
            },
            'n' => {
                const p = va.next();
                if (p != 0) {
                    const dst: *align(1) u32 = @ptrFromInt(host_base + p);
                    dst.* = @intCast(e.total);
                }
            },
            else => std.debug.panic("printf: unsupported specifier '%{c}' in \"{s}\"", .{ spec, fmt }),
        }
    }
    return e;
}

export fn tramp_printf(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    var buf: [65536]u8 = undefined;
    var va = guestVa(s, 1);
    const e = vformat(&buf, gstr(arg(s, 0)), &va);
    _ = writeAllFd(1, buf[0..e.pos]);
    ret(s, @intCast(e.total));
}

export fn tramp_sprintf(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const dst_addr = arg(s, 0);
    var buf: [65536]u8 = undefined;
    var va = guestVa(s, 2);
    const e = vformat(&buf, gstr(arg(s, 1)), &va);
    const d = gslice(dst_addr, e.pos + 1);
    @memcpy(d[0..e.pos], buf[0..e.pos]);
    d[e.pos] = 0;
    ret(s, @intCast(e.total));
}

export fn tramp_fprintf(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const e = lookupFile(arg(s, 0)) orelse {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    };
    var buf: [65536]u8 = undefined;
    var va = guestVa(s, 2);
    const out = vformat(&buf, gstr(arg(s, 1)), &va);
    if (!writeAllFd(e.fd, buf[0..out.pos])) {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    }
    ret(s, @intCast(out.total));
}

export fn tramp_vfprintf(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    const e = lookupFile(arg(s, 0)) orelse {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    };
    // In 32-bit cdecl a va_list is a pointer to the first vararg word.
    var va = VaList{ .words = @ptrFromInt(host_base + arg(s, 2)) };
    var buf: [65536]u8 = undefined;
    const out = vformat(&buf, gstr(arg(s, 1)), &va);
    if (!writeAllFd(e.fd, buf[0..out.pos])) {
        ret(s, @bitCast(@as(i32, -1)));
        return;
    }
    ret(s, @intCast(out.total));
}

// ---------------------------------------------------------------------------
// sscanf
// ---------------------------------------------------------------------------

fn isScanWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0b' or ch == '\x0c';
}

fn writeGuestInt(addr: u32, v: u32, len_mod: u2) void {
    // len_mod: 0 = int/long (32-bit), 1 = short, 2 = char.
    switch (len_mod) {
        0 => {
            const p: *align(1) u32 = @ptrFromInt(host_base + addr);
            p.* = v;
        },
        1 => {
            const p: *align(1) u16 = @ptrFromInt(host_base + addr);
            p.* = @truncate(v);
        },
        2 => {
            const p: *align(1) u8 = @ptrFromInt(host_base + addr);
            p.* = @truncate(v);
        },
        3 => unreachable,
    }
}

/// Returns assignments made, or -1 on EOF-before-any-conversion.
fn vsscanf(input: []const u8, fmt: []const u8, va: *VaList) i32 {
    var pos: usize = 0;
    var assigned: i32 = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        const ch = fmt[i];
        if (isScanWs(ch)) {
            while (pos < input.len and isScanWs(input[pos])) pos += 1;
            i += 1;
            continue;
        }
        if (ch != '%') {
            if (pos >= input.len or input[pos] != ch) break; // literal mismatch
            pos += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            if (pos >= input.len or input[pos] != '%') break;
            pos += 1;
            i += 1;
            continue;
        }
        var suppress = false;
        if (i < fmt.len and fmt[i] == '*') {
            suppress = true;
            i += 1;
        }
        var width: ?usize = null;
        if (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
            var w: usize = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                w = w * 10 + (fmt[i] - '0');
            }
            width = w;
        }
        var len_mod: u2 = 0;
        var saw_long = false;
        if (i < fmt.len and fmt[i] == 'l') {
            i += 1; // guest long is 32 bits, but %lf still means double
            saw_long = true;
        } else if (i < fmt.len and fmt[i] == 'h') {
            i += 1;
            len_mod = 1;
            if (i < fmt.len and fmt[i] == 'h') {
                i += 1;
                len_mod = 2;
            }
        } else if (i < fmt.len and fmt[i] == 'L') {
            i += 1;
        }
        if (i >= fmt.len) break;
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            'd', 'i', 'u', 'o', 'x', 'X' => {
                while (pos < input.len and isScanWs(input[pos])) pos += 1;
                if (pos >= input.len) break;
                var slice = input[pos..];
                if (width) |w| {
                    if (slice.len > w) slice = slice[0..w];
                }
                const base: u32 = switch (spec) {
                    'd', 'u' => 10,
                    'i' => 0,
                    'o' => 8,
                    else => 16,
                };
                const r = if (spec == 'd' or spec == 'i')
                    parseStrtol(slice, base)
                else
                    parseStrtoulInner(slice, base);
                if (r.end_off == 0) break; // no conversion
                if (!suppress) {
                    writeGuestInt(va.next(), @bitCast(r.value), len_mod);
                    assigned += 1;
                }
                pos += r.end_off;
            },
            'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A' => {
                while (pos < input.len and isScanWs(input[pos])) pos += 1;
                if (pos >= input.len) break;
                var slice = input[pos..];
                if (width) |w| {
                    if (slice.len > w) slice = slice[0..w];
                }
                const len = floatPrefixLen(slice);
                if (len == 0) break;
                const v: f64 = std.fmt.parseFloat(f64, slice[0..len]) catch break;
                if (!suppress) {
                    const dst = va.next();
                    if (saw_long) {
                        const p: *align(1) u64 = @ptrFromInt(host_base + dst);
                        p.* = @bitCast(v);
                    } else {
                        // %f (and meaningless %hf): float.
                        const p: *align(1) u32 = @ptrFromInt(host_base + dst);
                        p.* = @bitCast(@as(f32, @floatCast(v)));
                    }
                    assigned += 1;
                }
                pos += len;
            },
            's' => {
                while (pos < input.len and isScanWs(input[pos])) pos += 1;
                if (pos >= input.len) break;
                var end = pos;
                while (end < input.len and !isScanWs(input[end])) end += 1;
                if (width) |w| {
                    if (end - pos > w) end = pos + w;
                }
                if (end == pos) break;
                if (!suppress) {
                    const d = gslice(va.next(), end - pos + 1);
                    @memcpy(d[0 .. end - pos], input[pos..end]);
                    d[end - pos] = 0;
                    assigned += 1;
                }
                pos = end;
            },
            'c' => {
                const n = width orelse 1;
                if (pos + n > input.len) break;
                if (!suppress) {
                    @memcpy(gslice(va.next(), n), input[pos..][0..n]);
                    assigned += 1;
                }
                pos += n;
            },
            'p' => {
                while (pos < input.len and isScanWs(input[pos])) pos += 1;
                if (pos >= input.len) break;
                var slice = input[pos..];
                if (width) |w| {
                    if (slice.len > w) slice = slice[0..w];
                }
                if (std.mem.startsWith(u8, slice, "0x") or std.mem.startsWith(u8, slice, "0X")) {
                    slice = slice[2..];
                }
                const r = parseStrtoulInner(slice, 16);
                if (r.end_off == 0) break;
                // end_off is relative to the stripped slice; add the prefix.
                const consumed = (input[pos..].len - slice.len) + r.end_off;
                if (!suppress) {
                    writeGuestInt(va.next(), @bitCast(r.value), 0);
                    assigned += 1;
                }
                pos += consumed;
            },
            '[' => {
                // Scanset: %[abc], %[^abc], ranges a-z. No ws skipping.
                if (i < fmt.len and fmt[i] == '^') {
                    // Negated set.
                    i += 1;
                    var set: [256]bool = @splat(true);
                    if (i < fmt.len and fmt[i] == ']') {
                        set[']'] = false;
                        i += 1;
                    }
                    while (i < fmt.len and fmt[i] != ']') : (i += 1) {
                        if (i + 2 < fmt.len and fmt[i + 1] == '-' and fmt[i + 2] != ']') {
                            var rc: u16 = fmt[i];
                            while (rc <= fmt[i + 2]) : (rc += 1) set[rc] = false;
                            i += 2;
                        } else {
                            set[fmt[i]] = false;
                        }
                    }
                    if (i < fmt.len) i += 1; // consume ']'
                    var end = pos;
                    const lim = if (width) |w| @min(input.len, pos + w) else input.len;
                    while (end < lim and set[input[end]]) end += 1;
                    if (end == pos) break;
                    if (!suppress) {
                        const d = gslice(va.next(), end - pos + 1);
                        @memcpy(d[0 .. end - pos], input[pos..end]);
                        d[end - pos] = 0;
                        assigned += 1;
                    }
                    pos = end;
                } else {
                    var set: [256]bool = @splat(false);
                    if (i < fmt.len and fmt[i] == ']') {
                        set[']'] = true;
                        i += 1;
                    }
                    while (i < fmt.len and fmt[i] != ']') : (i += 1) {
                        if (i + 2 < fmt.len and fmt[i + 1] == '-' and fmt[i + 2] != ']') {
                            var rc: u16 = fmt[i];
                            while (rc <= fmt[i + 2]) : (rc += 1) set[rc] = true;
                            i += 2;
                        } else {
                            set[fmt[i]] = true;
                        }
                    }
                    if (i < fmt.len) i += 1;
                    var end = pos;
                    const lim = if (width) |w| @min(input.len, pos + w) else input.len;
                    while (end < lim and set[input[end]]) end += 1;
                    if (end == pos) break;
                    if (!suppress) {
                        const d = gslice(va.next(), end - pos + 1);
                        @memcpy(d[0 .. end - pos], input[pos..end]);
                        d[end - pos] = 0;
                        assigned += 1;
                    }
                    pos = end;
                }
            },
            'n' => {
                if (!suppress) {
                    writeGuestInt(va.next(), @intCast(pos), len_mod);
                }
            },
            else => std.debug.panic("sscanf: unsupported specifier '%{c}' in \"{s}\"", .{ spec, fmt }),
        }
    }
    if (assigned == 0 and pos >= input.len) return -1; // EOF
    return assigned;
}

export fn tramp_sscanf(s: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = mem;
    var va = guestVa(s, 2);
    ret(s, @bitCast(vsscanf(gstr(arg(s, 0)), gstr(arg(s, 1)), &va)));
}

// ---------------------------------------------------------------------------
// Dispatch: the engine maps lifted `import_<sym>` calls through here.
// ---------------------------------------------------------------------------

const Entry = struct {
    name: []const u8,
    f: *const TrampFn,
};

/// All 52 adapters: the guest's 26 libc imports, plus the string/stdlib/
/// stdio surface the guest doesn't currently call (each tested; kept so a
/// guest change that adds an import keeps working).
pub const table = [_]Entry{
    .{ .name = "memmove", .f = tramp_memmove },
    .{ .name = "memcpy", .f = tramp_memcpy },
    .{ .name = "memset", .f = tramp_memset },
    .{ .name = "memcmp", .f = tramp_memcmp },
    .{ .name = "strlen", .f = tramp_strlen },
    .{ .name = "strcpy", .f = tramp_strcpy },
    .{ .name = "strncpy", .f = tramp_strncpy },
    .{ .name = "strcat", .f = tramp_strcat },
    .{ .name = "strcmp", .f = tramp_strcmp },
    .{ .name = "strncmp", .f = tramp_strncmp },
    .{ .name = "strchr", .f = tramp_strchr },
    .{ .name = "strrchr", .f = tramp_strrchr },
    .{ .name = "strspn", .f = tramp_strspn },
    .{ .name = "strcspn", .f = tramp_strcspn },
    .{ .name = "strpbrk", .f = tramp_strpbrk },
    .{ .name = "strtol", .f = tramp_strtol },
    .{ .name = "strtoul", .f = tramp_strtoul },
    .{ .name = "atoi", .f = tramp_atoi },
    .{ .name = "atol", .f = tramp_atol },
    .{ .name = "atof", .f = tramp_atof },
    .{ .name = "strtod", .f = tramp_strtod },
    .{ .name = "abs", .f = tramp_abs },
    .{ .name = "sqrt", .f = tramp_sqrt },
    .{ .name = "tolower", .f = tramp_tolower },
    .{ .name = "toupper", .f = tramp_toupper },
    .{ .name = "rand", .f = tramp_rand },
    .{ .name = "malloc", .f = tramp_malloc },
    .{ .name = "free", .f = tramp_free },
    .{ .name = "exit", .f = tramp_exit },
    .{ .name = "atexit", .f = tramp_atexit },
    .{ .name = "clock", .f = tramp_clock },
    .{ .name = "fopen", .f = tramp_fopen },
    .{ .name = "fclose", .f = tramp_fclose },
    .{ .name = "fread", .f = tramp_fread },
    .{ .name = "fwrite", .f = tramp_fwrite },
    .{ .name = "fseek", .f = tramp_fseek },
    .{ .name = "ftell", .f = tramp_ftell },
    .{ .name = "rewind", .f = tramp_rewind },
    .{ .name = "fputs", .f = tramp_fputs },
    .{ .name = "putc", .f = tramp_putc },
    .{ .name = "fputc", .f = tramp_fputc },
    .{ .name = "putchar", .f = tramp_putchar },
    .{ .name = "puts", .f = tramp_puts },
    .{ .name = "fflush", .f = tramp_fflush },
    .{ .name = "remove", .f = tramp_remove },
    .{ .name = "unlink", .f = tramp_unlink },
    .{ .name = "getcwd", .f = tramp_getcwd },
    .{ .name = "printf", .f = tramp_printf },
    .{ .name = "sprintf", .f = tramp_sprintf },
    .{ .name = "fprintf", .f = tramp_fprintf },
    .{ .name = "vfprintf", .f = tramp_vfprintf },
    .{ .name = "sscanf", .f = tramp_sscanf },
};

/// Resolve an import name (with or without the guest's `_` prefix) to its
/// adapter, or NULL when the engine must handle it (C_* hooks) or fail.
export fn zffe_tramp_resolve(name_ptr: [*:0]const u8) ?*const TrampFn {
    const name = std.mem.span(name_ptr);
    const bare = if (std.mem.startsWith(u8, name, "_")) name[1..] else name;
    for (table) |e| {
        if (std.mem.eql(u8, e.name, bare)) return e.f;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests: fake State + fake guest memory, real adapter calls
// ---------------------------------------------------------------------------

const t = std.testing;

const Fixture = struct {
    h: []u8,
    st: []u8,

    fn init(h_buf: []u8, st_buf: []u8, esp: u32) Fixture {
        @memset(h_buf, 0);
        @memset(st_buf, 0);
        host_base = @intFromPtr(h_buf.ptr);
        const fx = Fixture{ .h = h_buf, .st = st_buf };
        fx.setEsp(esp);
        return fx;
    }

    fn statePtr(fx: Fixture) ?*anyopaque {
        return @ptrCast(fx.st.ptr);
    }

    fn setEsp(fx: Fixture, esp: u32) void {
        const p: *align(1) u32 = @ptrCast(fx.st.ptr + state.gpr_rsp);
        p.* = esp;
    }

    fn setArgs(fx: Fixture, vals: []const u32) void {
        const esp: usize = @as(*align(1) const u32, @ptrCast(fx.st.ptr + state.gpr_rsp)).*;
        for (vals, 0..) |v, i| {
            const p: *align(1) u32 = @ptrFromInt(host_base + esp + 4 + 4 * i);
            p.* = v;
        }
    }

    fn eax(fx: Fixture) u32 {
        return @as(*align(1) const u32, @ptrCast(fx.st.ptr + state.gpr_rax)).*;
    }

    fn st0f64(fx: Fixture) f64 {
        const p: *align(1) const u64 = @ptrCast(fx.st.ptr + state.x87_st0);
        return @bitCast(p.*);
    }

    fn putStr(fx: Fixture, addr: u32, s: []const u8) void {
        @memcpy(fx.h[addr..][0..s.len], s);
        fx.h[addr + s.len] = 0;
    }

    fn getStr(fx: Fixture, addr: u32) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(fx.h.ptr + addr)));
    }

    fn putU32(fx: Fixture, addr: u32, v: u32) void {
        const p: *align(1) u32 = @ptrCast(fx.h.ptr + addr);
        p.* = v;
    }

    fn getU32(fx: Fixture, addr: u32) u32 {
        return @as(*align(1) const u32, @ptrCast(fx.h.ptr + addr)).*;
    }
};

test "framework: strlen/args/ret round trip" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    fx.putStr(0x100, "hello");
    fx.setArgs(&[_]u32{0x100});
    tramp_strlen(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 5), fx.eax());
}

test "mem adapters" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    fx.putStr(0x100, "hello world");
    // memcpy
    fx.setArgs(&[_]u32{ 0x200, 0x100, 12 });
    tramp_memcpy(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0x200), fx.eax());
    try t.expectEqualStrings("hello world", fx.getStr(0x200));
    // memmove with overlap (dst > src shifts right; the space at [5] dies)
    fx.setArgs(&[_]u32{ 0x101, 0x100, 5 });
    tramp_memmove(fx.statePtr(), 0, null);
    try t.expectEqualStrings("hhelloworld", fx.getStr(0x100));
    // memset
    fx.setArgs(&[_]u32{ 0x300, 'A', 4 });
    tramp_memset(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0x300), fx.eax());
    try t.expectEqualStrings("AAAA", fx.getStr(0x300));
    // memcmp
    fx.putStr(0x400, "abc");
    fx.putStr(0x410, "abd");
    fx.setArgs(&[_]u32{ 0x400, 0x410, 3 });
    tramp_memcmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, -1), @as(i32, @bitCast(fx.eax())));
    fx.setArgs(&[_]u32{ 0x410, 0x400, 3 });
    tramp_memcmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, 1), @as(i32, @bitCast(fx.eax())));
    fx.setArgs(&[_]u32{ 0x400, 0x400, 3 });
    tramp_memcmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
}

test "string adapters" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    fx.putStr(0x100, "hello");
    fx.putStr(0x200, "hello");
    fx.putStr(0x210, "hellp");
    fx.putStr(0x220, "hell");
    // strcpy / strcat
    fx.setArgs(&[_]u32{ 0x300, 0x100 });
    tramp_strcpy(fx.statePtr(), 0, null);
    try t.expectEqualStrings("hello", fx.getStr(0x300));
    fx.setArgs(&[_]u32{ 0x300, 0x210 });
    tramp_strcat(fx.statePtr(), 0, null);
    try t.expectEqualStrings("hellohellp", fx.getStr(0x300));
    // strncpy pads, and omits NUL when src is long
    fx.setArgs(&[_]u32{ 0x400, 0x100, 8 });
    tramp_strncpy(fx.statePtr(), 0, null);
    try t.expectEqualStrings("hello", fx.getStr(0x400));
    try t.expectEqual(@as(u8, 0), fx.h[0x407]);
    fx.setArgs(&[_]u32{ 0x410, 0x100, 3 });
    tramp_strncpy(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u8, 'h'), fx.h[0x410]);
    try t.expectEqual(@as(u8, 'l'), fx.h[0x412]);
    // strcmp / strncmp
    fx.setArgs(&[_]u32{ 0x100, 0x200 });
    tramp_strcmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{ 0x100, 0x210 });
    tramp_strcmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, -1), @as(i32, @bitCast(fx.eax())));
    fx.setArgs(&[_]u32{ 0x100, 0x220 }); // prefix: longer wins
    tramp_strcmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, 1), @as(i32, @bitCast(fx.eax())));
    fx.setArgs(&[_]u32{ 0x100, 0x210, 4 });
    tramp_strncmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{ 0x100, 0x220, 99 });
    tramp_strncmp(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, 1), @as(i32, @bitCast(fx.eax())));
    // strchr / strrchr incl NUL needle
    fx.setArgs(&[_]u32{ 0x100, 'l' });
    tramp_strchr(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0x102), fx.eax());
    fx.setArgs(&[_]u32{ 0x100, 'l' });
    tramp_strrchr(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0x103), fx.eax());
    fx.setArgs(&[_]u32{ 0x100, 0 });
    tramp_strchr(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0x105), fx.eax());
    fx.setArgs(&[_]u32{ 0x100, 'z' });
    tramp_strchr(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    // spans
    fx.putStr(0x500, "abc123");
    fx.putStr(0x510, "abc");
    fx.putStr(0x520, "123");
    fx.setArgs(&[_]u32{ 0x500, 0x510 });
    tramp_strspn(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 3), fx.eax());
    fx.setArgs(&[_]u32{ 0x500, 0x520 });
    tramp_strcspn(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 3), fx.eax());
    fx.setArgs(&[_]u32{ 0x500, 0x520 });
    tramp_strpbrk(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0x503), fx.eax());
    fx.setArgs(&[_]u32{ 0x500, 0x220 }); // "hell": no match... 'h'? no h in abc123
    tramp_strpbrk(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
}

test "conversion adapters" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    fx.putStr(0x100, "  -42xyz");
    fx.setArgs(&[_]u32{0x100});
    tramp_atoi(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, -42), @as(i32, @bitCast(fx.eax())));
    fx.setArgs(&[_]u32{0x100});
    tramp_atol(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, -42), @as(i32, @bitCast(fx.eax())));
    // strtol with base detection + endptr
    fx.putStr(0x200, "0x10!");
    fx.setArgs(&[_]u32{ 0x200, 0x300, 0 });
    tramp_strtol(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 16), fx.eax());
    try t.expectEqual(@as(u32, 0x204), fx.getU32(0x300));
    fx.putStr(0x210, "010!");
    fx.setArgs(&[_]u32{ 0x210, 0, 0 });
    tramp_strtol(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 8), fx.eax()); // octal
    fx.putStr(0x220, "99999999999999999999!");
    fx.setArgs(&[_]u32{ 0x220, 0x300, 10 });
    tramp_strtol(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, std.math.maxInt(i32)), @as(i32, @bitCast(fx.eax()))); // clamp
    try t.expectEqual(@as(u32, 0x220 + 20), fx.getU32(0x300)); // endptr past digits
    fx.putStr(0x230, "zz");
    fx.setArgs(&[_]u32{ 0x230, 0x300, 10 });
    tramp_strtol(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    try t.expectEqual(@as(u32, 0x230), fx.getU32(0x300)); // no conversion
    // strtoul bit pattern
    fx.putStr(0x240, "4294967295");
    fx.setArgs(&[_]u32{ 0x240, 0, 10 });
    tramp_strtoul(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0xFFFFFFFF), fx.eax());
    fx.putStr(0x260, "-1");
    fx.setArgs(&[_]u32{ 0x260, 0, 10 });
    tramp_strtoul(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0xFFFFFFFF), fx.eax()); // wraps mod 2^32
    // strtol(INT_MIN) must not panic on negation
    fx.putStr(0x270, "-2147483648");
    fx.setArgs(&[_]u32{ 0x270, 0, 10 });
    tramp_strtol(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, std.math.minInt(i32)), @as(i32, @bitCast(fx.eax())));
    // atof / strtod land in ST0
    fx.putStr(0x250, "3.5!");
    fx.setArgs(&[_]u32{0x250});
    tramp_atof(fx.statePtr(), 0, null);
    try t.expectEqual(@as(f64, 3.5), fx.st0f64());
    fx.setArgs(&[_]u32{ 0x250, 0x300 });
    tramp_strtod(fx.statePtr(), 0, null);
    try t.expectEqual(@as(f64, 3.5), fx.st0f64());
    try t.expectEqual(@as(u32, 0x253), fx.getU32(0x300));
    // abs / sqrt / ctype
    fx.setArgs(&[_]u32{@bitCast(@as(i32, -7))});
    tramp_abs(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 7), fx.eax());
    fx.setArgs(&[_]u32{@bitCast(@as(i32, std.math.minInt(i32)))});
    tramp_abs(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, std.math.minInt(i32)), @as(i32, @bitCast(fx.eax())));
    const two: f64 = 2.0;
    fx.putU32(0x1004, @truncate(@as(u64, @bitCast(two))));
    fx.putU32(0x1008, @truncate(@as(u64, @bitCast(two)) >> 32));
    tramp_sqrt(fx.statePtr(), 0, null); // reads double at ESP+4
    try t.expectEqual(@sqrt(@as(f64, 2.0)), fx.st0f64());
    fx.setArgs(&[_]u32{'a'});
    tramp_toupper(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 'A'), fx.eax());
    fx.setArgs(&[_]u32{'Z'});
    tramp_tolower(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 'z'), fx.eax());
    fx.setArgs(&[_]u32{'5'});
    tramp_toupper(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, '5'), fx.eax());
}

test "stdlib adapters: rand, malloc/free, atexit" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    // Heap window [0x2000, 0x3000) inside the fake reservation.
    zffe_tramp_init(@intFromPtr(&h_buf), 0x2000, 0x1000);
    @memset(st_buf[0..], 0);
    const fx = Fixture{ .h = &h_buf, .st = &st_buf };
    fx.setEsp(0x1000);
    // MSVC rand() with seed 1: (1*214013+2531011)>>16 & 0x7FFF = 41.
    rand_seed = 1;
    tramp_rand(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 41), fx.eax());
    tramp_rand(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, (2745024 *% 214013 +% 2531011) >> 16 & 0x7FFF), fx.eax());
    // malloc/free through the guest heap
    fx.setArgs(&[_]u32{100});
    tramp_malloc(fx.statePtr(), 0, null);
    const a = fx.eax();
    try t.expectEqual(@as(u32, 0x2008), a); // base + 8-byte header
    try t.expect(gheap.?.liveBytes() >= 100);
    fx.setArgs(&[_]u32{a});
    tramp_free(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u64, 0), gheap.?.liveBytes());
    fx.setArgs(&[_]u32{0x10000}); // bigger than the window
    tramp_malloc(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    // atexit records
    atexit_len = 0;
    fx.setArgs(&[_]u32{0x401000});
    tramp_atexit(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    try t.expectEqual(@as(u32, 0x401000), atexit_fns[0]);
    // clock returns wall ms (nonzero on any sane system clock)
    tramp_clock(fx.statePtr(), 0, null);
    try t.expect(fx.eax() != 0);
}

test "file adapters round trip" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    const path = "/tmp/zffe_tramp_test.txt";
    fx.putStr(0x100, path);
    fx.putStr(0x200, "w");
    fx.putStr(0x210, "r");
    // Create + write via fwrite/fputs/fputc.
    fx.setArgs(&[_]u32{ 0x100, 0x200 });
    tramp_fopen(fx.statePtr(), 0, null);
    const w = fx.eax();
    try t.expect(w >= 4);
    fx.putStr(0x300, "AB");
    fx.setArgs(&[_]u32{ 0x300, 1, 2, w });
    tramp_fwrite(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 2), fx.eax());
    fx.putStr(0x310, "CD");
    fx.setArgs(&[_]u32{ 0x310, w });
    tramp_fputs(fx.statePtr(), 0, null);
    try t.expect(fx.eax() != @as(u32, @bitCast(@as(i32, -1))));
    fx.setArgs(&[_]u32{ 'E', w });
    tramp_fputc(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 'E'), fx.eax());
    fx.setArgs(&[_]u32{0}); // fflush(NULL) is a no-op success
    tramp_fflush(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{w});
    tramp_fclose(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    // Reopen + seek/tell/rewind/read.
    fx.setArgs(&[_]u32{ 0x100, 0x210 });
    tramp_fopen(fx.statePtr(), 0, null);
    const r = fx.eax();
    try t.expect(r >= 4); // slot 4 likely reused after the close above
    fx.setArgs(&[_]u32{ r, 2, 0 }); // SEEK_SET 2
    tramp_fseek(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{r});
    tramp_ftell(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 2), fx.eax());
    fx.setArgs(&[_]u32{ r, 1, 1 }); // SEEK_CUR +1 -> 3
    tramp_fseek(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{ 0x400, 1, 1, r }); // fread(buf, size, count, stream)
    tramp_fread(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 1), fx.eax()); // one item of size 1: 'D'
    try t.expectEqual(@as(u8, 'D'), fx.h[0x400]);
    fx.setArgs(&[_]u32{r});
    tramp_rewind(fx.statePtr(), 0, null);
    fx.setArgs(&[_]u32{r});
    tramp_ftell(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{ r, @bitCast(@as(i32, -1)), 2 }); // SEEK_END -1
    tramp_fseek(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{r});
    tramp_ftell(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 4), fx.eax()); // "ABCDE" is 5 bytes
    fx.setArgs(&[_]u32{r});
    tramp_fclose(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    // Failures: missing file, bad handle, bad whence.
    fx.putStr(0x500, "/tmp/zffe_tramp_nope_missing.txt");
    fx.setArgs(&[_]u32{ 0x500, 0x210 });
    tramp_fopen(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{99});
    tramp_fclose(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, -1), @as(i32, @bitCast(fx.eax())));
    // getcwd
    fx.setArgs(&[_]u32{ 0x600, 256 });
    tramp_getcwd(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0x600), fx.eax());
    try t.expect(fx.getStr(0x600).len > 1);
    fx.setArgs(&[_]u32{ 0x600, 2 }); // too small
    tramp_getcwd(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    // remove
    fx.setArgs(&[_]u32{0x100});
    tramp_remove(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{0x100}); // again: gone
    tramp_remove(fx.statePtr(), 0, null);
    try t.expectEqual(@as(i32, -1), @as(i32, @bitCast(fx.eax())));
}

test "printf rendering" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    fx.putStr(0x100, "hi");
    var out: [512]u8 = undefined;

    const Case = struct {
        fmt: []const u8,
        words: []const u32,
        want: []const u8,
    };
    const f64words = struct {
        fn w(v: f64) [2]u32 {
            const b: u64 = @bitCast(v);
            return .{ @truncate(b), @truncate(b >> 32) };
        }
    }.w;
    const pi_lo, const pi_hi = f64words(3.14159);
    const e_lo, const e_hi = f64words(12345.678);
    const g_lo, const g_hi = f64words(3.5);
    const cases = [_]Case{
        .{ .fmt = "%d", .words = &[_]u32{@bitCast(@as(i32, -42))}, .want = "-42" },
        .{ .fmt = "%d", .words = &[_]u32{@bitCast(@as(i32, std.math.minInt(i32)))}, .want = "-2147483648" },
        .{ .fmt = "%5d|", .words = &[_]u32{42}, .want = "   42|" },
        .{ .fmt = "%-5d|", .words = &[_]u32{42}, .want = "42   |" },
        .{ .fmt = "%05d", .words = &[_]u32{42}, .want = "00042" },
        .{ .fmt = "%05d", .words = &[_]u32{@bitCast(@as(i32, -42))}, .want = "-0042" },
        .{ .fmt = "%.3d", .words = &[_]u32{42}, .want = "042" },
        .{ .fmt = "%x %X %o %u", .words = &[_]u32{ 255, 255, 8, 0xFFFFFFFF }, .want = "ff FF 10 4294967295" },
        .{ .fmt = "%c", .words = &[_]u32{'A'}, .want = "A" },
        .{ .fmt = "%s", .words = &[_]u32{0x100}, .want = "hi" },
        .{ .fmt = "%.1s", .words = &[_]u32{0x100}, .want = "h" },
        .{ .fmt = "%s", .words = &[_]u32{0}, .want = "(null)" },
        .{ .fmt = "%p", .words = &[_]u32{0x401000}, .want = "0x00401000" },
        .{ .fmt = "100%%", .words = &[_]u32{}, .want = "100%" },
        .{ .fmt = "%f", .words = &[_]u32{ g_lo, g_hi }, .want = "3.500000" },
        .{ .fmt = "%.2f", .words = &[_]u32{ pi_lo, pi_hi }, .want = "3.14" },
        .{ .fmt = "%.2e", .words = &[_]u32{ e_lo, e_hi }, .want = "1.23e+04" },
        .{ .fmt = "%ld %d", .words = &[_]u32{ 7, 8 }, .want = "7 8" },
    };
    for (cases) |cs| {
        var va = VaList{ .words = @ptrCast(cs.words.ptr) };
        const e = vformat(&out, cs.fmt, &va);
        try t.expectEqualStrings(cs.want, out[0..e.pos]);
        try t.expectEqual(cs.want.len, e.total);
    }
    // %n writes the count so far.
    fx.putU32(0x700, 0xDEAD);
    {
        var words = [_]u32{ 0x700, 99 };
        var va = VaList{ .words = &words };
        const e = vformat(&out, "ab%n%d", &va);
        try t.expectEqualStrings("ab99", out[0..e.pos]);
        try t.expectEqual(@as(u32, 2), fx.getU32(0x700));
    }
}

test "sprintf adapter end to end" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    fx.putStr(0x100, "n=%d s=%s");
    fx.putStr(0x200, "ok");
    fx.setArgs(&[_]u32{ 0x300, 0x100, 42, 0x200 });
    tramp_sprintf(fx.statePtr(), 0, null);
    try t.expectEqualStrings("n=42 s=ok", fx.getStr(0x300));
    try t.expectEqual(@as(u32, 9), fx.eax());
}

// printf/puts/putchar write raw bytes to fd 1, which under `zig build test`
// corrupts the runner's --listen IPC and wedges the build. So fd 1 is
// redirected to a scratch file for the duration of this test (restored
// before any expect runs), and the captured bytes are asserted.
test "stdout adapters with captured fd 1" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    const cap_path: [*:0]const u8 = "/tmp/zffe_tramp_stdout_cap.txt";
    const saved = c.dup(1);
    try t.expect(saved >= 0);
    const cap = c.open(cap_path, O.WRONLY | O.CREAT | O.TRUNC, @as(c_uint, 0o666));
    try t.expect(cap >= 0);
    try t.expectEqual(@as(c_int, 1), c.dup2(cap, 1));
    _ = c.close(cap);
    fx.putStr(0x100, "n=%d s=%s");
    fx.putStr(0x200, "ok");
    fx.setArgs(&[_]u32{ 0x100, 7, 0x200 });
    tramp_printf(fx.statePtr(), 0, null);
    const n = fx.eax();
    fx.putStr(0x210, "yo");
    fx.setArgs(&[_]u32{0x210});
    tramp_puts(fx.statePtr(), 0, null);
    const p = fx.eax();
    fx.setArgs(&[_]u32{'!'});
    tramp_putchar(fx.statePtr(), 0, null);
    const ch = fx.eax();
    _ = c.dup2(saved, 1);
    _ = c.close(saved);
    try t.expectEqual(@as(u32, 8), n); // "n=7 s=ok"
    try t.expect(p != @as(u32, @bitCast(@as(i32, -1))));
    try t.expectEqual(@as(u32, '!'), ch);
    const rfd = c.open(cap_path, O.RDONLY, @as(c_uint, 0));
    try t.expect(rfd >= 0);
    var out: [64]u8 = undefined;
    var got: usize = 0;
    while (got < out.len) {
        const k = c.read(rfd, out[got..].ptr, out.len - got);
        if (k <= 0) break;
        got += @intCast(k);
    }
    _ = c.close(rfd);
    _ = c.unlink(cap_path);
    try t.expectEqualStrings("n=7 s=okyo\n!", out[0..got]);
}

test "fprintf/vfprintf adapters to file" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    fx.putStr(0x100, "/tmp/zffe_tramp_fprintf_test.txt");
    fx.putStr(0x200, "w");
    fx.putStr(0x210, "r");
    fx.setArgs(&[_]u32{ 0x100, 0x200 });
    tramp_fopen(fx.statePtr(), 0, null);
    const h = fx.eax();
    try t.expect(h >= 4);
    fx.putStr(0x300, "[%d:%s]");
    fx.putStr(0x310, "v");
    fx.setArgs(&[_]u32{ h, 0x300, 1, 0x310 });
    tramp_fprintf(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 5), fx.eax()); // "[1:v]"
    // vfprintf takes a guest va_list: pointer to consecutive arg words.
    fx.putU32(0x400, 2);
    fx.putU32(0x404, 0x310);
    fx.setArgs(&[_]u32{ h, 0x300, 0x400 });
    tramp_vfprintf(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 5), fx.eax()); // "[2:v]"
    fx.setArgs(&[_]u32{h});
    tramp_fclose(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
    fx.setArgs(&[_]u32{ 0x100, 0x210 });
    tramp_fopen(fx.statePtr(), 0, null);
    const r = fx.eax();
    try t.expect(r >= 4);
    fx.setArgs(&[_]u32{ 0x500, 1, 10, r });
    tramp_fread(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 10), fx.eax());
    try t.expectEqualStrings("[1:v][2:v]", fx.h[0x500..][0..10]);
    fx.setArgs(&[_]u32{r});
    tramp_fclose(fx.statePtr(), 0, null);
    fx.setArgs(&[_]u32{0x100});
    tramp_remove(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 0), fx.eax());
}

test "sscanf conversions" {
    var h_buf: [16384]u8 = undefined;
    var st_buf: [4096]u8 = undefined;
    const fx = Fixture.init(&h_buf, &st_buf, 0x1000);
    // %d %s %x with end-to-end adapter call
    fx.putStr(0x100, "42 hello 0xff");
    fx.putStr(0x200, "%d %s %x");
    fx.setArgs(&[_]u32{ 0x100, 0x200, 0x300, 0x310, 0x320 });
    tramp_sscanf(fx.statePtr(), 0, null);
    try t.expectEqual(@as(u32, 3), fx.eax());
    try t.expectEqual(@as(u32, 42), fx.getU32(0x300));
    try t.expectEqualStrings("hello", fx.getStr(0x310));
    try t.expectEqual(@as(u32, 255), fx.getU32(0x320));
    // Pure-core cases: floats, width, suppression, %n, scanset, %c, literals.
    {
        var words = [_]u32{ 0x330, 0x340 };
        var va = VaList{ .words = &words };
        try t.expectEqual(@as(i32, 2), vsscanf("3.5 2.5", "%f %lf", &va));
        try t.expectEqual(@as(f32, 3.5), @as(f32, @bitCast(fx.getU32(0x330))));
        const d: f64 = @bitCast((@as(u64, fx.getU32(0x344)) << 32) | fx.getU32(0x340));
        try t.expectEqual(@as(f64, 2.5), d);
    }
    {
        var words = [_]u32{ 0x350, 0x354, 0x358 };
        var va = VaList{ .words = &words };
        try t.expectEqual(@as(i32, 2), vsscanf("1234 99", "%2d %*d %d%n", &va));
        try t.expectEqual(@as(u32, 12), fx.getU32(0x350));
        try t.expectEqual(@as(u32, 99), fx.getU32(0x354));
        try t.expectEqual(@as(u32, 7), fx.getU32(0x358)); // "1234 99" is 7 chars
    }
    {
        var words = [_]u32{0x360};
        var va = VaList{ .words = &words };
        try t.expectEqual(@as(i32, 1), vsscanf("abc123", "%[a-z]", &va));
        try t.expectEqualStrings("abc", fx.getStr(0x360));
    }
    {
        var words = [_]u32{ 0x370, 0x371 };
        var va = VaList{ .words = &words };
        try t.expectEqual(@as(i32, 2), vsscanf("XY", "%c%c", &va));
        try t.expectEqual(@as(u8, 'X'), fx.h[0x370]);
        try t.expectEqual(@as(u8, 'Y'), fx.h[0x371]);
    }
    {
        var words = [_]u32{0x380};
        var va = VaList{ .words = &words };
        try t.expectEqual(@as(i32, 1), vsscanf("id=7", "id=%d", &va));
        try t.expectEqual(@as(u32, 7), fx.getU32(0x380));
    }
    {
        var words = [_]u32{0x390};
        var va = VaList{ .words = &words };
        try t.expectEqual(@as(i32, -1), vsscanf("", "%d", &va)); // EOF
    }
    {
        var words = [_]u32{0x390};
        var va = VaList{ .words = &words };
        try t.expectEqual(@as(i32, 0), vsscanf("xyz", "%d", &va)); // no conversion
    }
}

test "dispatch resolves guest imports" {
    try t.expectEqual(@as(usize, 52), table.len);
    // Every adapter resolves by bare and _-prefixed name.
    for (table) |e| {
        var bare_buf: [32]u8 = undefined;
        @memcpy(bare_buf[0..e.name.len], e.name);
        bare_buf[e.name.len] = 0;
        try t.expect(zffe_tramp_resolve(bare_buf[0..e.name.len :0].ptr) != null);
        var pre_buf: [32]u8 = undefined;
        pre_buf[0] = '_';
        @memcpy(pre_buf[1..][0..e.name.len], e.name);
        pre_buf[e.name.len + 1] = 0;
        try t.expectEqual(e.f, zffe_tramp_resolve(pre_buf[0 .. e.name.len + 1 :0].ptr).?);
    }
    // Engine hooks and unknowns resolve to NULL.
    try t.expect(zffe_tramp_resolve("_C_DrawSprite") == null);
    try t.expect(zffe_tramp_resolve("_testhook2") == null);
    try t.expect(zffe_tramp_resolve("nope") == null);
}
