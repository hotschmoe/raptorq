// RFC 6330 Section 5.4 - Inactivation decoding (PI solver)

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("../matrix/octet_matrix.zig").OctetMatrix;
const Symbol = @import("../codec/symbol.zig").Symbol;
const OperationVector = @import("../codec/operation_vector.zig").OperationVector;
const SymbolOp = @import("../codec/operation_vector.zig").SymbolOp;

pub const SolverError = error{ SingularMatrix, OutOfMemory };

pub const IntermediateSymbolResult = struct {
    symbols: []Symbol,
    ops: OperationVector,
};

/// Internal solver state tracking permutations and progress.
const SolverState = struct {
    a: *OctetMatrix,
    l: u32,
    row_perm: []u32,
    col_perm: []u32,
    i: u32,
    u_count: u32,
    ops: std.ArrayList(SymbolOp),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, a: *OctetMatrix) !SolverState {
        const l = a.numRows();
        const row_perm = try allocator.alloc(u32, l);
        const col_perm = try allocator.alloc(u32, l);
        for (row_perm, 0..) |*r, idx| r.* = @intCast(idx);
        for (col_perm, 0..) |*c, idx| c.* = @intCast(idx);

        return .{
            .a = a,
            .l = l,
            .row_perm = row_perm,
            .col_perm = col_perm,
            .i = 0,
            .u_count = 0,
            .ops = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *SolverState) void {
        self.allocator.free(self.row_perm);
        self.allocator.free(self.col_perm);
        self.ops.deinit(self.allocator);
    }

    fn swapPhysicalRows(self: *SolverState, r1: u32, r2: u32) void {
        if (r1 == r2) return;
        self.a.swapRows(r1, r2);
        std.mem.swap(u32, &self.row_perm[r1], &self.row_perm[r2]);
    }

    fn swapPhysicalCols(self: *SolverState, c1: u32, c2: u32) void {
        if (c1 == c2) return;
        // Swap column entries in every row
        var r: u32 = 0;
        while (r < self.l) : (r += 1) {
            const v1 = self.a.get(r, c1);
            const v2 = self.a.get(r, c2);
            self.a.set(r, c1, v2);
            self.a.set(r, c2, v1);
        }
        std.mem.swap(u32, &self.col_perm[c1], &self.col_perm[c2]);
    }

    /// Count nonzeros in columns [col_start..col_end) for a given row.
    fn rowNonzeros(self: *SolverState, row: u32, col_start: u32, col_end: u32) u32 {
        var count: u32 = 0;
        var c = col_start;
        while (c < col_end) : (c += 1) {
            if (!self.a.get(row, c).isZero()) count += 1;
        }
        return count;
    }

    /// Scale pivot row to 1 and eliminate all rows below position i.
    fn scalePivotAndEliminate(self: *SolverState) SolverError!void {
        const pivot_val = self.a.get(self.i, self.i);
        if (pivot_val.isZero()) return error.SingularMatrix;

        if (!pivot_val.isOne()) {
            const inv = pivot_val.inverse();
            self.a.mulAssignRow(self.i, inv);
            self.ops.append(self.allocator, .{ .mul_assign = .{
                .index = self.row_perm[self.i],
                .scalar = inv,
            } }) catch return error.OutOfMemory;
        }

        var row: u32 = self.i + 1;
        while (row < self.l) : (row += 1) {
            const factor = self.a.get(row, self.i);
            if (!factor.isZero()) {
                self.a.fmaRow(self.i, row, factor);
                self.ops.append(self.allocator, .{ .fma = .{
                    .src = self.row_perm[self.i],
                    .dst = self.row_perm[row],
                    .scalar = factor,
                } }) catch return error.OutOfMemory;
            }
        }
    }
};

/// Solve for intermediate symbols using inactivation decoding.
/// Implements the five phases described in RFC 6330 Section 5.4.2.
pub fn solve(
    allocator: std.mem.Allocator,
    constraint_matrix: *OctetMatrix,
    symbols: []Symbol,
    num_source_symbols: u32,
) SolverError!IntermediateSymbolResult {
    _ = num_source_symbols;
    var state = SolverState.init(allocator, constraint_matrix) catch return error.OutOfMemory;
    defer state.deinit();

    try phase1(&state);
    try phase2(&state);
    // Phases 3-4 (backward substitution) are subsumed by phase 2's full elimination.
    try phase5(&state, symbols);

    const ops_slice = state.ops.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return .{
        .symbols = symbols,
        .ops = .{ .ops = ops_slice },
    };
}

