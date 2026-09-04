const std = @import("std");
const command_error = @import("../cli/error.zig");
pub const Mode = enum { drun, clipboard };
pub fn parseArg(arg: []const u8) !Mode {
    if (std.mem.eql(u8, arg, "drun")) {
        return Mode.drun;
    } else if (std.mem.eql(u8, arg, "clipboard")) {
        return Mode.clipboard;
    } else {
        return command_error.OptionError.InvalidOptionValue;
    }
}
