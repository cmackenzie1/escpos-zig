//! Minimal ESC/POS library for Zig: a command builder for Epson thermal
//! receipt printers (tested against the
//! TM-T20III, 80mm paper, 48 columns in Font A).
//!
//! `Printer` writes raw ESC/POS bytes to any `*Io.Writer`, so it can target a
//! device file, a socket, or an in-memory buffer.
const std = @import("std");
const Io = std.Io;

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

    /// ESC p - pulse the cash drawer connected to pin 2.
    pub fn openDrawer(self: Printer) Io.Writer.Error!void {
        try self.writer.writeAll(&.{ esc, 'p', 0, 25, 250 });
    }

    /// Print a QR code (GS ( k, model 2).
    pub fn qrCode(self: Printer, data: []const u8, module_size: u8) Io.Writer.Error!void {
        const w = self.writer;
        // Model 2
        try w.writeAll(&.{ gs, '(', 'k', 4, 0, 49, 65, 50, 0 });
        // Module size (1...16)
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 49, 67, std.math.clamp(module_size, 1, 16) });
        // Error correction level M
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 49, 69, 49 });
        // Store data
        const len: u16 = @intCast(data.len + 3);
        try w.writeAll(&.{ gs, '(', 'k', @truncate(len), @truncate(len >> 8), 49, 80, 48 });
        try w.writeAll(data);
        // Print stored symbol
        try w.writeAll(&.{ gs, '(', 'k', 3, 0, 49, 81, 48 });
    }
};

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
