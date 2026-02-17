// RFC 6330 Section 5.4 - Inactivation decoding (PI solver)
//
// Five-phase algorithm:
//   Phase 1: Forward elimination with inactivation (Section 5.4.2.2)
//            HDPC rows excluded from pivot selection (Errata 2)
//            Binary rows use bit-packed DenseBinaryMatrix (~64x faster pivot selection)
//   Phase 2: Solve u x u inactivated submatrix via GF(256) GE (Section 5.4.2.3)
//            Eliminates from ALL rows to also zero the upper-right block
//   Phase 3: Back-substitution on upper-triangular first-i block (Section 5.4.2.4)
//   Apply deferred symbol operations and remap via permutations

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("../matrix/octet_matrix.zig").OctetMatrix;
const DenseBinaryMatrix = @import("../matrix/dense_binary_matrix.zig").DenseBinaryMatrix;
const Symbol = @import("../codec/symbol.zig").Symbol;
const OperationVector = @import("../codec/operation_vector.zig").OperationVector;
const SymbolOp = @import("../codec/operation_vector.zig").SymbolOp;
const ConnectedComponentGraph = @import("graph.zig").ConnectedComponentGraph;
const systematic_constants = @import("../tables/systematic_constants.zig");

pub const SolverError = error{ SingularMatrix, OutOfMemory };

pub const IntermediateSymbolResult = struct {
    symbols: []Symbol,
    ops: OperationVector,
};

