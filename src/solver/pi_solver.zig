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
const ConstraintMatrices = @import("../matrix/constraint_matrix.zig").ConstraintMatrices;
const symbol_mod = @import("../codec/symbol.zig");
const Symbol = symbol_mod.Symbol;
const SymbolBuffer = symbol_mod.SymbolBuffer;
const OperationVector = @import("../codec/operation_vector.zig").OperationVector;
const SymbolOp = @import("../codec/operation_vector.zig").SymbolOp;
const ConnectedComponentGraph = @import("graph.zig").ConnectedComponentGraph;
const systematic_constants = @import("../tables/systematic_constants.zig");

pub const SolverError = error{ SingularMatrix, OutOfMemory };

const SolverState = struct {
    binary: *DenseBinaryMatrix, // borrowed from ConstraintMatrices
    hdpc: *OctetMatrix, // borrowed from ConstraintMatrices (H rows x L cols)
    graph: ConnectedComponentGraph,
    l: u32,
    d: []u32,
    c: []u32,
    i: u32,
    u: u32,
    hdpc_start: u32, // L - H (first logical HDPC row index)
    deferred_ops: std.ArrayList(SymbolOp),
    original_degree: []u16,
    v_degree: []u16, // current nonzeros in V-region [i, L-u) per binary row
    log_to_phys: []u32, // logical binary row -> physical storage row
    phys_to_log: []u32, // physical storage row -> logical binary row
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, cm: *ConstraintMatrices, k_prime: u32) SolverError!SolverState {
        const si = systematic_constants.findSystematicIndex(k_prime) orelse
            return error.SingularMatrix;
        const s = si.s;
        const h = si.h;
        const w = si.w;
        const l = cm.l;
        const hdpc_start = l - h;

        const d = allocator.alloc(u32, l) catch return error.OutOfMemory;
        errdefer allocator.free(d);
        const c_arr = allocator.alloc(u32, l) catch return error.OutOfMemory;
        errdefer allocator.free(c_arr);
        const orig_deg = allocator.alloc(u16, l) catch return error.OutOfMemory;
        errdefer allocator.free(orig_deg);
        const v_deg = allocator.alloc(u16, hdpc_start) catch return error.OutOfMemory;
        errdefer allocator.free(v_deg);
        const l2p = allocator.alloc(u32, hdpc_start) catch return error.OutOfMemory;
        errdefer allocator.free(l2p);
        const p2l = allocator.alloc(u32, hdpc_start) catch return error.OutOfMemory;
        errdefer allocator.free(p2l);

        // d[] maps logical row -> D vector index
        // Binary rows [0, S): LDPC constraints -> D vector [0, S)
        for (0..s) |j| d[j] = @intCast(j);
        // Binary rows [S, L-H): LT/data rows -> D vector [S+H, L)
        for (0..hdpc_start - s) |j| d[s + j] = @intCast(s + h + j);
        // HDPC rows [L-H, L): constraints -> D vector [S, S+H)
        for (0..h) |j| d[hdpc_start + j] = @intCast(s + j);

        for (c_arr, 0..) |*v, idx| v.* = @intCast(idx);
        @memset(orig_deg, 0);

        // Initial V-region is [0, W) since i=0, u=L-W
        {
            var row: u32 = 0;
            while (row < hdpc_start) : (row += 1) {
                const deg: u16 = @intCast(cm.binary.countOnesInRange(row, 0, w));
                orig_deg[row] = deg;
                v_deg[row] = deg;
                l2p[row] = row;
                p2l[row] = row;
            }
        }

        var graph = ConnectedComponentGraph.init(allocator, l) catch
            return error.OutOfMemory;
        errdefer graph.deinit(allocator);

        return SolverState{
            .binary = &cm.binary,
            .hdpc = &cm.hdpc,
            .graph = graph,
            .l = l,
            .d = d,
            .c = c_arr,
            .i = 0,
            .u = l - w,
            .hdpc_start = hdpc_start,
            .deferred_ops = .empty,
            .original_degree = orig_deg,
            .v_degree = v_deg,
            .log_to_phys = l2p,
            .phys_to_log = p2l,
            .allocator = allocator,
        };
    }

    fn deinit(self: *SolverState) void {
        self.graph.deinit(self.allocator);
        self.allocator.free(self.d);
        self.allocator.free(self.c);
        self.allocator.free(self.original_degree);
        self.allocator.free(self.v_degree);
        self.allocator.free(self.log_to_phys);
        self.allocator.free(self.phys_to_log);
        self.deferred_ops.deinit(self.allocator);
    }

    fn swapRows(self: *SolverState, r1: u32, r2: u32) void {
        if (r1 == r2) return;
        if (r1 < self.hdpc_start and r2 < self.hdpc_start) {
            // O(1) via indirection -- no physical data movement
            const p1 = self.log_to_phys[r1];
            const p2 = self.log_to_phys[r2];
            self.log_to_phys[r1] = p2;
            self.log_to_phys[r2] = p1;
            self.phys_to_log[p1] = r2;
            self.phys_to_log[p2] = r1;
            std.mem.swap(u16, &self.v_degree[r1], &self.v_degree[r2]);
        } else if (r1 >= self.hdpc_start and r2 >= self.hdpc_start) {
            self.hdpc.swapRows(r1 - self.hdpc_start, r2 - self.hdpc_start);
        } else {
            self.swapRowsCrossRegion(r1, r2);
        }
        std.mem.swap(u32, &self.d[r1], &self.d[r2]);
        std.mem.swap(u16, &self.original_degree[r1], &self.original_degree[r2]);
    }

    fn swapRowsCrossRegion(self: *SolverState, r1: u32, r2: u32) void {
        const bin_log = if (r1 < self.hdpc_start) r1 else r2;
        const hdpc_row = if (r1 >= self.hdpc_start) r1 else r2;
        const hdpc_local = hdpc_row - self.hdpc_start;
        const bin_phys = self.log_to_phys[bin_log];

        var col: u32 = 0;
        while (col < self.l) : (col += 1) {
            const bin_val = self.binary.get(bin_phys, col);
            const hdpc_val = self.hdpc.get(hdpc_local, col);
            self.binary.set(bin_phys, col, !hdpc_val.isZero());
            self.hdpc.set(hdpc_local, col, if (bin_val) Octet.ONE else Octet.ZERO);
        }
        // Recompute v_degree for the binary row after its data changed
        const v_start = self.i;
        const v_end = self.l - self.u;
        self.v_degree[bin_log] = @intCast(self.binary.countOnesInRange(bin_phys, v_start, v_end));
    }

    // Access helpers through indirection layer
    inline fn binaryGet(self: *const SolverState, logical_row: u32, col: u32) bool {
        return self.binary.get(self.log_to_phys[logical_row], col);
    }

    inline fn binaryRowSliceConst(self: *const SolverState, logical_row: u32) []const u64 {
        return self.binary.rowSliceConst(self.log_to_phys[logical_row]);
    }

    inline fn binaryXorRowRange(self: *SolverState, src_log: u32, dst_log: u32, start_col: u32) void {
        self.binary.xorRowRange(self.log_to_phys[src_log], self.log_to_phys[dst_log], start_col);
    }

    inline fn binaryCountOnesInRange(self: *const SolverState, logical_row: u32, start: u32, end: u32) u32 {
        return self.binary.countOnesInRange(self.log_to_phys[logical_row], start, end);
    }

    inline fn binaryNonzeroColsInRange(self: *const SolverState, logical_row: u32, start: u32, end: u32, buf: []u32) u32 {
        return self.binary.nonzeroColsInRange(self.log_to_phys[logical_row], start, end, buf);
    }

    fn swapCols(self: *SolverState, c1: u32, c2: u32) void {
        if (c1 == c2) return;
        // Swap across ALL physical rows (indirection means any physical row
        // could map to an active logical row)
        self.binary.swapCols(c1, c2, 0);
        const h = self.l - self.hdpc_start;
        var r: u32 = 0;
        while (r < h) : (r += 1) {
            const row_bytes = self.hdpc.rowSlice(r);
            std.mem.swap(u8, &row_bytes[c1], &row_bytes[c2]);
        }
        std.mem.swap(u32, &self.c[c1], &self.c[c2]);
    }

    /// Move a column from V to U: decrement v_degree, swap to boundary, grow u.
    fn inactivateColumn(self: *SolverState, col: u32) void {
        // Decrement v_degree for active rows that have a 1 in this column
        var row: u32 = self.i;
        while (row < self.hdpc_start) : (row += 1) {
            if (self.binaryGet(row, col)) {
                self.v_degree[row] -= 1;
            }
        }
        // Swap column to boundary position and shrink V
        const new_boundary = self.l - self.u - 1;
        self.swapCols(col, new_boundary);
        self.u += 1;
    }

    fn addOp(self: *SolverState, op: SymbolOp) SolverError!void {
        self.deferred_ops.append(self.allocator, op) catch return error.OutOfMemory;
    }
};

