const std = @import("std");

pub const swar = @import("swar.zig");
pub const simd = @import("simd.zig");

pub fn contains(needle: []const u8, haystack: []const u8) bool {
    if (comptime (std.simd.suggestVectorLength(u8) orelse 1) > 1) {
        return simd.contains(needle, haystack);
    }
    return swar.contains(needle, haystack);
}