/// Phase 1: Forward elimination with inactivation (Section 5.4.2.2)
fn phase1(state: *SolverState) SolverError!void {
    const l = state.l;

    while (state.i + state.u_count < l) {
        const v_end = l - state.u_count;

        // Find row with minimum nonzeros in V submatrix (rows/cols [i..v_end))
        var min_r: u32 = 0;
        var min_row_idx: u32 = 0;
        var found = false;

        {
            var row = state.i;
            while (row < l) : (row += 1) {
                const nz = state.rowNonzeros(row, state.i, v_end);
                if (!found or nz < min_r) {
                    min_r = nz;
                    min_row_idx = row;
                    found = true;
                    if (nz == 1) break;
                }
            }
        }

        if (!found or min_r == 0) {
            return error.SingularMatrix;
        }

        // All branches: move chosen row to position i, then select pivot column(s)
        state.swapPhysicalRows(state.i, min_row_idx);

        if (min_r == 1) {
            // Single nonzero: find and swap it to the diagonal
            var pivot_col = state.i;
            while (pivot_col < v_end) : (pivot_col += 1) {
                if (!state.a.get(state.i, pivot_col).isZero()) break;
            }
            state.swapPhysicalCols(state.i, pivot_col);
        } else if (min_r == 2) {
            // Two nonzeros: pivot on first, inactivate second
            var cols_found: [2]u32 = undefined;
            var cf: u32 = 0;
            {
                var c = state.i;
                while (c < v_end and cf < 2) : (c += 1) {
                    if (!state.a.get(state.i, c).isZero()) {
                        cols_found[cf] = c;
                        cf += 1;
                    }
                }
            }
            state.swapPhysicalCols(state.i, cols_found[0]);
            // After swapping cols_found[0] to state.i, the second nonzero
            // may have moved if it was originally at state.i
            const second = if (cols_found[1] == state.i) cols_found[0] else cols_found[1];
            state.swapPhysicalCols(v_end - 1, second);
            state.u_count += 1;
        } else {
            // r >= 3: pivot first nonzero, inactivate the rest
            var first_nz: u32 = state.i;
            while (first_nz < v_end) : (first_nz += 1) {
                if (!state.a.get(state.i, first_nz).isZero()) break;
            }
            state.swapPhysicalCols(state.i, first_nz);

            var inactivated: u32 = 0;
            var c = state.i + 1;
            var current_v_end = v_end;
            while (c < current_v_end) {
                if (!state.a.get(state.i, c).isZero()) {
                    current_v_end -= 1;
                    state.swapPhysicalCols(c, current_v_end);
                    inactivated += 1;
                } else {
                    c += 1;
                }
            }
            state.u_count += inactivated;
        }

        try state.scalePivotAndEliminate();

        state.i += 1;
    }
}

/// Phase 2: Solve u x u inactivated submatrix (Section 5.4.2.3)
fn phase2(state: *SolverState) SolverError!void {
    const i_val = state.i;
    const l = state.l;
    const u_val = state.u_count;

    if (u_val == 0) return;

    // Standard Gaussian elimination on the u x u block at (i, L-u)
    var col: u32 = i_val;
    while (col < l) : (col += 1) {
        // Find pivot
        var pivot_row: ?u32 = null;
        {
            var r = col;
            while (r < l) : (r += 1) {
                if (!state.a.get(r, col).isZero()) {
                    pivot_row = r;
                    break;
                }
            }
        }

        if (pivot_row == null) return error.SingularMatrix;

        state.swapPhysicalRows(col, pivot_row.?);

        // Scale pivot row
        const pivot_val = state.a.get(col, col);
        if (!pivot_val.isOne()) {
            const inv = pivot_val.inverse();
            state.a.mulAssignRow(col, inv);
            state.ops.append(state.allocator,.{ .mul_assign = .{ .index = state.row_perm[col], .scalar = inv } }) catch return error.OutOfMemory;
        }

        // Eliminate all other rows
        {
            var r: u32 = 0;
            while (r < l) : (r += 1) {
                if (r == col) continue;
                const factor = state.a.get(r, col);
                if (!factor.isZero()) {
                    state.a.fmaRow(col, r, factor);
                    state.ops.append(state.allocator,.{ .fma = .{
                        .src = state.row_perm[col],
                        .dst = state.row_perm[r],
                        .scalar = factor,
                    } }) catch return error.OutOfMemory;
                }
            }
        }
    }
}

