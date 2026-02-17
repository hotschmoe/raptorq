// RFC 6330 Section 5.4 - Inactivation decoding (PI solver)
//
// Five-phase algorithm:
//   Phase 1: Forward elimination with inactivation (Section 5.4.2.2)
//            HDPC rows excluded from pivot selection (Errata 2)
//   Phase 2: Solve u x u inactivated submatrix via GF(256) GE (Section 5.4.2.3)
//            Eliminates from ALL rows to also zero the upper-right block
//   Phase 3: Back-substitution on upper-triangular first-i block (Section 5.4.2.4)
//   Apply deferred symbol operations and remap via permutations

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("../matrix/octet_matrix.zig").OctetMatrix;
const Symbol = @import("../codec/symbol.zig").Symbol;
const OperationVector = @import("../codec/operation_vector.zig").OperationVector;
const SymbolOp = @import("../codec/operation_vector.zig").SymbolOp;
const Graph = @import("graph.zig").Graph;
const systematic_constants = @import("../tables/systematic_constants.zig");

pub const SolverError = error{ SingularMatrix, OutOfMemory };

pub const IntermediateSymbolResult = struct {
    symbols: []Symbol,
    ops: OperationVector,
};

const SolverState = struct {
    a: *OctetMatrix,
    l: u32,
    d: []u32, // row permutation: d[physical] = original row index
    c: []u32, // col permutation: c[physical] = original col index
    i: u32, // Phase 1 progress counter
    u: u32, // inactivated column count
    num_hdpc: u32, // H (number of HDPC rows)
    deferred_ops: std.ArrayList(SymbolOp),
    original_degree: []u16,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, a: *OctetMatrix, k_prime: u32) SolverError!SolverState {
        const si = systematic_constants.findSystematicIndex(k_prime) orelse
            return error.SingularMatrix;
        const s = si.s;
        const h = si.h;
        const l = a.numRows();
        const w = si.w;

        const d = allocator.alloc(u32, l) catch return error.OutOfMemory;
        errdefer allocator.free(d);
        const c_arr = allocator.alloc(u32, l) catch return error.OutOfMemory;
        errdefer allocator.free(c_arr);
        const orig_deg = allocator.alloc(u16, l) catch return error.OutOfMemory;
        errdefer allocator.free(orig_deg);

        for (d, 0..) |*v, idx| v.* = @intCast(idx);
        for (c_arr, 0..) |*v, idx| v.* = @intCast(idx);
        @memset(orig_deg, 0);

        var state = SolverState{
            .a = a,
            .l = l,
            .d = d,
            .c = c_arr,
            .i = 0,
            .u = l - w,
            .num_hdpc = h,
            .deferred_ops = .empty,
            .original_degree = orig_deg,
            .allocator = allocator,
        };

        // Move HDPC rows from [S, S+H) to [L-H, L)
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            state.swapRows(s + j, l - h + j);
        }

        // Compute original degree for non-HDPC rows in V = columns [0, W)
        var row: u32 = 0;
        while (row < l - h) : (row += 1) {
            var count: u16 = 0;
            var col: u32 = 0;
            while (col < w) : (col += 1) {
                if (!a.get(row, col).isZero()) count += 1;
            }
            orig_deg[row] = count;
        }

        return state;
    }

    fn deinit(self: *SolverState) void {
        self.allocator.free(self.d);
        self.allocator.free(self.c);
        self.allocator.free(self.original_degree);
        self.deferred_ops.deinit(self.allocator);
    }

    fn swapRows(self: *SolverState, r1: u32, r2: u32) void {
        if (r1 == r2) return;
        self.a.swapRows(r1, r2);
        std.mem.swap(u32, &self.d[r1], &self.d[r2]);
        std.mem.swap(u16, &self.original_degree[r1], &self.original_degree[r2]);
    }

    fn swapCols(self: *SolverState, c1: u32, c2: u32) void {
        if (c1 == c2) return;
        var r: u32 = 0;
        while (r < self.l) : (r += 1) {
            const v1 = self.a.get(r, c1);
            const v2 = self.a.get(r, c2);
            self.a.set(r, c1, v2);
            self.a.set(r, c2, v1);
        }
        std.mem.swap(u32, &self.c[c1], &self.c[c2]);
    }

    fn rowNonzerosInV(self: *SolverState, row: u32) u32 {
        const v_start = self.i;
        const v_end = self.l - self.u;
        var count: u32 = 0;
        var col = v_start;
        while (col < v_end) : (col += 1) {
            if (!self.a.get(row, col).isZero()) count += 1;
        }
        return count;
    }

    /// Collect nonzero column indices in V for the given row (up to buf.len).
    /// Returns the number of indices written.
    fn nonzeroColsInV(self: *SolverState, row: u32, buf: []u32) u32 {
        const v_start = self.i;
        const v_end = self.l - self.u;
        var count: u32 = 0;
        var col = v_start;
        while (col < v_end and count < buf.len) : (col += 1) {
            if (!self.a.get(row, col).isZero()) {
                buf[count] = col;
                count += 1;
            }
        }
        return count;
    }

    fn addOp(self: *SolverState, op: SymbolOp) SolverError!void {
        self.deferred_ops.append(self.allocator, op) catch return error.OutOfMemory;
    }
};

