const std = @import("std");
const drun = @import("drun.zig");

const ParsedFixture = struct {
    arena: std.heap.ArenaAllocator,
    entry: ?drun.DesktopEntry,

    fn deinit(self: *ParsedFixture) void {
        self.arena.deinit();
    }
};

fn writeFixture(
    io: std.Io,
    name: []const u8,
    text: []const u8,
) !void {
    var cwd = std.Io.Dir.cwd();

    var file = try cwd.createFile(io, name, .{
        .truncate = true,
    });
    defer file.close(io);

    try file.writeStreamingAll(io, text);
}

fn parseFixture(
    name: []const u8,
    text: []const u8,
) !ParsedFixture {
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();

    try writeFixture(io, name, text);
    defer cwd.deleteFile(io, name) catch {};

    var file = try cwd.openFile(io, name, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    const entry = try drun.parseDesktopText(
        arena.allocator(),
        name,
        &reader,
    );

    return .{
        .arena = arena,
        .entry = entry,
    };
}

test "fieldFromKey recognizes every supported key" {
    try std.testing.expectEqual(
        drun.Field.name,
        drun.fieldFromKey("Name").?,
    );
    try std.testing.expectEqual(
        drun.Field.exec,
        drun.fieldFromKey("Exec").?,
    );
    try std.testing.expectEqual(
        drun.Field.generic_name,
        drun.fieldFromKey("GenericName").?,
    );
    try std.testing.expectEqual(
        drun.Field.comment,
        drun.fieldFromKey("Comment").?,
    );
    try std.testing.expectEqual(
        drun.Field.icon,
        drun.fieldFromKey("Icon").?,
    );
}

test "fieldFromKey rejects unsupported keys" {
    const unsupported = [_][]const u8{
        "",
        "name",
        "NAME",
        "exec",
        "Icon ",
        " Name",
        "Terminal",
        "Type",
        "Path",
        "TryExec",
        "NoDisplay",
        "Name[en_US]",
        "GenericName[en_US]",
        "X-Zofi-Test",
    };

    for (unsupported) |key| {
        try std.testing.expect(drun.fieldFromKey(key) == null);
    }
}

test "parseDesktopText parses required fields" {
    var parsed = try parseFixture(
        "zofi-test-required.desktop",
        "[Desktop Entry]\n" ++
            "Name=Example Editor\n" ++
            "Exec=example-editor --new-window\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Example Editor",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "example-editor --new-window",
        entry.exec,
    );
    try std.testing.expectEqualStrings(
        "zofi-test-required.desktop",
        entry.desktop_file_path,
    );
    try std.testing.expect(entry.generic_name == null);
    try std.testing.expect(entry.comment == null);
    try std.testing.expect(entry.icon == null);
}

test "parseDesktopText parses optional fields" {
    var parsed = try parseFixture(
        "zofi-test-optional.desktop",
        "[Desktop Entry]\n" ++
            "Name=Terminal\n" ++
            "GenericName=Terminal Emulator\n" ++
            "Comment=Use the command line\n" ++
            "Icon=utilities-terminal\n" ++
            "Exec=terminal --working-directory %f\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Terminal",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "terminal --working-directory %f",
        entry.exec,
    );
    try std.testing.expectEqualStrings(
        "Terminal Emulator",
        entry.generic_name.?,
    );
    try std.testing.expectEqualStrings(
        "Use the command line",
        entry.comment.?,
    );
    try std.testing.expectEqualStrings(
        "utilities-terminal",
        entry.icon.?,
    );
}

test "parseDesktopText accepts CRLF line endings" {
    var parsed = try parseFixture(
        "zofi-test-crlf.desktop",
        "[Desktop Entry]\r\n" ++
            "Name=CRLF App\r\n" ++
            "Exec=crlf-app\r\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "CRLF App",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "crlf-app",
        entry.exec,
    );
}

test "parseDesktopText ignores comments blank lines and other groups" {
    var parsed = try parseFixture(
        "zofi-test-groups.desktop",
        "# Comment before any group\n" ++
            "\n" ++
            "[Other Group]\n" ++
            "Name=Ignored Name\n" ++
            "Exec=ignored-command\n" ++
            "\n" ++
            "  # Leading whitespace comment\n" ++
            "[Desktop Entry]\n" ++
            "# Comment in desktop entry\n" ++
            "Name=Correct Name\n" ++
            "Exec=correct-command\n" ++
            "\n" ++
            "[Desktop Action NewWindow]\n" ++
            "Name=Ignored Action Name #comment \n" ++
            "Exec=ignored-action-command\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Correct Name",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "correct-command",
        entry.exec,
    );
}

test "parseDesktopText trims outer whitespace and retains internal spaces" {
    var parsed = try parseFixture(
        "zofi-test-whitespace.desktop",
        " \t [Desktop Entry] \t \r\n" ++
            "\t Name \t = \t Example   App \t \r\n" ++
            " Exec\t=\t example --flag --two \t\r\n" ++
            " GenericName =  Example Category  \n" ++
            " Comment =  An application with  internal spaces  \n" ++
            " Icon =  example-icon  \n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Example   App",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "example --flag --two",
        entry.exec,
    );
    try std.testing.expectEqualStrings(
        "Example Category",
        entry.generic_name.?,
    );
    try std.testing.expectEqualStrings(
        "An application with  internal spaces",
        entry.comment.?,
    );
    try std.testing.expectEqualStrings(
        "example-icon",
        entry.icon.?,
    );
}

test "parseDesktopText retains equals signs in values" {
    var parsed = try parseFixture(
        "zofi-test-equals.desktop",
        "[Desktop Entry]\n" ++
            "Name=Key=Value App\n" ++
            "Exec=env FOO=bar application --option=value\n" ++
            "Comment=A=B=C\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Key=Value App",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "env FOO=bar application --option=value",
        entry.exec,
    );
    try std.testing.expectEqualStrings(
        "A=B=C",
        entry.comment.?,
    );
}

test "parseDesktopText uses the last duplicate value" {
    var parsed = try parseFixture(
        "zofi-test-duplicates.desktop",
        "[Desktop Entry]\n" ++
            "Name=First Name\n" ++
            "Exec=first-command\n" ++
            "Icon=first-icon\n" ++
            "Name=Final Name\n" ++
            "Exec=final-command --arg\n" ++
            "Icon=final-icon\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Final Name",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "final-command --arg",
        entry.exec,
    );
    try std.testing.expectEqualStrings(
        "final-icon",
        entry.icon.?,
    );
}

test "parseDesktopText returns null without Desktop Entry" {
    var parsed = try parseFixture(
        "zofi-test-no-group.desktop",
        "Name=Outside Group\n" ++
            "Exec=not-read\n" ++
            "[Other Group]\n" ++
            "Name=Still Outside\n" ++
            "Exec=also-not-read\n",
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.entry == null);
}

test "parseDesktopText returns null when Name is missing" {
    var parsed = try parseFixture(
        "zofi-test-missing-name.desktop",
        "[Desktop Entry]\n" ++
            "Exec=some-command\n" ++
            "Comment=No display name\n",
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.entry == null);
}

test "parseDesktopText returns null when Exec is missing" {
    var parsed = try parseFixture(
        "zofi-test-missing-exec.desktop",
        "[Desktop Entry]\n" ++
            "Name=No Command\n" ++
            "Icon=application-x-executable\n",
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.entry == null);
}

test "parseDesktopText accepts explicitly empty values" {
    var parsed = try parseFixture(
        "zofi-test-empty-values.desktop",
        "[Desktop Entry]\n" ++
            "Name=\n" ++
            "Exec=\n" ++
            "Comment=\n" ++
            "GenericName=\n" ++
            "Icon=\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings("", entry.name);
    try std.testing.expectEqualStrings("", entry.exec);
    try std.testing.expectEqualStrings("", entry.comment.?);
    try std.testing.expectEqualStrings("", entry.generic_name.?);
    try std.testing.expectEqualStrings("", entry.icon.?);
}

test "parseDesktopText ignores malformed and unsupported lines" {
    var parsed = try parseFixture(
        "zofi-test-malformed.desktop",
        "[Desktop Entry]\n" ++
            "This line has no equals sign\n" ++
            "=value with an empty key\n" ++
            "Terminal=true\n" ++
            "Type=Application\n" ++
            "NoDisplay=true\n" ++
            "Name=Valid App\n" ++
            "Exec=valid-app\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Valid App",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "valid-app",
        entry.exec,
    );
}

test "parseDesktopText stops parsing fields after a new group" {
    var parsed = try parseFixture(
        "zofi-test-group-boundary.desktop",
        "[Desktop Entry]\n" ++
            "Name=Main Application\n" ++
            "Exec=main-command\n" ++
            "[Desktop Action Secondary]\n" ++
            "GenericName=Ignored Generic Name\n" ++
            "Comment=Ignored Comment\n" ++
            "Icon=ignored-icon\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Main Application",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "main-command",
        entry.exec,
    );
    try std.testing.expect(entry.generic_name == null);
    try std.testing.expect(entry.comment == null);
    try std.testing.expect(entry.icon == null);
}

test "parseDesktopText resumes in a later Desktop Entry group" {
    var parsed = try parseFixture(
        "zofi-test-second-desktop-entry.desktop",
        "[Desktop Entry]\n" ++
            "Name=Initial Name\n" ++
            "Exec=initial-command\n" ++
            "[Other Group]\n" ++
            "Name=Ignored Name\n" ++
            "Exec=ignored-command\n" ++
            "[Desktop Entry]\n" ++
            "Name=Replacement Name\n" ++
            "Exec=replacement-command\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Replacement Name",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "replacement-command",
        entry.exec,
    );
}

test "parseDesktopText ignores localized keys" {
    var parsed = try parseFixture(
        "zofi-test-localized.desktop",
        "[Desktop Entry]\n" ++
            "Name[fr]=Application Francaise\n" ++
            "GenericName[fr]=Editeur\n" ++
            "Comment[fr]=Une description\n" ++
            "Name=Fallback Application\n" ++
            "Exec=fallback-application\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Fallback Application",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "fallback-application",
        entry.exec,
    );
    try std.testing.expect(entry.generic_name == null);
    try std.testing.expect(entry.comment == null);
}
test "parseDesktopText parses a final line without a trailing newline" {
    var parsed = try parseFixture(
        "zofi-test-no-final-newline.desktop",
        "[Desktop Entry]\n" ++
            "Name=No Final Newline\n" ++
            "Exec=no-final-newline",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "No Final Newline",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "no-final-newline",
        entry.exec,
    );
}
test "parseDesktopText preserves duplicate desktop-entry values from one file only by final value" {
    var parsed = try parseFixture(
        "zofi-test-duplicate-fields.desktop",
        "[Desktop Entry]\n" ++
            "Name=First Name\n" ++
            "Exec=first-command\n" ++
            "Name=Second Name\n" ++
            "Exec=second-command\n" ++
            "Name=Final Name\n" ++
            "Exec=final-command\n",
    );
    defer parsed.deinit();

    const entry = parsed.entry.?;

    try std.testing.expectEqualStrings(
        "Final Name",
        entry.name,
    );
    try std.testing.expectEqualStrings(
        "final-command",
        entry.exec,
    );
}
