const std = @import("std");
const drun = @import("drun.zig");
const launcher = @import("launcher.zig");

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
    @cInclude("poll.h");
    @cInclude("time.h");
});

const blink_interval_ns: i128 = 500 * std.time.ns_per_ms;
const default_width: c_uint = 1040;
const default_height: c_uint = 520;
const input_height: c_int = 64;
const padding: c_int = 20;
const caret_width: c_uint = 2;
const max_visible_results: usize = 7;
const row_height: c_int = 64;
const input_font_name = "-misc-fixed-medium-r-normal--20-200-75-75-c-100-iso8859-1";

fn monotonicNowNs() i128 {
    var ts: x11.struct_timespec = undefined;
    if (x11.clock_gettime(x11.CLOCK_MONOTONIC, &ts) != 0) return 0;

    return @as(i128, ts.tv_sec) * std.time.ns_per_s + @as(i128, ts.tv_nsec);
}

pub const Selector = struct {
    query: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(usize) = .empty,
    selected: usize = 0,
    scroll: usize = 0,

    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.matches.deinit(allocator);
    }

    pub fn append(
        self: *Selector,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        try self.query.appendSlice(allocator, bytes);
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn backspace(self: *Selector) void {
        if (self.query.items.len == 0) return;

        var i = self.query.items.len - 1;
        while (i > 0 and (self.query.items[i] & 0b1100_0000) == 0b1000_0000) {
            i -= 1;
        }

        self.query.shrinkRetainingCapacity(i);
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn clear(self: *Selector) void {
        self.query.clearRetainingCapacity();
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn moveUp(self: *Selector) void {
        const count = self.matches.items.len;
        if (count == 0) return;

        self.selected = if (self.selected == 0)
            count - 1
        else
            self.selected - 1;
    }

    pub fn moveDown(self: *Selector) void {
        const count = self.matches.items.len;
        if (count == 0) return;

        self.selected = (self.selected + 1) % count;
    }

    pub fn selectedAppIndex(self: *const Selector) ?usize {
        if (self.matches.items.len == 0) return null;
        return self.matches.items[self.selected];
    }
};

pub const Popup = struct {
    init_state: std.process.Init,
    allocator: std.mem.Allocator,
    apps: []const drun.DesktopEntry,

    display: *x11.Display,
    screen: c_int,
    root: x11.Window,
    window: x11.Window,
    gc: x11.GC,
    font_info: *x11.XFontStruct,

    width: c_uint,
    height: c_uint,
    selector: Selector = .{},
    cursor_visible: bool = true,
    next_cursor_toggle_ns: i128,

    pub fn init(
        init_state: std.process.Init,
        apps: []const drun.DesktopEntry,
    ) !Popup {
        const allocator = init_state.gpa;

        const display = x11.XOpenDisplay(null) orelse return error.NoDisplay;
        errdefer _ = x11.XCloseDisplay(display);

        const screen = x11.XDefaultScreen(display);
        const root = x11.XRootWindow(display, screen);
        const screen_width = x11.XDisplayWidth(display, screen);
        const screen_height = x11.XDisplayHeight(display, screen);
        const x = @divTrunc(screen_width - @as(c_int, @intCast(default_width)), 2);
        const y = @divTrunc(screen_height - @as(c_int, @intCast(default_height)), 2);

        var attrs = std.mem.zeroes(x11.XSetWindowAttributes);
        attrs.override_redirect = x11.True;
        attrs.background_pixel = x11.XWhitePixel(display, screen);

        const window = x11.XCreateWindow(
            display,
            root,
            x,
            y,
            default_width,
            default_height,
            0,
            x11.CopyFromParent,
            x11.InputOutput,
            null,
            x11.CWOverrideRedirect | x11.CWBackPixel,
            &attrs,
        );
        if (window == 0) return error.CouldNotCreateWindow;
        errdefer _ = x11.XDestroyWindow(display, window);

        const gc = x11.XCreateGC(display, window, 0, null);
        if (gc == null) return error.CouldNotCreateGraphicsContext;
        errdefer _ = x11.XFreeGC(display, gc);

        const font_info = x11.XLoadQueryFont(display, input_font_name) orelse
            x11.XLoadQueryFont(display, "10x20") orelse
            x11.XLoadQueryFont(display, "9x15bold") orelse
            x11.XLoadQueryFont(display, "fixed") orelse
            return error.CouldNotLoadFont;
        errdefer _ = x11.XFreeFont(display, font_info);

        _ = x11.XSetFont(display, gc, font_info.*.fid);
        _ = x11.XSelectInput(
            display,
            window,
            x11.ExposureMask |
                x11.KeyPressMask |
                x11.StructureNotifyMask |
                x11.FocusChangeMask,
        );

        _ = x11.XMapRaised(display, window);
        _ = x11.XSetInputFocus(
            display,
            window,
            x11.RevertToParent,
            x11.CurrentTime,
        );

        _ = x11.XFlush(display);

        var popup = Popup{
            .init_state = init_state,
            .allocator = allocator,
            .apps = apps,
            .display = display,
            .screen = screen,
            .root = root,
            .window = window,
            .gc = gc,
            .font_info = font_info,
            .width = default_width,
            .height = default_height,
            .next_cursor_toggle_ns = monotonicNowNs() + blink_interval_ns,
        };
        errdefer popup.selector.deinit(allocator);

        try popup.rerank();
        popup.redraw();
        return popup;
    }

    pub fn deinit(self: *Popup) void {
        self.selector.deinit(self.allocator);
        _ = x11.XFreeFont(self.display, self.font_info);
        _ = x11.XFreeGC(self.display, self.gc);
        _ = x11.XDestroyWindow(self.display, self.window);
        _ = x11.XCloseDisplay(self.display);
    }

    pub fn run(self: *Popup) !void {
        const x_fd = x11.XConnectionNumber(self.display);

        while (true) {
            while (x11.XPending(self.display) > 0) {
                var event: x11.XEvent = undefined;
                _ = x11.XNextEvent(self.display, &event);
                if (try self.handleEvent(&event)) return;
            }

            const now = monotonicNowNs();
            if (now >= self.next_cursor_toggle_ns) {
                self.cursor_visible = !self.cursor_visible;
                self.next_cursor_toggle_ns = now + blink_interval_ns;
                self.redraw();
                continue;
            }

            const remaining_ns = self.next_cursor_toggle_ns - now;
            const timeout_ms_i128 = @divFloor(
                remaining_ns + std.time.ns_per_ms - 1,
                std.time.ns_per_ms,
            );
            const timeout_ms: c_int = @intCast(@min(
                timeout_ms_i128,
                @as(i128, std.math.maxInt(c_int)),
            ));

            var fds = [_]x11.pollfd{.{
                .fd = x_fd,
                .events = x11.POLLIN,
                .revents = 0,
            }};
            if (x11.poll(&fds, 1, timeout_ms) < 0) continue;
        }
    }

    fn handleEvent(self: *Popup, event: *x11.XEvent) !bool {
        switch (event.type) {
            x11.Expose => {
                if (event.xexpose.count == 0) self.redraw();
            },
            x11.ConfigureNotify => {
                self.width = @intCast(event.xconfigure.width);
                self.height = @intCast(event.xconfigure.height);
                self.redraw();
            },
            x11.FocusOut => {
                switch (event.xfocus.mode) {
                    x11.NotifyNormal => return true,
                    x11.NotifyWhileGrabbed => return true,
                    x11.NotifyGrab => return true,
                    x11.NotifyUngrab => return false,
                    else => {},
                }
            },
            x11.KeyPress => return try self.handleKeyPress(&event.xkey),
            else => {},
        }
        return false;
    }

    fn handleKeyPress(self: *Popup, key_event: *x11.XKeyEvent) !bool {
        var keysym: x11.KeySym = x11.NoSymbol;
        var typed: [64]u8 = [_]u8{0} ** 64;

        const n = x11.XLookupString(
            key_event,
            @ptrCast(typed[0..].ptr),
            64,
            &keysym,
            null,
        );

        if (keysym == x11.XK_Escape) return true;

        if (keysym == x11.XK_Return or keysym == x11.XK_KP_Enter) {
            if (self.selector.selectedAppIndex()) |app_index| {
                const app = self.apps[app_index];
                try launcher.launch(
                    self.init_state,
                    self.allocator,
                    app.exec,
                    app.name,
                    app.desktop_file_path,
                    app.icon,
                    .{},
                );
                return true;
            }
            return false;
        }

        if (keysym == x11.XK_Up) {
            self.selector.moveUp();
            self.ensureSelectionVisible();
            self.redraw();
            return false;
        }

        if (keysym == x11.XK_Down) {
            self.selector.moveDown();
            self.ensureSelectionVisible();
            self.redraw();
            return false;
        }

        if (keysym == x11.XK_BackSpace) {
            self.selector.backspace();
            try self.rerank();
            self.resetCursorBlink();
            self.redraw();
            return false;
        }

        if (keysym == x11.XK_u and (key_event.state & x11.ControlMask) != 0) {
            self.selector.clear();
            try self.rerank();
            self.resetCursorBlink();
            self.redraw();
            return false;
        }

        if (n > 0) {
            const count: usize = @intCast(n);
            if (count <= typed.len) {
                try self.selector.append(self.allocator, typed[0..count]);
                try self.rerank();
                self.resetCursorBlink();
                self.redraw();
            }
        }

        return false;
    }

    fn rerank(self: *Popup) !void {
        self.selector.matches.clearRetainingCapacity();
        const query = self.selector.query.items;
        if (query.len == 0) {
            for (self.apps, 0..) |app, app_index| {
                if (std.mem.eql(u8, app.id, "librewolf.desktop")) {
                    try self.selector.matches.append(
                        self.allocator,
                        app_index,
                    );
                    break;
                }
            }
        }

        for (self.apps, 0..) |app, app_index| {
            if (!matchesApp(self.selector.query.items, app)) continue;
            try self.selector.matches.append(self.allocator, app_index);
        }

        self.selector.selected = 0;
        self.selector.scroll = 0;
    }

    fn matchesApp(query: []const u8, app: drun.DesktopEntry) bool {
        return containsIgnoreCase(app.name, query) or
            (if (app.generic_name) |value| containsIgnoreCase(value, query) else false) or
            (if (app.comment) |value| containsIgnoreCase(value, query) else false);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var start: usize = 0;
        while (start + needle.len <= haystack.len) : (start += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
                return true;
            }
        }
        return false;
    }

    fn ensureSelectionVisible(self: *Popup) void {
        const count = self.selector.matches.items.len;
        if (count == 0) {
            self.selector.scroll = 0;
            return;
        }

        if (self.selector.selected < self.selector.scroll) {
            self.selector.scroll = self.selector.selected;
        } else if (self.selector.selected >= self.selector.scroll + max_visible_results) {
            self.selector.scroll = self.selector.selected - max_visible_results + 1;
        }

        const max_scroll = if (count > max_visible_results)
            count - max_visible_results
        else
            0;
        self.selector.scroll = @min(self.selector.scroll, max_scroll);
    }

    fn resetCursorBlink(self: *Popup) void {
        self.cursor_visible = true;
        self.next_cursor_toggle_ns = monotonicNowNs() + blink_interval_ns;
    }

    fn drawText(self: *Popup, x: c_int, baseline_y: c_int, text: []const u8) void {
        if (text.len == 0) return;
        _ = x11.XDrawString(
            self.display,
            self.window,
            self.gc,
            x,
            baseline_y,
            text.ptr,
            @intCast(text.len),
        );
    }

    fn fillRect(
        self: *Popup,
        x: c_int,
        y: c_int,
        width: c_uint,
        height: c_uint,
        color: c_ulong,
    ) void {
        _ = x11.XSetForeground(self.display, self.gc, color);
        _ = x11.XFillRectangle(
            self.display,
            self.window,
            self.gc,
            x,
            y,
            width,
            height,
        );
    }

    pub fn redraw(self: *Popup) void {
        const bg = 0xDBD4BA;
        const fg = x11.XBlackPixel(self.display, self.screen);
        const selected_bg = 0x033070;
        const odd_bg = 0xB5B3AC;
        const selected_fg = bg;

        self.fillRect(0, 0, self.width, self.height, bg);

        const prompt_x = padding;
        const query_x = padding + 28;
        const ascent: c_int = self.font_info.*.ascent;
        const descent: c_int = self.font_info.*.descent;
        const input_baseline = @divTrunc(input_height - (ascent + descent), 2) + ascent;
        const query = self.selector.query.items;

        _ = x11.XSetForeground(self.display, self.gc, fg);
        self.drawText(prompt_x, input_baseline, ">");
        self.drawText(query_x, input_baseline, query);
        self.fillRect(0, input_height - 1, self.width, 1, fg);
        if (self.cursor_visible) {
            const query_width = if (query.len == 0) 0 else x11.XTextWidth(
                self.font_info,
                query.ptr,
                @intCast(query.len),
            );

            const cursor_x = query_x + query_width + 2;
            const cursor_y = input_baseline - ascent;
            const cursor_height: c_uint = @intCast(ascent + descent);

            self.fillRect(cursor_x, cursor_y, caret_width, cursor_height, fg);
        }

        for (0..max_visible_results) |visible_row| {
            const result_index = self.selector.scroll + visible_row;
            if (result_index >= self.selector.matches.items.len) break;

            const app_index = self.selector.matches.items[result_index];
            const app = self.apps[app_index];
            const row_y = input_height + @as(c_int, @intCast(visible_row)) * row_height;
            const is_selected = result_index == self.selector.selected;

            if (is_selected) {
                self.fillRect(
                    8,
                    row_y + 6,
                    self.width - 16,
                    @intCast(row_height - 12),
                    selected_bg,
                );
                _ = x11.XSetForeground(self.display, self.gc, selected_fg);
            } else {
                if (visible_row % 2 == 1) {
                    self.fillRect(
                        8,
                        row_y + 6,
                        self.width - 16,
                        @intCast(row_height - 12),
                        odd_bg,
                    );
                } else {}
                _ = x11.XSetForeground(self.display, self.gc, fg);
            }

            const name_baseline = row_y + 28;
            self.drawText(padding, name_baseline, app.name);

            const subtitle = app.generic_name orelse app.comment orelse "";
            if (subtitle.len > 0) {
                self.drawText(padding, row_y + 52, subtitle);
            }
        }

        _ = x11.XFlush(self.display);
    }
};
