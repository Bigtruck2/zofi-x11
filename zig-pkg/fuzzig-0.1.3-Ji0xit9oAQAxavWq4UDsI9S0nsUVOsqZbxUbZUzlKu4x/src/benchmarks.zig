const std = @import("std");

pub const BenchmarkOptions = struct {
    trials: u32 = 10_000,
    warmup: u32 = 100,
};

pub const BenchmarkResult = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    opts: BenchmarkOptions,
    mean: std.Io.Duration,

    pub fn deinit(_: *Self) void {}

    pub fn printSummary(self: *const Self) void {
        const print = std.debug.print;
        print(
            \\ Benchmark summary for {d} trials:
            \\ Mean: {f}
            \\
        , .{
            self.opts.trials,
            self.mean,
        });
    }
};

fn invoke(comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) void {
    const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    switch (@typeInfo(ReturnType)) {
        .error_union => {
            _ = @call(.never_inline, func, args) catch {
                // std.debug.panic("Benchmarked function returned error {s}", .{err});
            };
        },
        else => _ = @call(.never_inline, func, args),
    }
}

pub fn benchmark(
    io: std.Io,
    alloc: std.mem.Allocator,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
    opts: BenchmarkOptions,
) !BenchmarkResult {
    var count: usize = 0;
    while (count < opts.warmup) : (count += 1) {
        std.mem.doNotOptimizeAway(true);
        invoke(func, args);
    }
    var timer = std.Io.Timestamp.now(io, .awake);
    while (count < opts.trials) : (count += 1) {
        std.mem.doNotOptimizeAway(true);
        invoke(func, args);
    }
    var end = timer.untilNow(io, .awake);
    end.nanoseconds = @divFloor(end.nanoseconds, opts.trials);
    return .{ .alloc = alloc, .opts = opts, .mean = end };
}