/// Solve for intermediate symbols using inactivation decoding.
/// Implements RFC 6330 Section 5.4.2.
pub fn solve(
    allocator: std.mem.Allocator,
    constraint_matrix: *OctetMatrix,
    symbols: []Symbol,
    k_prime: u32,
) SolverError!IntermediateSymbolResult {
    var state = try SolverState.init(allocator, constraint_matrix, k_prime);
    defer state.deinit();

    try phase1(&state);
    try phase2(&state);
    try phase3(&state);
    try applyAndRemap(&state, symbols);

    const ops_slice = state.deferred_ops.toOwnedSlice(allocator) catch
        return error.OutOfMemory;

    return .{
        .symbols = symbols,
        .ops = .{ .ops = ops_slice },
    };
}

/// Phase 1: Forward elimination with inactivation (Section 5.4.2.2)
/// HDPC rows are excluded from pivot selection per Errata 2.
/// Non-HDPC rows are binary; elimination uses XOR (addAssignRow).
/// HDPC rows are eliminated using GF(256) FMA.
fn phase1(state: *SolverState) SolverError!void {
    const l = state.l;
    const hdpc_start = l - state.num_hdpc;

    while (state.i + state.u < l) {
        const v_end = l - state.u;

        const selection = try selectPivotRow(state, hdpc_start);

        state.swapRows(state.i, selection.row);
        const min_r = selection.nonzeros;

        // Column swaps: first nonzero to diagonal, remaining r-1 to U boundary
        var nz_buf: [2]u32 = undefined;
        _ = state.nonzeroColsInV(state.i, &nz_buf);

        state.swapCols(state.i, nz_buf[0]);
        if (min_r == 2) {
            const second = if (nz_buf[1] == state.i) nz_buf[0] else nz_buf[1];
            state.swapCols(v_end - 1, second);
            state.u += 1;
        } else if (min_r >= 3) {
            var inactivated: u32 = 0;
            var c_iter = state.i + 1;
            var current_v_end = v_end;
            while (c_iter < current_v_end) {
                if (!state.a.get(state.i, c_iter).isZero()) {
                    current_v_end -= 1;
                    state.swapCols(c_iter, current_v_end);
                    inactivated += 1;
                } else {
                    c_iter += 1;
                }
            }
            state.u += inactivated;
        }

        // Eliminate column i from rows below
        try eliminateColumn(state, state.i, hdpc_start);

        state.i += 1;
    }
}

const PivotSelection = struct { row: u32, nonzeros: u32 };

/// Select the best pivot row from non-HDPC rows in [i, hdpc_start).
/// Chooses minimum nonzeros in V, breaking ties by original degree.
/// For r=2, applies the graph substep (connected component heuristic).
fn selectPivotRow(state: *SolverState, hdpc_start: u32) SolverError!PivotSelection {
    var min_r: u32 = std.math.maxInt(u32);
    var chosen_row: u32 = 0;
    var chosen_orig_deg: u16 = std.math.maxInt(u16);
    var found = false;

    var row = state.i;
    while (row < hdpc_start) : (row += 1) {
        const r_val = state.rowNonzerosInV(row);
        if (r_val == 0) continue;
        if (r_val < min_r or
            (r_val == min_r and state.original_degree[row] < chosen_orig_deg))
        {
            min_r = r_val;
            chosen_row = row;
            chosen_orig_deg = state.original_degree[row];
            found = true;
        }
    }

    if (!found) return error.SingularMatrix;

    if (min_r == 2) {
        if (try graphSubstep(state, hdpc_start)) |graph_row| {
            chosen_row = graph_row;
        }
    }

    return .{ .row = chosen_row, .nonzeros = min_r };
}