/// Solve for intermediate symbols using inactivation decoding.
/// Mutates buf in-place so that buf[c[j]] = intermediate_symbol[j].
/// Implements RFC 6330 Section 5.4.2.
pub fn solve(
    allocator: std.mem.Allocator,
    cm: *ConstraintMatrices,
    buf: *SymbolBuffer,
    k_prime: u32,
) SolverError!void {
    var state = try SolverState.init(allocator, cm, k_prime);
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
    try applyAndRemap(&state, buf);
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
}

pub var profile_enabled: bool = false;

fn phase1(state: *SolverState) SolverError!void {
    const l = state.l;
    const hdpc_start = state.hdpc_start;

    while (state.i + state.u < l) {
        const selection = try selectPivotRow(state, hdpc_start);

        state.swapRows(state.i, selection.row);
        const min_r = selection.nonzeros;

        var nz_buf: [2]u32 = undefined;
        _ = state.binaryNonzeroColsInRange(state.i, state.i, l - state.u, &nz_buf);

        // Swap first nonzero column to the pivot position (stays in V)
        state.swapCols(state.i, nz_buf[0]);

        if (min_r == 2) {
            // Inactivate the second nonzero column (move from V to U)
            const second_col = if (nz_buf[1] == state.i) nz_buf[0] else nz_buf[1];
            state.inactivateColumn(second_col);
        } else if (min_r >= 3) {
            // Inactivate all nonzero columns except the pivot column
            var c_iter = state.i + 1;
            while (c_iter < l - state.u) {
                if (state.binaryGet(state.i, c_iter)) {
                    state.inactivateColumn(c_iter);
                    // Don't advance c_iter: the swapped-in column needs checking
                } else {
                    c_iter += 1;
                }
            }
        }

        try eliminateColumn(state, state.i, hdpc_start);

        // Column state.i leaves V as i advances. After eliminateColumn, only
        // the pivot row has a 1 at column state.i; all others were zeroed.
        state.v_degree[state.i] -|= 1;

        state.i += 1;
    }
}

