//! ASCII stand-ins for typographic punctuation (curly quotes, dashes,
//! ellipsis, special spaces, bullets). `Printer.textUtf8` consults this only
//! after the selected code page has failed to encode a character, so code
//! pages that have the real glyph keep it.
const std = @import("std");

/// The ASCII replacement for `cp`, which may be empty (the character is
/// dropped), or null if `cp` is not typographic punctuation.
pub fn fromCodePoint(cp: u21) ?[]const u8 {
    return switch (cp) {
        0x2018, 0x2019, 0x201A, 0x201B, 0x2032 => "'",
        0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x00AB, 0x00BB => "\"",
        0x2010, 0x2011, 0x2012, 0x2013, 0x2212 => "-",
        0x2014, 0x2015 => "--",
        0x2026 => "...",
        0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000 => " ",
        0x2022, 0x2023, 0x25E6, 0x2219 => "*",
        0x00B7 => ".",
        0x00D7 => "x",
        0x00F7 => "/",
        0x2122 => "(TM)",
        // zero-width characters and the soft hyphen
        0x200B...0x200D, 0x2060, 0xFEFF, 0x00AD => "",
        else => null,
    };
}

test "fromCodePoint" {
    const t = std.testing;
    try t.expectEqualStrings("'", fromCodePoint(0x2019).?);
    try t.expectEqualStrings("\"", fromCodePoint(0x201C).?);
    try t.expectEqualStrings("--", fromCodePoint(0x2014).?);
    try t.expectEqualStrings("...", fromCodePoint(0x2026).?);
    try t.expectEqualStrings(" ", fromCodePoint(0x3000).?);
    try t.expectEqualStrings("", fromCodePoint(0x200B).?);
    try t.expectEqualStrings("(TM)", fromCodePoint(0x2122).?);
    try t.expect(fromCodePoint(0x4E2D) == null);
    try t.expect(fromCodePoint('a') == null);
}
