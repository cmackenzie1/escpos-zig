//! Minimal ESC/POS library for Zig: a command builder for Epson thermal
//! receipt printers (tested against the
//! TM-T20III, 80mm paper, 48 columns in Font A).
//!
//! `Printer` writes raw ESC/POS bytes to any `*Io.Writer`, so it can target a
//! device file, a socket, or an in-memory buffer.
const std = @import("std");
const Io = std.Io;

/// Image loading, scaling and 1-bit conversion for `Printer.bitmap`.
pub const image = @import("image.zig");

/// UTF-8 to printer code page conversion tables.
pub const encoding = @import("encoding.zig");

/// Real-time status decoding for `Printer.queryStatus`.
pub const status = @import("status.zig");
pub const Status = status.Status;
pub const Encoding = encoding.Encoding;

/// ESC control byte, the prefix of most ESC/POS commands.
pub const esc = 0x1b;
/// GS control byte, the prefix of ESC/POS extended commands.
pub const gs = 0x1d;
/// Line feed; prints the buffered line and advances the paper.
pub const lf = 0x0a;

/// Horizontal justification for subsequent lines.
pub const Align = enum(u8) {
    left = 0,
    center = 1,
    right = 2,
};

/// Built-in character font.
pub const Font = enum(u8) {
    /// 12x24 dots, 48 columns on 80mm paper.
    a = 0,
    /// 9x17 dots, 64 columns on 80mm paper.
    b = 1,
};

/// Underline thickness.
pub const Underline = enum(u8) {
    none = 0,
    /// 1-dot underline.
    single = 1,
    /// 2-dot underline.
    double = 2,
};

/// How far the cutter blade travels.
pub const CutMode = enum {
    /// Cut the paper completely.
    full,
    /// Leave a small uncut tab so the receipt stays attached.
    partial,
};

/// 1D barcode symbology (GS k, function B).
pub const BarcodeType = enum(u8) {
    /// 11-12 digits; the printer computes the check digit if it is omitted.
    upca = 65,
    /// 6-8, 11 or 12 digits.
    upce = 66,
    /// 12-13 digits; the printer computes the check digit if it is omitted.
    ean13 = 67,
    /// 7-8 digits; the printer computes the check digit if it is omitted.
    ean8 = 68,
    /// Digits, A-Z, space and `$ % + - . /`, optionally wrapped in `*`.
    code39 = 69,
    /// Interleaved 2 of 5: an even number of digits.
    itf = 70,
    /// Digits and `$ + - . / :`, starting and ending with A-D (or a-d).
    codabar = 71,
    /// Any ASCII byte (0-127).
    code93 = 72,
    /// Printable ASCII. Without a leading `{A`, `{B` or `{C` code set
    /// selector, `{B` is prepended automatically.
    code128 = 73,
};

/// Where the human-readable text is printed relative to a barcode.
pub const BarcodeText = enum(u8) {
    none = 0,
    above = 1,
    below = 2,
    both = 3,
};

/// Appearance of a 1D barcode.
pub const BarcodeOptions = struct {
    /// Bar height in dots (1-255). 80 dots is about 10mm at 203 dpi.
    height: u8 = 80,
    /// Width of the narrowest bar in dots (2-6). Wide data at larger widths
    /// can exceed the paper width, in which case the printer prints nothing.
    module_width: u8 = 2,
    /// Placement of the human-readable text.
    text: BarcodeText = .below,
    /// Font of the human-readable text.
    font: Font = .a,
};

/// QR code error correction level: how much damage a symbol can survive, at
/// the cost of a denser symbol.
pub const QrErrorCorrection = enum(u8) {
    /// Recovers about 7% of the symbol.
    l = 48,
    /// Recovers about 15% (the default).
    m = 49,
    /// Recovers about 25%.
    q = 50,
    /// Recovers about 30%.
    h = 51,
};

/// Appearance of a QR code.
pub const QrOptions = struct {
    /// Module (dot) size in dots, 1-16.
    module_size: u8 = 6,
    error_correction: QrErrorCorrection = .m,
};

/// Appearance of a PDF417 symbol.
pub const Pdf417Options = struct {
    /// Number of data columns, 1-30, or 0 to let the printer choose.
    columns: u8 = 0,
    /// Number of rows, 3-90, or 0 to let the printer choose.
    rows: u8 = 0,
    /// Width of the narrowest bar in dots, 2-8.
    module_width: u8 = 3,
    /// Row height as a multiple of the module width, 2-8.
    row_height: u8 = 3,
    /// Error correction level, 0-8. Higher survives more damage.
    error_correction: u8 = 1,
    /// Omit the right-hand row indicators for a narrower symbol.
    truncated: bool = false,
};

