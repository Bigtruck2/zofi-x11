const std = @import("std");

pub const Entry = struct {
    text: []const u8,
};

pub fn load(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) ![]Entry {
    const argv = [_][]const u8{
        "greenclip",
        "print",
    };

    const result = try std.process.run(
        allocator,
        init.io,
        .{
            .argv = &argv,
        },
    );
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err(
            "greenclip print failed: {s}",
            .{result.stderr},
        );
        return error.GreenclipPrintFailed;
    }

    // Preserve stdout for the lifetime of the supplied allocator.
    const stdout = result.stdout;

    var entries = std.ArrayList(Entry).empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");

        if (line.len == 0) continue;

        try entries.append(allocator, .{
            .text = line,
        });
    }

    return try entries.toOwnedSlice(allocator);
}
pub fn copy(
    init: std.process.Init,
    text: []const u8,
) !void {
    const argv = [_][]const u8{
        "xclip",
        "-in",
        "-selection",
        "clipboard",
    };

    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    if (child.stdin) |stdin| {
        try stdin.writeStreamingAll(init.io, text);

        // EOF tells xclip that the full clipboard item has been written.
        stdin.close(init.io);

        // We closed it ourselves, so prevent `wait()` from double-closing it.
        child.stdin = null;
    } else {
        return error.CouldNotOpenXclipStdin;
    }

    const term = try child.wait(init.io);

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.XclipFailed;
        },
        else => return error.XclipFailed,
    }
}
