const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const engine = @import("lifting").engine;

export fn init() void {}

export fn frame() void {}

export fn cleanup() void {}

export fn event(ev: [*c]const sapp.Event) void {
    _ = ev;
}

pub fn main(proc: std.process.Init) !void {
    var guest = try bringUp(proc.io);
    defer engine.deinit(&guest);

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

// Full guest bring-up from <exe-dir>/data/ffe.{bin,map}: reserve, load,
// place, wire heap/trampolines, init state (engine.init), then lift every
// function. Any failure is fatal: without a lifted image there is no guest.
fn bringUp(io: std.Io) !engine.Guest {
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_n = try std.process.executableDirPath(io, &dir_buf);
    const exe_dir = dir_buf[0..dir_n];
    var bin_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var map_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bin_path = try std.fmt.bufPrintSentinel(&bin_buf, "{s}/data/ffe.bin", .{exe_dir}, 0);
    const map_path = try std.fmt.bufPrintSentinel(&map_buf, "{s}/data/ffe.map", .{exe_dir}, 0);

    var guest = engine.init(bin_path, map_path, .{}) catch |err| {
        std.debug.print("guest init failed ({}): {s} {s}\n", .{ err, bin_path, map_path });
        return err;
    };
    errdefer engine.deinit(&guest);

    const n = try engine.liftAll(&guest);
    std.debug.print("lifted {} traces\n", .{n});
    return guest;
}
