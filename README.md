# thermal - ESC/POS library for Zig

thermal is a Zig library and command-line tool that implements a subset of
Epson's ESC/POS protocol for thermal receipt printers. It lets you generate and
print documents with text formatting, QR codes, and paper cutting from Zig, or
print straight from your shell with the bundled `thermal` binary.

It is tested against the Epson TM-T20III (USB `04b8:0e28`) and should work with
other ESC/POS compatible printers (Epson TM-T88, TM-T20, and many generic
58mm/80mm USB receipt printers).

## Features

- Zig ESC/POS command builder that writes to any `std.Io.Writer`: a USB device
  file, a network socket (port 9100), or an in-memory buffer for testing
- Text alignment (left, center, right), bold, underline, reverse, fonts A/B,
  and 1-8x character scaling
- Two-column receipt lines, divider rules, and code page selection
- QR codes (GS `(` `k`, model 2)
- Paper cut (full or partial), line feed, and cash drawer pulse
- Command-line tool: print text from arguments or stdin
- Zero dependencies, no libusb; cross-compiles to a static binary for arm64
  and other Linux targets
- Not yet supported: raster images, 1D barcodes, and printer status queries

## Installation

Requires Zig 0.17. Build the binary from source:

```bash
zig build -Doptimize=ReleaseSafe
# -> zig-out/bin/thermal
```

To cross-compile a static binary for arm64 Linux (e.g. a Raspberry Pi):

```bash
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall -p zig-out-arm64
# -> zig-out-arm64/bin/thermal
```

To use the library, add it to your project and import the `thermal` module:

```bash
zig fetch --save <path-or-url>
```

```zig
// build.zig
const dep = b.dependency("thermal", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("thermal", dep.module("thermal"));
```

## Usage

```zig
const std = @import("std");
const thermal = @import("thermal");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(
        try std.Io.Dir.openFileAbsolute(io, "/dev/usb/lp0", .{ .mode = .write_only }),
        io,
        &buf,
    );
    const p = thermal.Printer.init(&file_writer.interface);

    try p.initialize();
    try p.setAlign(.center);
    try p.setBold(true);
    try p.line("COFFEE SHOP");
    try p.setBold(false);
    try p.setAlign(.left);
    try p.columns("Latte", "$4.50", thermal.columns_font_a);
    try p.cut(.partial);

    try file_writer.interface.flush();
}
```

### Command line

The ESC/POS binary writes to the Linux `usblp` device (`/dev/usb/lp0` by default), so
no libusb is needed. You may need to join the `lp` group to access it.

```bash
thermal "Hello, world"
echo "From stdin" | thermal
thermal -a center -b -s 2 "RECEIPT"
thermal --qr https://example.com "Scan me"
thermal --demo                         # sample receipt using most features
thermal --stdout "dump raw bytes" | xxd   # no printer needed
```

Run `thermal --help` for all options.

## Related projects

Looking for ESC/POS in another language? See
[escpos](https://docs.rs/escpos/latest/escpos/) for Rust,
[python-escpos](https://github.com/python-escpos/python-escpos) for Python,
and [escpos-php](https://github.com/mike42/escpos-php) for PHP.
The [ESC/POS command reference](https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/)
documents the protocol.

## Contributing

Pull requests are welcome. For major changes, please open an issue first
to discuss what you would like to change.

Please make sure to update tests as appropriate (`zig build test`).