pub const BitmapError = error{
    /// The bitmap is empty, too wide for the protocol, or its data is the
    /// wrong length.
    InvalidBitmap,
};

pub const BarcodeError = error{
    /// The data is not valid for the chosen `BarcodeType`.
    InvalidBarcode,
};

/// Characters per line on 80mm paper in Font A.
pub const columns_font_a = 48;
/// Characters per line on 80mm paper in Font B.
pub const columns_font_b = 64;

/// Builds ESC/POS byte streams and writes them to `writer`.
///
/// Output is not flushed by `Printer`; flush the underlying writer when done.
pub const Printer = struct {
    writer: *Io.Writer,

    /// Create a printer that writes to `writer`. Does not send any bytes;
    /// call `initialize` to reset the printer first.
    pub fn init(writer: *Io.Writer) Printer {
        return .{ .writer = writer };
    }

    /// ESC @ - clear buffers and reset modes to defaults.
    pub fn initialize(self: Printer) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, '@' });
    }

    /// Write text as-is (no trailing newline).
    pub fn text(self: Printer, s: []const u8) Io.Writer.Error!void {
        try self.writer.writeAll(s);
    }

    /// Write text followed by a line feed.
    pub fn line(self: Printer, s: []const u8) Io.Writer.Error!void {
        try self.writer.writeAll(s);
        try self.writer.writeByte(lf);
    }

    /// Write formatted text (no trailing newline added).
    pub fn print(self: Printer, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        try self.writer.print(fmt, args);
    }

    /// Feed `n` blank lines.
    pub fn feed(self: Printer, n: u8) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 'd', n });
    }

    /// ESC a n - justification.
    pub fn setAlign(self: Printer, a: Align) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 'a', @backingInt(a) });
    }

    /// ESC E n - emphasized (bold).
    pub fn setBold(self: Printer, on: bool) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 'E', @intFromBool(on) });
    }

    /// ESC - n - underline.
    pub fn setUnderline(self: Printer, u: Underline) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, '-', @backingInt(u) });
    }

    /// GS B n - white/black reverse printing.
    pub fn setReverse(self: Printer, on: bool) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ gs, 'B', @intFromBool(on) });
    }

    /// ESC M n - character font.
    pub fn setFont(self: Printer, f: Font) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 'M', @backingInt(f) });
    }

    /// GS ! n - character size multipliers, each 1...8.
    pub fn setSize(self: Printer, width: u4, height: u4) Io.Writer.Error!void {
        const w = std.math.clamp(width, 1, 8) - 1;
        const h = std.math.clamp(height, 1, 8) - 1;
        try self.writer.writeAll(&.{ gs, '!', (@as(u8, w) << 4) | h });
    }

    /// ESC t n - select code page (0 = PC437, 16 = WPC1252, ...).
    pub fn setCodePage(self: Printer, page: u8) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 't', page });
    }

    /// Print a line of `ch` spanning the full paper width.
    pub fn rule(self: Printer, ch: u8, width: usize) Io.Writer.Error!void {
        try self.writer.splatByteAll(ch, width);
        try self.writer.writeByte(lf);
    }

    /// Print `left` and `right` on one line, padded to `width` columns.
    /// If they do not fit, a single space separates them.
    pub fn columns(self: Printer, left: []const u8, right: []const u8, width: usize) Io.Writer.Error!void {
        try self.writer.writeAll(left);
        const used = left.len + right.len;
        try self.writer.splatByteAll(' ', if (used < width) width - used else 1);
        try self.writer.writeAll(right);
        try self.writer.writeByte(lf);
    }

    /// GS V - cut paper. Feeds past the cutter first (GS V B n form).
    pub fn cut(self: Printer, mode: CutMode) Io.Writer.Error!void {
        const m: u8 = switch (mode) {
            .full => 65,
            .partial => 66,
        };
        try self.writer.writeAll(&.{ gs, 'V', m, 3 });
    }

    /// DLE EOT n - ask the printer for one real-time status byte. The reply
    /// arrives on the connection's read side; most callers want `queryStatus`.
    pub fn requestStatus(self: Printer, kind: status.Kind) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ status.dle, status.eot, @backingInt(kind) });
    }

    /// Ask the printer for all four status bytes and decode them.
    ///
    /// `reader` must read from the same connection the printer writes to.
    /// Each request is flushed and then waits for the reply, and a printer
    /// that doesn't answer blocks forever (a write-only device file never
    /// will), so open the connection read-write and use this only on
    /// bidirectional links.
    pub fn queryStatus(self: Printer, reader: *Io.Reader) (status.ParseError || Io.Reader.Error || Io.Writer.Error)!Status {
        var replies: [4]u8 = undefined;
        inline for (.{ status.Kind.printer, .offline_cause, .error_cause, .paper }, 0..) |kind, i| {
            try self.requestStatus(kind);
            try self.writer.flush();
            replies[i] = try takeReply(reader);
        }
        return status.parse(replies[0], replies[1], replies[2], replies[3]);
    }

    /// Read one reply byte. A character device can complete a read with zero
    /// bytes (Linux `usblp` does this for a stale empty packet), which `Io.Reader`
    /// reports as end of stream. That isn't a real EOF here, so try again a few
    /// times before giving up.
    fn takeReply(reader: *Io.Reader) Io.Reader.Error!u8 {
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            return reader.takeByte() catch |e| switch (e) {
                error.EndOfStream => if (attempts < status.empty_read_retries) continue else e,
                else => e,
            };
        }
    }

    /// ESC t - select the code page for bytes 0x80-0xFF. Pair with
    /// `textUtf8` using the same `enc`.
    pub fn setEncoding(self: Printer, enc: Encoding) Io.Writer.Error!void {
        try self.setCodePage(enc.codePage());
    }

    /// Write UTF-8 text converted to the code page `enc`, which must already
    /// be selected with `setEncoding`. Invalid UTF-8 and characters the code
    /// page lacks are written as `?`.
    pub fn textUtf8(self: Printer, enc: Encoding, s: []const u8) Io.Writer.Error!void {
        var i: usize = 0;
        while (i < s.len) {
            // An invalid lead byte or truncated sequence consumes one byte.
            var len: usize = 1;
            var out: u8 = encoding.replacement;
            if (std.unicode.utf8ByteSequenceLength(s[i])) |n| {
                if (i + n <= s.len) {
                    if (std.unicode.utf8Decode(s[i..][0..n])) |cp| {
                        len = n;
                        out = enc.encode(cp) orelse encoding.replacement;
                    } else |_| {}
                }
            } else |_| {}
            try self.writer.writeByte(out);
            i += len;
        }
    }

    /// `textUtf8` followed by a line feed.
    pub fn lineUtf8(self: Printer, enc: Encoding, s: []const u8) Io.Writer.Error!void {
        try self.textUtf8(enc, s);
        try self.writer.writeByte(lf);
    }

    /// ESC 3 - set line spacing in dots (about 1/203 inch). The power-on
    /// default is 30 dots; `resetLineSpacing` restores it.
    pub fn setLineSpacing(self: Printer, dots: u8) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, '3', dots });
    }

    /// ESC 2 - restore the default line spacing.
    pub fn resetLineSpacing(self: Printer) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, '2' });
    }

    /// ESC SP - extra space in dots to the right of each character (0-255).
    pub fn setCharSpacing(self: Printer, dots: u8) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, ' ', dots });
    }

    /// GS L - left margin in dots. Takes effect at the start of a line.
    pub fn setLeftMargin(self: Printer, dots: u16) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ gs, 'L', @truncate(dots), @truncate(dots >> 8) });
    }

    /// GS W - width of the print area in dots, measured from the left
    /// margin. 576 is the full width of 80mm paper.
    pub fn setPrintWidth(self: Printer, dots: u16) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ gs, 'W', @truncate(dots), @truncate(dots >> 8) });
    }

    /// ESC $ - move the print position to `dots` from the left margin.
    pub fn setPosition(self: Printer, dots: u16) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, '$', @truncate(dots), @truncate(dots >> 8) });
    }

    /// ESC \ - move the print position by `dots` (negative moves left).
    pub fn movePosition(self: Printer, dots: i16) Io.Writer.Error!void {
        const bits: u16 = @bitCast(dots);
        try self.writer.writeAll(&.{ esc, '\\', @truncate(bits), @truncate(bits >> 8) });
    }

    /// ESC V - rotate text 90 degrees clockwise.
    pub fn setRotate90(self: Printer, on: bool) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 'V', @intFromBool(on) });
    }

    /// ESC { - print text upside down (rotated 180 degrees). Takes effect at
    /// the start of a line.
    pub fn setUpsideDown(self: Printer, on: bool) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, '{', @intFromBool(on) });
    }

    /// ESC p - pulse the cash drawer connected to pin 2.
    pub fn openDrawer(self: Printer) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 'p', 0, 25, 250 });
    }

    /// Print a QR code (GS ( k, model 2) at error correction level M.
    pub fn qrCode(self: Printer, data: []const u8, module_size: u8) (BarcodeError || Io.Writer.Error)!void {
        try self.qrCodeWith(data, .{ .module_size = module_size });
    }

    /// Print a QR code (GS ( k, model 2). Nothing is written if `data` is
    /// empty or longer than a QR code can hold (7089 bytes).
    pub fn qrCodeWith(self: Printer, data: []const u8, opts: QrOptions) (BarcodeError || Io.Writer.Error)!void {
        if (data.len == 0 or data.len > 7089) return error.InvalidBarcode;
        const w = self.writer;
        // Model 2
        try w.writeAll(&.{ gs, '(', 'k', 4, 0, 49, 65, 50, 0 });
        // Module size (1...16)
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 49, 67, std.math.clamp(opts.module_size, 1, 16) });
        // Error correction level
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 49, 69, @backingInt(opts.error_correction) });
        try self.storeAndPrint2d(49, data);
    }

    /// Print a PDF417 symbol (GS ( k, function group 48). Nothing is written
    /// if `data` is empty or too long for the protocol.
    pub fn pdf417(self: Printer, data: []const u8, opts: Pdf417Options) (BarcodeError || Io.Writer.Error)!void {
        if (data.len == 0 or data.len > 65532) return error.InvalidBarcode;
        const w = self.writer;
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 48, 65, @min(opts.columns, 30) });
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 48, 66, if (opts.rows == 0) 0 else std.math.clamp(opts.rows, 3, 90) });
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 48, 67, std.math.clamp(opts.module_width, 2, 8) });
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 48, 68, std.math.clamp(opts.row_height, 2, 8) });
        try w.writeAll(&.{ gs, '(', 'k', 4, 0, 48, 69, 48, @as(u8, 48) + @min(opts.error_correction, 8) });
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 48, 70, @intFromBool(opts.truncated) });
        try self.storeAndPrint2d(48, data);
    }

    /// Store `data` in the symbol buffer for 2D code family `cn` (48 PDF417,
    /// 49 QR) and print it.
    fn storeAndPrint2d(self: Printer, cn: u8, data: []const u8) Io.Writer.Error!void {
        const w = self.writer;
        const len: u16 = @intCast(data.len + 3);
        try w.writeAll(&.{ gs, '(', 'k', @truncate(len), @truncate(len >> 8), cn, 80, 48 });
        try w.writeAll(data);
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, cn, 81, 48 });
    }

    /// Print a 1-bit raster image (GS v 0). Alignment applies, and the image
    /// is clipped by the printer if wider than the paper (576 dots on 80mm).
    ///
    /// Sent in bands of 256 rows so large images don't overflow the printer's
    /// receive buffer. Nothing is written if `bmp` is invalid.
    pub fn bitmap(self: Printer, bmp: image.Bitmap) (BitmapError || Io.Writer.Error)!void {
        const stride = bmp.stride();
        if (bmp.width == 0 or bmp.height == 0 or stride > std.math.maxInt(u16) or
            bmp.data.len != stride * bmp.height) return error.InvalidBitmap;

        const w = self.writer;
        var row: usize = 0;
        while (row < bmp.height) {
            const n: u16 = @intCast(@min(256, bmp.height - row));
            try w.writeAll(&.{ gs, 'v', '0', 0, @truncate(stride), @truncate(stride >> 8), @truncate(n), @truncate(n >> 8) });
            try w.writeAll(bmp.data[row * stride ..][0 .. n * stride]);
            row += n;
        }
    }

    /// Print a 1D barcode (GS h, w, H, f, then GS k function B).
    ///
    /// Nothing is written if `data` is invalid for `kind`.
    pub fn barcode(self: Printer, kind: BarcodeType, data: []const u8, opts: BarcodeOptions) (BarcodeError || Io.Writer.Error)!void {
        try validateBarcode(kind, data);
        const w = self.writer;
        try w.writeAll(&.{ gs, 'h', @max(opts.height, 1) });
        try w.writeAll(&.{ gs, 'w', std.math.clamp(opts.module_width, 2, 6) });
        try w.writeAll(&.{ gs, 'H', @backingInt(opts.text) });
        try w.writeAll(&.{ gs, 'f', @backingInt(opts.font) });
        const prefix = code128Prefix(kind, data);
        try w.writeAll(&.{ gs, 'k', @backingInt(kind), @intCast(prefix.len + data.len) });
        try w.writeAll(prefix);
        try w.writeAll(data);
    }
};

