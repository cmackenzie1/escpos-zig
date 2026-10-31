//! Sample receipt that exercises most of the `escpos.Printer` API.
const std = @import("std");
const Io = std.Io;

const escpos = @import("escpos");

const width = escpos.columns_font_a;

const Item = struct { name: []const u8, price_cents: u32 };

const items = [_]Item{
    .{ .name = "Flat White", .price_cents = 450 },
    .{ .name = "Almond Croissant", .price_cents = 395 },
    .{ .name = "Cold Brew", .price_cents = 525 },
};

/// Print the demo receipt. The caller is responsible for flushing the writer.
pub fn print(p: escpos.Printer) (escpos.BarcodeError || escpos.BitmapError || std.mem.Allocator.Error || Io.Writer.Error)!void {
    try p.initialize();
    // WPC1252, so the accented e below prints correctly.
    try p.setCodePage(16);

    // Header
    try p.setAlign(.center);
    try p.setSize(3, 3);
    try p.setBold(true);
    try p.line("ZIG CAFE");
    try p.setSize(1, 1);
    try p.setBold(false);
    try p.line("123 Receipt Street");
    try p.line("Open daily 7am - 7pm");
    try p.feed(1);

    try p.setReverse(true);
    try p.line("  ESC/POS DEMO  ");
    try p.setReverse(false);
    try p.feed(1);

    // Line items
    try p.setAlign(.left);
    try p.rule('=', width);
    var total: u32 = 0;
    for (items) |item| {
        var price_buf: [16]u8 = undefined;
        try p.columns(item.name, money(&price_buf, item.price_cents), width);
        total += item.price_cents;
    }
    try p.rule('-', width);

    // Totals
    var buf: [16]u8 = undefined;
    try p.setBold(true);
    try p.setSize(2, 2);
    try p.columns("TOTAL", money(&buf, total), width / 2);
    try p.setSize(1, 1);
    try p.setBold(false);
    try p.feed(1);

    // Text styles
    try p.setUnderline(.single);
    try p.line("Underline single");
    try p.setUnderline(.double);
    try p.line("Underline double");
    try p.setUnderline(.none);
    try p.setFont(.b);
    try p.line("Font B packs 64 columns into the same 80mm paper width.");
    try p.setFont(.a);
    try p.setAlign(.right);
    try p.line("Right aligned");
    try p.setAlign(.center);
    try p.line("Centered caf\xe9 au lait");
    try p.feed(1);

    // QR code
    try p.line("Scan for the source:");
    try p.qrCodeWith("https://ziglang.org", .{ .module_size = 6, .error_correction = .q });
    try p.feed(1);

    // PDF417
    try p.line("PDF417:");
    try p.pdf417("ESC/POS from Zig", .{ .columns = 4 });
    try p.feed(1);

    // Raster image: a generated gradient, dithered to 1 bit.
    try p.line("Dithered gradient:");
    try gradient(p);
    try p.feed(1);

    // Barcodes
    try p.line("Order barcode:");
    try p.barcode(.code128, "ZIG-0042", .{});
    try p.feed(1);
    try p.barcode(.ean13, "4006381333931", .{ .height = 60 });
    try p.feed(1);

    // Footer
    try p.setBold(true);
    try p.line("Thank you!");
    try p.setBold(false);
    try p.feed(3);
    try p.cut(.partial);
}

fn gradient(p: escpos.Printer) !void {
    const w = 288;
    const h = 32;
    var mem: [w * h + w / 8 * h + (w + 2) * 2 * @sizeOf(i32)]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    const a = fba.allocator();
    const px = try a.alloc(u8, w * h);
    for (0..h) |y| {
        for (0..w) |x| px[y * w + x] = @intCast(x * 255 / (w - 1));
    }
    const bmp = try escpos.image.dither(a, .{ .width = w, .height = h, .pixels = px });
    try p.bitmap(bmp);
}

fn money(buf: []u8, cents: u32) []const u8 {
    return std.fmt.bufPrint(buf, "${d}.{d:0>2}", .{ cents / 100, cents % 100 }) catch unreachable;
}

test "demo emits a cut at the end" {
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try print(.init(&w));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1dVB\x03"));
}
