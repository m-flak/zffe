//! By convention, root.zig is the root source file when making a package.

pub const bridge = @import("bridge.zig");
pub const engine = @import("engine.zig");
pub const guest_heap = @import("guest_heap.zig");
pub const guest_mem = @import("guest_mem.zig");
pub const jit = @import("jit.zig");
pub const reservation = @import("reservation.zig");
pub const trampoline = @import("trampoline.zig");

// The C++ shim links against the trampoline C ABI, but no Zig code calls
// it, so reference the exports or they get dead-code-eliminated from
// binaries using this module. (The per-import tramp_* adapters stay alive
// through the resolve table's pointers.)
comptime {
    _ = &trampoline.zffe_tramp_resolve;
    _ = &trampoline.zffe_tramp_init;
    _ = &trampoline.zffe_tramp_set_base;
    _ = &trampoline.zffe_heap_stats;
}

test {
    _ = @import("bridge.zig");
    _ = @import("engine.zig");
    _ = @import("guest_heap.zig");
    _ = @import("guest_mem.zig");
    _ = @import("jit.zig");
    _ = @import("reservation.zig");
    _ = @import("trampoline.zig");
}
