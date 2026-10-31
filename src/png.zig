//! Minimal PNG decoder: every color type and bit depth, converted to 8-bit
//! grayscale with transparency composited over white. Interlaced (Adam7)
//! files are not supported.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const image = @import("image.zig");

pub const signature = "\x89PNG\r\n\x1a\n";

pub const Error = error{
    /// Not a PNG, or the file is corrupt (bad chunk order, CRC or data).
    InvalidPng,
    /// A valid PNG using a feature this decoder skips, such as interlacing.
    UnsupportedPng,
    /// The file ends early.
    Truncated,
    /// Zero-sized, or larger than `image.max_dimension`.
    InvalidSize,
} || Allocator.Error;

/// Cap on decompressed pixel data, to bound memory use.
const max_raw_len = 256 << 20;

const Color = enum(u8) { gray = 0, rgb = 2, palette = 3, gray_alpha = 4, rgba = 6 };

/// Decode a PNG file. Caller owns the result.
pub fn decode(allocator: Allocator, bytes: []const u8) Error!image.Gray {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], signature)) return error.InvalidPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var color: Color = .gray;
    var have_header = false;
    var palette: [256][3]u8 = undefined;
    var palette_len: usize = 0;
    var alpha: [256]u8 = @splat(255);
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);

    var pos: usize = signature.len;
    while (true) {
        if (bytes.len - pos < 12) return error.Truncated;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (len > bytes.len - pos - 12) return error.Truncated;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        var crc: std.hash.Crc32 = .init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big)) return error.InvalidPng;
        pos += 12 + len;

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (have_header or data.len != 13) return error.InvalidPng;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            color = std.enums.fromInt(Color, data[9]) orelse return error.InvalidPng;
            if (data[10] != 0 or data[11] != 0) return error.InvalidPng;
            if (data[12] != 0) return error.UnsupportedPng;
            if (width == 0 or height == 0 or width > image.max_dimension or height > image.max_dimension) return error.InvalidSize;
            const depth_ok = switch (color) {
                .gray => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                .palette => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                else => depth == 8 or depth == 16,
            };
            if (!depth_ok) return error.InvalidPng;
            have_header = true;
        } else if (!have_header) {
            return error.InvalidPng;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (data.len == 0 or data.len % 3 != 0 or data.len / 3 > 256) return error.InvalidPng;
            palette_len = data.len / 3;
            for (0..palette_len) |i| palette[i] = data[i * 3 ..][0..3].*;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (color == .palette) @memcpy(alpha[0..@min(data.len, 256)], data[0..@min(data.len, 256)]);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    if (idat.items.len == 0) return error.InvalidPng;
    if (color == .palette and palette_len == 0) return error.InvalidPng;

    const channels: usize = switch (color) {
        .gray, .palette => 1,
        .gray_alpha => 2,
        .rgb => 3,
        .rgba => 4,
    };
    const bits_per_pixel = channels * depth;
    const stride = (@as(usize, width) * bits_per_pixel + 7) / 8;
    const bpp = @max(1, bits_per_pixel / 8);
    const raw_len = (stride + 1) * height;
    if (raw_len > max_raw_len) return error.InvalidSize;

    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    var input: Io.Reader = .fixed(idat.items);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&input, .zlib, &window);
    inflate.reader.readSliceAll(raw) catch return error.InvalidPng;

    const zeros = try allocator.alloc(u8, stride);
    defer allocator.free(zeros);
    @memset(zeros, 0);
    var prev: []const u8 = zeros;
    for (0..height) |y| {
        const line = raw[y * (stride + 1) ..][0 .. stride + 1];
        const row = line[1..];
        try unfilter(line[0], row, prev, bpp);
        prev = row;
    }

    const pixels = try allocator.alloc(u8, @as(usize, width) * height);
    errdefer allocator.free(pixels);
    const bytes_per_sample = depth / 8; // 0 for sub-byte depths
    const mask: u16 = (@as(u16, 1) << @intCast(@min(depth, 8))) - 1;
    for (0..height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..width) |x| {
            pixels[y * width + x] = switch (color) {
                .gray => if (depth < 8)
                    @intCast(@as(u16, unpack(row, x, depth)) * 255 / mask)
                else
                    row[x * bytes_per_sample],
                .palette => blk: {
                    const idx = unpack(row, x, depth);
                    if (idx >= palette_len) return error.InvalidPng;
                    const c = palette[idx];
                    break :blk composite(luma(c[0], c[1], c[2]), alpha[idx]);
                },
                .gray_alpha => composite(row[x * 2 * bytes_per_sample], row[(x * 2 + 1) * bytes_per_sample]),
                .rgb => luma(row[x * 3 * bytes_per_sample], row[(x * 3 + 1) * bytes_per_sample], row[(x * 3 + 2) * bytes_per_sample]),
                .rgba => composite(
                    luma(row[x * 4 * bytes_per_sample], row[(x * 4 + 1) * bytes_per_sample], row[(x * 4 + 2) * bytes_per_sample]),
                    row[(x * 4 + 3) * bytes_per_sample],
                ),
            };
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

/// Read the `x`th sample of `depth` bits (1, 2, 4 or 8) from a row.
fn unpack(row: []const u8, x: usize, depth: u8) u8 {
    if (depth == 8) return row[x];
    const per_byte = 8 / @as(usize, depth);
    const shift: u3 = @intCast(8 - depth * (x % per_byte + 1));
    return (row[x / per_byte] >> shift) & @as(u8, @intCast((@as(u16, 1) << @intCast(depth)) - 1));
}

fn luma(r: u8, g: u8, b: u8) u8 {
    return @intCast((@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114) / 1000);
}

/// Blend `v` over white using `a` as the opacity.
fn composite(v: u8, a: u8) u8 {
    return @intCast((@as(u32, v) * a + 255 * (255 - @as(u32, a))) / 255);
}

fn unfilter(kind: u8, row: []u8, prev: []const u8, bpp: usize) error{InvalidPng}!void {
    if (kind > 4) return error.InvalidPng;
    for (row, 0..) |*px, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b = prev[i];
        const c: u8 = if (i >= bpp) prev[i - bpp] else 0;
        px.* +%= switch (kind) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            else => paeth(a, b, c),
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    return if (pb <= pc) b else c;
}

// Fixtures generated with Python's zlib; filters are chosen to cover Sub, Up, Average and Paeth.
const png_gray8 = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x03\x00\x00\x00\x02\x08\x00\x00\x00\x00\xb8\x1f\x39\xc6\x00\x00\x00\x10\x49\x44\x41\x54\x78\x9c\x63\x64\x68\xa8\x67\xe2\x9a\x22\x0f\x00\x06\xf8\x01\xc0\x9e\x4e\x91\x9d\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const png_rgb8 = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x02\x08\x02\x00\x00\x00\xfd\xd4\x9a\x73\x00\x00\x00\x16\x49\x44\x41\x54\x78\x9c\x63\xf9\xcf\xc0\xc0\xf8\x9f\x81\xb9\x91\xe1\xff\xff\x86\x06\x00\x21\xce\x05\x86\x25\xda\x62\x98\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const png_rgba8 = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f\x8a\x00\x00\x00\x0f\x49\x44\x41\x54\x78\x9c\x63\x60\x60\x60\xf8\x0f\xc4\x0c\x00\x05\x04\x01\x00\xb0\x05\x48\x92\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const png_pal2 = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x05\x00\x00\x00\x01\x02\x03\x00\x00\x00\x6b\x90\x8c\x60\x00\x00\x00\x0c\x50\x4c\x54\x45\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\xff\x01\x1d\x33\x4a\x00\x00\x00\x03\x74\x52\x4e\x53\xff\xff\x00\xd7\xca\x0d\x41\x00\x00\x00\x0b\x49\x44\x41\x54\x78\x9c\x63\x90\x6e\x00\x00\x00\xb9\x00\x9c\x51\x8e\xc1\x4b\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const png_gray1 = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x0a\x00\x00\x00\x01\x01\x00\x00\x00\x00\xcf\x8e\x02\xd3\x00\x00\x00\x0b\x49\x44\x41\x54\x78\x9c\x63\x58\xe5\x00\x00\x01\x97\x00\xeb\x36\xd2\xcb\xd1\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const png_gray16 = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x10\x00\x00\x00\x00\x81\xd9\xfc\x15\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\x60\x60\xf8\xff\x1f\x00\x03\x02\x01\xff\xe6\x77\x0b\xae\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const png_gray_alpha = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x08\x04\x00\x00\x00\x5e\x2b\xb7\x01\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\x48\xf9\x9f\xc2\x00\x00\x05\x5a\x01\xc8\xc2\xa8\xe4\x4a\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

fn expectPixels(expected: []const u8, w: u32, h: u32, bytes: []const u8) !void {
    const gpa = std.testing.allocator;
    const img = try decode(gpa, bytes);
    defer img.deinit(gpa);
    try std.testing.expectEqual(w, img.width);
    try std.testing.expectEqual(h, img.height);
    try std.testing.expectEqualSlices(u8, expected, img.pixels);
}

test "grayscale with Sub and Up filters" {
    try expectPixels(&.{ 0, 128, 255, 10, 20, 30 }, 3, 2, png_gray8);
}

test "rgb with Paeth and Average filters converts to luma" {
    try expectPixels(&.{ 76, 149, 29, 255 }, 2, 2, png_rgb8);
}

test "rgba composites over white" {
    try expectPixels(&.{ 0, 255 }, 2, 1, png_rgba8);
}

test "palette with transparency and 2-bit indexes" {
    try expectPixels(&.{ 0, 255, 255, 29, 255 }, 5, 1, png_pal2);
}

test "1-bit and 16-bit grayscale" {
    try expectPixels(&.{ 255, 0, 255, 0, 255, 0, 255, 0, 0, 255 }, 10, 1, png_gray1);
    try expectPixels(&.{ 0, 255 }, 2, 1, png_gray16);
}

test "gray with alpha" {
    try expectPixels(&.{ 100, 255 }, 2, 1, png_gray_alpha);
}

test "rejects bad files" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidPng, decode(gpa, "GIF89a not a png"));
    try std.testing.expectError(error.Truncated, decode(gpa, png_gray8[0 .. png_gray8.len - 20]));
    var corrupt: [png_gray8.len]u8 = undefined;
    @memcpy(&corrupt, png_gray8);
    corrupt[20] ^= 0xff; // inside IHDR, so the CRC no longer matches
    try std.testing.expectError(error.InvalidPng, decode(gpa, &corrupt));
}
