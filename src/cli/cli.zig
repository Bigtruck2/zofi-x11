const mode = @import("../core/mode.zig");
const std = @import("std");
const cli_errors = @import("error.zig");
pub const help =
    \\Usage: zofi --show <mode> [options]
    \\
    \\Launch zofi in a selected mode.
    \\
    \\Modes:
    \\  drun             Show desktop applications.
    \\  clipboard        Show clipboard history.
    \\
    \\Options:
    \\  --show <mode>    Select the mode to launch.
    \\  --debug          Enable debug output.
    \\  -h, --help       Display this help message and exit.
    \\
    \\Examples:
    \\  zofi --show drun
    \\  zofi --show clipboard --debug
    \\
;
pub const Options = struct { mode: ?mode.Mode = null, debug: bool = false };
pub fn parse(init: std.process.Init) !Options {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("zofi: out of memory\n", .{});
            std.process.exit(134);
        },
        else => {
            std.log.err("argument parsing failed, panicked: {s}", .{@errorName(err)});
            std.process.exit(2);
        },
    };
    return parseArgs(args) catch |err| switch (err) {
        cli_errors.OptionError.MissingRequiredOption => {
            std.debug.print("zofi: Missing Required Option\n" ++ help, .{});
            std.process.exit(2);
        },
        cli_errors.ArgumentError.MissingArgument => {
            std.debug.print("zofi: An Option is Missing an Argument\n" ++ help, .{});
            std.process.exit(2);
        },
        cli_errors.ArgumentError.InvalidArgument => {
            std.debug.print("zofi: An Argumen is Invalid\n" ++ help, .{});
            std.process.exit(2);
        },
        cli_errors.OptionError.InvalidOptionValue => {
            std.debug.print("zofi: The Option Value for an Argument is Invalid\n" ++ help, .{});
            std.process.exit(2);
        },
        cli_errors.CommandError.HelpRequested => {
            try std.Io.File.stdout().writeStreamingAll(init.io, help);
            std.process.exit(0);
        },
        else => {
            std.log.err("argument parsing failed, panicked: {s}", .{@errorName(err)});
            std.process.exit(2);
        },
    };
}
pub fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--show")) {
            i += 1;
            if (i >= args.len) {
                return cli_errors.ArgumentError.MissingArgument;
            }
            const raw_arg = args[i];
            options.mode = try mode.parseArg(raw_arg);
            i += 1;
            continue;
        } else if (std.mem.eql(u8, args[i], "--debug")) {
            options.debug = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            return cli_errors.CommandError.HelpRequested;
        } else {
            if (std.mem.startsWith(u8, args[i], "-")) {
                return cli_errors.ArgumentError.InvalidArgument;
            }
            return cli_errors.OptionError.InvalidOptionValue;
        }
        i += 1;
    }
    if (options.mode == null) {
        return cli_errors.OptionError.MissingRequiredOption;
    }
    return options;
}
