const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;

const zffe = @import("zffe");

export fn init() void {}

export fn frame() void {}

export fn cleanup() void {}

export fn event(ev: [*c]const sapp.Event) void {
    _ = ev;
}

pub fn main() !void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .window_title = "zFFE",
        .width = 800,
        .height = 600,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
