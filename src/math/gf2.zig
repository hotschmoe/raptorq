// GF(2) binary field operations on u64-packed bit vectors

/// dst[i] ^= src[i] for all i
pub fn xorSlice(dst: []u64, src: []const u64) void {
    _ = .{ dst, src };
    @panic("TODO");
}

/// Count total set bits across slice.
pub fn countOnes(data: []const u64) usize {
    _ = data;
    @panic("TODO");
}

/// Get bit at position within packed u64 slice.
pub fn getBit(data: []const u64, pos: usize) bool {
    _ = .{ data, pos };
    @panic("TODO");
}

/// Set bit at position within packed u64 slice.
pub fn setBit(data: []u64, pos: usize, val: bool) void {
    _ = .{ data, pos, val };
    @panic("TODO");
}
