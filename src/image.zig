//! Raster image helpers: parse Netpbm files, scale, and reduce to the 1-bit
//! bitmaps that `Printer.bitmap` prints.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// An 8-bit grayscale image: 0 is black, 255 is white. Rows are tightly packed.
pub const Gray = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: Gray, allocator: Allocator) void {
        allocator.free(self.pixels);
    }
};

/// A 1-bit-per-pixel image. Each row is padded to a whole byte, the most
/// significant bit is the leftmost pixel, and a set bit prints a black dot.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    data: []u8,

    /// Bytes per row.
    pub fn stride(self: Bitmap) usize {
        return (self.width + 7) / 8;
    }

    pub fn deinit(self: Bitmap, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// PNG decoding.
pub const png = @import("png.zig");

pub const ParseError = error{
    /// Not a binary Netpbm file (P4, P5 or P6), or the header is malformed.
    InvalidNetpbm,
    /// The file ends before all pixel data.
    Truncated,
    /// Zero-sized, or larger than `max_dimension`.
    InvalidSize,
} || Allocator.Error;

pub const DecodeError = ParseError || png.Error || error{UnknownFormat};

/// Decode a PNG or binary Netpbm file by sniffing its first bytes. Caller
/// owns the result.
pub fn decode(allocator: Allocator, bytes: []const u8) DecodeError!Gray {
    if (std.mem.startsWith(u8, bytes, png.signature)) return png.decode(allocator, bytes);
    if (bytes.len >= 2 and bytes[0] == 'P') return parseNetpbm(allocator, bytes);
    return error.UnknownFormat;
}

/// Largest accepted width or height, to keep allocations sane.
pub const max_dimension = 1 << 14;

/// Parse a binary Netpbm image: P4 (bitmap), P5 (graymap) or P6 (pixmap).
/// Color is converted to luma. Caller owns the result.
pub fn parseNetpbm(allocator: Allocator, bytes: []const u8) ParseError!Gray {
    if (bytes.len < 2 or bytes[0] != 'P') return error.InvalidNetpbm;
    const kind = bytes[1];
    if (kind != '4' and kind != '5' and kind != '6') return error.InvalidNetpbm;

    var pos: usize = 2;
    const width = try headerNumber(bytes, &pos);
    const height = try headerNumber(bytes, &pos);
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidSize;
    var maxval: u32 = 1;
    if (kind != '4') {
        maxval = try headerNumber(bytes, &pos);
        if (maxval == 0 or maxval > 255) return error.InvalidNetpbm;
    }
    // Exactly one whitespace byte separates the header from the raster.
    if (pos >= bytes.len or !std.ascii.isWhitespace(bytes[pos])) return error.InvalidNetpbm;
    pos += 1;
    const raster = bytes[pos..];

    const pixels = try allocator.alloc(u8, @as(usize, width) * height);
    errdefer allocator.free(pixels);

    switch (kind) {
        '4' => {
            const stride = (width + 7) / 8;
            if (raster.len < stride * height) return error.Truncated;
            for (0..height) |y| {
                for (0..width) |x| {
                    const bit = (raster[y * stride + x / 8] >> @intCast(7 - x % 8)) & 1;
                    // In P4 a set bit is black.
                    pixels[y * width + x] = if (bit == 1) 0 else 255;
                }
            }
        },
        '5' => {
            if (raster.len < pixels.len) return error.Truncated;
            for (pixels, raster[0..pixels.len]) |*dst, v| dst.* = scaleToByte(v, maxval);
        },
        else => {
            if (raster.len < pixels.len * 3) return error.Truncated;
            for (pixels, 0..) |*dst, i| {
                const r: u32 = scaleToByte(raster[i * 3], maxval);
                const g: u32 = scaleToByte(raster[i * 3 + 1], maxval);
                const b: u32 = scaleToByte(raster[i * 3 + 2], maxval);
                // Rec. 601 luma.
                dst.* = @intCast((r * 299 + g * 587 + b * 114) / 1000);
            }
        },
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn scaleToByte(v: u8, maxval: u32) u8 {
    return @intCast(@min(255, @as(u32, v) * 255 / maxval));
}

/// Read the next decimal number from a Netpbm header, skipping whitespace and
/// `#` comments.
fn headerNumber(bytes: []const u8, pos: *usize) ParseError!u32 {
    var i = pos.*;
    while (i < bytes.len) {
        if (std.ascii.isWhitespace(bytes[i])) {
            i += 1;
        } else if (bytes[i] == '#') {
            while (i < bytes.len and bytes[i] != '\n') i += 1;
        } else break;
    }
    const start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == start or i - start > 9) return error.InvalidNetpbm;
    pos.* = i;
    return std.fmt.parseInt(u32, bytes[start..i], 10) catch error.InvalidNetpbm;
}

/// Resize to `new_width`, keeping the aspect ratio. Shrinking averages the
/// covered source pixels (box filter); enlarging repeats pixels. Caller owns
/// the result.
pub fn scale(allocator: Allocator, src: Gray, new_width: u32) ParseError!Gray {
    if (new_width == 0 or new_width > max_dimension) return error.InvalidSize;
    const new_height: u32 = @intCast(@max(1, (@as(u64, src.height) * new_width + src.width / 2) / src.width));
    const out = try allocator.alloc(u8, @as(usize, new_width) * new_height);
    errdefer allocator.free(out);

    for (0..new_height) |dy| {
        const y0 = dy * src.height / new_height;
        const y1 = @max(y0 + 1, (dy + 1) * src.height / new_height);
        for (0..new_width) |dx| {
            const x0 = dx * src.width / new_width;
            const x1 = @max(x0 + 1, (dx + 1) * src.width / new_width);
            var sum: u32 = 0;
            for (y0..y1) |y| {
                for (x0..x1) |x| sum += src.pixels[y * src.width + x];
            }
            out[dy * new_width + dx] = @intCast(sum / @as(u32, @intCast((y1 - y0) * (x1 - x0))));
        }
    }
    return .{ .width = new_width, .height = new_height, .pixels = out };
}

/// Reduce to 1 bit: pixels darker than `level` print black. Caller owns the
/// result.
pub fn threshold(allocator: Allocator, src: Gray, level: u8) Allocator.Error!Bitmap {
    const bmp = try emptyBitmap(allocator, src);
    for (0..src.height) |y| {
        for (0..src.width) |x| {
            if (src.pixels[y * src.width + x] < level) setBlack(bmp, x, y);
        }
    }
    return bmp;
}

/// Reduce to 1 bit with Floyd-Steinberg error diffusion, which keeps
/// photographs and gradients readable. Caller owns the result.
pub fn dither(allocator: Allocator, src: Gray) Allocator.Error!Bitmap {
    const bmp = try emptyBitmap(allocator, src);
    errdefer bmp.deinit(allocator);

    // Two rows of accumulated error, with a one-pixel margin on each side.
    const w = src.width;
    const errs = try allocator.alloc(i32, (w + 2) * 2);
    defer allocator.free(errs);
    @memset(errs, 0);
    var cur = errs[0 .. w + 2];
    var next = errs[w + 2 ..];

    for (0..src.height) |y| {
        @memset(next, 0);
        for (0..w) |x| {
            const old: i32 = @as(i32, src.pixels[y * w + x]) + @divTrunc(cur[x + 1], 16);
            const new: i32 = if (old < 128) 0 else 255;
            if (new == 0) setBlack(bmp, x, y);
            const e = old - new;
            cur[x + 2] += e * 7;
            next[x] += e * 3;
            next[x + 1] += e * 5;
            next[x + 2] += e;
        }
        std.mem.swap([]i32, &cur, &next);
    }
    return bmp;
}

fn emptyBitmap(allocator: Allocator, src: Gray) Allocator.Error!Bitmap {
    const stride = (src.width + 7) / 8;
    const data = try allocator.alloc(u8, stride * src.height);
    @memset(data, 0);
    return .{ .width = src.width, .height = src.height, .data = data };
}

fn setBlack(bmp: Bitmap, x: usize, y: usize) void {
    bmp.data[y * bmp.stride() + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
}

test {
    _ = png;
}

test "decode picks the format" {
    const gpa = std.testing.allocator;
    const img = try decode(gpa, "P5 1 1 255\n\x07");
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{7}, img.pixels);
    try std.testing.expectError(error.UnknownFormat, decode(gpa, "GIF89a"));
}

test "parse P5 and P6" {
    const gpa = std.testing.allocator;
    const p5 = try parseNetpbm(gpa, "P5\n# comment\n2 1\n255\n\x00\xff");
    defer p5.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, p5.pixels);

    const p6 = try parseNetpbm(gpa, "P6 1 1 255\n\xff\x00\x00");
    defer p6.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{76}, p6.pixels);
}

