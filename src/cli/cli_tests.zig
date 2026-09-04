const testing = std.testing;

const std = @import("std");
const cli = @import("cli.zig");
const mode = @import("../core/mode.zig");
const errors = @import("error.zig");

test "parseArgs accepts --show drun" {
    const args = [_][]const u8{
        "zofi",
        "--show",
        "drun",
    };

    const options = try cli.parseArgs(&args);

    try testing.expectEqual(mode.Mode.drun, options.mode.?);
    try testing.expectEqual(false, options.debug);
}

test "parseArgs accepts --show clipboard" {
    const args = [_][]const u8{
        "zofi",
        "--show",
        "clipboard",
    };

    const options = try cli.parseArgs(&args);

    try testing.expectEqual(mode.Mode.clipboard, options.mode.?);
    try testing.expectEqual(false, options.debug);
}

test "parseArgs accepts --debug before --show" {
    const args = [_][]const u8{
        "zofi",
        "--debug",
        "--show",
        "drun",
    };

    const options = try cli.parseArgs(&args);

    try testing.expectEqual(mode.Mode.drun, options.mode.?);
    try testing.expect(options.debug);
}

test "parseArgs accepts --debug after --show" {
    const args = [_][]const u8{
        "zofi",
        "--show",
        "clipboard",
        "--debug",
    };

    const options = try cli.parseArgs(&args);

    try testing.expectEqual(mode.Mode.clipboard, options.mode.?);
    try testing.expect(options.debug);
}

test "parseArgs rejects no arguments" {
    const args = [_][]const u8{"zofi"};

    try testing.expectError(
        errors.OptionError.MissingRequiredOption,
        cli.parseArgs(&args),
    );
}

test "parseArgs rejects --show without a mode" {
    const args = [_][]const u8{
        "zofi",
        "--show",
    };

    try testing.expectError(
        errors.ArgumentError.MissingArgument,
        cli.parseArgs(&args),
    );
}

test "parseArgs rejects an invalid mode" {
    const args = [_][]const u8{
        "zofi",
        "--show",
        "not-a-mode",
    };

    try testing.expectError(
        errors.OptionError.InvalidOptionValue,
        cli.parseArgs(&args),
    );
}
test "parseArgs rejects an unknown option" {
    const args = [_][]const u8{
        "zofi",
        "--wat",
    };

    try testing.expectError(
        errors.ArgumentError.InvalidArgument,
        cli.parseArgs(&args),
    );
}

test "parseArgs returns HelpRequested for --help" {
    const args = [_][]const u8{
        "zofi",
        "--help",
    };

    try testing.expectError(
        error.HelpRequested,
        cli.parseArgs(&args),
    );
}

test "parseArgs returns HelpRequested for -h" {
    const args = [_][]const u8{
        "zofi",
        "-h",
    };

    try testing.expectError(
        error.HelpRequested,
        cli.parseArgs(&args),
    );
}

test "help text contains usage and flags" {
    try testing.expect(std.mem.indexOf(u8, cli.help, "Usage: zofi") != null);
    try testing.expect(std.mem.indexOf(u8, cli.help, "--show <mode>") != null);
    try testing.expect(std.mem.indexOf(u8, cli.help, "--debug") != null);
    try testing.expect(std.mem.indexOf(u8, cli.help, "--help") != null);
}
