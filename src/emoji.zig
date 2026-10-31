//! ASCII stand-ins for emoji, which no printer code page contains. Emoji are
//! looked up by code point (`😀`) or by Slack/Discord style shortcode
//! (`:smile:`). Anything not listed is left for the caller to handle.
const std = @import("std");

const Entry = struct {
    /// Unicode scalar value, or 0 for a shortcode-only alias.
    cp: u21,
    name: []const u8,
    text: []const u8,
};

const entries = [_]Entry{
    .{ .cp = 0x1F600, .name = "grinning", .text = ":D" },
    .{ .cp = 0x1F603, .name = "smiley", .text = ":D" },
    .{ .cp = 0x1F604, .name = "smile", .text = ":D" },
    .{ .cp = 0x1F601, .name = "grin", .text = ":D" },
    .{ .cp = 0x1F60A, .name = "blush", .text = ":)" },
    .{ .cp = 0x1F642, .name = "slightly_smiling_face", .text = ":)" },
    .{ .cp = 0x263A, .name = "smiling_face", .text = ":)" },
    .{ .cp = 0x1F609, .name = "wink", .text = ";)" },
    .{ .cp = 0x1F602, .name = "joy", .text = ":'D" },
    .{ .cp = 0x1F923, .name = "rofl", .text = ":'D" },
    .{ .cp = 0x1F605, .name = "sweat_smile", .text = "^^'" },
    .{ .cp = 0x1F622, .name = "cry", .text = ":'(" },
    .{ .cp = 0x1F62D, .name = "sob", .text = ":'(" },
    .{ .cp = 0x1F61E, .name = "disappointed", .text = ":(" },
    .{ .cp = 0x1F641, .name = "slightly_frowning_face", .text = ":(" },
    .{ .cp = 0x2639, .name = "frowning_face", .text = ":(" },
    .{ .cp = 0x1F62E, .name = "open_mouth", .text = ":O" },
    .{ .cp = 0x1F61B, .name = "stuck_out_tongue", .text = ":P" },
    .{ .cp = 0x1F60E, .name = "sunglasses", .text = "B)" },
    .{ .cp = 0x1F60D, .name = "heart_eyes", .text = "<3" },
    .{ .cp = 0x1F610, .name = "neutral_face", .text = ":|" },
    .{ .cp = 0x1F621, .name = "rage", .text = ">:(" },
    .{ .cp = 0x1F620, .name = "angry", .text = ">:(" },
    .{ .cp = 0x1F914, .name = "thinking", .text = "(hmm)" },
    .{ .cp = 0x1F634, .name = "sleeping", .text = "zzz" },
    .{ .cp = 0x2764, .name = "heart", .text = "<3" },
    .{ .cp = 0x1F494, .name = "broken_heart", .text = "</3" },
    .{ .cp = 0x1F44D, .name = "thumbsup", .text = "+1" },
    .{ .cp = 0, .name = "+1", .text = "+1" },
    .{ .cp = 0x1F44E, .name = "thumbsdown", .text = "-1" },
    .{ .cp = 0, .name = "-1", .text = "-1" },
    .{ .cp = 0x1F44B, .name = "wave", .text = "(wave)" },
    .{ .cp = 0x1F44F, .name = "clap", .text = "(clap)" },
    .{ .cp = 0x1F64F, .name = "pray", .text = "(pray)" },
    .{ .cp = 0x1F440, .name = "eyes", .text = "(eyes)" },
    .{ .cp = 0x2714, .name = "heavy_check_mark", .text = "[x]" },
    .{ .cp = 0x2705, .name = "white_check_mark", .text = "[x]" },
    .{ .cp = 0x2713, .name = "check", .text = "[x]" },
    .{ .cp = 0x274C, .name = "x", .text = "[x]" },
    .{ .cp = 0x2B50, .name = "star", .text = "*" },
    .{ .cp = 0x2728, .name = "sparkles", .text = "*" },
    .{ .cp = 0x1F525, .name = "fire", .text = "(fire)" },
    .{ .cp = 0x1F389, .name = "tada", .text = "\\o/" },
    .{ .cp = 0x1F680, .name = "rocket", .text = "(rocket)" },
    .{ .cp = 0x26A0, .name = "warning", .text = "(!)" },
    .{ .cp = 0x2615, .name = "coffee", .text = "(coffee)" },
    .{ .cp = 0x1F4AF, .name = "100", .text = "100" },
};

/// Joiners, variation selectors and skin tone modifiers. They have no
/// stand-in and are dropped so they don't print as `?` after an emoji.
pub fn isModifier(cp: u21) bool {
    return cp == 0xFE0F or cp == 0x200D or (cp >= 0x1F3FB and cp <= 0x1F3FF);
}

/// The ASCII stand-in for an emoji, or null if there is none.
pub fn fromCodePoint(cp: u21) ?[]const u8 {
    for (entries) |e| {
        if (e.cp == cp) return e.text;
    }
    return null;
}

/// The ASCII stand-in for a shortcode name without colons, or null.
pub fn fromName(name: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.text;
    }
    return null;
}

const max_name = 32;

/// If `s` starts with a known `:shortcode:`, return its stand-in and the
/// number of bytes the shortcode occupies.
pub fn shortcode(s: []const u8) ?struct { text: []const u8, len: usize } {
    if (s.len < 3 or s[0] != ':') return null;
    var n: usize = 1;
    while (n < s.len and n <= max_name) : (n += 1) {
        const c = s[n];
        if (c == ':') break;
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '+' and c != '-') return null;
    } else return null;
    if (n >= s.len or n == 1) return null;
    const text = fromName(s[1..n]) orelse return null;
    return .{ .text = text, .len = n + 1 };
}

test "code points and modifiers" {
    try std.testing.expectEqualStrings("<3", fromCodePoint(0x2764).?);
    try std.testing.expect(fromCodePoint(0x1F9A6) == null);
    try std.testing.expect(isModifier(0xFE0F));
    try std.testing.expect(isModifier(0x1F3FD));
    try std.testing.expect(!isModifier('a'));
}

test "shortcodes" {
    const r = shortcode(":smile: hi").?;
    try std.testing.expectEqualStrings(":D", r.text);
    try std.testing.expectEqual(@as(usize, 7), r.len);
    try std.testing.expectEqualStrings("+1", shortcode(":+1:").?.text);
    try std.testing.expect(shortcode(":nope:") == null);
    try std.testing.expect(shortcode("12:30:45") == null);
    try std.testing.expect(shortcode("::") == null);
    try std.testing.expect(shortcode(":smile") == null);
    try std.testing.expect(shortcode(": smile:") == null);
}
