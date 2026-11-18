//! The picture a webcam's file shows while there's no video from it: from the recording's
//! start to its first frame, while it was gone, and from when it went to the recording's end.
//! "NO VIDEO" on a dark ground, as an NV12 frame for the webcam's encoder to make a keyframe of
//! (webcam.makeNoVideo), so whatever decodes the webcam's frames decodes it too: a GPU's
//! decoder may not take a stream another encoder made, with other parameter sets.

/// Draws the picture at `width` x `height` (even, as 4:2:0 needs) into `frame`, NV12: the
/// luma, then the chroma samples, a Cb and Cr pair for each 2x2 of luma.
pub fn nv12(frame: []u8, width: u32, height: u32) void {
    std.debug.assert(width % 2 == 0 and height % 2 == 0 and frame.len == nv12Len(width, height));
    for (0..height) |y| for (0..width) |x| {
        frame[y * width + x] = luma(width, height, @intCast(x), @intCast(y));
    };
    // No colour.
    @memset(frame[width * height ..], 128);
}

pub fn nv12Len(width: u32, height: u32) usize {
    return @as(usize, width) * height * 3 / 2;
}

/// The ground and the letters, in video range (16-235).
pub const ground = 40;
pub const ink = 220;

/// The picture's luma at (x, y): the ground, with "NO VIDEO" in the middle, 60% of the width
/// (or half the height, whichever is less), its letters drawn from `glyph`, scaled to whole
/// samples.
pub fn luma(width: u32, height: u32, x: u32, y: u32) u8 {
    const text_w: u32 = text.len * (glyph_w + 1) - 1;
    const scale = @max(1, @min(width * 6 / 10 / text_w, height / 2 / glyph_h));
    const left = (width -| text_w * scale) / 2;
    const top = (height -| glyph_h * scale) / 2;
    if (x < left or y < top) return ground;
    const col = (x - left) / scale;
    const row = (y - top) / scale;
    if (col >= text_w or row >= glyph_h) return ground;
    const ch = col / (glyph_w + 1);
    const gx = col % (glyph_w + 1);
    if (gx == glyph_w) return ground; // between letters
    const rows = glyph(text[ch]);
    return if (rows[row] >> @intCast(glyph_w - 1 - gx) & 1 != 0) ink else ground;
}

const text = "NO VIDEO";
const glyph_w = 5;
const glyph_h = 7;

/// A 5x7 letter, a row a byte, its leftmost column the high bit of five.
fn glyph(c: u8) [glyph_h]u8 {
    return switch (c) {
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        ' ' => @splat(0),
        else => unreachable,
    };
}

test luma {
    // The corners: ground. The left edge of the N's first stroke: ink, with ground just left
    // of it.
    try std.testing.expectEqual(ground, luma(640, 480, 0, 0));
    try std.testing.expectEqual(ground, luma(640, 480, 639, 479));
    const text_w: u32 = text.len * (glyph_w + 1) - 1;
    const scale: u32 = @min(640 * 6 / 10 / text_w, 480 / 2 / glyph_h);
    const left = (640 - text_w * scale) / 2;
    const top = (480 - glyph_h * scale) / 2;
    try std.testing.expectEqual(ink, luma(640, 480, left, top));
    try std.testing.expectEqual(ground, luma(640, 480, left - 1, top));
}

test nv12 {
    const gpa = std.testing.allocator;
    const frame = try gpa.alloc(u8, nv12Len(64, 32));
    defer gpa.free(frame);
    nv12(frame, 64, 32);
    try std.testing.expectEqual(luma(64, 32, 10, 10), frame[10 * 64 + 10]);
    try std.testing.expect(std.mem.allEqual(u8, frame[64 * 32 ..], 128));
}

const std = @import("std");
