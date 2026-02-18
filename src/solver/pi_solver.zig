// RFC 6330 Section 5.4 - Inactivation decoding (PI solver)
//
// Five-phase algorithm:
//   Phase 1: Forward elimination with inactivation (Section 5.4.2.2)
//            HDPC rows excluded from pivot selection (Errata 2)
//            Generic over binary matrix type (DenseBinaryMatrix or SparseBinaryMatrix)
//   Phase 2: Solve u x u inactivated submatrix via GF(256) GE (Section 5.4.2.3)
//            Eliminates from ALL rows to also zero the upper-right block
//   Phase 3: Back-substitution on upper-triangular first-i block (Section 5.4.2.4)
//   Apply deferred symbol operations and remap via permutations

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("../matrix/octet_matrix.zig").OctetMatrix;
const DenseBinaryMatrix = @import("../matrix/dense_binary_matrix.zig").DenseBinaryMatrix;
const SparseBinaryMatrix = @import("../matrix/sparse_matrix.zig").SparseBinaryMatrix;
const constraint_matrix_mod = @import("../matrix/constraint_matrix.zig");
const SymbolBuffer = @import("../codec/symbol.zig").SymbolBuffer;
const OperationVector = @import("../codec/operation_vector.zig").OperationVector;
const SymbolOp = @import("../codec/operation_vector.zig").SymbolOp;
const ConnectedComponentGraph = @import("graph.zig").ConnectedComponentGraph;
const systematic_constants = @import("../tables/systematic_constants.zig");

pub const SolverError = error{ SingularMatrix, OutOfMemory };

pub const sparse_matrix_threshold: u32 = 2000;

pub var profile_enabled: bool = false;

