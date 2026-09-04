const std = @import("std");
const root = @import("root.zig");
const utils = @import("utils.zig");
const structures = @import("structures.zig");

const code_point = @import("code_point");
const GeneralCategories = @import("GeneralCategories");
const LetterCasing = @import("LetterCasing");
const Normalize = @import("Normalize");

const CharacterType = utils.CharacterType;
const MatrixT = structures.MatrixT;

const AlgorithmType = root.AlgorithmType;
const ScoresType = root.ScoresType;

fn charFromUnicode(c: u21) CharacterType {
    if (LetterCasing.isLower(c)) {
        return .Lower;
    } else if (LetterCasing.isUpper(c)) {
        return .Upper;
    } else if (GeneralCategories.isNumber(c)) {
        return .Number;
    } else if (switch (c) {
        ' ', '\\', '/', '|', '(', ')', '[', ']', '{', '}' => true,
        else => false,
    }) {
        return .HardSeperator;
    } else if (GeneralCategories.isSeparator(c)) {
        return .HardSeperator;
    } else if (GeneralCategories.isPunctuation(c) or GeneralCategories.isSymbol(c) or GeneralCategories.isMark(c)) {
        return .SoftSeperator;
    } else if (GeneralCategories.isControl(c)) {
        return .Empty;
    } else {
        return .Lower; // Maybe .Empty instead ?
    }
}

pub const Unicode = struct {
    pub const Algorithm = AlgorithmType(u21, i32);
    pub const Scores = ScoresType(i32);

    const FunctionTable: Algorithm.FunctionTable(*Unicode) = .{
        .score = scoreFunc,
        .bonus = bonusFunc,
        .isEqual = eqlFunc,
    };

    fn eqlFunc(self: *Unicode, h: u21, n: u21) bool {
        if (GeneralCategories.isSeparator(n) and self.opts.wildcard_spaces) {
            if (GeneralCategories.isLetter(h) or
                GeneralCategories.isNumber(h) or
                GeneralCategories.isSymbol(h))
            {
                return true;
            } else {
                return false;
            }
        } else if (!self.opts.case_sensitive) {
            return LetterCasing.toLower(h) == LetterCasing.toLower(n);
        } else {
            return h == n;
        }
    }

    fn scoreFunc(
        a: *Unicode,
        scores: Scores,
        h: u21,
        n: u21,
    ) ?i32 {
        if (!a.eqlFunc(h, n)) return null;

        if (a.opts.case_penalize and (h != n)) {
            return scores.score_match + a.opts.penalty_case_mistmatch;
        }
        return scores.score_match;
    }

    fn bonusFunc(
        _: *Unicode,
        scores: Scores,
        h: u21,
        n: u21,
    ) i32 {
        const p = charFromUnicode(h);
        const c = charFromUnicode(n);

        return switch (p.roleNextTo(c)) {
            .Head => scores.bonus_head,
            .Camel => scores.bonus_camel,
            .Break => scores.bonus_break,
            .Tail => scores.bonus_tail,
        };
    }

    fn convertString(self: *const Unicode, string: []const u8) ![]const u21 {
        const nfc_result = try Normalize.nfc(self.alg.allocator, string);
        defer nfc_result.deinit(self.alg.allocator);

        var iter = code_point.Iterator{ .bytes = nfc_result.slice };

        var converted_string = std.ArrayList(u21).empty;
        defer converted_string.deinit(self.alg.allocator);

        while (iter.next()) |c| {
            try converted_string.append(self.alg.allocator, c.code);
        }
        return converted_string.toOwnedSlice(self.alg.allocator);
    }

    pub const Options = struct {
        case_sensitive: bool = true,
        case_penalize: bool = false,
        // treat spaces as wildcards for any kind of boundary
        // i.e. match with any `[^a-z,A-Z,0-9]`
        wildcard_spaces: bool = false,

        penalty_case_mistmatch: i32 = -2,

        char_buffer_size: usize = 8192,

        scores: Scores = .{},
    };

    alg: Algorithm,
    opts: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        max_haystack: usize,
        max_needle: usize,
        opts: Options,
    ) !Unicode {
        var alg = try Algorithm.init(allocator, max_haystack, max_needle, opts.scores);
        errdefer alg.deinit();

        return .{
            .alg = alg,
            .opts = opts,
        };
    }

    pub fn deinit(self: *Unicode) void {
        self.alg.deinit();
    }

    /// Compute matching score. Recasts the `u8` array to `u21` to properly
    /// encode unicode characters
    pub fn score(
        self: *Unicode,
        haystack: []const u8,
        needle: []const u8,
    ) !?i32 {
        const haystack_normal = try self.convertString(haystack);
        defer self.alg.allocator.free(haystack_normal);

        const needle_normal = try self.convertString(needle);
        defer self.alg.allocator.free(needle_normal);

        return self.alg.score(
            self,
            FunctionTable,
            haystack_normal,
            needle_normal,
        );
    }

    /// Compute the score and the indices of the matched characters. Recasts
    /// the `u8` array to `u21` to properly encode unicode characters
    pub fn scoreMatches(
        self: *Unicode,
        haystack: []const u8,
        needle: []const u8,
    ) Algorithm.Matches {
        const haystack_normal = self.convertString(haystack);
        defer self.allocator.free(haystack_normal);

        const needle_normal = self.convertString(needle);
        defer self.allocator.free(needle_normal);

        return self.alg.scoreMatches(
            self,
            FunctionTable,
            haystack_normal,
            needle_normal,
        );
    }

    /// Resize pre-allocated buffers to fit a new maximum haystack and
    /// needle size
    pub fn resize(self: *Unicode, max_haystack: usize, max_needle: usize) !void {
        try self.alg.resize(max_haystack, max_needle);
    }

    // Check if buffers have sufficient memory for a given haystack and
    // needle length.
    pub fn hasSize(self: *const Unicode, max_haystack: usize, max_needle: usize) bool {
        return self.alg.hasSize(max_haystack, max_needle);
    }
};

fn doTestScoreUnicode(
    alg: *Unicode,
    haystack: []const u8,
    needle: []const u8,
    comptime score: ?i32,
) !void {
    const s = try alg.score(haystack, needle);
    try std.testing.expectEqual(score, s.?);
}

test "Unicode search" {
    const o = Unicode.Scores{};

    var alg = try Unicode.init(
        std.testing.allocator,
        128,
        32,
        .{},
    );
    defer alg.deinit();

    try doTestScoreUnicode(&alg, "zig⚡ fast", "⚡", o.score_match);
}
