const std = @import("std");
const common = @import("common.zig");

const width = std.simd.suggestVectorLength(u8) orelse 1;

pub const Searcher = struct {
    needle: []const u8,
    first_offset: usize,
    second_offset: usize,
    first: @Vector(width, u8),
    second: @Vector(width, u8),

    pub fn init(needle: []const u8) Searcher {
        const first_offset, const second_offset = common.rarest(needle) orelse .{ 0, 0 };
        return .{
            .needle = needle,
            .first_offset = first_offset,
            .second_offset = second_offset,
            .first = if (needle.len == 0) @splat(0) else @splat(needle[first_offset]),
            .second = if (needle.len == 0) @splat(0) else @splat(needle[second_offset]),
        };
    }

    pub fn contains(self: *const Searcher, haystack: []const u8) bool {
        const needle = self.needle;
        if (needle.len == 0 or needle.len > haystack.len) return false;
        const candidates = haystack.len - needle.len + 1;
        var i: usize = 0;
        while (candidates - i >= width) : (i += width) {
            const a: @Vector(width, u8) = haystack[i + self.first_offset ..][0..width].*;
            const b: @Vector(width, u8) = haystack[i + self.second_offset ..][0..width].*;
            var matches: std.meta.Int(.unsigned, width) = @bitCast((self.first == a) & (self.second == b));
            while (matches != 0) {
                const lane = @ctz(matches);
                if (std.mem.eql(u8, haystack[i + lane ..][0..needle.len], needle)) return true;
                matches &= matches - 1;
            }
        }
        return common.scalarContains(needle, haystack[i..]);
    }
};

pub fn contains(needle: []const u8, haystack: []const u8) bool {
    return Searcher.init(needle).contains(haystack);
}