const SolverState = struct {
    binary: DenseBinaryMatrix, // (L-H) rows x L cols, bit-packed
    hdpc: *OctetMatrix, // original matrix, used for HDPC rows
    graph: ConnectedComponentGraph, // persistent, reset per r=2 iteration
    l: u32,
    d: []u32, // row permutation: d[physical] = original row index
    c: []u32, // col permutation: c[physical] = original col index
    i: u32, // Phase 1 progress counter
    u: u32, // inactivated column count
    hdpc_start: u32, // L - H (first HDPC row index)
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
        const hdpc_start = l - h;

        const d = allocator.alloc(u32, l) catch return error.OutOfMemory;
        errdefer allocator.free(d);
        const c_arr = allocator.alloc(u32, l) catch return error.OutOfMemory;
        errdefer allocator.free(c_arr);
        const orig_deg = allocator.alloc(u16, l) catch return error.OutOfMemory;
        errdefer allocator.free(orig_deg);

        for (d, 0..) |*v, idx| v.* = @intCast(idx);
        for (c_arr, 0..) |*v, idx| v.* = @intCast(idx);
        @memset(orig_deg, 0);

        // Move HDPC rows from [S, S+H) to [L-H, L) in OctetMatrix
        if (s != hdpc_start) {
            var j: u32 = 0;
            while (j < h) : (j += 1) {
                a.swapRows(s + j, hdpc_start + j);
                std.mem.swap(u32, &d[s + j], &d[hdpc_start + j]);
            }
        }

        // Build DenseBinaryMatrix from OctetMatrix rows [0, hdpc_start)
        var binary = DenseBinaryMatrix.init(allocator, hdpc_start, l) catch
            return error.OutOfMemory;
        errdefer binary.deinit();

        {
            var row: u32 = 0;
            while (row < hdpc_start) : (row += 1) {
                var col: u32 = 0;
                while (col < l) : (col += 1) {
                    if (!a.get(row, col).isZero()) {
                        binary.set(row, col, true);
                    }
                }
            }
        }

        // Compute original degree from binary matrix (popcount)
        {
            var row: u32 = 0;
            while (row < hdpc_start) : (row += 1) {
                orig_deg[row] = @intCast(binary.countOnesInRange(row, 0, w));
            }
        }

        var graph = ConnectedComponentGraph.init(allocator, l) catch
            return error.OutOfMemory;
        errdefer graph.deinit(allocator);

        return SolverState{
            .binary = binary,
            .hdpc = a,
            .graph = graph,
            .l = l,
            .d = d,
            .c = c_arr,
            .i = 0,
            .u = l - w,
            .hdpc_start = hdpc_start,
            .deferred_ops = .empty,
            .original_degree = orig_deg,
            .allocator = allocator,
        };
    }

    fn deinit(self: *SolverState) void {
        self.binary.deinit();
        self.graph.deinit(self.allocator);
        self.allocator.free(self.d);
        self.allocator.free(self.c);
        self.allocator.free(self.original_degree);
        self.deferred_ops.deinit(self.allocator);
    }

    fn swapRows(self: *SolverState, r1: u32, r2: u32) void {
        if (r1 == r2) return;
        // Both in binary region
        if (r1 < self.hdpc_start and r2 < self.hdpc_start) {
            self.binary.swapRows(r1, r2);
        }
        // Both in HDPC region
        else if (r1 >= self.hdpc_start and r2 >= self.hdpc_start) {
            self.hdpc.swapRows(r1, r2);
        }
        // Cross-region swap (should not occur in Phase 1 after HDPC relocation,
        // but Phase 2 may swap freely)
        else {
            self.swapRowsCrossRegion(r1, r2);
        }
        std.mem.swap(u32, &self.d[r1], &self.d[r2]);
        std.mem.swap(u16, &self.original_degree[r1], &self.original_degree[r2]);
    }

    fn swapRowsCrossRegion(self: *SolverState, r1: u32, r2: u32) void {
        const bin_row = if (r1 < self.hdpc_start) r1 else r2;
        const hdpc_row = if (r1 >= self.hdpc_start) r1 else r2;

        // Exchange element by element across the two matrix representations
        var col: u32 = 0;
        while (col < self.l) : (col += 1) {
            const bin_val = self.binary.get(bin_row, col);
            const hdpc_val = self.hdpc.get(hdpc_row, col);
            self.binary.set(bin_row, col, !hdpc_val.isZero());
            self.hdpc.set(hdpc_row, col, if (bin_val) Octet.ONE else Octet.ZERO);
        }
    }

    fn swapCols(self: *SolverState, c1: u32, c2: u32) void {
        if (c1 == c2) return;
        self.binary.swapCols(c1, c2, self.i);
        var r = self.hdpc_start;
        while (r < self.l) : (r += 1) {
            const row_bytes = self.hdpc.rowSlice(r);
            std.mem.swap(u8, &row_bytes[c1], &row_bytes[c2]);
        }
        std.mem.swap(u32, &self.c[c1], &self.c[c2]);
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

    const do_profile = profile_enabled;

    var t: [5]std.time.Instant = undefined;
    if (do_profile) t[0] = std.time.Instant.now() catch unreachable;
    try phase1(&state);
    if (do_profile) t[1] = std.time.Instant.now() catch unreachable;
    try phase2(&state);
    if (do_profile) t[2] = std.time.Instant.now() catch unreachable;
    try phase3(&state);
    if (do_profile) t[3] = std.time.Instant.now() catch unreachable;
    try applyAndRemap(&state, symbols);
    if (do_profile) t[4] = std.time.Instant.now() catch unreachable;

    if (do_profile) {
        const p1 = t[1].since(t[0]);
        const p2 = t[2].since(t[1]);
        const p3 = t[3].since(t[2]);
        const ap = t[4].since(t[3]);
        const total = t[4].since(t[0]);
        const w = std.fs.File.stderr().deprecatedWriter();
        w.print("[pi_solver K'={d} L={d}] phase1={d}us phase2={d}us phase3={d}us apply={d}us total={d}us i={d} u={d}\n", .{
            k_prime,
            state.l,
            p1 / 1000,
            p2 / 1000,
            p3 / 1000,
            ap / 1000,
            total / 1000,
            state.i,
            state.u,
        }) catch {};
    }

    const ops_slice = state.deferred_ops.toOwnedSlice(allocator) catch
        return error.OutOfMemory;

    return .{
        .symbols = symbols,
        .ops = .{ .ops = ops_slice },
    };
}

pub var profile_enabled: bool = false;