/// Eliminate a pivot column from all rows below it.
/// Non-HDPC rows use binary XOR; HDPC rows use GF(256) FMA.
fn eliminateColumn(state: *SolverState, col: u32, hdpc_start: u32) SolverError!void {
    var row = col + 1;
    while (row < hdpc_start) : (row += 1) {
        if (!state.a.get(row, col).isZero()) {
            state.a.addAssignRow(col, row);
            try state.addOp(.{ .add_assign = .{
                .src = state.d[col],
                .dst = state.d[row],
            } });
        }
    }
    row = hdpc_start;
    while (row < state.l) : (row += 1) {
        const factor = state.a.get(row, col);
        if (!factor.isZero()) {
            state.a.fmaRow(col, row, factor);
            try state.addOp(.{ .fma = .{
                .src = state.d[col],
                .dst = state.d[row],
                .scalar = factor,
            } });
        }
    }
}

/// Graph substep for r=2 rows: find largest connected component.
/// Returns the chosen row index, or null if no improvement found.
fn graphSubstep(state: *SolverState, hdpc_start: u32) SolverError!?u32 {
    const v_start = state.i;
    const v_end = state.l - state.u;
    const v_size = v_end - v_start;
    if (v_size < 2) return null;

    var graph = Graph.init(state.allocator, v_size) catch return error.OutOfMemory;
    defer graph.deinit();

    var row = state.i;
    while (row < hdpc_start) : (row += 1) {
        if (state.rowNonzerosInV(row) != 2) continue;
        var cols: [2]u32 = undefined;
        if (state.nonzeroColsInV(row, &cols) == 2) {
            graph.addEdge(cols[0] - v_start, cols[1] - v_start) catch
                return error.OutOfMemory;
        }
    }

    const labels = graph.connectedComponents(state.allocator) catch
        return error.OutOfMemory;
    defer state.allocator.free(labels);

    if (labels.len == 0) return null;

    const target_col = try findLargestComponentColumn(state.allocator, labels, v_start);

    row = state.i;
    while (row < hdpc_start) : (row += 1) {
        if (state.rowNonzerosInV(row) != 2) continue;
        if (!state.a.get(row, target_col).isZero()) return row;
    }

    return null;
}

/// Find a column belonging to the largest connected component.
fn findLargestComponentColumn(allocator: std.mem.Allocator, labels: []const u32, v_start: u32) SolverError!u32 {
    var max_label: u32 = 0;
    for (labels) |lv| {
        if (lv > max_label) max_label = lv;
    }

    const sizes = allocator.alloc(u32, max_label + 1) catch return error.OutOfMemory;
    defer allocator.free(sizes);
    @memset(sizes, 0);
    for (labels) |lv| sizes[lv] += 1;

    var largest_comp: u32 = 0;
    var largest_size: u32 = 0;
    for (sizes, 0..) |sz, comp| {
        if (sz > largest_size) {
            largest_size = sz;
            largest_comp = @intCast(comp);
        }
    }

    for (labels, 0..) |lv, node| {
        if (lv == largest_comp) return @as(u32, @intCast(node)) + v_start;
    }

    unreachable;
}

/// Phase 2: Solve u x u inactivated submatrix (Section 5.4.2.3)
/// Standard GF(256) Gaussian elimination with full pivoting.
/// Eliminates from ALL rows (including first i) to also zero the upper-right block.
fn phase2(state: *SolverState) SolverError!void {
    const l = state.l;

    var col = state.i;
    while (col < l) : (col += 1) {
        const pivot_row = findPivot(state, col) orelse return error.SingularMatrix;
        state.swapRows(col, pivot_row);

        const pivot_val = state.a.get(col, col);
        if (!pivot_val.isOne()) {
            const inv = pivot_val.inverse();
            state.a.mulAssignRow(col, inv);
            try state.addOp(.{ .mul_assign = .{
                .index = state.d[col],
                .scalar = inv,
            } });
        }

        var r: u32 = 0;
        while (r < l) : (r += 1) {
            if (r == col) continue;
            const factor = state.a.get(r, col);
            if (!factor.isZero()) {
                state.a.fmaRow(col, r, factor);
                try state.addOp(.{ .fma = .{
                    .src = state.d[col],
                    .dst = state.d[r],
                    .scalar = factor,
                } });
            }
        }
    }
}

