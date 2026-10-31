const std = @import("std");
const Io = std.Io;

const escpos = @import("escpos");
const demo = @import("demo.zig");

const usage =
    \\Usage: escpos [options] [text...]
    \\
    \\Print text to an ESC/POS receipt printer (Epson TM-T20III).
    \\Text comes from the arguments, or from stdin if none are given.
    \\
    \\Options:
    \\  -d, --device <path>   Printer device (default: /dev/usb/lp0)
    \\  -a, --align <a>       left | center | right
    \\  -b, --bold            Bold text
    \\  -u, --underline       Underline text
    \\  -s, --size <n>        Character size multiplier, 1-8
    \\  -n, --feed <n>        Blank lines to feed before cutting (default: 3)
    \\      --line-spacing <n>    Line spacing in dots (default: 30)
    \\      --char-spacing <n>    Extra dots after each character
    \\      --left-margin <n>     Left margin in dots
    \\      --upside-down     Print the text upside down
    \\      --encoding <e>        Convert UTF-8 text to a code page: cp858 | cp437 |
    \\                            cp1252 | raw (default: cp858; raw sends bytes as-is)
    \\      --no-cut          Do not cut the paper
    \\      --qr <data>       Print a QR code after the text
    \\      --qr-size <n>     QR module size in dots, 1-16 (default: 6)
    \\      --qr-level <l>    QR error correction: l | m | q | h (default: m)
    \\      --pdf417 <data>   Print a PDF417 symbol after the text
    \\      --pdf417-columns <n>  PDF417 data columns, 1-30 (default: auto)
    \\      --barcode <data>  Print a 1D barcode after the text
    \\      --barcode-type <t>    upca | upce | ean13 | ean8 | code39 | itf |
    \\                            codabar | code93 | code128 (default: code128)
    \\      --barcode-height <n>  Bar height in dots, 1-255 (default: 80)
    \\      --barcode-width <n>   Narrowest bar width in dots, 2-6 (default: 2)
    \\      --barcode-text <t>    none | above | below | both (default: below)
    \\      --image <path>    Print a PNG or Netpbm (P4/P5/P6) image before the text
    \\      --image-width <n> Scale the image to n dots wide (default: at most 576)
    \\      --image-gamma <g>     Darken (>1) or lighten (<1) midtones (default: 1)
    \\      --no-autolevel        Don't stretch the image to full contrast
    \\      --image-mode <m>  dither | threshold (default: dither)
    \\      --demo            Print a sample receipt showing most features
    \\      --status          Query and print the printer's status; exit 1 if not ready
    \\      --stdout          Write raw ESC/POS bytes to stdout instead
    \\  -h, --help            Show this help
    \\
;

const default_device = "/dev/usb/lp0";