fn SolverState(comptime MatrixType: type) type {
    const is_sparse = (MatrixType == SparseBinaryMatrix);

    return struct {
        const Self = @This();

        binary: *MatrixType,
        hdpc: *OctetMatrix,
        graph: ConnectedComponentGraph,
        l: u32,
        d: []u32,
        c: []u32,
        i: u32,
        u: u32,
        hdpc_start: u32,
        deferred_ops: std.ArrayList(SymbolOp),
        original_degree: []u16,
        v_degree: []u16,
        degree_histogram: []u32,
        log_to_phys: []u32,
        phys_to_log: []u32,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, cm: *constraint_matrix_mod.ConstraintMatrices(MatrixType), k_prime: u32) SolverError!Self {
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
            const histogram = allocator.alloc(u32, l + 1) catch return error.OutOfMemory;
            errdefer allocator.free(histogram);
            @memset(histogram, 0);

            // Row indirection: only needed for DenseBinaryMatrix (sparse manages its own)
            const indirection_len: usize = if (comptime is_sparse) 0 else hdpc_start;
            const l2p = allocator.alloc(u32, indirection_len) catch return error.OutOfMemory;
            errdefer allocator.free(l2p);
            const p2l = allocator.alloc(u32, indirection_len) catch return error.OutOfMemory;
            errdefer allocator.free(p2l);

            for (0..s) |j| d[j] = @intCast(j);
            for (0..hdpc_start - s) |j| d[s + j] = @intCast(s + h + j);
            for (0..h) |j| d[hdpc_start + j] = @intCast(s + j);

            for (c_arr, 0..) |*v, idx| v.* = @intCast(idx);
            @memset(orig_deg, 0);

            // Initial V-region is [0, W) since i=0, u=L-W
            {
                var row: u32 = 0;
                while (row < hdpc_start) : (row += 1) {
                    // Both matrix types accept row index directly at init (identity mapping)
                    const deg: u16 = @intCast(cm.binary.countOnesInRange(row, 0, w));
                    orig_deg[row] = deg;
                    v_deg[row] = deg;
                    histogram[deg] += 1;
                    if (comptime !is_sparse) {
                        l2p[row] = row;
                        p2l[row] = row;
                    }
                }
            }

            var graph = ConnectedComponentGraph.init(allocator, l) catch
                return error.OutOfMemory;
            errdefer graph.deinit(allocator);

            return Self{
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
                .degree_histogram = histogram,
                .log_to_phys = l2p,
                .phys_to_log = p2l,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            self.graph.deinit(self.allocator);
            self.allocator.free(self.d);
            self.allocator.free(self.c);
            self.allocator.free(self.original_degree);
            self.allocator.free(self.v_degree);
            self.allocator.free(self.degree_histogram);
            self.allocator.free(self.log_to_phys);
            self.allocator.free(self.phys_to_log);
            self.deferred_ops.deinit(self.allocator);
        }

        fn swapRows(self: *Self, r1: u32, r2: u32) void {
            if (r1 == r2) return;
            if (r1 < self.hdpc_start and r2 < self.hdpc_start) {
                if (comptime is_sparse) {
                    self.binary.swapRows(r1, r2);
                } else {
                    self.phys_to_log[self.log_to_phys[r1]] = r2;
                    self.phys_to_log[self.log_to_phys[r2]] = r1;
                    std.mem.swap(u32, &self.log_to_phys[r1], &self.log_to_phys[r2]);
                }
                std.mem.swap(u16, &self.v_degree[r1], &self.v_degree[r2]);
            } else if (r1 >= self.hdpc_start and r2 >= self.hdpc_start) {
                self.hdpc.swapRows(r1 - self.hdpc_start, r2 - self.hdpc_start);
            } else {
                self.swapRowsCrossRegion(r1, r2);
            }
            std.mem.swap(u32, &self.d[r1], &self.d[r2]);
            std.mem.swap(u16, &self.original_degree[r1], &self.original_degree[r2]);
        }

        fn swapRowsCrossRegion(self: *Self, r1: u32, r2: u32) void {
            const bin_log = if (r1 < self.hdpc_start) r1 else r2;
            const hdpc_row = if (r1 >= self.hdpc_start) r1 else r2;
            const hdpc_local = hdpc_row - self.hdpc_start;

            var col: u32 = 0;
            while (col < self.l) : (col += 1) {
                const bin_val = self.binaryGet(bin_log, col);
                const hdpc_val = self.hdpc.get(hdpc_local, col);
                if (comptime is_sparse) {
                    self.binary.set(bin_log, col, !hdpc_val.isZero()) catch {};
                } else {
                    self.binary.set(self.log_to_phys[bin_log], col, !hdpc_val.isZero());
                }
                self.hdpc.set(hdpc_local, col, if (bin_val) Octet.ONE else Octet.ZERO);
            }
            const v_start = self.i;
            const v_end = self.l - self.u;
            const old_deg = self.v_degree[bin_log];
            const new_deg: u16 = @intCast(self.binaryCountOnesInRange(bin_log, v_start, v_end));
            self.updateDegree(bin_log, old_deg, new_deg);
        }

        inline fn updateDegree(self: *Self, row: u32, old: u16, new: u16) void {
            self.v_degree[row] = new;
            self.degree_histogram[old] -= 1;
            self.degree_histogram[new] += 1;
        }

        inline fn removeFromHistogram(self: *Self, row: u32) void {
            self.degree_histogram[self.v_degree[row]] -= 1;
        }

        inline fn binaryGet(self: *const Self, logical_row: u32, col: u32) bool {
            if (comptime is_sparse) {
                return self.binary.get(logical_row, col);
            } else {
                return self.binary.get(self.log_to_phys[logical_row], col);
            }
        }

        inline fn binaryXorRowRange(self: *Self, src_log: u32, dst_log: u32, start_col: u32) SolverError!void {
            if (comptime is_sparse) {
                self.binary.xorRowRange(src_log, dst_log, start_col) catch return error.OutOfMemory;
            } else {
                self.binary.xorRowRange(self.log_to_phys[src_log], self.log_to_phys[dst_log], start_col);
            }
        }

        inline fn binaryNonzeroColsInRange(self: *const Self, logical_row: u32, start: u32, end: u32, buf: []u32) u32 {
            if (comptime is_sparse) {
                return self.binary.nonzeroColsInRange(logical_row, start, end, buf);
            } else {
                return self.binary.nonzeroColsInRange(self.log_to_phys[logical_row], start, end, buf);
            }
        }

        inline fn binaryCountOnesInRange(self: *const Self, logical_row: u32, start: u32, end: u32) u32 {
            if (comptime is_sparse) {
                return self.binary.countOnesInRange(logical_row, start, end);
            } else {
                return self.binary.countOnesInRange(self.log_to_phys[logical_row], start, end);
            }
        }

        inline fn binaryAndCountOnesInRange(self: *const Self, log_a: u32, log_b: u32, start: u32, end: u32) u32 {
            if (comptime is_sparse) {
                return self.binary.andCountOnesInRange(log_a, log_b, start, end);
            } else {
                return self.binary.andCountOnesInRange(self.log_to_phys[log_a], self.log_to_phys[log_b], start, end);
            }
        }

        inline fn binaryClearBit(self: *Self, logical_row: u32, col: u32) void {
            if (comptime is_sparse) {
                self.binary.clearBit(logical_row, col);
            } else {
                self.binary.set(self.log_to_phys[logical_row], col, false);
            }
        }

        fn swapCols(self: *Self, c1: u32, c2: u32) void {
            if (c1 == c2) return;
            self.binary.swapCols(c1, c2, 0);
            const h = self.l - self.hdpc_start;
            var r: u32 = 0;
            while (r < h) : (r += 1) {
                const row_bytes = self.hdpc.rowSlice(r);
                std.mem.swap(u8, &row_bytes[c1], &row_bytes[c2]);
            }
            std.mem.swap(u32, &self.c[c1], &self.c[c2]);
        }

        fn inactivateColumn(self: *Self, col: u32) void {
            if (comptime is_sparse) {
                // Use columnar index for O(nnz) v_degree update
                const phys_rows = self.binary.getOnesInColumn(col);
                for (phys_rows) |phys_row| {
                    const log_row = self.binary.phys_row_to_log[phys_row];
                    if (log_row >= self.i and log_row < self.hdpc_start) {
                        if (self.binary.get(log_row, col)) {
                            const old = self.v_degree[log_row];
                            self.updateDegree(log_row, old, old - 1);
                        }
                    }
                }
                // Migrate column from sparse to dense before swapping position
                self.binary.hintColumnDenseAndFrozen(col);
            } else {
                var row: u32 = self.i;
                while (row < self.hdpc_start) : (row += 1) {
                    if (self.binaryGet(row, col)) {
                        const old = self.v_degree[row];
                        self.updateDegree(row, old, old - 1);
                    }
                }
            }
            const new_boundary = self.l - self.u - 1;
            self.swapCols(col, new_boundary);
            self.u += 1;
        }

        fn addOp(self: *Self, op: SymbolOp) SolverError!void {
            self.deferred_ops.append(self.allocator, op) catch return error.OutOfMemory;
        }

        // -- Phase functions --

        fn phase1(self: *Self) SolverError!void {
            const l = self.l;
            const hdpc_start = self.hdpc_start;

            if (comptime is_sparse) {
                self.binary.enableColumnAcceleration() catch return error.OutOfMemory;
            }
            defer {
                if (comptime is_sparse) self.binary.disableColumnAcceleration();
            }

            while (self.i + self.u < l) {
                const selection = try self.selectPivotRow(hdpc_start);

                self.swapRows(self.i, selection.row);
                const min_r = selection.nonzeros;

                var nz_buf: [2]u32 = undefined;
                _ = self.binaryNonzeroColsInRange(self.i, self.i, l - self.u, &nz_buf);

                self.swapCols(self.i, nz_buf[0]);

                if (min_r == 2) {
                    const second_col = if (nz_buf[1] == self.i) nz_buf[0] else nz_buf[1];
                    self.inactivateColumn(second_col);
                } else if (min_r >= 3) {
                    var c_iter = self.i + 1;
                    while (c_iter < l - self.u) {
                        if (self.binaryGet(self.i, c_iter)) {
                            self.inactivateColumn(c_iter);
                        } else {
                            c_iter += 1;
                        }
                    }
                }

                try self.eliminateColumn(self.i, hdpc_start);

                self.removeFromHistogram(self.i);
                self.v_degree[self.i] -|= 1;

                self.i += 1;
            }
        }

        const PivotSelection = struct { row: u32, nonzeros: u32 };

        fn selectPivotRow(self: *Self, hdpc_start: u32) SolverError!PivotSelection {
            const histogram = self.degree_histogram;
            var min_r: u32 = 0;
            for (1..histogram.len) |d| {
                if (histogram[d] > 0) {
                    min_r = @intCast(d);
                    break;
                }
            }
            if (min_r == 0) return error.SingularMatrix;

            if (min_r == 1) {
                var row = self.i;
                while (row < hdpc_start) : (row += 1) {
                    if (self.v_degree[row] == 1) {
                        return .{ .row = row, .nonzeros = 1 };
                    }
                }
                return error.SingularMatrix;
            }

            var chosen_row: u32 = 0;
            var chosen_orig_deg: u16 = std.math.maxInt(u16);
            var found = false;

            var row = self.i;
            while (row < hdpc_start) : (row += 1) {
                if (self.v_degree[row] != min_r) continue;
                if (!found or self.original_degree[row] < chosen_orig_deg) {
                    chosen_row = row;
                    chosen_orig_deg = self.original_degree[row];
                    found = true;
                }
            }

            if (min_r == 2) {
                if (self.graphSubstep(hdpc_start)) |graph_row| {
                    chosen_row = graph_row;
                }
            }

            return .{ .row = chosen_row, .nonzeros = min_r };
        }

        /// Errata 11: the pivot row has exactly one V nonzero (at column col).
        /// Clear col directly and XOR only the U section, skipping V entirely.
        fn eliminateColumn(self: *Self, col: u32, hdpc_start: u32) SolverError!void {
            const boundary = self.l - self.u;

            if (comptime is_sparse) {
                const phys_rows = self.binary.getOnesInColumn(col);
                for (phys_rows) |phys_row| {
                    const row = self.binary.phys_row_to_log[phys_row];
                    if (row <= col or row >= hdpc_start) continue;
                    if (!self.binary.get(row, col)) continue;

                    self.binaryClearBit(row, col);
                    try self.binaryXorRowRange(col, row, boundary);

                    const old_deg = self.v_degree[row];
                    self.updateDegree(row, old_deg, old_deg - 1);

                    try self.addOp(.{ .add_assign = .{
                        .src = self.d[col],
                        .dst = self.d[row],
                    } });
                }
            } else {
                var row = col + 1;
                while (row < hdpc_start) : (row += 1) {
                    if (!self.binaryGet(row, col)) continue;

                    self.binaryClearBit(row, col);
                    try self.binaryXorRowRange(col, row, boundary);

                    const old_deg = self.v_degree[row];
                    self.updateDegree(row, old_deg, old_deg - 1);

                    try self.addOp(.{ .add_assign = .{
                        .src = self.d[col],
                        .dst = self.d[row],
                    } });
                }
            }

            // HDPC: XOR column col (only V nonzero) + U section of pivot row
            const h = self.l - hdpc_start;

            // Pivot row data is invariant across HDPC rows -- resolve once
            const pivot_phys = if (comptime is_sparse)
                self.binary.log_row_to_phys[col]
            else
                self.log_to_phys[col];

            var hdpc_r: u32 = 0;
            while (hdpc_r < h) : (hdpc_r += 1) {
                const logical_row = hdpc_start + hdpc_r;
                const factor = self.hdpc.get(hdpc_r, col);
                if (factor.isZero()) continue;

                const hdpc_row_bytes = self.hdpc.rowSlice(hdpc_r);
                hdpc_row_bytes[col] ^= factor.value;

                if (comptime is_sparse) {
                    const wpr = self.binary.denseWordsUsed();
                    const dense_words = self.binary.denseRowConst(pivot_phys);
                    for (0..wpr) |wi| {
                        var bits = dense_words[wi];
                        while (bits != 0) {
                            const bit_pos: u16 = @intCast(@ctz(bits));
                            const dense_bit: u16 = @as(u16, @intCast(wi)) * 64 + bit_pos;
                            const d_phys_col = self.binary.dense_bit_to_phys_col[dense_bit];
                            const log_col: u32 = self.binary.phys_col_to_log[d_phys_col];
                            hdpc_row_bytes[log_col] ^= factor.value;
                            bits &= bits - 1;
                        }
                    }
                } else {
                    const pivot_row_data = self.binary.rowSliceConst(pivot_phys);
                    const start_word = boundary / 64;
                    for (start_word..pivot_row_data.len) |wi| {
                        var bits = pivot_row_data[wi];
                        if (wi == start_word) {
                            const shift: u6 = @intCast(boundary % 64);
                            bits &= @as(u64, std.math.maxInt(u64)) << shift;
                        }
                        while (bits != 0) {
                            const bit_pos: u32 = @intCast(@ctz(bits));
                            const pivot_col = @as(u32, @intCast(wi)) * 64 + bit_pos;
                            if (pivot_col < self.l) {
                                hdpc_row_bytes[pivot_col] ^= factor.value;
                            }
                            bits &= bits - 1;
                        }
                    }
                }

                try self.addOp(.{ .fma = .{
                    .src = self.d[col],
                    .dst = self.d[logical_row],
                    .scalar = factor,
                } });
            }
        }

        fn graphSubstep(self: *Self, hdpc_start: u32) ?u32 {
            const v_start = self.i;
            const v_end = self.l - self.u;
            const v_size = v_end - v_start;
            if (v_size < 2) return null;

            self.graph.reset();

            var row = self.i;
            while (row < hdpc_start) : (row += 1) {
                if (self.v_degree[row] != 2) continue;
                var cols: [2]u32 = undefined;
                if (self.binaryNonzeroColsInRange(row, v_start, v_end, &cols) == 2) {
                    self.graph.addEdge(cols[0] - v_start, cols[1] - v_start);
                }
            }

            const target_node = self.graph.getNodeInLargestComponent(0, v_size) orelse return null;
            const target_col = target_node + v_start;

            row = self.i;
            while (row < hdpc_start) : (row += 1) {
                if (self.v_degree[row] != 2) continue;
                if (self.binaryGet(row, target_col)) return row;
            }

            return null;
        }

        fn phase2(self: *Self) SolverError!void {
            const l = self.l;
            const i_val = self.i;
            const num_cols = l - i_val;
            if (num_cols == 0) return;

            var temp = OctetMatrix.init(self.allocator, l, num_cols) catch
                return error.OutOfMemory;
            defer temp.deinit();

            // Fill from binary rows [0, hdpc_start)
            {
                var row: u32 = 0;
                while (row < self.hdpc_start) : (row += 1) {
                    var col_idx: u32 = 0;
                    while (col_idx < num_cols) : (col_idx += 1) {
                        if (self.binaryGet(row, i_val + col_idx)) {
                            temp.set(row, col_idx, Octet.ONE);
                        }
                    }
                }
            }
            // Fill from HDPC rows
            {
                const h_count = l - self.hdpc_start;
                var hdpc_r: u32 = 0;
                while (hdpc_r < h_count) : (hdpc_r += 1) {
                    const logical_row = self.hdpc_start + hdpc_r;
                    const src = self.hdpc.rowSliceConst(hdpc_r);
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
                    self.swapRows(abs_col, pivot_row);
                }

                const pivot_val = temp.get(abs_col, col);
                if (!pivot_val.isOne()) {
                    const inv = pivot_val.inverse();
                    temp.mulAssignRow(abs_col, inv);
                    try self.addOp(.{ .mul_assign = .{
                        .index = self.d[abs_col],
                        .scalar = inv,
                    } });
                }

                var r: u32 = 0;
                while (r < l) : (r += 1) {
                    if (r == abs_col) continue;
                    const factor = temp.get(r, col);
                    if (factor.isZero()) continue;

                    temp.fmaRow(abs_col, r, factor);
                    try self.addOp(.{ .fma = .{
                        .src = self.d[abs_col],
                        .dst = self.d[r],
                        .scalar = factor,
                    } });
                }
            }

            // Write back to binary rows
            {
                var row: u32 = 0;
                while (row < self.hdpc_start) : (row += 1) {
                    var c: u32 = 0;
                    while (c < num_cols) : (c += 1) {
                        const val = !temp.get(row, c).isZero();
                        if (comptime is_sparse) {
                            self.binary.set(row, i_val + c, val) catch {};
                        } else {
                            self.binary.set(self.log_to_phys[row], i_val + c, val);
                        }
                    }
                }
            }
            // Write back to HDPC rows
            {
                const h_count = l - self.hdpc_start;
                var hdpc_r: u32 = 0;
                while (hdpc_r < h_count) : (hdpc_r += 1) {
                    const logical_row = self.hdpc_start + hdpc_r;
                    const src = temp.rowSliceConst(logical_row);
                    @memcpy(self.hdpc.rowSlice(hdpc_r)[i_val..][0..num_cols], src);
                }
            }
        }

        fn phase3(self: *Self) SolverError!void {
            if (self.i <= 1) return;

            // After Phase 1, V is upper-triangular in rows/cols 0..i-1.
            // Clear bit + XOR U only (errata 11 for Phase 3).
            const boundary = self.l - self.u;

            if (comptime is_sparse) {
                // Build column-to-row lists from sparse vecs to avoid O(i^2)
                // iteration. Each V row has ~1 nonzero, so total entries ~= i.
                const col_heads = self.allocator.alloc(u32, self.i) catch
                    return error.OutOfMemory;
                defer self.allocator.free(col_heads);
                @memset(col_heads, std.math.maxInt(u32));

                // Linked-list nodes: next[node_idx] -> next node for same col
                // node_row[node_idx] -> the row for this entry
                const node_cap = self.i * 4;
                const node_next = self.allocator.alloc(u32, node_cap) catch
                    return error.OutOfMemory;
                defer self.allocator.free(node_next);
                const node_row = self.allocator.alloc(u32, node_cap) catch
                    return error.OutOfMemory;
                defer self.allocator.free(node_row);
                var node_count: u32 = 0;

                for (0..self.i) |row_idx| {
                    const row: u32 = @intCast(row_idx);
                    const phys_row = self.binary.log_row_to_phys[row];
                    const indices = self.binary.sparse_rows[phys_row].indices.items;
                    for (indices) |phys_col| {
                        const log_col: u32 = self.binary.phys_col_to_log[phys_col];
                        if (log_col > row and log_col < self.i) {
                            if (node_count >= node_cap) return error.OutOfMemory;
                            node_next[node_count] = col_heads[log_col];
                            node_row[node_count] = row;
                            col_heads[log_col] = node_count;
                            node_count += 1;
                        }
                    }
                }

                var col = self.i;
                while (col > 1) {
                    col -= 1;
                    var node = col_heads[col];
                    while (node != std.math.maxInt(u32)) {
                        const row = node_row[node];
                        self.binaryClearBit(row, col);
                        try self.binaryXorRowRange(col, row, boundary);
                        try self.addOp(.{ .add_assign = .{
                            .src = self.d[col],
                            .dst = self.d[row],
                        } });
                        node = node_next[node];
                    }
                }
            } else {
                var col = self.i;
                while (col > 1) {
                    col -= 1;
                    var row: u32 = 0;
                    while (row < col) : (row += 1) {
                        if (self.binaryGet(row, col)) {
                            self.binaryClearBit(row, col);
                            try self.binaryXorRowRange(col, row, boundary);
                            try self.addOp(.{ .add_assign = .{
                                .src = self.d[col],
                                .dst = self.d[row],
                            } });
                        }
                    }
                }
            }
        }

        fn applyAndRemap(self: *Self, buf: *SymbolBuffer) SolverError!void {
            const ops = OperationVector{ .ops = self.deferred_ops.items };
            ops.applyBuf(buf);

            const perm = self.allocator.alloc(u32, self.l) catch return error.OutOfMemory;
            defer self.allocator.free(perm);
            for (0..self.l) |j| {
                perm[self.c[j]] = self.d[j];
            }

            const sym_size = buf.symbol_size;
            const tmp = self.allocator.alloc(u8, sym_size) catch return error.OutOfMemory;
            defer self.allocator.free(tmp);

            for (0..self.l) |start| {
                if (perm[start] == start) continue;
                if (perm[start] == std.math.maxInt(u32)) continue;

                @memcpy(tmp, buf.getConst(@intCast(start)));

                var dst: u32 = @intCast(start);
                while (true) {
                    const src = perm[dst];
                    perm[dst] = std.math.maxInt(u32);
                    if (src == start) {
                        @memcpy(buf.get(dst), tmp);
                        break;
                    }
                    @memcpy(buf.get(dst), buf.getConst(src));
                    dst = src;
                }
            }
        }
    };
}

