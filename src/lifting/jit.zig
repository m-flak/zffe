//! Zig side of the JIT runner (src/jit.cpp).
//!
//! The JIT compiles the lifted module to native code and links the host
//! runtime. Traces are looked up by LLVM symbol name (a map func name, or
//! `sub_<hex>` for synthesized traces) and called with Remill's lifted
//! ABI. See engine.call() for the by-name invocation helper with cdecl
//! argument marshaling.

const std = @import("std");
const bridge = @import("bridge.zig");

/// Remill's lifted-call ABI: every trace is `Memory *trace(State*, pc, mem)`
/// with pc the trace's guest address. The Memory* token is threaded but the
/// guest runtime ignores it, so callers pass NULL and drop the result.
pub const GuestFn = fn (state_ptr: ?*anyopaque, pc: u32, mem: ?*anyopaque) callconv(.c) ?*anyopaque;

pub extern fn zffe_jit_create(img: *bridge.Image) ?*anyopaque;
pub extern fn zffe_jit_lookup(jit: *anyopaque, img: *bridge.Image, name: [*:0]const u8) ?*anyopaque;
pub extern fn zffe_jit_free(jit: ?*anyopaque) void;

pub const Jit = struct {
    ptr: *anyopaque,

    pub const CreateError = error{CreateFailed};

    /// Compile the image's lifted module and link the host runtime.
    /// Consumes the lift session (further zffe_lift fails); on failure the
    /// message is in img.errMsg(). One JIT per process.
    pub fn create(img: *bridge.Image) CreateError!Jit {
        const p = zffe_jit_create(img) orelse return error.CreateFailed;
        return .{ .ptr = p };
    }

    pub const LookupError = error{UnknownSymbol};

    /// Look up a trace's callable address by symbol name.
    pub fn lookup(j: Jit, img: *bridge.Image, name: [:0]const u8) LookupError!*const GuestFn {
        const p = zffe_jit_lookup(j.ptr, img, name.ptr) orelse return error.UnknownSymbol;
        return @ptrCast(@alignCast(p));
    }

    pub fn destroy(j: Jit) void {
        zffe_jit_free(j.ptr);
    }
};
