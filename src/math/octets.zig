// Bulk GF(256) operations on byte slices

const octet_tables = @import("../tables/octet_tables.zig");
const Octet = @import("octet.zig").Octet;

/// dst[i] ^= src[i] for all i
pub fn addAssign(dst: []u8, src: []const u8) void {
    for (dst, src) |*d, s| {
        d.* ^= s;
    }
}

/// dst[i] = dst[i] * scalar for all i
pub fn mulAssignScalar(dst: []u8, scalar: Octet) void {
    if (scalar.value == 0) {
        @memset(dst, 0);
        return;
    }
    if (scalar.value == 1) return;
    const log_scalar = @as(u16, octet_tables.OCT_LOG[scalar.value]);
    for (dst) |*d| {
        if (d.* != 0) {
            d.* = octet_tables.OCT_EXP[@as(u16, octet_tables.OCT_LOG[d.*]) + log_scalar];
        }
    }
}

/// dst[i] += src[i] * scalar for all i (fused multiply-add)
pub fn fmaSlice(dst: []u8, src: []const u8, scalar: Octet) void {
    if (scalar.value == 0) return;
    if (scalar.value == 1) {
        addAssign(dst, src);
        return;
    }
    const log_scalar = @as(u16, octet_tables.OCT_LOG[scalar.value]);
    for (dst, src) |*d, s| {
        if (s != 0) {
            d.* ^= octet_tables.OCT_EXP[@as(u16, octet_tables.OCT_LOG[s]) + log_scalar];
        }
    }
}

/// Set all bytes to zero.
pub fn zero(dst: []u8) void {
    @memset(dst, 0);
}
