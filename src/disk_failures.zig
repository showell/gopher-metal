//! **A DISK'S FAILURES, BY KIND** (metal-vmm QUEUE 193.3). A failed read or
//! write was counted nowhere: no virtio-blk status but OK, no SCSI CHECK
//! CONDITION or its sense, no virtio-scsi response but OK (191.2's gap 3).
//! Pure: the driver notes what each request ended with, and /admin/host
//! says the tally.

const std = @import("std");

/// SPC-4 §4.5.6, table 27: the sense keys, by number.
pub const sense_key_names = [16][]const u8{
    "NO SENSE",       "RECOVERED ERROR", "NOT READY",      "MEDIUM ERROR",
    "HARDWARE ERROR", "ILLEGAL REQUEST", "UNIT ATTENTION", "DATA PROTECT",
    "BLANK CHECK",    "VENDOR SPECIFIC", "COPY ABORTED",   "ABORTED COMMAND",
    "(reserved 0Ch)", "VOLUME OVERFLOW", "MISCOMPARE",     "(reserved 0Fh)",
};

pub const Failures = struct {
    /// virtio-blk's statuses: an I/O error, a request the device does not
    /// support, and anything else that is not OK; and ours, a request
    /// refused because the disk had stopped answering (193.2).
    ioerr: u64 = 0,
    unsupported: u64 = 0,
    ended: u64 = 0,
    other_status: u64 = 0,
    last_other_status: u8 = 0,
    /// virtio-scsi: a response other than OK (the transport's verdict),
    /// and the last one.
    scsi_responses: u64 = 0,
    last_response: u8 = 0,
    /// SCSI: CHECK CONDITION, by sense key, and the last one's ASC/ASCQ.
    check_conditions: u64 = 0,
    by_sense_key: [16]u64 = @splat(0),
    last_sense_key: u8 = 0,
    last_asc: u8 = 0,
    last_ascq: u8 = 0,
    /// SCSI: another status that is not GOOD (BUSY, RESERVATION CONFLICT, ...).
    other_scsi_status: u64 = 0,
    last_scsi_status: u8 = 0,
    /// SCSI: a read or write that ended GOOD having moved fewer bytes than
    /// asked, which the driver fails.
    short_transfers: u64 = 0,

    /// A virtio-blk (or the Block's) status a request ended with.
    pub fn noteStatus(self: *Failures, status: u8) void {
        switch (status) {
            status_ok => {},
            status_ioerr => self.ioerr +%= 1,
            status_unsupp => self.unsupported +%= 1,
            status_ended => self.ended +%= 1,
            else => {
                self.other_status +%= 1;
                self.last_other_status = status;
            },
        }
    }

    /// A SCSI command's outcome.
    pub fn noteScsi(self: *Failures, response: u8, status: u8, sense_key: u8, asc: u8, ascq: u8) void {
        if (response != scsi_response_ok) {
            self.scsi_responses +%= 1;
            self.last_response = response;
            return;
        }
        switch (status) {
            scsi_status_good => {},
            scsi_status_check_condition => {
                self.check_conditions +%= 1;
                self.by_sense_key[sense_key & 0x0F] +%= 1;
                self.last_sense_key = sense_key & 0x0F;
                self.last_asc = asc;
                self.last_ascq = ascq;
            },
            else => {
                self.other_scsi_status +%= 1;
                self.last_scsi_status = status;
            },
        }
    }

    pub fn any(self: *const Failures) bool {
        return self.ioerr + self.unsupported + self.ended + self.other_status +
            self.scsi_responses + self.check_conditions + self.other_scsi_status + self.short_transfers > 0;
    }

    /// `none`, or each kind there was.
    pub fn write(self: *const Failures, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!self.any()) return w.writeAll("none");
        var first = true;
        const Sep = struct {
            fn put(wr: *std.Io.Writer, f: *bool) std.Io.Writer.Error!void {
                if (!f.*) try wr.writeAll(", ");
                f.* = false;
            }
        };
        if (self.ioerr > 0) {
            try Sep.put(w, &first);
            try w.print("{d} I/O errors", .{self.ioerr});
        }
        if (self.unsupported > 0) {
            try Sep.put(w, &first);
            try w.print("{d} unsupported", .{self.unsupported});
        }
        if (self.ended > 0) {
            try Sep.put(w, &first);
            try w.print("{d} refused after the disk stopped answering", .{self.ended});
        }
        if (self.other_status > 0) {
            try Sep.put(w, &first);
            try w.print("{d} other status (last {X:0>2}h)", .{ self.other_status, self.last_other_status });
        }
        if (self.check_conditions > 0) {
            try Sep.put(w, &first);
            try w.print("{d} CHECK CONDITION (", .{self.check_conditions});
            // The sense keys seen, the most first.
            var shown: [16]bool = @splat(false);
            var k_first = true;
            while (true) {
                var best: ?usize = null;
                for (self.by_sense_key, 0..) |n, k| if (n > 0 and !shown[k] and (best == null or n > self.by_sense_key[best.?])) {
                    best = k;
                };
                const k = best orelse break;
                shown[k] = true;
                if (!k_first) try w.writeAll(", ");
                k_first = false;
                try w.print("{s} {d}", .{ sense_key_names[k], self.by_sense_key[k] });
            }
            try w.print("; the last ASC/ASCQ {X:0>2}h/{X:0>2}h)", .{ self.last_asc, self.last_ascq });
        }
        if (self.scsi_responses > 0) {
            try Sep.put(w, &first);
            try w.print("{d} virtio-scsi response not OK (last {X:0>2}h)", .{ self.scsi_responses, self.last_response });
        }
        if (self.other_scsi_status > 0) {
            try Sep.put(w, &first);
            try w.print("{d} other SCSI status (last {X:0>2}h)", .{ self.other_scsi_status, self.last_scsi_status });
        }
        if (self.short_transfers > 0) {
            try Sep.put(w, &first);
            try w.print("{d} short transfers", .{self.short_transfers});
        }
    }
};