pub const SolverPlan = struct {
    ops: []SymbolOp,
    perm: []u32,
    l: u32,
    allocator: std.mem.Allocator,

    /// Replay captured solver operations and permutation on a symbol buffer.
    /// Non-destructive: perm is not modified, so the plan can be reused.
    pub fn apply(self: *const SolverPlan, buf: *SymbolBuffer) std.mem.Allocator.Error!void {
        const ov = OperationVector{ .ops = self.ops };
        ov.applyBuf(buf);

        const visited = try self.allocator.alloc(bool, self.l);
        defer self.allocator.free(visited);
        @memset(visited, false);

        const tmp = try self.allocator.alloc(u8, buf.symbol_size);
        defer self.allocator.free(tmp);

        for (0..self.l) |start| {
            if (visited[start]) continue;
            if (self.perm[start] == start) {
                visited[start] = true;
                continue;
            }

            @memcpy(tmp, buf.getConst(@intCast(start)));
            var dst: u32 = @intCast(start);
            while (true) {
                visited[dst] = true;
                const src = self.perm[dst];
                if (src == start) {
                    @memcpy(buf.get(dst), tmp);
                    break;
                }
                @memcpy(buf.get(dst), buf.getConst(src));
                dst = src;
            }
        }
    }

    pub fn deinit(self: *SolverPlan) void {
        self.allocator.free(self.ops);
        self.allocator.free(self.perm);
    }
};

