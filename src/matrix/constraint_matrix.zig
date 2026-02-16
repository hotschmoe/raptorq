// RFC 6330 Section 5.3.3 - Constraint matrix construction

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("octet_matrix.zig").OctetMatrix;
const SparseBinaryMatrix = @import("sparse_matrix.zig").SparseBinaryMatrix;
const systematic_constants = @import("../tables/systematic_constants.zig");
const rng = @import("../math/rng.zig");

/// Build the constraint matrix A for a given K' (RFC 6330 Section 5.3.3.3).
/// A has L rows and L columns where L = K' + S + H.
pub fn buildConstraintMatrix(allocator: std.mem.Allocator, k_prime: u32) !OctetMatrix {
    _ = .{ allocator, k_prime };
    @panic("TODO");
}

/// Generate LDPC rows of constraint matrix (RFC 6330 Section 5.3.3.3, first part).
pub fn generateLDPC(matrix: *OctetMatrix, k_prime: u32, s: u32) void {
    _ = .{ matrix, k_prime, s };
    @panic("TODO");
}

/// Generate HDPC rows of constraint matrix (RFC 6330 Section 5.3.3.3, second part).
pub fn generateHDPC(matrix: *OctetMatrix, k_prime: u32, s: u32, h: u32) void {
    _ = .{ matrix, k_prime, s, h };
    @panic("TODO");
}

/// Generate LT rows (encoding relationships) in the constraint matrix.
pub fn generateLT(matrix: *OctetMatrix, k_prime: u32, s: u32, h: u32, num_symbols: u32) void {
    _ = .{ matrix, k_prime, s, h, num_symbols };
    @panic("TODO");
}
