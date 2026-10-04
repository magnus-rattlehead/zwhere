const std = @import("std");

pub const swar = @import("swar.zig");
pub const simd = @import("simd.zig");

// Immutable preprocessing can be shared by every worker and every chunk.
pub const Searcher = if ((std.simd.suggestVectorLength(u8) orelse 1) > 1) simd.Searcher else swar.Searcher;

pub fn contains(needle: []const u8, haystack: []const u8) bool {
    return Searcher.init(needle).contains(haystack);
}

test "prepared searchers agree with scalar search across lengths and alignments" {
    const scalar = @import("common.zig").scalarContains;
    var random = std.Random.DefaultPrng.init(0x7a7768657265);
    var needle_buf: [128]u8 = undefined;
    var haystack_buf: [512]u8 = undefined;
    for (0..129) |needle_len| {
        const needle = needle_buf[0..needle_len];
        random.random().bytes(needle);
        const vector = simd.Searcher.init(needle);
        const word = swar.Searcher.init(needle);
        for (0..65) |offset| {
            random.random().bytes(&haystack_buf);
            const haystack = haystack_buf[offset .. 256 + offset];
            try std.testing.expectEqual(scalar(needle, haystack), vector.contains(haystack));
            try std.testing.expectEqual(scalar(needle, haystack), word.contains(haystack));
            // Reuse the same searchers on a different slice, including matches
            // at vector boundaries and at the very end of the input.
            const start = if (offset % 2 == 0) offset else haystack.len - needle.len;
            @memcpy(haystack[start..][0..needle.len], needle);
            try std.testing.expectEqual(scalar(needle, haystack), vector.contains(haystack));
            try std.testing.expectEqual(scalar(needle, haystack), word.contains(haystack));
            try std.testing.expect(!vector.contains(haystack[0..needle.len -| 1]));
            try std.testing.expect(!word.contains(haystack[0..needle.len -| 1]));
        }
    }
}

test "prepared searchers handle repetitive and binary bytes" {
    const scalar = @import("common.zig").scalarContains;
    var haystack = [_]u8{0xff} ** 512;
    var needle = [_]u8{0xff} ** 128;
    needle[127] = 0;
    const vector = simd.Searcher.init(&needle);
    const word = swar.Searcher.init(&needle);
    for (0..haystack.len) |i| {
        haystack[i] = 0;
        try std.testing.expectEqual(scalar(&needle, &haystack), vector.contains(&haystack));
        try std.testing.expectEqual(scalar(&needle, &haystack), word.contains(&haystack));
        haystack[i] = 0xff;
    }
}
