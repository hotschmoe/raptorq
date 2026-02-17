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
    var count: u32 = 0;

    if (first_word == last_word) {
        return @popCount(data[first_word] & wordMask(start_bit % 64, end_bit - first_word * 64));
    }

    count += @popCount(data[first_word] & wordMask(start_bit % 64, 64));
    for (data[first_word + 1 .. last_word]) |word| {
        count += @popCount(word);
    }
    count += @popCount(data[last_word] & wordMask(0, end_bit - last_word * 64));

    return count;
}

/// Build a bitmask for bits [start, end) within a single u64 word.
/// start and end are bit positions within the word (0..64).
fn wordMask(start: u32, end: u32) u64 {
    const high: u64 = if (end >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(end)) - 1;
    const low: u64 = if (start == 0) 0 else (@as(u64, 1) << @intCast(start)) - 1;
    return high & ~low;
}

/// XOR src into dst, but only for bits from start_col onward.
pub fn xorSliceFrom(dst: []u64, src: []const u64, start_col: u32) void {
    const first_word = start_col / 64;
    if (first_word >= dst.len) return;

    const first_bit: u6 = @intCast(start_col % 64);
    if (first_bit != 0) {
        dst[first_word] ^= src[first_word] & (@as(u64, std.math.maxInt(u64)) << first_bit);
    } else {
        dst[first_word] ^= src[first_word];
    }
    for (dst[first_word + 1 ..], src[first_word + 1 ..]) |*d, s| {
        d.* ^= s;
    }
}