/// Check that `data` can be encoded as `kind`, without writing anything.
pub fn validateBarcode(kind: BarcodeType, data: []const u8) BarcodeError!void {
    const n = data.len;
    const ok = switch (kind) {
        .upca => (n == 11 or n == 12) and allDigits(data),
        .upce => (n == 6 or n == 7 or n == 8 or n == 11 or n == 12) and allDigits(data),
        .ean13 => (n == 12 or n == 13) and allDigits(data),
        .ean8 => (n == 7 or n == 8) and allDigits(data),
        .code39 => n >= 1 and n <= 255 and allIn(data, isCode39),
        .itf => n >= 2 and n <= 254 and n % 2 == 0 and allDigits(data),
        .codabar => n >= 2 and n <= 255 and allIn(data, isCodabar) and isCodabarStop(data[0]) and isCodabarStop(data[n - 1]),
        .code93 => n >= 1 and n <= 255 and allIn(data, isAscii),
        .code128 => n >= 1 and n + code128Prefix(kind, data).len <= 255 and
            (if (code128Prefix(kind, data).len == 0) allIn(data, isAscii) else allIn(data, isPrintable)),
    };
    if (!ok) return error.InvalidBarcode;
}

fn code128Prefix(kind: BarcodeType, data: []const u8) []const u8 {
    return if (kind == .code128 and data.len > 0 and data[0] != '{') "{B" else "";
}