/// Phase 1: Forward elimination with inactivation (Section 5.4.2.2)
/// HDPC rows are excluded from pivot selection per Errata 2.
/// Binary rows use bit-packed DenseBinaryMatrix for fast popcount and XOR.
/// HDPC rows use GF(256) FMA via set-bit iteration on the binary pivot row.
fn phase1(state: *SolverState) SolverError!void {
    const l = state.l;
    const hdpc_start = state.hdpc_start;

    while (state.i + state.u < l) {
        const v_end = l - state.u;

        const selection = try selectPivotRow(state, hdpc_start);

        state.swapRows(state.i, selection.row);
        const min_r = selection.nonzeros;

        // Column swaps: first nonzero to diagonal, remaining r-1 to U boundary
        var nz_buf: [2]u32 = undefined;
        _ = state.binary.nonzeroColsInRange(state.i, state.i, v_end, &nz_buf);

        state.swapCols(state.i, nz_buf[0]);
        if (min_r == 2) {
            // If the second nonzero was at the diagonal, it moved to nz_buf[0] during the swap above
            const second_col = if (nz_buf[1] == state.i) nz_buf[0] else nz_buf[1];
            state.swapCols(v_end - 1, second_col);
            state.u += 1;
        } else if (min_r >= 3) {
            var inactivated: u32 = 0;
            var c_iter = state.i + 1;
            var current_v_end = v_end;
            while (c_iter < current_v_end) {
                if (state.binary.get(state.i, c_iter)) {
                    current_v_end -= 1;
                    state.swapCols(c_iter, current_v_end);
                    inactivated += 1;
                } else {
                    c_iter += 1;
                }
            }
            state.u += inactivated;
        }

        try eliminateColumn(state, state.i, hdpc_start);

        state.i += 1;
    }
}

const PivotSelection = struct { row: u32, nonzeros: u32 };

/// Select the best pivot row from non-HDPC rows in [i, hdpc_start).
/// Uses popcount on bit-packed rows (~64x faster than byte scan).
fn selectPivotRow(state: *SolverState, hdpc_start: u32) SolverError!PivotSelection {
    const v_start = state.i;
    const v_end = state.l - state.u;

    var min_r: u32 = std.math.maxInt(u32);
    var chosen_row: u32 = 0;
    var chosen_orig_deg: u16 = std.math.maxInt(u16);
    var found = false;

    var row = state.i;
    while (row < hdpc_start) : (row += 1) {
        const r_val = state.binary.countOnesInRange(row, v_start, v_end);
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
        if (graphSubstep(state, hdpc_start)) |graph_row| {
            chosen_row = graph_row;
        }
    }

    return .{ .row = chosen_row, .nonzeros = min_r };
}

/// Eliminate a pivot column from all rows below it.
/// Binary rows: XOR row ranges. HDPC rows: FMA via set-bit iteration on binary pivot.
fn eliminateColumn(state: *SolverState, col: u32, hdpc_start: u32) SolverError!void {
    // Binary rows below pivot
    var row = col + 1;
    while (row < hdpc_start) : (row += 1) {
        if (state.binary.get(row, col)) {
            state.binary.xorRowRange(col, row, col);
            try state.addOp(.{ .add_assign = .{
                .src = state.d[col],
                .dst = state.d[row],
            } });
        }
    }
    // HDPC rows: pivot row is binary, so FMA simplifies to XOR-where-set
    const pivot_row_data = state.binary.rowSliceConst(col);
    row = hdpc_start;
    while (row < state.l) : (row += 1) {
        const factor = state.hdpc.get(row, col);
        if (factor.isZero()) continue;

        const hdpc_row_bytes = state.hdpc.rowSlice(row);
        for (pivot_row_data, 0..) |word, wi| {
            var bits = word;
            while (bits != 0) {
                const bit_pos: u32 = @intCast(@ctz(bits));
                const pivot_col = @as(u32, @intCast(wi)) * 64 + bit_pos;
                if (pivot_col < state.l) {
                    hdpc_row_bytes[pivot_col] ^= factor.value;
                }
                bits &= bits - 1;
            }
        }

        try state.addOp(.{ .fma = .{
            .src = state.d[col],
            .dst = state.d[row],
            .scalar = factor,
        } });
    }
}

/// Graph substep for r=2 rows: find largest connected component.
/// Uses persistent union-find graph (reset between iterations).
fn graphSubstep(state: *SolverState, hdpc_start: u32) ?u32 {
    const v_start = state.i;
    const v_end = state.l - state.u;
    const v_size = v_end - v_start;
    if (v_size < 2) return null;

    state.graph.reset();

    var row = state.i;
    while (row < hdpc_start) : (row += 1) {
        if (state.binary.countOnesInRange(row, v_start, v_end) != 2) continue;
        var cols: [2]u32 = undefined;
        if (state.binary.nonzeroColsInRange(row, v_start, v_end, &cols) == 2) {
            state.graph.addEdge(cols[0] - v_start, cols[1] - v_start);
        }
    }

    const target_node = state.graph.getNodeInLargestComponent(0, v_size) orelse return null;
    const target_col = target_node + v_start;

    row = state.i;
    while (row < hdpc_start) : (row += 1) {
        if (state.binary.countOnesInRange(row, v_start, v_end) != 2) continue;
        if (state.binary.get(row, target_col)) return row;
    }

    return null;
}

