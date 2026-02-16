// RFC 6330 Section 5.4 - Inactivation decoding (PI solver)

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("../matrix/octet_matrix.zig").OctetMatrix;
const Symbol = @import("../codec/symbol.zig").Symbol;
const OperationVector = @import("../codec/operation_vector.zig").OperationVector;
const Graph = @import("graph.zig").Graph;

pub const IntermediateSymbolResult = struct {
    symbols: []Symbol,
    ops: OperationVector,
};

/// Solve for intermediate symbols using inactivation decoding.
/// Implements the five phases described in RFC 6330 Section 5.4.2.
pub fn solve(
    allocator: std.mem.Allocator,
    constraint_matrix: *OctetMatrix,
    symbols: []Symbol,
    num_source_symbols: u32,
) !IntermediateSymbolResult {
    _ = .{ allocator, constraint_matrix, symbols, num_source_symbols };
    @panic("TODO");
}

/// Phase 1: Forward elimination with inactivation (Section 5.4.2.2)
fn phase1(matrix: *OctetMatrix, num_source: u32) !u32 {
    _ = .{ matrix, num_source };
    @panic("TODO");
}

/// Phase 2: Solve inactivated columns (Section 5.4.2.3)
fn phase2(matrix: *OctetMatrix, num_inactive: u32) !void {
    _ = .{ matrix, num_inactive };
    @panic("TODO");
}

/// Phase 3: Backward substitution for inactivated (Section 5.4.2.4)
fn phase3(matrix: *OctetMatrix) !void {
    _ = matrix;
    @panic("TODO");
}

/// Phase 4: Generate intermediate symbols from D (Section 5.4.2.5)
fn phase4(matrix: *OctetMatrix) !void {
    _ = matrix;
    @panic("TODO");
}

/// Phase 5: Final reconstruction (Section 5.4.2.6)
fn phase5(matrix: *OctetMatrix) !void {
    _ = matrix;
    @panic("TODO");
}