/// Phase 5: Apply recorded operations to symbols and remap (Section 5.4.2.6)
fn phase5(state: *SolverState, symbols: []Symbol) SolverError!void {
    // Apply all recorded operations to the symbol vector
    for (state.ops.items) |op| {
        switch (op) {
            .add_assign => |o| symbols[o.dst].addAssign(symbols[o.src]),
            .mul_assign => |o| symbols[o.index].mulAssign(o.scalar),
            .fma => |o| symbols[o.dst].fma(symbols[o.src], o.scalar),
            .reorder => |o| std.mem.swap(Symbol, &symbols[o.src], &symbols[o.dst]),
        }
    }

    // Remap symbols: physical position j solved for original column col_perm[j],
    // using the value from original row row_perm[j].
    // So x[col_perm[j]] = symbols_after_ops[row_perm[j]]
    const temp = state.allocator.alloc(Symbol, state.l) catch return error.OutOfMemory;
    defer state.allocator.free(temp);

    for (temp, 0..) |*t, idx| {
        t.* = symbols[idx];
    }
    for (0..state.l) |j| {
        symbols[state.col_perm[j]] = temp[state.row_perm[j]];
    }
}

test "pi_solver identity system" {
    const allocator = std.testing.allocator;

    // 3x3 identity matrix should pass through unchanged
    var m = try OctetMatrix.identity(allocator, 3);
    defer m.deinit();

    var syms: [3]Symbol = undefined;
    for (&syms, 0..) |*s, idx| {
        s.* = try Symbol.init(allocator, 4);
        s.data[0] = @intCast(idx + 1);
    }
    defer for (&syms) |s| s.deinit();

    const result = try solve(allocator, &m, &syms, 3);
    defer allocator.free(result.ops.ops);

    try std.testing.expectEqual(@as(u8, 1), syms[0].data[0]);
    try std.testing.expectEqual(@as(u8, 2), syms[1].data[0]);
    try std.testing.expectEqual(@as(u8, 3), syms[2].data[0]);
}

test "pi_solver simple 2x2 system" {
    const allocator = std.testing.allocator;

    // [ 1  1 ]   [ x ]   [ a^b ]
    // [ 0  1 ] * [ y ] = [  b  ]
    // where a=5, b=3
    // So x^y = 5^3 = 6, y = 3 => x = 6^3 = 5
    var m = try OctetMatrix.init(allocator, 2, 2);
    defer m.deinit();
    m.set(0, 0, Octet.ONE);
    m.set(0, 1, Octet.ONE);
    m.set(1, 0, Octet.ZERO);
    m.set(1, 1, Octet.ONE);

    var syms: [2]Symbol = undefined;
    syms[0] = try Symbol.init(allocator, 1);
    syms[0].data[0] = 5 ^ 3;
    syms[1] = try Symbol.init(allocator, 1);
    syms[1].data[0] = 3;
    defer for (&syms) |s| s.deinit();

    const result = try solve(allocator, &m, &syms, 2);
    defer allocator.free(result.ops.ops);

    try std.testing.expectEqual(@as(u8, 5), syms[0].data[0]);
    try std.testing.expectEqual(@as(u8, 3), syms[1].data[0]);
}

test "pi_solver singular detection" {
    const allocator = std.testing.allocator;

    var m = try OctetMatrix.init(allocator, 2, 2);
    defer m.deinit();
    m.set(0, 0, Octet.ONE);
    m.set(0, 1, Octet.ONE);
    m.set(1, 0, Octet.ONE);
    m.set(1, 1, Octet.ONE);

    var syms: [2]Symbol = undefined;
    syms[0] = try Symbol.init(allocator, 1);
    syms[1] = try Symbol.init(allocator, 1);
    defer for (&syms) |s| s.deinit();

    const result = solve(allocator, &m, &syms, 2);
    try std.testing.expectError(error.SingularMatrix, result);
}