/// Pre-solve the constraint matrix for a given K', capturing deferred operations
/// and the symbol permutation. The returned plan can be applied to any SymbolBuffer
/// with the same L dimension, avoiding repeated matrix construction and solving.
pub fn generatePlan(
    comptime MatrixType: type,
    allocator: std.mem.Allocator,
    k_prime: u32,
) SolverError!SolverPlan {
    var cm = constraint_matrix_mod.buildConstraintMatrices(MatrixType, allocator, k_prime) catch
        return error.OutOfMemory;
    defer cm.deinit();

    const State = SolverState(MatrixType);
    var state = try State.init(allocator, &cm, k_prime);
    defer state.deinit();

    try state.phase1();
    try state.phase2();
    try state.phase3();

    const perm = allocator.alloc(u32, state.l) catch return error.OutOfMemory;
    errdefer allocator.free(perm);
    for (0..state.l) |j| {
        perm[state.c[j]] = state.d[j];
    }

    // toOwnedSlice transfers ownership; state.deinit is safe on the emptied list
    const ops = state.deferred_ops.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return .{
        .ops = ops,
        .perm = perm,
        .l = state.l,
        .allocator = allocator,
    };
}

/// Solve for intermediate symbols using inactivation decoding.
/// Generic over binary matrix type. Mutates buf in-place.
pub fn solve(
    comptime MatrixType: type,
    allocator: std.mem.Allocator,
    cm: *constraint_matrix_mod.ConstraintMatrices(MatrixType),
    buf: *SymbolBuffer,
    k_prime: u32,
) SolverError!void {
    const State = SolverState(MatrixType);
    var state = try State.init(allocator, cm, k_prime);
    defer state.deinit();

    const do_profile = profile_enabled;

    var t: [5]std.time.Instant = undefined;
    if (do_profile) t[0] = std.time.Instant.now() catch unreachable;
    try state.phase1();
    if (do_profile) t[1] = std.time.Instant.now() catch unreachable;
    try state.phase2();
    if (do_profile) t[2] = std.time.Instant.now() catch unreachable;
    try state.phase3();
    if (do_profile) t[3] = std.time.Instant.now() catch unreachable;
    try state.applyAndRemap(buf);
    if (do_profile) t[4] = std.time.Instant.now() catch unreachable;

    if (do_profile) {
        const p1 = t[1].since(t[0]);
        const p2 = t[2].since(t[1]);
        const p3 = t[3].since(t[2]);
        const ap = t[4].since(t[3]);
        const total = t[4].since(t[0]);
        std.debug.print("[pi_solver K'={d} L={d}] phase1={d}us phase2={d}us phase3={d}us apply={d}us total={d}us i={d} u={d}\n", .{
            k_prime,
            state.l,
            p1 / 1000,
            p2 / 1000,
            p3 / 1000,
            ap / 1000,
            total / 1000,
            state.i,
            state.u,
        });
    }
}

