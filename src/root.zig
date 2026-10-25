//! By convention, root.zig is the root source file when making a package.

pub const bridge = @import("bridge.zig");
pub const guest_heap = @import("guest_heap.zig");
pub const guest_mem = @import("guest_mem.zig");
pub const trampoline = @import("trampoline.zig");

test {
    _ = @import("bridge.zig");
    _ = @import("guest_heap.zig");
    _ = @import("guest_mem.zig");
    _ = @import("trampoline.zig");
}