/// Find first row in [col, L) with nonzero entry in the given column.
fn findPivot(state: *SolverState, col: u32) ?u32 {
    var r = col;
    while (r < state.l) : (r += 1) {
        if (!state.a.get(r, col).isZero()) return r;
    }
    return null;
}

/// Phase 3: Back-substitution on upper-triangular first-i block (Section 5.4.2.4)
/// After Phase 1, the first i rows/columns form an upper-triangular matrix with
/// 1s on diagonal. Back-substitution converts it to identity.
/// Phase 2 already zeroed cols [i,L) for the first i rows, so addAssignRow
/// on full rows does not re-introduce entries in the upper-right.
fn phase3(state: *SolverState) SolverError!void {
    if (state.i <= 1) return;

    var col = state.i;
    while (col > 1) {
        col -= 1;
        var row: u32 = 0;
        while (row < col) : (row += 1) {
            if (!state.a.get(row, col).isZero()) {
                state.a.addAssignRow(col, row);
                try state.addOp(.{ .add_assign = .{
                    .src = state.d[col],
                    .dst = state.d[row],
                } });
            }
        }
    }
}

/// Apply all deferred operations to symbols and remap via permutations.
fn applyAndRemap(state: *SolverState, symbols: []Symbol) SolverError!void {
    const ops = OperationVector{ .ops = state.deferred_ops.items };
    ops.apply(symbols);

    const temp = state.allocator.alloc(Symbol, state.l) catch
        return error.OutOfMemory;
    defer state.allocator.free(temp);

    @memcpy(temp, symbols[0..state.l]);
    for (0..state.l) |j| {
        symbols[state.c[j]] = temp[state.d[j]];
    }
}

test "pi_solver solves real constraint matrix K'=10" {
    const allocator = std.testing.allocator;
    const constraint_matrix_mod = @import("../matrix/constraint_matrix.zig");

    const k_prime: u32 = 10;
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const l: u32 = k_prime + si.s + si.h;

    var a = try constraint_matrix_mod.buildConstraintMatrix(allocator, k_prime);
    defer a.deinit();

    var syms: [27]Symbol = undefined;
    var init_count: usize = 0;
    defer for (syms[0..init_count]) |s| s.deinit();

    for (&syms, 0..) |*s, idx| {
        s.* = try Symbol.init(allocator, 4);
        init_count += 1;
        s.data[0] = @intCast(idx + 1);
    }

    const result = try solve(allocator, &a, &syms, k_prime);
    defer allocator.free(result.ops.ops);

    // Verify matrix is now identity
    var row: u32 = 0;
    while (row < l) : (row += 1) {
        var col: u32 = 0;
        while (col < l) : (col += 1) {
            const expected: u8 = if (row == col) 1 else 0;
            try std.testing.expectEqual(expected, a.get(row, col).value);
        }
    }
}

test "pi_solver singular detection" {
    const allocator = std.testing.allocator;
    const constraint_matrix_mod = @import("../matrix/constraint_matrix.zig");

    const k_prime: u32 = 10;
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const l: u32 = k_prime + si.s + si.h;

    var a = try constraint_matrix_mod.buildConstraintMatrix(allocator, k_prime);
    defer a.deinit();

    // Zero out a column to make it singular
    var row: u32 = 0;
    while (row < l) : (row += 1) {
        a.set(row, 0, Octet.ZERO);
    }

    var syms: [27]Symbol = undefined;
    var init_count: usize = 0;
    defer for (syms[0..init_count]) |s| s.deinit();

    for (&syms) |*s| {
        s.* = try Symbol.init(allocator, 4);
        init_count += 1;
    }

    const result = solve(allocator, &a, &syms, k_prime);
    try std.testing.expectError(error.SingularMatrix, result);
}
