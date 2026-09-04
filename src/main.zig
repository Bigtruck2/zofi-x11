const std = @import("std");
const cli = @import("cli/cli.zig");
const modes = @import("./core/mode.zig");
const cli_errors = @import("cli/error.zig");
const drun = @import("core/drun.zig");
const window = @import("core/popup.zig");
const clip_window = @import("core/clipboard_popup.zig");
const clipboard = @import("core/clipboard.zig");
pub fn main(init: std.process.Init) !void {
    const options: cli.Options = try cli.parse(init);
    if (options.debug) std.log.debug("{}", .{options});
    const selected_mode = options.mode orelse unreachable;
    
    const alloc = init.arena.allocator();
    switch (selected_mode) {
        .drun => {
            const apps = try drun.load(init, alloc, options.debug);
            var popup = try window.Popup.init(init,apps);
    defer popup.deinit();
    try popup.run();
        },
        .clipboard => {
            const entries = try clipboard.load(init, alloc);
            var popup = try clip_window.Popup.init(init, entries);
            defer popup.deinit();
            try popup.run();
            if(options.debug) std.debug.print(
        "greenclip returned {d} entries\n",
        .{entries.len},
    );
        },
    } 
    
    //var ts = std.posix.timespec{
    //    .sec = 3,
    //    .nsec = 0,
    //};

    //_ = std.c.nanosleep(&ts, null);
}
