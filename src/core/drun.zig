const std = @import("std");

pub const DesktopEntry = struct {
    // Stable XDG desktop-file ID, used for deduplication and `gtk-launch`.
    // With this first-level scanner it is the basename, e.g.
    // `org.mozilla.firefox.desktop`.
    id: []const u8,
    name: []const u8,
    exec: []const u8,
    desktop_file_path: []const u8,

    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    icon: ?[]const u8 = null,

    hidden: bool = false,
    no_display: bool = false,
};

const Field = enum {
    name,
    exec,
    generic_name,
    comment,
    icon,
    hidden,
    no_display,
};

var debug_enabled = false;

pub fn load(
    init: std.process.Init,
    arena: std.mem.Allocator,
    debug_val: bool,
) ![]DesktopEntry {
    debug_enabled = debug_val;

    const home = getEnv(init, "HOME") orelse "/home/user";
    const default_data_home = try std.fmt.allocPrint(
        arena,
        "{s}/.local/share",
        .{home},
    );

    const data_home = getEnv(init, "XDG_DATA_HOME") orelse default_data_home;
    const data_dirs = getEnv(init, "XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";

    if (debug_enabled) {
        std.log.debug("XDG_DATA_HOME: {s}", .{data_home});
        std.log.debug("XDG_DATA_DIRS: {s}", .{data_dirs});
    }

    // Keep this ordering. XDG_DATA_HOME has precedence over XDG_DATA_DIRS,
    // and earlier entries in XDG_DATA_DIRS have precedence over later ones.
    const data_path_groups = [_][]const u8{
        data_home,
        data_dirs,
    };

    var files = try getDesktopFilesGroup(
        init,
        data_path_groups[0..],
        arena,
    );
    defer files.deinit(arena);

    const parsed = try parseDesktopFiles(init, files.items, arena);
    return try deduplicateById(arena, parsed);
}

fn getEnv(init: std.process.Init, name: []const u8) ?[]const u8 {
    return init.minimal.environ.getPosix(name);
}

fn fieldFromKey(key: []const u8) ?Field {
    if (std.mem.eql(u8, key, "Name")) return .name;
    if (std.mem.eql(u8, key, "Exec")) return .exec;
    if (std.mem.eql(u8, key, "Icon")) return .icon;
    if (std.mem.eql(u8, key, "Comment")) return .comment;
    if (std.mem.eql(u8, key, "GenericName")) return .generic_name;
    if (std.mem.eql(u8, key, "Hidden")) return .hidden;
    if (std.mem.eql(u8, key, "NoDisplay")) return .no_display;
    return null;
}

fn parseBool(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "1");
}

fn getDesktopFiles(
    init: std.process.Init,
    applications_dir: []const u8,
    arena: std.mem.Allocator,
) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(arena);

    var dir = std.Io.Dir.openDirAbsolute(
        init.io,
        applications_dir,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        // An XDG data directory may not exist. That contributes no entries.
        error.FileNotFound, error.NotDir => return files,
        else => return err,
    };
    defer dir.close(init.io);

    var iter = dir.iterate();
    while (try iter.next(init.io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

        const full_path = try std.fmt.allocPrint(
            arena,
            "{s}/{s}",
            .{ applications_dir, entry.name },
        );

        if (debug_enabled) {
            std.log.debug("desktop file: {s}", .{full_path});
        }

        try files.append(arena, full_path);
    }

    return files;
}

fn getDesktopFilesGroup(
    init: std.process.Init,
    data_path_groups: []const []const u8,
    arena: std.mem.Allocator,
) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(arena);

    for (data_path_groups) |path_group| {
        var paths = std.mem.splitScalar(u8, path_group, ':');
        while (paths.next()) |data_dir| {
            if (data_dir.len == 0) continue;

            const applications_dir = try std.fmt.allocPrint(
                arena,
                "{s}/applications",
                .{data_dir},
            );

            var found = try getDesktopFiles(init, applications_dir, arena);
            defer found.deinit(arena);

            try files.appendSlice(arena, found.items);
        }
    }

    return files;
}

fn parseDesktopFiles(
    init: std.process.Init,
    files: []const []const u8,
    arena: std.mem.Allocator,
) ![]DesktopEntry {
    var entries: std.ArrayList(DesktopEntry) = .empty;
    errdefer entries.deinit(arena);

    for (files) |file_path| {
        var file = std.Io.Dir.openFileAbsolute(init.io, file_path, .{}) catch |err| {
            if (debug_enabled) {
                std.log.warn("could not open {s}: {}", .{ file_path, err });
            }
            continue;
        };
        defer file.close(init.io);

        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(init.io, &buffer);
        const desktop_id = std.fs.path.basename(file_path);

        const entry = parseDesktopText(
            arena,
            desktop_id,
            file_path,
            &reader,
        ) catch |err| {
            if (debug_enabled) {
                std.log.warn("could not parse {s}: {}", .{ file_path, err });
            }
            continue;
        } orelse continue;

        // `Hidden` masks the application. `NoDisplay` means the desktop file
        // is useful for associations but should not appear in normal menus.
        if (entry.hidden or entry.no_display) continue;

        try entries.append(arena, entry);
    }

    return try entries.toOwnedSlice(arena);
}

fn parseDesktopText(
    arena: std.mem.Allocator,
    desktop_id: []const u8,
    file_path: []const u8,
    reader_ptr: *std.Io.File.Reader,
) !?DesktopEntry {
    var reader = reader_ptr.*;

    var name: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var generic_name: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var hidden = false;
    var no_display = false;
    var in_desktop_entry = false;

    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            in_desktop_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }

        if (!in_desktop_entry) continue;

        const equals = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");

        const field = fieldFromKey(key) orelse continue;

        switch (field) {
            .name => name = try arena.dupe(u8, value),
            .exec => exec = try arena.dupe(u8, value),
            .generic_name => generic_name = try arena.dupe(u8, value),
            .comment => comment = try arena.dupe(u8, value),
            .icon => icon = try arena.dupe(u8, value),
            .hidden => hidden = parseBool(value),
            .no_display => no_display = parseBool(value),
        }
    }

    const final_name = name orelse return null;
    const final_exec = exec orelse return null;

    return .{
        .id = try arena.dupe(u8, desktop_id),
        .name = final_name,
        .exec = final_exec,
        .desktop_file_path = try arena.dupe(u8, file_path),
        .generic_name = generic_name,
        .comment = comment,
        .icon = icon,
        .hidden = hidden,
        .no_display = no_display,
    };
}

fn deduplicateById(
    arena: std.mem.Allocator,
    entries: []const DesktopEntry,
) ![]DesktopEntry {
    var seen = std.StringHashMap(void).init(arena);
    var unique: std.ArrayList(DesktopEntry) = .empty;
    errdefer unique.deinit(arena);

    for (entries) |entry| {
        const result = try seen.getOrPut(entry.id);
        if (result.found_existing) continue;

        try unique.append(arena, entry);
    }

    return try unique.toOwnedSlice(arena);
}

