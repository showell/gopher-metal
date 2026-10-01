//! **THE SCREEN, FOR A MACHINE WHOSE ONLY WINDOW IS ITS SCREEN.** A droplet's
//! serial port goes nowhere anyone can read; DigitalOcean's recovery console
//! shows the screen. So everything the console says is also written here.
//!
//! After the BIOS, a PC's screen is in text mode 3: 80 columns by 25 rows,
//! two bytes a character (the character, then its colours) from physical
//! 0xB8000. The boot loader printed through the BIOS, and the BIOS keeps its
//! cursor in its data area (column at 0x450, row at 0x451), so this carries on
//! below the loader's lines rather than over them. The bottom row scrolls.
//!
//! **ONLY A MACHINE THAT HAS A SCREEN IS WRITTEN TO.** On QEMU's microvm or
//! metal-vmm, 0xB8000 may be ordinary memory, and text written there would
//! land in whatever the page allocator handed out. `attach` turns the screen
//! on only when the PCI bus lists a display controller (class 03), which a
//! droplet does in slot 02.

const pci = @import("pci.zig");
const port = @import("port.zig");

const columns = 80;
const rows = 25;
/// Light grey on black: what the BIOS left, so the two halves match.
const colour: u16 = 0x07 << 8;

var on = false;
var row: usize = 0;
var column: usize = 0;
/// The text memory, and whether it is the real screen (whose cursor is moved
/// through the display controller's ports). A host test points it at an array.
var buffer: [*]volatile u16 = @ptrFromInt(0xB8000);
var hardware = true;

fn cell(r: usize, c: usize) *volatile u16 {
    return &buffer[r * columns + c];
}

/// Turns the screen on if this machine has one, starting where the BIOS's
/// cursor was left.
pub fn attach() void {
    if (!pci.present()) return;
    var scan = pci.Scan{};
    while (scan.next()) |f| {
        if (f.read8(0x0B) == 0x03) {
            on = true;
            column = @min(@as(*volatile u8, @ptrFromInt(0x450)).*, columns - 1);
            row = @min(@as(*volatile u8, @ptrFromInt(0x451)).*, rows - 1);
            return;
        }
    }
}

pub fn present() bool {
    return on;
}

pub fn put(bytes: []const u8) void {
    if (!on) return;
    for (bytes) |b| putChar(b);
    // A host test has no display controller, and its compiler no I/O ports.
    if (!@import("builtin").is_test and hardware) moveCursor();
}

fn putChar(b: u8) void {
    switch (b) {
        '\r' => column = 0,
        '\n' => newLine(),
        else => {
            // **A FULL ROW WRAPS ON THE NEXT CHARACTER, NOT ON THE LAST ONE**,
            // as a terminal does: an 80-character line followed by its own
            // newline is one row, not a row and a blank one.
            if (column == columns) newLine();
            cell(row, column).* = colour | b;
            column += 1;
        },
    }
}

fn newLine() void {
    column = 0;
    if (row + 1 < rows) {
        row += 1;
        return;
    }
    for (1..rows) |r| {
        for (0..columns) |c| cell(r - 1, c).* = cell(r, c).*;
    }
    for (0..columns) |c| cell(rows - 1, c).* = colour | ' ';
}

/// The blinking cursor, through the display controller's index and data
/// ports, so it sits where the next character goes.
fn moveCursor() void {
    const at: u16 = @intCast(row * columns + @min(column, columns - 1));
    port.outb(0x3D4, 0x0F);
    port.outb(0x3D5, @truncate(at));
    port.outb(0x3D4, 0x0E);
    port.outb(0x3D5, @truncate(at >> 8));
}

// ── what can be checked without a screen ─────────────────────────────────────

const std = @import("std");

fn rowText(r: usize, out: *[columns]u8) []const u8 {
    for (0..columns) |c| out[c] = @truncate(cell(r, c).*);
    return std.mem.trimEnd(u8, out, " ");
}

test "thirty lines on a twenty-five row screen keep the last twenty-five, in order" {
    var memory: [rows * columns]u16 = @splat(colour | ' ');
    buffer = &memory;
    hardware = false;
    on = true;
    row = 0;
    column = 0;
    defer on = false;

    var line: [16]u8 = undefined;
    for (1..31) |n| put(try std.fmt.bufPrint(&line, "line {d}\n", .{n}));

    var text: [columns]u8 = undefined;
    for (0..rows - 1) |r| {
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&line, "line {d}", .{r + 7}), rowText(r, &text));
    }
    // The cursor sits on the empty bottom row the last newline made.
    try std.testing.expectEqualStrings("", rowText(rows - 1, &text));
    try std.testing.expectEqual(@as(usize, rows - 1), row);
}

test "a full row followed by its newline is one row, not two" {
    var memory: [rows * columns]u16 = @splat(colour | ' ');
    buffer = &memory;
    hardware = false;
    on = true;
    row = 0;
    column = 0;
    defer on = false;

    put("x" ** columns ++ "\nnext\n");
    var text: [columns]u8 = undefined;
    try std.testing.expectEqualStrings("x" ** columns, rowText(0, &text));
    try std.testing.expectEqualStrings("next", rowText(1, &text));
}