/// Printable width in dots on 80mm paper.
const max_image_width = 576;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stderr_buf: [256]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    var device: []const u8 = default_device;
    var alignment: escpos.Align = .left;
    var bold = false;
    var underline = false;
    var size: u4 = 1;
    var feed: u8 = 3;
    var cut = true;
    var to_stdout = false;
    var run_demo = false;
    var qr: ?[]const u8 = null;
    var show_status = false;
    var encoding: ?escpos.Encoding = .cp858;
    var line_spacing: ?u8 = null;
    var char_spacing: u8 = 0;
    var left_margin: u16 = 0;
    var upside_down = false;
    var qr_opts: escpos.QrOptions = .{};
    var pdf417: ?[]const u8 = null;
    var pdf417_opts: escpos.Pdf417Options = .{};
    var image_path: ?[]const u8 = null;
    var image_width: ?u32 = null;
    var image_dither = true;
    var image_gamma: f32 = 1;
    var image_autolevel = true;
    var barcode: ?[]const u8 = null;
    var barcode_type: escpos.BarcodeType = .code128;
    var barcode_opts: escpos.BarcodeOptions = .{};
    var words: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (eql(a, "-h") or eql(a, "--help")) {
            try err.writeAll(usage);
            try err.flush();
            return;
        } else if (eql(a, "-d") or eql(a, "--device")) {
            device = try value(args, &i, err);
        } else if (eql(a, "-a") or eql(a, "--align")) {
            const v = try value(args, &i, err);
            alignment = std.meta.stringToEnum(escpos.Align, v) orelse return fail(err, "invalid alignment: {s}", .{v});
        } else if (eql(a, "-b") or eql(a, "--bold")) {
            bold = true;
        } else if (eql(a, "-u") or eql(a, "--underline")) {
            underline = true;
        } else if (eql(a, "-s") or eql(a, "--size")) {
            const v = try value(args, &i, err);
            size = std.fmt.parseInt(u4, v, 10) catch return fail(err, "invalid size: {s}", .{v});
            if (size < 1 or size > 8) return fail(err, "size must be 1-8", .{});
        } else if (eql(a, "-n") or eql(a, "--feed")) {
            const v = try value(args, &i, err);
            feed = std.fmt.parseInt(u8, v, 10) catch return fail(err, "invalid feed: {s}", .{v});
        } else if (eql(a, "--status")) {
            show_status = true;
        } else if (eql(a, "--encoding")) {
            const v = try value(args, &i, err);
            encoding = if (eql(v, "raw")) null else std.meta.stringToEnum(escpos.Encoding, v) orelse
                return fail(err, "invalid encoding: {s}", .{v});
        } else if (eql(a, "--line-spacing")) {
            const v = try value(args, &i, err);
            line_spacing = std.fmt.parseInt(u8, v, 10) catch return fail(err, "invalid line spacing: {s}", .{v});
        } else if (eql(a, "--char-spacing")) {
            const v = try value(args, &i, err);
            char_spacing = std.fmt.parseInt(u8, v, 10) catch return fail(err, "invalid character spacing: {s}", .{v});
        } else if (eql(a, "--left-margin")) {
            const v = try value(args, &i, err);
            left_margin = std.fmt.parseInt(u16, v, 10) catch return fail(err, "invalid left margin: {s}", .{v});
        } else if (eql(a, "--upside-down")) {
            upside_down = true;
        } else if (eql(a, "--no-cut")) {
            cut = false;
        } else if (eql(a, "--qr")) {
            qr = try value(args, &i, err);
        } else if (eql(a, "--qr-size")) {
            const v = try value(args, &i, err);
            qr_opts.module_size = std.fmt.parseInt(u8, v, 10) catch return fail(err, "invalid QR size: {s}", .{v});
            if (qr_opts.module_size < 1 or qr_opts.module_size > 16) return fail(err, "QR size must be 1-16", .{});
        } else if (eql(a, "--qr-level")) {
            const v = try value(args, &i, err);
            qr_opts.error_correction = std.meta.stringToEnum(escpos.QrErrorCorrection, v) orelse return fail(err, "invalid QR level: {s}", .{v});
        } else if (eql(a, "--pdf417")) {
            pdf417 = try value(args, &i, err);
        } else if (eql(a, "--pdf417-columns")) {
            const v = try value(args, &i, err);
            pdf417_opts.columns = std.fmt.parseInt(u8, v, 10) catch return fail(err, "invalid PDF417 columns: {s}", .{v});
            if (pdf417_opts.columns > 30) return fail(err, "PDF417 columns must be 1-30", .{});
        } else if (eql(a, "--barcode")) {
            barcode = try value(args, &i, err);
        } else if (eql(a, "--barcode-type")) {
            const v = try value(args, &i, err);
            barcode_type = std.meta.stringToEnum(escpos.BarcodeType, v) orelse return fail(err, "invalid barcode type: {s}", .{v});
        } else if (eql(a, "--barcode-height")) {
            const v = try value(args, &i, err);
            barcode_opts.height = std.fmt.parseInt(u8, v, 10) catch return fail(err, "invalid barcode height: {s}", .{v});
            if (barcode_opts.height < 1) return fail(err, "barcode height must be 1-255", .{});
        } else if (eql(a, "--barcode-width")) {
            const v = try value(args, &i, err);
            barcode_opts.module_width = std.fmt.parseInt(u8, v, 10) catch return fail(err, "invalid barcode width: {s}", .{v});
            if (barcode_opts.module_width < 2 or barcode_opts.module_width > 6) return fail(err, "barcode width must be 2-6", .{});
        } else if (eql(a, "--barcode-text")) {
            const v = try value(args, &i, err);
            barcode_opts.text = std.meta.stringToEnum(escpos.BarcodeText, v) orelse return fail(err, "invalid barcode text: {s}", .{v});
        } else if (eql(a, "--image")) {
            image_path = try value(args, &i, err);
        } else if (eql(a, "--image-width")) {
            const v = try value(args, &i, err);
            image_width = std.fmt.parseInt(u32, v, 10) catch return fail(err, "invalid image width: {s}", .{v});
            if (image_width.? < 1) return fail(err, "image width must be at least 1", .{});
        } else if (eql(a, "--image-gamma")) {
            const v = try value(args, &i, err);
            image_gamma = std.fmt.parseFloat(f32, v) catch return fail(err, "invalid image gamma: {s}", .{v});
            if (!(image_gamma > 0 and image_gamma <= 10)) return fail(err, "image gamma must be between 0 and 10", .{});
        } else if (eql(a, "--no-autolevel")) {
            image_autolevel = false;
        } else if (eql(a, "--image-mode")) {
            const v = try value(args, &i, err);
            if (eql(v, "dither")) {
                image_dither = true;
            } else if (eql(v, "threshold")) {
                image_dither = false;
            } else return fail(err, "invalid image mode: {s}", .{v});
        } else if (eql(a, "--demo")) {
            run_demo = true;
        } else if (eql(a, "--stdout")) {
            to_stdout = true;
        } else if (a.len > 1 and a[0] == '-') {
            return fail(err, "unknown option: {s}", .{a});
        } else {
            try words.append(arena, a);
        }
    }

    if (show_status) {
        if (to_stdout) return fail(err, "--status needs a printer, not --stdout", .{});
        return printStatus(io, device, err);
    }

    if (qr) |data| if (data.len == 0 or data.len > 7089) return fail(err, "QR data must be 1-7089 bytes", .{});
    if (pdf417) |data| if (data.len == 0) return fail(err, "PDF417 data must not be empty", .{});
    if (barcode) |data| escpos.validateBarcode(barcode_type, data) catch
        return fail(err, "invalid data for barcode type {s}: {s}", .{ @tagName(barcode_type), data });

    const bitmap: ?escpos.image.Bitmap = if (image_path) |path| bmp: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e|
            return fail(err, "cannot read {s}: {s}", .{ path, @errorName(e) });
        var gray = escpos.image.decode(arena, bytes) catch |e|
            return fail(err, "cannot decode {s}: {s} (PNG and Netpbm only; convert other formats with e.g. `magick in.jpg out.png`)", .{ path, @errorName(e) });
        const target = image_width orelse if (gray.width > max_image_width) max_image_width else gray.width;
        if (target != gray.width) gray = escpos.image.scale(arena, gray, target) catch |e|
            return fail(err, "cannot scale image: {s}", .{@errorName(e)});
        if (image_autolevel) escpos.image.autoLevels(gray);
        escpos.image.adjustGamma(gray, image_gamma);
        break :bmp (if (image_dither)
            escpos.image.dither(arena, gray)
        else
            escpos.image.threshold(arena, gray, 128)) catch |e|
            return fail(err, "cannot convert image: {s}", .{@errorName(e)});
    } else null;

    // Gather the body before touching the printer.
    const body: []const u8 = if (run_demo)
        ""
    else if (words.items.len > 0)
        try std.mem.join(arena, " ", words.items)
    else body: {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buf);
        break :body try stdin_reader.interface.allocRemaining(arena, .limited(1 << 20));
    };

    const file: Io.File = if (to_stdout)
        .stdout()
    else
        Io.Dir.openFileAbsolute(io, device, .{ .mode = .write_only }) catch |e|
            return fail(err, "cannot open {s}: {s}", .{ device, @errorName(e) });
    defer if (!to_stdout) file.close(io);

    var out_buf: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &out_buf);
    const p = escpos.Printer.init(&file_writer.interface);

    if (run_demo) {
        try demo.print(p);
        try file_writer.interface.flush();
        return;
    }

    try p.initialize();
    try p.setAlign(alignment);
    try p.setBold(bold);
    if (underline) try p.setUnderline(.single);
    if (left_margin > 0) try p.setLeftMargin(left_margin);
    if (bitmap) |bmp| try p.bitmap(bmp);
    if (line_spacing) |dots| try p.setLineSpacing(dots);
    if (char_spacing > 0) try p.setCharSpacing(char_spacing);
    if (upside_down) try p.setUpsideDown(true);
    try p.setSize(size, size);
    if (encoding) |enc| {
        try p.setEncoding(enc);
        try p.textUtf8(enc, body);
    } else try p.text(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try p.text("\n");
    // Undo the text-only settings so the codes below print normally.
    if (upside_down) try p.setUpsideDown(false);
    if (char_spacing > 0) try p.setCharSpacing(0);
    if (line_spacing != null) try p.resetLineSpacing();
    if (left_margin > 0) try p.setLeftMargin(0);
    try p.setSize(1, 1);
    try p.setBold(false);
    try p.setUnderline(.none);
    if (qr) |data| {
        try p.setAlign(.center);
        try p.qrCodeWith(data, qr_opts);
        try p.text("\n");
    }
    if (pdf417) |data| {
        try p.setAlign(.center);
        try p.pdf417(data, pdf417_opts);
        try p.text("\n");
    }
    if (barcode) |data| {
        try p.setAlign(.center);
        try p.barcode(barcode_type, data, barcode_opts);
        try p.text("\n");
    }
    if (cut) {
        try p.feed(feed);
        try p.cut(.partial);
    } else try p.feed(feed);
    try file_writer.interface.flush();
}

