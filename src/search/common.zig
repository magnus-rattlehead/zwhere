const std = @import("std");

// Courtesy of:
// https://github.com/BurntSushi/memchr/blob/2.8.3/src/arch/all/packedpair/default_rank.rs
const R: [256]u8 = .{
    55, 52, 51, 50, 49, 48, 47, 46, 45, 103, 242, 66, 67, 229, 44, 43, // 0x00..0x0F
    42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 56, 32, 31, 30, 29, 28, // 0x10..0x1F
    255, 148, 164, 149, 136, 160, 155, 173, 221, 222, 134, 122, 232, 202, 215, 224, // 0x20..0x2F
    208, 220, 204, 187, 183, 179, 177, 168, 178, 200, 226, 195, 154, 184, 174, 126, // 0x30..0x3F
    120, 191, 157, 194, 170, 189, 162, 161, 150, 193, 142, 137, 171, 176, 185, 167, // 0x40..0x4F
    186, 112, 175, 192, 188, 156, 140, 143, 123, 133, 128, 147, 138, 146, 114, 223, // 0x50..0x5F
    151, 249, 216, 238, 236, 253, 227, 218, 230, 247, 135, 180, 241, 233, 246, 244, // 0x60..0x6F
    231, 139, 245, 243, 251, 235, 201, 196, 240, 214, 152, 182, 205, 181, 127, 27, // 0x70..0x7F
    212, 211, 210, 213, 228, 197, 169, 159, 131, 172, 105, 80, 98, 96, 97, 81, // 0x80..0x8F
    207, 145, 116, 115, 144, 130, 153, 121, 107, 132, 109, 110, 124, 111, 82, 108, // 0x90..0x9F
    118, 141, 113, 129, 119, 125, 165, 117, 92, 106, 83, 72, 99, 93, 65, 79, // 0xA0..0xAF
    166, 237, 163, 199, 190, 225, 209, 203, 198, 217, 219, 206, 234, 248, 158, 239, // 0xB0..0xBF
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xC0..0xCF
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xD0..0xDF
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xE0..0xEF
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xF0..0xFF
};

pub fn rarest(needle: []const u8) ?[2]usize {
    if (needle.len <= 1) {
        return null;
    }

    var first = needle[0];
    var fidx: usize = 0;
    var second = needle[1];
    var sidx: usize = 1;

    if (R[second] < R[first]) {
        std.mem.swap(u8, &first, &second);
        std.mem.swap(usize, &fidx, &sidx);
    }

    for (needle[2..], 2..) |char, i| {
        if (R[char] < R[first]) {
            second = first;
            sidx = fidx;
            first = char;
            fidx = i;
        } else if (char != first and R[char] < R[second]) {
            second = char;
            sidx = i;
        }
    }

    if (fidx == sidx) {
        unreachable;
    }

    return [2]usize{ fidx, sidx };
}

pub fn scalarContains(needle: []const u8, haystack: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    const candidates = haystack.len - needle.len + 1;
    for (0..candidates) |i| {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
