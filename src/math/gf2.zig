// GF(2) binary field operations on u64-packed bit vectors

const std = @import("std");

/// dst[i] ^= src[i] for all i
pub fn xorSlice(dst: []u64, src: []const u64) void {
    for (dst, src) |*d, s| {
        d.* ^= s;
    }
}

/// Count total set bits across slice.
pub fn countOnes(data: []const u64) usize {
    var count: usize = 0;
    for (data) |word| {
        count += @popCount(word);
    }
    return count;
}

/// Get bit at position within packed u64 slice.
pub fn getBit(data: []const u64, pos: usize) bool {
    return (data[pos / 64] >> @intCast(pos % 64)) & 1 == 1;
}

/// Set bit at position within packed u64 slice.
pub fn setBit(data: []u64, pos: usize, val: bool) void {
    const bit: u6 = @intCast(pos % 64);
    if (val) {
        data[pos / 64] |= @as(u64, 1) << bit;
    } else {
        data[pos / 64] &= ~(@as(u64, 1) << bit);
    }
}

/// Count set bits in [start_bit, end_bit) range of a packed u64 slice.
pub fn countOnesInRange(data: []const u64, start_bit: u32, end_bit: u32) u32 {
    if (start_bit >= end_bit) return 0;
    const first_word = start_bit / 64;
    const last_word = (end_bit - 1) / 64;

    if (first_word == last_word) {
        const mask = rangeMask(start_bit % 64, end_bit - first_word * 64);
        return @popCount(data[first_word] & mask);
    }

    var count: u32 = 0;

    // First partial word
    const first_bit: u6 = @intCast(start_bit % 64);
    count += @popCount(data[first_word] & (@as(u64, std.math.maxInt(u64)) << first_bit));

    // Full words in the middle
    var w = first_word + 1;
    while (w < last_word) : (w += 1) {
        count += @popCount(data[w]);
    }

    // Last partial word
    const end_mod: u7 = @intCast(end_bit - last_word * 64);
    if (end_mod == 64) {
        count += @popCount(data[last_word]);
    } else {
        count += @popCount(data[last_word] & ((@as(u64, 1) << @intCast(end_mod)) - 1));
    }

    return count;
}

/// Build a bitmask for bits [start, end) within a single word.
fn rangeMask(start: u32, end: u32) u64 {
    const high: u64 = if (end >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(end)) - 1;
    const low: u64 = if (start == 0) 0 else (@as(u64, 1) << @intCast(start)) - 1;
    return high & ~low;
}

/// XOR src into dst, but only for bits from start_col onward.
pub fn xorSliceFrom(dst: []u64, src: []const u64, start_col: u32) void {
    const first_word = start_col / 64;
    if (first_word >= dst.len) return;

    // First partial word: mask off bits below start_col
    const first_bit: u6 = @intCast(start_col % 64);
    if (first_bit != 0) {
        const mask = @as(u64, std.math.maxInt(u64)) << first_bit;
        dst[first_word] ^= src[first_word] & mask;
        for (dst[first_word + 1 ..], src[first_word + 1 ..]) |*d, s| {
            d.* ^= s;
        }
    } else {
        for (dst[first_word..], src[first_word..]) |*d, s| {
            d.* ^= s;
        }
    }
}
