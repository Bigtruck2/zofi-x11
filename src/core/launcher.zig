const std = @import("std");

pub const LaunchContext = struct {
    files: []const []const u8 = &.{},
    urls: []const []const u8 = &.{},
};

pub const LaunchError = error{
    EmptyExec,
    EmptyExecutable,
    UnterminatedQuote,
    TrailingEscape,
    UnsupportedFieldCode,
    FieldCodeInsideQuotedArgument,
    FieldCodeEmbeddedInArgument,
};

/// Launch a freedesktop Desktop Entry Exec line directly as argv.
/// This never invokes a shell.
pub fn launch(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    exec_line: []const u8,
    app_name: []const u8,
    desktop_file_path: []const u8,
    icon: ?[]const u8,
    context: LaunchContext,
) !void {
    var argv = try buildArgv(
        allocator,
        exec_line,
        app_name,
        desktop_file_path,
        icon,
        context,
    );
    defer deinitArgv(allocator, &argv);

    if (argv.items.len == 0) return error.EmptyExec;
    if (argv.items[0].len == 0) return error.EmptyExecutable;

    if (@import("builtin").mode == .Debug) {
        std.log.debug("launch argv:", .{});
        for (argv.items, 0..) |arg, index| {
            std.log.debug("  [{d}] {s}", .{ index, arg });
        }
    }

    _ = try std.process.spawn(init.io, .{
        .argv = argv.items,
    });
}

/// Build argv without spawning. All returned slices are owned by allocator.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    exec_line: []const u8,
    app_name: []const u8,
    desktop_file_path: []const u8,
    icon: ?[]const u8,
    context: LaunchContext,
) !std.ArrayList([]u8) {
    var tokens = try tokenizeExec(allocator, exec_line);
    defer deinitTokens(allocator, &tokens);

    var argv: std.ArrayList([]u8) = .empty;
    errdefer deinitArgv(allocator, &argv);

    for (tokens.items) |token| {
        try expandToken(
            allocator,
            &argv,
            token.text,
            token.had_quotes,
            app_name,
            desktop_file_path,
            icon,
            context,
        );
    }

    return argv;
}

pub fn deinitArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]u8),
) void {
    for (argv.items) |arg| allocator.free(arg);
    argv.deinit(allocator);
}

const Token = struct {
    text: []u8,
    had_quotes: bool,
};

fn deinitTokens(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
) void {
    for (tokens.items) |token| allocator.free(token.text);
    tokens.deinit(allocator);
}

fn tokenizeExec(
    allocator: std.mem.Allocator,
    exec_line: []const u8,
) !std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer deinitTokens(allocator, &tokens);

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var in_quotes = false;
    var had_quotes = false;
    var token_started = false;
    var i: usize = 0;

    while (i < exec_line.len) {
        const ch = exec_line[i];

        if (!in_quotes and (ch == ' ' or ch == '\t')) {
            if (token_started) {
                try tokens.append(allocator, .{
                    .text = try current.toOwnedSlice(allocator),
                    .had_quotes = had_quotes,
                });
                had_quotes = false;
                token_started = false;
            }
            i += 1;
            continue;
        }

        if (ch == '"') {
            in_quotes = !in_quotes;
            had_quotes = true;
            token_started = true;
            i += 1;
            continue;
        }

        if (ch == '\\') {
            if (i + 1 >= exec_line.len) return error.TrailingEscape;

            const next = exec_line[i + 1];
            if (!in_quotes or next == '"' or next == '\\' or next == '`' or next == '$') {
                try current.append(allocator, next);
                token_started = true;
                i += 2;
                continue;
            }

            try current.append(allocator, '\\');
            token_started = true;
            i += 1;
            continue;
        }

        try current.append(allocator, ch);
        token_started = true;
        i += 1;
    }

    if (in_quotes) return error.UnterminatedQuote;

    if (token_started) {
        try tokens.append(allocator, .{
            .text = try current.toOwnedSlice(allocator),
            .had_quotes = had_quotes,
        });
    }

    return tokens;
}

fn appendOwned(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    try argv.append(allocator, try allocator.dupe(u8, value));
}

fn appendMany(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]u8),
    values: []const []const u8,
) !void {
    for (values) |value| try appendOwned(allocator, argv, value);
}

