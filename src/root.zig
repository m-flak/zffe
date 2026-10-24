//! By convention, root.zig is the root source file when making a package.

pub const bridge = @import("bridge.zig");

test {
    _ = @import("bridge.zig");
}
