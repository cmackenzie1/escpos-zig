# escpos-zig - ESC/POS library for Zig

[![Docs](https://img.shields.io/badge/docs-API%20reference-blue)](https://cmackenzie1.github.io/escpos-zig/)

escpos-zig is a Zig library and command-line tool that implements a subset of
Epson's ESC/POS protocol for thermal receipt printers. It lets you generate and
print documents with text formatting, QR codes, and paper cutting from Zig, or
print straight from your shell with the bundled `escpos` binary.

![A receipt printed by the escpos demo](static/demo.jpeg)

It is tested against the Epson TM-T20III (USB `04b8:0e28`) and should work with
other ESC/POS compatible printers (Epson TM-T88, TM-T20, and many generic
58mm/80mm USB receipt printers).

## Features

- Zig ESC/POS command builder that writes to any `std.Io.Writer`: a USB device
  file, a network socket (port 9100), or an in-memory buffer for testing
- Text alignment (left, center, right), bold, underline, reverse, fonts A/B,
  and 1-8x character scaling
- Line and character spacing, left margin, print width, absolute and relative
  positioning, 90-degree and upside-down text
- Two-column receipt lines, divider rules, and code page selection
- UTF-8 text converted to PC437, PC858 (with euro) or WPC1252, so accents and
  currency symbols print correctly; emoji and `:shortcode:`s print as ASCII
  stand-ins (`:smile:` → `:D`, ❤️ → `<3`)
- QR codes (GS `(` `k`, model 2) with selectable size and error correction
- PDF417 with configurable columns, rows, module size and error correction
- 1D barcodes: UPC-A, UPC-E, EAN-13, EAN-8, Code 39, ITF, Codabar, Code 93 and
  Code 128, with height, width and human-readable text placement
- Raster images: load PNG or Netpbm (P4/P5/P6) files, scale to the paper width, and
  reduce to 1 bit with Floyd-Steinberg dithering or a threshold, with automatic
  contrast stretching and a gamma control for faint images
- Paper cut (full or partial), line feed, and cash drawer pulse
- Command-line tool: print text from arguments or stdin
- Zero dependencies, no libusb; cross-compiles to a static binary for arm64
  and other Linux targets
- Printer status queries (paper out, cover open, errors) over a bidirectional
  connection

## Installation

Requires Zig 0.17. Build the binary from source:

```bash
zig build -Doptimize=ReleaseSafe
# -> zig-out/bin/escpos
```

To cross-compile a static binary for arm64 Linux (e.g. a Raspberry Pi):

```bash
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall -p zig-out-arm64
# -> zig-out-arm64/bin/escpos
```

To use the library, add it to your project and import the `escpos` module:

```bash
zig fetch --save <path-or-url>
```

```zig
// build.zig
const dep = b.dependency("escpos", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("escpos", dep.module("escpos"));
```

## Usage

```zig
const std = @import("std");
const escpos = @import("escpos");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(
        try std.Io.Dir.openFileAbsolute(io, "/dev/usb/lp0", .{ .mode = .write_only }),
        io,
        &buf,
    );
    const p = escpos.Printer.init(&file_writer.interface);

    try p.initialize();
    try p.setAlign(.center);
    try p.setBold(true);
    try p.line("COFFEE SHOP");
    try p.setBold(false);
    try p.setAlign(.left);
    try p.columns("Latte", "$4.50", escpos.columns_font_a);
    try p.cut(.partial);

    try file_writer.interface.flush();
}
```

### Command line

The ESC/POS binary writes to the Linux `usblp` device (`/dev/usb/lp0` by default), so
no libusb is needed. You may need to join the `lp` group to access it.

```bash
escpos "Hello, world"
echo "From stdin" | escpos
escpos -a center -b -s 2 "RECEIPT"
escpos --status                                  # needs a readable device; exits 1 if not ready
escpos --status --json                           # same, machine-readable
escpos "Café €4,50"                              # UTF-8 is converted to PC858
escpos --left-margin 96 --char-spacing 2 --line-spacing 40 "Spaced out"
escpos --qr https://example.com "Scan me"
escpos --qr https://example.com --qr-level h --qr-size 8 "High-redundancy QR"
escpos --pdf417 "TICKET-0042" --pdf417-columns 4
escpos --barcode 4006381333931 --barcode-type ean13 "Item 42"
escpos --image logo.png -a center "Welcome"      # PNG or Netpbm; convert JPEGs first
escpos --image photo.png --image-gamma 1.6        # darker, if the print looks faint
escpos --demo                         # sample receipt using most features
escpos --stdout "dump raw bytes" | xxd   # no printer needed
```

Run `escpos --help` for all options.

## Related projects

Looking for ESC/POS in another language? See
[escpos](https://docs.rs/escpos/latest/escpos/) for Rust,
[python-escpos](https://github.com/python-escpos/python-escpos) for Python,
and [escpos-php](https://github.com/mike42/escpos-php) for PHP.
The [ESC/POS command reference](https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/)
documents the protocol.

## Disclaimer

This project is provided as is, without warranty of any kind. It was built
with the assistance of an LLM, so review the code before relying on it,
especially before pointing it at hardware.

I offer no support. If you find this useful, I encourage you to fork it and
make it your own.

## License

[MIT](LICENSE)
