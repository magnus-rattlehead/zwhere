const std = @import("std");
const common = @import("common.zig");

pub fn contains(needle: []const u8, haystack: []const u8) bool {
    const width = std.simd.suggestVectorLength(u8) orelse 1;
    if (needle.len == 0 or needle.len > haystack.len) return false;
    const first_offset, const second_offset = common.rarest(needle) orelse .{ 0, 0 };
    const first: @Vector(width, u8) = @splat(needle[first_offset]);
    const second: @Vector(width, u8) = @splat(needle[second_offset]);
    const candidates = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (candidates - i >= width) : (i += width) {
        const a: @Vector(width, u8) = haystack[i + first_offset ..][0..width].*;
        const b: @Vector(width, u8) = haystack[i + second_offset ..][0..width].*;
        var matches: std.meta.Int(.unsigned, width) = @bitCast((first == a) & (second == b));
        while (matches != 0) {
            const lane = @ctz(matches);
            if (std.mem.eql(u8, haystack[i + lane ..][0..needle.len], needle)) return true;
            matches &= matches - 1;
        }
    }
    return common.scalarContains(needle, haystack[i..]);
}