const PivotSelection = struct { row: u32, nonzeros: u32 };

fn selectPivotRow(state: *SolverState, hdpc_start: u32) SolverError!PivotSelection {
    var min_r: u32 = std.math.maxInt(u32);
    var chosen_row: u32 = 0;
    var chosen_orig_deg: u16 = std.math.maxInt(u16);
    var found = false;

    // Scan v_degree[] -- O(hdpc_start - i) u16 comparisons, no popcount
    var row = state.i;
    while (row < hdpc_start) : (row += 1) {
        const r_val: u32 = state.v_degree[row];
        if (r_val == 0) continue;
        if (r_val < min_r or
            (r_val == min_r and state.original_degree[row] < chosen_orig_deg))
        {
            min_r = r_val;
            chosen_row = row;
            chosen_orig_deg = state.original_degree[row];
            found = true;
            if (min_r == 1) break;
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

fn eliminateColumn(state: *SolverState, col: u32, hdpc_start: u32) SolverError!void {
    const pivot_phys = state.log_to_phys[col];
    const v_start = col; // after this pivot is processed, V starts at col+1
    const v_end = state.l - state.u;

    var row = col + 1;
    while (row < hdpc_start) : (row += 1) {
        const row_phys = state.log_to_phys[row];
        if (state.binary.get(row_phys, col)) {
            // Compute overlap in V-region BEFORE XOR for incremental v_degree update
            // After XOR: new_v_deg = old_v_deg + pivot_v_deg - 2*overlap
            // But we must exclude the pivot column itself (col = v_start) since it
            // will become part of the solved diagonal after this step.
            // The effective V-region for the next iteration is [col+1, v_end).
            const overlap = state.binary.andCountOnesInRange(row_phys, pivot_phys, v_start, v_end);
            const pivot_nz = state.binary.countOnesInRange(pivot_phys, v_start, v_end);

            state.binary.xorRowRange(pivot_phys, row_phys, col);

            // Update v_degree: XOR flips shared bits off and unshared bits on
            const old_deg = state.v_degree[row];
            state.v_degree[row] = @intCast(@as(u32, old_deg) + pivot_nz - 2 * overlap);

            try state.addOp(.{ .add_assign = .{
                .src = state.d[col],
                .dst = state.d[row],
            } });
        }
    }

    // After pivot column is used, it leaves V. Decrement v_degree for rows
    // that have a 1 in this column (they were just XOR'd, so only pivot has it).
    // Actually, the pivot row itself moves to the diagonal, and all other rows
    // had col zeroed by the XOR. But v_degree already accounts for col being
    // in [v_start, v_end). Since i advances after this call, col leaves V
    // naturally. We account for this in phase1 by noting i increments.

    const pivot_row_data = state.binary.rowSliceConst(pivot_phys);
    const h = state.l - hdpc_start;
    var hdpc_r: u32 = 0;
    while (hdpc_r < h) : (hdpc_r += 1) {
        const logical_row = hdpc_start + hdpc_r;
        const factor = state.hdpc.get(hdpc_r, col);
        if (factor.isZero()) continue;

        const hdpc_row_bytes = state.hdpc.rowSlice(hdpc_r);
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
            .dst = state.d[logical_row],
            .scalar = factor,
        } });
    }
}

