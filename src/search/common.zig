const std = @import("std");

// Courtesy of BurntSushi's memchr
const R: [256]u8 = [128]u8{
    // Control chars
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0,   255, 255, 255, 255, 255, // 0x0A is a \n
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    127, // 0x20 ' '
    18, // 0x21 '!'
    19, // 0x22 '"'
    2, // 0x23 '#'
    3, // 0x24 '$'
    4, // 0x25 '%'
    5, // 0x26 '&'
    20, // 0x27 '''
    21, // 0x28 '('
    22, // 0x29 ')'
    6, // 0x2A '*'
    15, // 0x2B '+'
    23, // 0x2C ','
    16, // 0x2D '-'
    24, // 0x2E '.'
    17, // 0x2F '/'

    30, // 0x30 '0' ... 0x39 '9' (Digits)
    30,
    30,
    30,
    30,
    30,
    30,
    30,
    30,
    30,
    14, // 0x3A ':'
    13, // 0x3B ';'
    11, // 0x3C '<'
    12, // 0x3D '='
    10, // 0x3E '>'
    9, // 0x3F '?'

    7, // 0x40 '@'
    50, // 0x41 'A' through 0x5A 'Z' (Uppercase letters)
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,

    50,
    50,
    50,
    50,
    50,
    50,
    50,
    50,
    35,
    50,
    35,
    8,
    1,
    8,
    0,
    8,
    1, // 0x60 '`'
    100, // 0x61 'a'
    90, // 0x62 'b'
    85, // 0x63 'c'
    80, // 0x64 'd'
    115, // 0x65 'e'
    92, // 0x66 'f'
    91, // 0x67 'g'
    78, // 0x68 'h'
    110, // 0x69 'i'
    38, // 0x6A 'j'
    40, // 0x6B 'k'
    79, // 0x6C 'l'
    86, // 0x6D 'm'
    112, // 0x6E 'n'
    108, // 0x6F 'o'

    88, // 0x70 'p'
    36, // 0x71 'q'
    113, // 0x72 'r'
    114, // 0x73 's'
    105, // 0x74 't'
    82, // 0x75 'u'
    42, // 0x76 'v'
    89, // 0x77 'w'
    37, // 0x78 'x'
    93, // 0x79 'y'
    35, // 0x7A 'z'
    1, // 0x7B '{'
    0, // 0x7C '|'
    1, // 0x7D '}'
    1, // 0x7E '~'
} ++ [_]u8{255} ** 128;

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
