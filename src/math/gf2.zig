// GF(2) binary field operations on u64-packed bit vectors

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