fn allDigits(data: []const u8) bool {
    return allIn(data, std.ascii.isDigit);
}

fn allIn(data: []const u8, comptime pred: fn (u8) bool) bool {
    for (data) |c| if (!pred(c)) return false;
    return true;
}

fn isAscii(c: u8) bool {
    return c < 128;
}

fn isPrintable(c: u8) bool {
    return c >= 32 and c < 128;
}

fn isCode39(c: u8) bool {
    return std.ascii.isDigit(c) or std.ascii.isUpper(c) or std.mem.indexOfScalar(u8, " $%+-./*", c) != null;
}

fn isCodabarStop(c: u8) bool {
    return (c >= 'A' and c <= 'D') or (c >= 'a' and c <= 'd');
}

fn isCodabar(c: u8) bool {
    return std.ascii.isDigit(c) or isCodabarStop(c) or std.mem.indexOfScalar(u8, "$+-./:", c) != null;
}

fn expectBytes(expected: []const u8, comptime f: anytype, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try @call(.auto, f, .{Printer.init(&w)} ++ args);
    try std.testing.expectEqualSlices(u8, expected, w.buffered());
}

test "initialize" {
    try expectBytes("\x1b@", Printer.initialize, .{});
}

test "alignment, bold, underline" {
    try expectBytes("\x1ba\x01", Printer.setAlign, .{Align.center});
    try expectBytes("\x1bE\x01", Printer.setBold, .{true});
    try expectBytes("\x1b-\x02", Printer.setUnderline, .{Underline.double});
}

