//! Real-time printer status (DLE EOT n). The printer answers each request with
//! one byte, so this needs a connection you can read from, such as a USB
//! device file opened read-write or a network socket.
const std = @import("std");
const Io = std.Io;

/// The DLE control byte.
pub const dle = 0x10;
/// The EOT control byte.
pub const eot = 0x04;

/// Which status byte to request with DLE EOT.
pub const Kind = enum(u8) {
    printer = 1,
    offline_cause = 2,
    error_cause = 3,
    paper = 4,
};

/// How `Printer.queryStatusWith` waits for a reply.
pub const QueryOptions = struct {
    /// Times a reply read is retried after returning no data. Some printers
    /// answer a read that arrives before the reply is ready with an empty
    /// packet instead of making the read wait.
    retries: usize = 100,
    /// Pause between retries, in milliseconds.
    wait_ms: u32 = 10,
};

pub const ParseError = error{
    /// The byte's fixed bits don't match a status reply, so it probably isn't
    /// one (for example, stale data on the connection).
    InvalidStatus,
};

/// All four status replies, decoded.
pub const Status = struct {
    /// DLE EOT 1: the printer is offline and won't accept print data.
    offline: bool,
    /// DLE EOT 1: drawer kick-out connector pin 3 reads HIGH. This is the raw
    /// pin level, not "drawer open": what HIGH means depends on how the drawer
    /// is wired, and a printer with nothing attached may report either level.
    /// `ready` ignores it.
    drawer_pin_high: bool,
    /// DLE EOT 1: the printer is waiting for an operator to clear a condition.
    waiting_for_online: bool,
    /// DLE EOT 1: the paper feed button is being pressed.
    feed_button_pressed: bool,
    /// DLE EOT 2: the paper cover is open.
    cover_open: bool,
    /// DLE EOT 2: paper is being fed with the feed button.
    feeding_by_button: bool,
    /// DLE EOT 2: printing stopped because the paper ran out.
    stopped_paper_end: bool,
    /// DLE EOT 2: an error occurred.
    error_occurred: bool,
    /// DLE EOT 3: mechanical error.
    mechanical_error: bool,
    /// DLE EOT 3: auto-cutter error.
    cutter_error: bool,
    /// DLE EOT 3: unrecoverable error.
    unrecoverable_error: bool,
    /// DLE EOT 3: error that clears itself, such as a head over-temperature.
    recoverable_error: bool,
    /// DLE EOT 4: paper is nearly out.
    paper_near_end: bool,
    /// DLE EOT 4: paper is out.
    paper_end: bool,

    /// True when the printer can accept a print job: online, cover closed,
    /// paper present and no error.
    pub fn ready(self: Status) bool {
        return !self.offline and !self.cover_open and !self.paper_end and !self.error_occurred and
            !self.mechanical_error and !self.cutter_error and !self.unrecoverable_error and !self.recoverable_error;
    }
};

/// Write a short human-readable report, for example:
///
///     Printer is ready
///       Online:      yes
///       Paper:       ok
///       Cover:       closed
///       Errors:      none
///       Drawer pin:  high
pub fn writeSummary(st: Status, w: *Io.Writer) Io.Writer.Error!void {
    try w.print("Printer is {s}\n", .{if (st.ready()) "ready" else "not ready"});

    try w.writeAll("  Online:      ");
    try w.writeAll(if (st.offline) "no" else "yes");
    if (st.waiting_for_online) try w.writeAll(" (waiting for an operator)");
    try w.writeByte('\n');

    const paper = if (st.paper_end or st.stopped_paper_end) "out" else if (st.paper_near_end) "low" else "ok";
    try w.print("  Paper:       {s}\n", .{paper});
    try w.print("  Cover:       {s}\n", .{if (st.cover_open) "open" else "closed"});

    try w.writeAll("  Errors:      ");
    const errors = [_]struct { bool, []const u8 }{
        .{ st.mechanical_error, "mechanical" },
        .{ st.cutter_error, "cutter" },
        .{ st.unrecoverable_error, "unrecoverable" },
        .{ st.recoverable_error, "recoverable (such as head over-temperature)" },
        .{ st.error_occurred and !(st.mechanical_error or st.cutter_error or st.unrecoverable_error or st.recoverable_error), "unspecified" },
    };
    var first = true;
    for (errors) |e| {
        if (!e[0]) continue;
        if (!first) try w.writeAll(", ");
        try w.writeAll(e[1]);
        first = false;
    }
    if (first) try w.writeAll("none");
    try w.writeByte('\n');

    if (st.feed_button_pressed) try w.writeAll("  Feed button: pressed\n");
    if (st.feeding_by_button) try w.writeAll("  Feeding:     paper is being fed by the button\n");
    try w.print("  Drawer pin:  {s}\n", .{if (st.drawer_pin_high) "high" else "low"});
}