test "parse P4 treats set bits as black" {
    const gpa = std.testing.allocator;
    const img = try parseNetpbm(gpa, "P4\n3 1\n\xa0");
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0 }, img.pixels);
}

test "parse rejects bad input" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidNetpbm, parseNetpbm(gpa, "GIF89a"));
    try std.testing.expectError(error.InvalidNetpbm, parseNetpbm(gpa, "P3\n1 1\n255\n0 0 0"));
    try std.testing.expectError(error.Truncated, parseNetpbm(gpa, "P5\n2 2\n255\n\x00"));
    try std.testing.expectError(error.InvalidSize, parseNetpbm(gpa, "P5\n0 2\n255\n"));
}

test "threshold packs bits MSB first" {
    const gpa = std.testing.allocator;
    var px = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255, 0 };
    const bmp = try threshold(gpa, .{ .width = 9, .height = 1, .pixels = &px }, 128);
    defer bmp.deinit(gpa);
    try std.testing.expectEqual(2, bmp.stride());
    try std.testing.expectEqualSlices(u8, &.{ 0b10101010, 0b10000000 }, bmp.data);
}

test "dither keeps flat black and white" {
    const gpa = std.testing.allocator;
    var black: [16]u8 = @splat(0);
    const b = try dither(gpa, .{ .width = 4, .height = 4, .pixels = &black });
    defer b.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xf0, 0xf0, 0xf0, 0xf0 }, b.data);

    var white: [16]u8 = @splat(255);
    const w = try dither(gpa, .{ .width = 4, .height = 4, .pixels = &white });
    defer w.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, w.data);
}

test "dither renders mid-gray as roughly half black" {
    const gpa = std.testing.allocator;
    var gray: [64]u8 = @splat(128);
    const bmp = try dither(gpa, .{ .width = 8, .height = 8, .pixels = &gray });
    defer bmp.deinit(gpa);
    var black: usize = 0;
    for (bmp.data) |byte| black += @popCount(byte);
    try std.testing.expect(black >= 24 and black <= 40);
}

test "scale averages when shrinking" {
    const gpa = std.testing.allocator;
    var px = [_]u8{ 0, 100, 200, 100 };
    const out = try scale(gpa, .{ .width = 4, .height = 1, .pixels = &px }, 2);
    defer out.deinit(gpa);
    try std.testing.expectEqual(2, out.width);
    try std.testing.expectEqual(1, out.height);
    try std.testing.expectEqualSlices(u8, &.{ 50, 150 }, out.pixels);
}
