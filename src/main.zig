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
    \\      --no-cut          Do not cut the paper
    \\      --qr <data>       Print a QR code after the text
    \\      --barcode <data>  Print a 1D barcode after the text
    \\      --barcode-type <t>    upca | upce | ean13 | ean8 | code39 | itf |
    \\                            codabar | code93 | code128 (default: code128)
    \\      --barcode-height <n>  Bar height in dots, 1-255 (default: 80)
    \\      --barcode-width <n>   Narrowest bar width in dots, 2-6 (default: 2)
    \\      --barcode-text <t>    none | above | below | both (default: below)
    \\      --image <path>    Print a Netpbm image (P4/P5/P6) before the text
    \\      --image-width <n> Scale the image to n dots wide (default: at most 576)
    \\      --image-mode <m>  dither | threshold (default: dither)
    \\      --demo            Print a sample receipt showing most features
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
    var image_path: ?[]const u8 = null;
    var image_width: ?u32 = null;
    var image_dither = true;
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
        } else if (eql(a, "--no-cut")) {
            cut = false;
        } else if (eql(a, "--qr")) {
            qr = try value(args, &i, err);
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

    if (barcode) |data| escpos.validateBarcode(barcode_type, data) catch
        return fail(err, "invalid data for barcode type {s}: {s}", .{ @tagName(barcode_type), data });

    const bitmap: ?escpos.image.Bitmap = if (image_path) |path| bmp: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e|
            return fail(err, "cannot read {s}: {s}", .{ path, @errorName(e) });
        var gray = escpos.image.parseNetpbm(arena, bytes) catch |e|
            return fail(err, "cannot decode {s}: {s} (convert with e.g. `magick in.png out.pgm`)", .{ path, @errorName(e) });
        const target = image_width orelse if (gray.width > max_image_width) max_image_width else gray.width;
        if (target != gray.width) gray = escpos.image.scale(arena, gray, target) catch |e|
            return fail(err, "cannot scale image: {s}", .{@errorName(e)});
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
    if (bitmap) |bmp| try p.bitmap(bmp);
    try p.setSize(size, size);
    try p.text(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try p.text("\n");
    try p.setSize(1, 1);
    try p.setBold(false);
    try p.setUnderline(.none);
    if (qr) |data| {
        try p.setAlign(.center);
        try p.qrCode(data, 6);
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