test "size packs width and height" {
    try expectBytes("\x1d!\x11", Printer.setSize, .{ 2, 2 });
    try expectBytes("\x1d!\x00", Printer.setSize, .{ 1, 1 });
}

test "cut and feed" {
    try expectBytes("\x1dVB\x03", Printer.cut, .{CutMode.partial});
    try expectBytes("\x1bd\x04", Printer.feed, .{4});
}

test "columns pads to width" {
    try expectBytes("Total     $5\n", Printer.columns, .{ "Total", "$5", 12 });
}

test "qr code" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Printer.init(&w).qrCode("hi", 4);
    // store-data length is len + 3 = 5
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1d(k\x05\x001P0hi") != null);
}

test "barcode ean13" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Printer.init(&w).barcode(.ean13, "4006381333931", .{ .height = 100, .module_width = 3 });
    try std.testing.expectEqualSlices(
        u8,
        "\x1dh\x64\x1dw\x03\x1dH\x02\x1df\x00\x1dkC\x0d4006381333931",
        w.buffered(),
    );
}

test "barcode code128 selects code set B unless given" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Printer.init(&w).barcode(.code128, "ABC-1", .{});
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1dkI\x07{BABC-1"));

    w = .fixed(&buf);
    try Printer.init(&w).barcode(.code128, "{C\x12\x34", .{});
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1dkI\x04{C\x12\x34"));
}

test "barcode options are clamped" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Printer.init(&w).barcode(.code39, "A", .{ .height = 0, .module_width = 9, .text = .none });
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "\x1dh\x01\x1dw\x06\x1dH\x00"));
}