test "pi_solver solves real constraint matrix K'=10" {
    const allocator = std.testing.allocator;

    const k_prime: u32 = 10;

    var cm = try constraint_matrix_mod.buildConstraintMatrices(DenseBinaryMatrix, allocator, k_prime);
    defer cm.deinit();

    var buf = try SymbolBuffer.init(allocator, 27, 4);
    defer buf.deinit();

    for (0..27) |idx| {
        buf.get(@intCast(idx))[0] = @intCast(idx + 1);
    }

    try solve(DenseBinaryMatrix, allocator, &cm, &buf, k_prime);

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

    const k_prime: u32 = 10;

    var cm = try constraint_matrix_mod.buildConstraintMatrices(DenseBinaryMatrix, allocator, k_prime);
    defer cm.deinit();

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

    const result = solve(DenseBinaryMatrix, allocator, &cm, &buf, k_prime);
    try std.testing.expectError(error.SingularMatrix, result);
}

test "SolverPlan matches solve for K'=10" {
    const allocator = std.testing.allocator;
    const encoder = @import("../codec/encoder.zig");

    const k_prime: u32 = 10;
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = k_prime + si.s + si.h;
    const sym_size: u32 = 4;

    // Method 1: solve directly
    var cm1 = try constraint_matrix_mod.buildConstraintMatrices(DenseBinaryMatrix, allocator, k_prime);
    defer cm1.deinit();

    var buf1 = try SymbolBuffer.init(allocator, l, sym_size);
    defer buf1.deinit();

    for (0..k_prime) |i| {
        const row = buf1.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| v.* = @intCast((i * sym_size + j + 1) % 256);
    }

    var source_copy: [10][4]u8 = undefined;
    for (0..k_prime) |i| @memcpy(&source_copy[i], buf1.getConst(@intCast(s + h + i)));

    try solve(DenseBinaryMatrix, allocator, &cm1, &buf1, k_prime);

    // Method 2: generatePlan + apply
    var plan = try generatePlan(DenseBinaryMatrix, allocator, k_prime);
    defer plan.deinit();

    var buf2 = try SymbolBuffer.init(allocator, l, sym_size);
    defer buf2.deinit();

    for (0..k_prime) |i| {
        const row = buf2.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| v.* = @intCast((i * sym_size + j + 1) % 256);
    }

    try plan.apply(&buf2);

    // Verify identical intermediate symbols
    for (0..l) |i| {
        try std.testing.expectEqualSlices(u8, buf1.getConst(@intCast(i)), buf2.getConst(@intCast(i)));
    }

    // Verify plan produces correct encoding via ltEncode
    for (0..k_prime) |i| {
        const regenerated = try encoder.ltEncode(allocator, k_prime, &buf2, @intCast(i));
        defer allocator.free(regenerated);
        try std.testing.expectEqualSlices(u8, &source_copy[i], regenerated);
    }
}

test "SolverPlan reusable across applies" {
    const allocator = std.testing.allocator;
    const encoder = @import("../codec/encoder.zig");

    const k_prime: u32 = 10;
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = k_prime + si.s + si.h;
    const sym_size: u32 = 4;

    var plan = try generatePlan(DenseBinaryMatrix, allocator, k_prime);
    defer plan.deinit();

    // Apply to two different data sets
    for (0..2) |run| {
        var buf = try SymbolBuffer.init(allocator, l, sym_size);
        defer buf.deinit();

        for (0..k_prime) |i| {
            const row = buf.get(@intCast(s + h + i));
            for (row, 0..) |*v, j| v.* = @intCast(((run + 1) * i * sym_size + j + 1) % 256);
        }

        var source_copy: [10][4]u8 = undefined;
        for (0..k_prime) |i| @memcpy(&source_copy[i], buf.getConst(@intCast(s + h + i)));

        try plan.apply(&buf);

        for (0..k_prime) |i| {
            const regenerated = try encoder.ltEncode(allocator, k_prime, &buf, @intCast(i));
            defer allocator.free(regenerated);
            try std.testing.expectEqualSlices(u8, &source_copy[i], regenerated);
        }
    }
}