/// Open the printer read-write, query it and report. Exits 1 if it isn't ready.
fn printStatus(io: Io, device: []const u8, err: *Io.Writer) !void {
    const file = Io.Dir.openFileAbsolute(io, device, .{ .mode = .read_write }) catch |e|
        return fail(err, "cannot open {s}: {s}", .{ device, @errorName(e) });
    defer file.close(io);

    var out_buf: [64]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &out_buf);
    var in_buf: [16]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(file, io, &in_buf);

    const st = escpos.Printer.init(&file_writer.interface).queryStatus(&file_reader.interface) catch |e|
        return fail(err, "cannot read status from {s}: {s}{s}", .{
            device,
            @errorName(e),
            if (e == error.EndOfStream) " (the printer sent no data; it may not support reads on this connection)" else "",
        });

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;
    try out.print("{s}\n", .{if (st.ready()) "ready" else "not ready"});
    inline for (comptime std.meta.fieldNames(escpos.Status)) |name| {
        if (@field(st, name)) try out.print("  {s}\n", .{name});
    }
    try out.flush();
    if (!st.ready()) std.process.exit(1);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn value(args: []const [:0]const u8, i: *usize, err: *Io.Writer) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return fail(err, "{s} requires a value", .{args[i.* - 1]});
    return args[i.*];
}

fn fail(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print("escpos: " ++ fmt ++ "\n", args) catch {};
    err.flush() catch {};
    std.process.exit(1);
}