/// Phase 2: Solve u x u inactivated submatrix (Section 5.4.2.3)
/// Builds a temporary OctetMatrix from binary+HDPC state for columns [i, L),
/// runs GF(256) Gaussian elimination, then applies results back.
fn phase2(state: *SolverState) SolverError!void {
    const l = state.l;
    const i_val = state.i;
    const num_cols = l - i_val;
    if (num_cols == 0) return;

    // Build temporary OctetMatrix: L rows x num_cols columns (cols [i, L))
    var temp = OctetMatrix.init(state.allocator, l, num_cols) catch
        return error.OutOfMemory;
    defer temp.deinit();

    // Fill from binary rows [0, hdpc_start)
    {
        var row: u32 = 0;
        while (row < state.hdpc_start) : (row += 1) {
            var col: u32 = 0;
            while (col < num_cols) : (col += 1) {
                if (state.binary.get(row, i_val + col)) {
                    temp.set(row, col, Octet.ONE);
                }
            }
        }
    }
    // Fill from HDPC rows [hdpc_start, L) via slice copy
    {
        var row = state.hdpc_start;
        while (row < l) : (row += 1) {
            const src = state.hdpc.rowSliceConst(row);
            @memcpy(temp.rowSlice(row), src[i_val..][0..num_cols]);
        }
    }

    // GF(256) Gaussian elimination on temp
    var col: u32 = 0;
    while (col < num_cols) : (col += 1) {
        const abs_col = i_val + col;

        // Find pivot in [col, L) within temp
        const pivot_row = blk: {
            var r = abs_col;
            while (r < l) : (r += 1) {
                if (!temp.get(r, col).isZero()) break :blk r;
            }
            return error.SingularMatrix;
        };

        // Swap pivot row to diagonal position
        if (pivot_row != abs_col) {
            temp.swapRows(abs_col, pivot_row);
            state.swapRows(abs_col, pivot_row);
        }

        // Scale pivot row to 1
        const pivot_val = temp.get(abs_col, col);
        if (!pivot_val.isOne()) {
            const inv = pivot_val.inverse();
            temp.mulAssignRow(abs_col, inv);
            try state.addOp(.{ .mul_assign = .{
                .index = state.d[abs_col],
                .scalar = inv,
            } });
        }

        // Eliminate from ALL rows
        var r: u32 = 0;
        while (r < l) : (r += 1) {
            if (r == abs_col) continue;
            const factor = temp.get(r, col);
            if (factor.isZero()) continue;

            temp.fmaRow(abs_col, r, factor);
            try state.addOp(.{ .fma = .{
                .src = state.d[abs_col],
                .dst = state.d[r],
                .scalar = factor,
            } });
        }
    }

    // Write results back to binary matrix for rows [0, hdpc_start):
    // After Phase 2 GE, columns [i, L) should be identity on diagonal
    // and zero elsewhere. Update binary matrix to reflect this.
    {
        var row: u32 = 0;
        while (row < state.hdpc_start) : (row += 1) {
            var c: u32 = 0;
            while (c < num_cols) : (c += 1) {
                state.binary.set(row, i_val + c, !temp.get(row, c).isZero());
            }
        }
    }
    // Write back to HDPC rows in OctetMatrix via slice copy
    {
        var row = state.hdpc_start;
        while (row < l) : (row += 1) {
            const src = temp.rowSliceConst(row);
            @memcpy(state.hdpc.rowSlice(row)[i_val..][0..num_cols], src);
        }
    }
}

/// Phase 3: Back-substitution on upper-triangular first-i block (Section 5.4.2.4)
/// All rows [0, i) are binary. Back-substitution uses XOR only.
fn phase3(state: *SolverState) SolverError!void {
    if (state.i <= 1) return;

    var col = state.i;
    while (col > 1) {
        col -= 1;
        var row: u32 = 0;
        while (row < col) : (row += 1) {
            if (state.binary.get(row, col)) {
                state.binary.xorRow(col, row);
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

    // Verify solve produced non-trivial output
    var all_zero = true;
    for (syms[0..27]) |s| {
        if (s.data[0] != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
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
