const std = @import("std");
const common = @import("common.zig");

const width = @sizeOf(usize);
const ones = std.math.maxInt(usize) / 255;
const low_bits = ones * 0x7f;
const high_bits = ones * 0x80;

fn zeroBytes(word: usize) usize {
    return ~(((word & low_bits) + low_bits) | word | low_bits) & high_bits;
}

pub fn contains(needle: []const u8, haystack: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    const first_offset, const second_offset = common.rarest(needle) orelse .{ 0, 0 };
    const first = ones * needle[first_offset];
    const second = ones * needle[second_offset];
    const candidates = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (candidates - i >= width) : (i += width) {
        const a = std.mem.readInt(usize, haystack[i + first_offset ..][0..width], .little);
        const b = std.mem.readInt(usize, haystack[i + second_offset ..][0..width], .little);
        var mask = zeroBytes(a ^ first) & zeroBytes(b ^ second);
        while (mask != 0) {
            const lane = @ctz(mask) / 8;
            if (std.mem.eql(u8, haystack[i + lane ..][0..needle.len], needle)) return true;
            mask &= mask - 1;
        }
    }
    return common.scalarContains(needle, haystack[i..]);
}