fn expandToken(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]u8),
    token: []const u8,
    had_quotes: bool,
    app_name: []const u8,
    desktop_file_path: []const u8,
    icon: ?[]const u8,
    context: LaunchContext,
) !void {
    if (token.len == 0) {
        try appendOwned(allocator, argv, token);
        return;
    }

    if (std.mem.eql(u8, token, "%F")) {
        if (had_quotes) return error.FieldCodeInsideQuotedArgument;
        try appendMany(allocator, argv, context.files);
        return;
    }

    if (std.mem.eql(u8, token, "%U")) {
        if (had_quotes) return error.FieldCodeInsideQuotedArgument;
        try appendMany(allocator, argv, context.urls);
        return;
    }

    if (std.mem.eql(u8, token, "%i")) {
        if (had_quotes) return error.FieldCodeInsideQuotedArgument;
        if (icon) |icon_name| {
            try appendOwned(allocator, argv, "--icon");
            try appendOwned(allocator, argv, icon_name);
        }
        return;
    }

    if (std.mem.eql(u8, token, "%f")) {
        if (had_quotes) return error.FieldCodeInsideQuotedArgument;
        if (context.files.len > 0) try appendOwned(allocator, argv, context.files[0]);
        return;
    }

    if (std.mem.eql(u8, token, "%u")) {
        if (had_quotes) return error.FieldCodeInsideQuotedArgument;
        if (context.urls.len > 0) try appendOwned(allocator, argv, context.urls[0]);
        return;
    }

    // Deprecated standalone field codes are intentionally ignored for drun.
    if (std.mem.eql(u8, token, "%d") or
        std.mem.eql(u8, token, "%D") or
        std.mem.eql(u8, token, "%n") or
        std.mem.eql(u8, token, "%N") or
        std.mem.eql(u8, token, "%v") or
        std.mem.eql(u8, token, "%m"))
    {
        return;
    }

    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(allocator);

    var i: usize = 0;
    while (i < token.len) {
        if (token[i] != '%') {
            try expanded.append(allocator, token[i]);
            i += 1;
            continue;
        }

        if (i + 1 >= token.len) return error.UnsupportedFieldCode;

        switch (token[i + 1]) {
            '%' => try expanded.append(allocator, '%'),
            'c' => {
                if (had_quotes) return error.FieldCodeInsideQuotedArgument;
                try expanded.appendSlice(allocator, app_name);
            },
            'k' => {
                if (had_quotes) return error.FieldCodeInsideQuotedArgument;
                try expanded.appendSlice(allocator, desktop_file_path);
            },
            'f', 'F', 'u', 'U', 'i' => return error.FieldCodeEmbeddedInArgument,
            'd', 'D', 'n', 'N', 'v', 'm' => return error.UnsupportedFieldCode,
            else => return error.UnsupportedFieldCode,
        }

        i += 2;
    }

    try argv.append(allocator, try expanded.toOwnedSlice(allocator));
}

test "drun drops empty file fields" {
    const allocator = std.testing.allocator;

    var argv = try buildArgv(
        allocator,
        "winapps excel-o365 %F",
        "Excel",
        "/usr/share/applications/excel.desktop",
        null,
        .{},
    );
    defer deinitArgv(allocator, &argv);

    try std.testing.expectEqual(@as(usize, 2), argv.items.len);
    try std.testing.expectEqualStrings("winapps", argv.items[0]);
    try std.testing.expectEqualStrings("excel-o365", argv.items[1]);
}

test "flatpak forwarding tokens survive" {
    const allocator = std.testing.allocator;

    var argv = try buildArgv(
        allocator,
        "flatpak run --file-forwarding org.mozilla.firefox @@u %u @@",
        "Firefox",
        "/usr/share/applications/org.mozilla.firefox.desktop",
        null,
        .{},
    );
    defer deinitArgv(allocator, &argv);

    try std.testing.expectEqual(@as(usize, 6), argv.items.len);
    try std.testing.expectEqualStrings("@@u", argv.items[4]);
    try std.testing.expectEqualStrings("@@", argv.items[5]);
}

test "quoted argument remains one argv item" {
    const allocator = std.testing.allocator;

    var argv = try buildArgv(
        allocator,
        "app --title=\"hello world\"",
        "App",
        "/tmp/app.desktop",
        null,
        .{},
    );
    defer deinitArgv(allocator, &argv);

    try std.testing.expectEqual(@as(usize, 2), argv.items.len);
    try std.testing.expectEqualStrings("--title=hello world", argv.items[1]);
}

