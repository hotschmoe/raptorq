// Bulk GF(256) operations on byte slices

const Octet = @import("octet.zig").Octet;

/// dst[i] ^= src[i] for all i
pub fn addAssign(dst: []u8, src: []const u8) void {
    _ = .{ dst, src };
    @panic("TODO");
}

/// dst[i] = dst[i] * scalar for all i
pub fn mulAssignScalar(dst: []u8, scalar: Octet) void {
    _ = .{ dst, scalar };
    @panic("TODO");
}

/// dst[i] += src[i] * scalar for all i (fused multiply-add)
pub fn fmaSlice(dst: []u8, src: []const u8, scalar: Octet) void {
    _ = .{ dst, src, scalar };
    @panic("TODO");
}

/// Set all bytes to zero.
pub fn zero(dst: []u8) void {
    _ = dst;
    @panic("TODO");
}