/// virtio-blk's and the Block's status bytes (virtio.zig's blk_s_*).
pub const status_ok: u8 = 0;
pub const status_ioerr: u8 = 1;
pub const status_unsupp: u8 = 2;
pub const status_ended: u8 = 0xEE;
/// virtio-scsi's VIRTIO_SCSI_S_OK, and SCSI's GOOD and CHECK CONDITION.
pub const scsi_response_ok: u8 = 0;
pub const scsi_status_good: u8 = 0x00;
pub const scsi_status_check_condition: u8 = 0x02;

const testing = std.testing;

fn text(f: *const Failures) ![]const u8 {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try f.write(&w);
    return testing.allocator.dupe(u8, w.buffered());
}

test "disk failures: none is said as none, and an OK counts nothing" {
    var f: Failures = .{};
    f.noteStatus(status_ok);
    f.noteScsi(scsi_response_ok, scsi_status_good, 0, 0, 0);
    try testing.expect(!f.any());
    const t = try text(&f);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("none", t);
}

test "disk failures: each virtio-blk status by its kind, ours too" {
    var f: Failures = .{};
    f.noteStatus(status_ioerr);
    f.noteStatus(status_ioerr);
    f.noteStatus(status_unsupp);
    f.noteStatus(status_ended);
    f.noteStatus(0x7F);
    try testing.expect(f.any());
    const t = try text(&f);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("2 I/O errors, 1 unsupported, 1 refused after the disk stopped answering, 1 other status (last 7Fh)", t);
}

test "disk failures: SCSI's CHECK CONDITION by sense key, with the last ASC/ASCQ, and a transport response not OK" {
    var f: Failures = .{};
    f.noteScsi(scsi_response_ok, scsi_status_check_condition, 6, 0x29, 0x00); // UNIT ATTENTION, power on
    f.noteScsi(scsi_response_ok, scsi_status_check_condition, 3, 0x11, 0x00); // MEDIUM ERROR, unrecovered read
    f.noteScsi(scsi_response_ok, scsi_status_check_condition, 3, 0x11, 0x00);
    f.noteScsi(0x09, 0xFF, 0, 0, 0); // VIRTIO_SCSI_S_FAILURE
    f.noteScsi(scsi_response_ok, 0x08, 0, 0, 0); // BUSY
    const t = try text(&f);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("3 CHECK CONDITION (MEDIUM ERROR 2, UNIT ATTENTION 1; the last ASC/ASCQ 11h/00h), 1 virtio-scsi response not OK (last 09h), 1 other SCSI status (last 08h)", t);
}