test "invalid barcodes write nothing" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const p = Printer.init(&w);
    try std.testing.expectError(error.InvalidBarcode, p.barcode(.ean13, "123", .{}));
    try std.testing.expectError(error.InvalidBarcode, p.barcode(.ean13, "40063813339ab", .{}));
    try std.testing.expectError(error.InvalidBarcode, p.barcode(.itf, "123", .{}));
    try std.testing.expectError(error.InvalidBarcode, p.barcode(.code39, "abc", .{}));
    try std.testing.expectError(error.InvalidBarcode, p.barcode(.codabar, "1234", .{}));
    try std.testing.expectError(error.InvalidBarcode, p.barcode(.code128, "", .{}));
    try std.testing.expectError(error.InvalidBarcode, p.barcode(.code128, "caf\xe9", .{}));
    try std.testing.expectEqual(0, w.buffered().len);
}

test "valid barcodes" {
    try validateBarcode(.upca, "03600029145");
    try validateBarcode(.upce, "012345");
    try validateBarcode(.ean8, "9638507");
    try validateBarcode(.code39, "*HELLO-123*");
    try validateBarcode(.itf, "1234567890");
    try validateBarcode(.codabar, "A1234B");
    try validateBarcode(.code93, "Hello");
}

test "bitmap bands" {
    var data: [600]u8 = @splat(0xaa);
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // 8 wide (1 byte per row), 600 rows -> bands of 256, 256, 88
    try Printer.init(&w).bitmap(.{ .width = 8, .height = 600, .data = &data });
    const out = w.buffered();
    try std.testing.expectEqualSlices(u8, "\x1dv0\x00\x01\x00\x00\x01", out[0..8]);
    try std.testing.expectEqual(8 + 256 + 8 + 256 + 8 + 88, out.len);
    try std.testing.expectEqualSlices(u8, "\x1dv0\x00\x01\x00\x58\x00", out[out.len - 88 - 8 ..][0..8]);
}

test "invalid bitmap writes nothing" {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const p = Printer.init(&w);
    var short = [_]u8{0};
    try std.testing.expectError(error.InvalidBitmap, p.bitmap(.{ .width = 8, .height = 2, .data = &short }));
    try std.testing.expectError(error.InvalidBitmap, p.bitmap(.{ .width = 0, .height = 0, .data = short[0..0] }));
    try std.testing.expectEqual(0, w.buffered().len);
}

test {
    _ = image;
}

test "qr code options" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Printer.init(&w).qrCodeWith("hi", .{ .module_size = 20, .error_correction = .h });
    const out = w.buffered();
    // module size clamps to 16, EC level H is 51
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1d(k\x03\x001C\x10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1d(k\x03\x001E3") != null);
}

test "qr code rejects empty and oversized data" {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const p = Printer.init(&w);
    try std.testing.expectError(error.InvalidBarcode, p.qrCode("", 4));
    const big: [7090]u8 = @splat('x');
    try std.testing.expectError(error.InvalidBarcode, p.qrCodeWith(&big, .{}));
    try std.testing.expectEqual(0, w.buffered().len);
}

test "pdf417" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Printer.init(&w).pdf417("hi", .{ .columns = 40, .rows = 1, .module_width = 9, .error_correction = 12, .truncated = true });
    try std.testing.expectEqualSlices(
        u8,
        "\x1d(k\x03\x000A\x1e" ++ // columns clamp to 30
            "\x1d(k\x03\x000B\x03" ++ // rows clamp to 3
            "\x1d(k\x03\x000C\x08" ++ // width clamp to 8
            "\x1d(k\x03\x000D\x03" ++ // row height
            "\x1d(k\x04\x000E08" ++ // EC level clamps to 8 -> '0' + 8
            "\x1d(k\x03\x000F\x01" ++ // truncated
            "\x1d(k\x05\x000P0hi" ++
            "\x1d(k\x03\x000Q0",
        w.buffered(),
    );
}