fn graphSubstep(state: *SolverState, hdpc_start: u32) ?u32 {
    const v_start = state.i;
    const v_end = state.l - state.u;
    const v_size = v_end - v_start;
    if (v_size < 2) return null;

    state.graph.reset();

    var row = state.i;
    while (row < hdpc_start) : (row += 1) {
        if (state.v_degree[row] != 2) continue;
        var cols: [2]u32 = undefined;
        if (state.binaryNonzeroColsInRange(row, v_start, v_end, &cols) == 2) {
            state.graph.addEdge(cols[0] - v_start, cols[1] - v_start);
        }
    }

    const target_node = state.graph.getNodeInLargestComponent(0, v_size) orelse return null;
    const target_col = target_node + v_start;

    row = state.i;
    while (row < hdpc_start) : (row += 1) {
        if (state.v_degree[row] != 2) continue;
        if (state.binaryGet(row, target_col)) return row;
    }

    return null;
}

fn phase2(state: *SolverState) SolverError!void {
    const l = state.l;
    const i_val = state.i;
    const num_cols = l - i_val;
    if (num_cols == 0) return;

    var temp = OctetMatrix.init(state.allocator, l, num_cols) catch
        return error.OutOfMemory;
    defer temp.deinit();

    // Fill from binary rows [0, hdpc_start) using indirection
    {
        var row: u32 = 0;
        while (row < state.hdpc_start) : (row += 1) {
            const phys = state.log_to_phys[row];
            var col: u32 = 0;
            while (col < num_cols) : (col += 1) {
                if (state.binary.get(phys, i_val + col)) {
                    temp.set(row, col, Octet.ONE);
                }
            }
        }
    }
    // Fill from HDPC rows
    {
        const h = l - state.hdpc_start;
        var hdpc_r: u32 = 0;
        while (hdpc_r < h) : (hdpc_r += 1) {
            const logical_row = state.hdpc_start + hdpc_r;
            const src = state.hdpc.rowSliceConst(hdpc_r);
            @memcpy(temp.rowSlice(logical_row), src[i_val..][0..num_cols]);
        }
    }

    // GF(256) Gaussian elimination
    var col: u32 = 0;
    while (col < num_cols) : (col += 1) {
        const abs_col = i_val + col;

        const pivot_row = blk: {
            var r = abs_col;
            while (r < l) : (r += 1) {
                if (!temp.get(r, col).isZero()) break :blk r;
            }
            return error.SingularMatrix;
        };

        if (pivot_row != abs_col) {
            temp.swapRows(abs_col, pivot_row);
            state.swapRows(abs_col, pivot_row);
        }

        const pivot_val = temp.get(abs_col, col);
        if (!pivot_val.isOne()) {
            const inv = pivot_val.inverse();
            temp.mulAssignRow(abs_col, inv);
            try state.addOp(.{ .mul_assign = .{
                .index = state.d[abs_col],
                .scalar = inv,
            } });
        }

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

    // Write back to binary rows using indirection
    {
        var row: u32 = 0;
        while (row < state.hdpc_start) : (row += 1) {
            const phys = state.log_to_phys[row];
            var c: u32 = 0;
            while (c < num_cols) : (c += 1) {
                state.binary.set(phys, i_val + c, !temp.get(row, c).isZero());
            }
        }
    }
    // Write back to HDPC rows
    {
        const h = l - state.hdpc_start;
        var hdpc_r: u32 = 0;
        while (hdpc_r < h) : (hdpc_r += 1) {
            const logical_row = state.hdpc_start + hdpc_r;
            const src = temp.rowSliceConst(logical_row);
            @memcpy(state.hdpc.rowSlice(hdpc_r)[i_val..][0..num_cols], src);
        }
    }
}

fn phase3(state: *SolverState) SolverError!void {
    if (state.i <= 1) return;

    var col = state.i;
    while (col > 1) {
        col -= 1;
        var row: u32 = 0;
        while (row < col) : (row += 1) {
            if (state.binaryGet(row, col)) {
                state.binaryXorRowRange(col, row, 0);
                try state.addOp(.{ .add_assign = .{
                    .src = state.d[col],
                    .dst = state.d[row],
                } });
            }
        }
    }
}

fn applyAndRemap(state: *SolverState, buf: *SymbolBuffer) SolverError!void {
    const ops = OperationVector{ .ops = state.deferred_ops.items };
    ops.applyBuf(buf);

    var temp = SymbolBuffer.init(state.allocator, state.l, buf.symbol_size) catch
        return error.OutOfMemory;
    defer temp.deinit();

    for (0..state.l) |j| {
        @memcpy(temp.get(@intCast(state.c[j])), buf.getConst(@intCast(state.d[j])));
    }
    @memcpy(buf.data[0..@as(usize, state.l) * buf.symbol_size], temp.data[0..@as(usize, state.l) * buf.symbol_size]);
}

test "pi_solver solves real constraint matrix K'=10" {
    const allocator = std.testing.allocator;
    const constraint_matrix_mod = @import("../matrix/constraint_matrix.zig");

    const k_prime: u32 = 10;

    var cm = try constraint_matrix_mod.buildConstraintMatrices(allocator, k_prime);
    defer cm.deinit();

    var buf = try SymbolBuffer.init(allocator, 27, 4);
    defer buf.deinit();

    for (0..27) |idx| {
        buf.get(@intCast(idx))[0] = @intCast(idx + 1);
    }

    try solve(allocator, &cm, &buf, k_prime);

    var all_zero = true;
    for (0..27) |idx| {
        if (buf.getConst(@intCast(idx))[0] != 0) {
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

    var cm = try constraint_matrix_mod.buildConstraintMatrices(allocator, k_prime);
    defer cm.deinit();

    // Zero out column 0 in both binary and hdpc to make it singular
    const l = cm.l;
    const hdpc_start = l - cm.h;
    var row: u32 = 0;
    while (row < hdpc_start) : (row += 1) {
        cm.binary.set(row, 0, false);
    }
    row = 0;
    while (row < cm.h) : (row += 1) {
        cm.hdpc.set(row, 0, Octet.ZERO);
    }

    var buf = try SymbolBuffer.init(allocator, 27, 4);
    defer buf.deinit();

    const result = solve(allocator, &cm, &buf, k_prime);
    try std.testing.expectError(error.SingularMatrix, result);
}