/// Write one JSON object with `ready` and every `Status` field as booleans.
pub fn writeJson(st: Status, w: *Io.Writer) Io.Writer.Error!void {
    try w.print("{{\"ready\":{}", .{st.ready()});
    inline for (comptime std.meta.fieldNames(Status)) |name| {
        try w.print(",\"{s}\":{}", .{ name, @field(st, name) });
    }
    try w.writeAll("}\n");
}

/// Check the fixed bits shared by every status reply: bit 7 and bit 0 clear,
/// bit 4 and bit 1 set (`0xx1xx10`).
fn check(byte: u8) ParseError!void {
    if (byte & 0x93 != 0x12) return error.InvalidStatus;
}

/// Decode the four replies (`printer` = DLE EOT 1, and so on).
pub fn parse(printer: u8, offline_cause: u8, error_cause: u8, paper: u8) ParseError!Status {
    inline for (.{ printer, offline_cause, error_cause, paper }) |b| try check(b);
    return .{
        .drawer_pin_high = printer & 0x04 != 0,
        .offline = printer & 0x08 != 0,
        .waiting_for_online = printer & 0x20 != 0,
        .feed_button_pressed = printer & 0x40 != 0,
        .cover_open = offline_cause & 0x04 != 0,
        .feeding_by_button = offline_cause & 0x08 != 0,
        .stopped_paper_end = offline_cause & 0x20 != 0,
        .error_occurred = offline_cause & 0x40 != 0,
        .mechanical_error = error_cause & 0x04 != 0,
        .cutter_error = error_cause & 0x08 != 0,
        .unrecoverable_error = error_cause & 0x20 != 0,
        .recoverable_error = error_cause & 0x40 != 0,
        .paper_near_end = paper & 0x0c != 0,
        .paper_end = paper & 0x60 != 0,
    };
}

test "healthy printer is ready" {
    const s = try parse(0x12, 0x12, 0x12, 0x12);
    try std.testing.expect(s.ready());
    try std.testing.expect(!s.paper_near_end);
}

test "decodes each condition" {
    const s = try parse(0x12 | 0x08 | 0x04, 0x12 | 0x04, 0x12 | 0x08, 0x12 | 0x0c | 0x60);
    try std.testing.expect(s.offline and s.drawer_pin_high);
    try std.testing.expect(s.cover_open);
    try std.testing.expect(s.cutter_error);
    try std.testing.expect(s.paper_near_end and s.paper_end);
    try std.testing.expect(!s.ready());
}

test "rejects bytes without the fixed bits" {
    try std.testing.expectError(error.InvalidStatus, parse(0x00, 0x12, 0x12, 0x12));
    try std.testing.expectError(error.InvalidStatus, parse(0x12, 0x92, 0x12, 0x12));
    try std.testing.expectError(error.InvalidStatus, parse(0x12, 0x12, 0x13, 0x12));
}

test "summary of a healthy printer" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeSummary(try parse(0x16, 0x12, 0x12, 0x12), &w);
    try std.testing.expectEqualStrings(
        \\Printer is ready
        \\  Online:      yes
        \\  Paper:       ok
        \\  Cover:       closed
        \\  Errors:      none
        \\  Drawer pin:  high
        \\
    , w.buffered());
}

test "summary lists problems" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // offline, cover open, cutter error, paper near end
    try writeSummary(try parse(0x12 | 0x08, 0x12 | 0x04 | 0x40, 0x12 | 0x08, 0x12 | 0x0c), &w);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "Printer is not ready\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Online:      no\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Paper:       low\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cover:       open\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Errors:      cutter\n") != null);
}

test "json has ready and every field" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJson(try parse(0x12, 0x12, 0x12, 0x12 | 0x60), &w);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"ready\":false,\"offline\":false,\"drawer_pin_high\":false"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"paper_end\":true}\n") != null);
}