test "line and character spacing" {
    try expectBytes("\x1b3\x14", Printer.setLineSpacing, .{20});
    try expectBytes("\x1b2", Printer.resetLineSpacing, .{});
    try expectBytes("\x1b \x03", Printer.setCharSpacing, .{3});
}

test "margins and positions are little-endian" {
    try expectBytes("\x1dL\x40\x01", Printer.setLeftMargin, .{320});
    try expectBytes("\x1dW\x40\x02", Printer.setPrintWidth, .{576});
    try expectBytes("\x1b$\x2c\x01", Printer.setPosition, .{300});
    try expectBytes("\x1b\\\xf6\xff", Printer.movePosition, .{-10});
    try expectBytes("\x1b\\\x0a\x00", Printer.movePosition, .{10});
}

test "rotation" {
    try expectBytes("\x1bV\x01", Printer.setRotate90, .{true});
    try expectBytes("\x1b{\x00", Printer.setUpsideDown, .{false});
}

test "setEncoding selects the Epson code page" {
    try expectBytes("\x1bt\x13", Printer.setEncoding, .{Encoding.cp858});
    try expectBytes("\x1bt\x10", Printer.setEncoding, .{Encoding.cp1252});
}

test "textUtf8 converts to the code page" {
    try expectBytes("caf\x82 \xd5", Printer.textUtf8, .{ Encoding.cp858, "caf\xc3\xa9 \xe2\x82\xac" });
    try expectBytes("caf\xe9", Printer.textUtf8, .{ Encoding.cp1252, "caf\xc3\xa9" });
}

test "textUtf8 replaces unmappable and invalid input" {
    // CJK is missing from the code page; 0xff and a truncated sequence are invalid UTF-8
    try expectBytes("?", Printer.textUtf8, .{ Encoding.cp437, "\xe4\xb8\xad" });
    try expectBytes("a?b", Printer.textUtf8, .{ Encoding.cp437, "a\xffb" });
    try expectBytes("a?", Printer.textUtf8, .{ Encoding.cp437, "a\xc3" });
}

test {
    _ = encoding;
}

test "requestStatus" {
    try expectBytes("\x10\x04\x04", Printer.requestStatus, .{status.Kind.paper});
}

test "queryStatus sends four requests and decodes the replies" {
    var out: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var r: Io.Reader = .fixed(&.{ 0x12, 0x12 | 0x04, 0x12, 0x12 | 0x60 });
    const s = try Printer.init(&w).queryStatus(&r);
    try std.testing.expectEqualSlices(u8, "\x10\x04\x01\x10\x04\x02\x10\x04\x03\x10\x04\x04", w.buffered());
    try std.testing.expect(s.cover_open and s.paper_end and !s.offline);
}

/// A reader that returns `empties` empty reads, then endless status bytes.
const FlakyReader = struct {
    interface: Io.Reader,
    empties: usize,

    fn init(buffer: []u8, empties: usize) FlakyReader {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .empties = empties,
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        const self: *FlakyReader = @fieldParentPtr("interface", r);
        if (self.empties > 0) {
            self.empties -= 1;
            return error.EndOfStream;
        }
        try w.writeByte(0x12);
        return 1;
    }
};

test "queryStatus retries empty reads" {
    var out: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var buf: [8]u8 = undefined;
    var flaky: FlakyReader = .init(&buf, status.empty_read_retries);
    const s = try Printer.init(&w).queryStatus(&flaky.interface);
    try std.testing.expect(s.ready());
}

test "queryStatus gives up after too many empty reads" {
    var out: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var buf: [8]u8 = undefined;
    var flaky: FlakyReader = .init(&buf, status.empty_read_retries + 1);
    try std.testing.expectError(error.EndOfStream, Printer.init(&w).queryStatus(&flaky.interface));
}

test "queryStatus fails when the printer stops answering" {
    var out: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var r: Io.Reader = .fixed(&.{0x12});
    try std.testing.expectError(error.EndOfStream, Printer.init(&w).queryStatus(&r));
}

test {
    _ = status;
}
