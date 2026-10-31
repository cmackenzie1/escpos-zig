//! Real-time printer status (DLE EOT n). The printer answers each request with
//! one byte, so this needs a connection you can read from, such as a USB
//! device file opened read-write or a network socket.
const std = @import("std");

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

pub const ParseError = error{
    /// The byte's fixed bits don't match a status reply, so it probably isn't
    /// one (for example, stale data on the connection).
    InvalidStatus,
};

/// All four status replies, decoded.
pub const Status = struct {
    /// DLE EOT 1: the printer is offline and won't accept print data.
    offline: bool,
    /// DLE EOT 1: a cash drawer is connected and its sense pin reads high.
    drawer_open: bool,
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

/// Check the fixed bits shared by every status reply: bit 7 and bit 0 clear,
/// bit 4 and bit 1 set (`0xx1xx10`).
fn check(byte: u8) ParseError!void {
    if (byte & 0x93 != 0x12) return error.InvalidStatus;
}

/// Decode the four replies (`printer` = DLE EOT 1, and so on).
pub fn parse(printer: u8, offline_cause: u8, error_cause: u8, paper: u8) ParseError!Status {
    inline for (.{ printer, offline_cause, error_cause, paper }) |b| try check(b);
    return .{
        .drawer_open = printer & 0x04 != 0,
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
    try std.testing.expect(s.offline and s.drawer_open);
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
