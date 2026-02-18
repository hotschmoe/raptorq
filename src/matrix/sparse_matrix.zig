// Hybrid sparse/dense binary matrix with row and column indirection.
//
// The matrix has two storage regions:
//   Sparse (V): sorted u16 physical column indices per row (SparseBinaryVec)
//   Dense  (U): bit-packed u64 words per row
//
// Column indirection: O(1) swapCols via logical<->physical mapping
// Row indirection:    O(1) swapRows via logical<->physical mapping
//
// Columns migrate from sparse to dense via hintColumnDenseAndFrozen().
// The dense section grows monotonically during Phase 1 as columns are inactivated.

const std = @import("std");
const SparseBinaryVec = @import("../util/sparse_vec.zig").SparseBinaryVec;
const ColumnarIndex = @import("../util/arraymap.zig").ColumnarIndex;
const gf2 = @import("../math/gf2.zig");

pub const SparseBinaryMatrix = struct {
    height: u32,
    width: u32,
    sparse_rows: []SparseBinaryVec, // indexed by physical row
    dense_elements: []u64, // flat: phys_row * max_words_per_row + word_idx
    max_words_per_row: u32, // (width + 63) / 64, pre-allocated for worst case
    num_dense_cols: u32, // grows during Phase 1
    phys_col_to_dense_bit: []u16, // physical col -> dense bit position, or NONE
    dense_bit_to_phys_col: []u16, // dense bit -> physical col (reverse of above)
    log_col_to_phys: []u16, // logical col -> physical col
    phys_col_to_log: []u16, // physical col -> logical col
    log_row_to_phys: []u32, // logical row -> physical row
    phys_row_to_log: []u32, // physical row -> logical row
    columnar_index: ?ColumnarIndex, // built on demand for Phase 1
    allocator: std.mem.Allocator,

    const DENSE_BIT_NONE: u16 = std.math.maxInt(u16);

    pub fn init(allocator: std.mem.Allocator, height: u32, width: u32, initial_dense_cols: u32) !SparseBinaryMatrix {
        const sparse_rows = try allocator.alloc(SparseBinaryVec, height);
        for (sparse_rows) |*row| row.* = SparseBinaryVec.init(allocator);
        errdefer {
            for (sparse_rows) |*row| row.deinit();
            allocator.free(sparse_rows);
        }

        const max_words = (width + 63) / 64;
        const dense_total = @as(usize, height) * @as(usize, max_words);
        const dense_elements = try allocator.alloc(u64, dense_total);
        errdefer allocator.free(dense_elements);
        @memset(dense_elements, 0);

        const p2d = try allocator.alloc(u16, width);
        errdefer allocator.free(p2d);
        @memset(p2d, @as(u16, DENSE_BIT_NONE));
        const d2p = try allocator.alloc(u16, width);
        errdefer allocator.free(d2p);
        @memset(d2p, @as(u16, DENSE_BIT_NONE));
        // Assign dense bits for initial dense columns (rightmost logical columns)
        const sparse_boundary = width - initial_dense_cols;
        for (sparse_boundary..width) |pc| {
            p2d[pc] = @intCast(pc - sparse_boundary);
            d2p[pc - sparse_boundary] = @intCast(pc);
        }

        const l2p_col = try allocator.alloc(u16, width);
        errdefer allocator.free(l2p_col);
        const p2l_col = try allocator.alloc(u16, width);
        errdefer allocator.free(p2l_col);
        for (0..width) |i| {
            l2p_col[i] = @intCast(i);
            p2l_col[i] = @intCast(i);
        }

        const l2p_row = try allocator.alloc(u32, height);
        errdefer allocator.free(l2p_row);
        const p2l_row = try allocator.alloc(u32, height);
        errdefer allocator.free(p2l_row);
        for (0..height) |i| {
            l2p_row[i] = @intCast(i);
            p2l_row[i] = @intCast(i);
        }

        return .{
            .height = height,
            .width = width,
            .sparse_rows = sparse_rows,
            .dense_elements = dense_elements,
            .max_words_per_row = max_words,
            .num_dense_cols = initial_dense_cols,
            .phys_col_to_dense_bit = p2d,
            .dense_bit_to_phys_col = d2p,
            .log_col_to_phys = l2p_col,
            .phys_col_to_log = p2l_col,
            .log_row_to_phys = l2p_row,
            .phys_row_to_log = p2l_row,
            .columnar_index = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SparseBinaryMatrix) void {
        if (self.columnar_index) |*ci| ci.deinit();
        for (self.sparse_rows) |*row| row.deinit();
        self.allocator.free(self.sparse_rows);
        self.allocator.free(self.dense_elements);
        self.allocator.free(self.phys_col_to_dense_bit);
        self.allocator.free(self.dense_bit_to_phys_col);
        self.allocator.free(self.log_col_to_phys);
        self.allocator.free(self.phys_col_to_log);
        self.allocator.free(self.log_row_to_phys);
        self.allocator.free(self.phys_row_to_log);
    }

    pub inline fn denseWordsUsed(self: SparseBinaryMatrix) u32 {
        return (self.num_dense_cols + 63) / 64;
    }

    inline fn denseRow(self: SparseBinaryMatrix, phys_row: u32) []u64 {
        const off = @as(usize, phys_row) * @as(usize, self.max_words_per_row);
        return self.dense_elements[off..][0..self.max_words_per_row];
    }

    pub inline fn denseRowConst(self: SparseBinaryMatrix, phys_row: u32) []const u64 {
        const off = @as(usize, phys_row) * @as(usize, self.max_words_per_row);
        return self.dense_elements[off..][0..self.max_words_per_row];
    }

    pub fn get(self: SparseBinaryMatrix, logical_row: u32, logical_col: u32) bool {
        const phys_row = self.log_row_to_phys[logical_row];
        const phys_col = self.log_col_to_phys[logical_col];
        const dense_bit = self.phys_col_to_dense_bit[phys_col];
        if (dense_bit != DENSE_BIT_NONE) {
            return gf2.getBit(self.denseRowConst(phys_row), dense_bit);
        }
        return self.sparse_rows[phys_row].get(phys_col);
    }

    pub fn set(self: *SparseBinaryMatrix, logical_row: u32, logical_col: u32, val: bool) !void {
        const phys_row = self.log_row_to_phys[logical_row];
        const phys_col = self.log_col_to_phys[logical_col];
        const dense_bit = self.phys_col_to_dense_bit[phys_col];
        if (dense_bit != DENSE_BIT_NONE) {
            gf2.setBit(self.denseRow(phys_row), dense_bit, val);
            return;
        }
        if (val) {
            try self.sparse_rows[phys_row].set(phys_col);
        } else {
            self.sparse_rows[phys_row].unset(phys_col);
        }
    }

    /// O(1) row swap via indirection.
    pub fn swapRows(self: *SparseBinaryMatrix, i: u32, j: u32) void {
        if (i == j) return;
        self.phys_row_to_log[self.log_row_to_phys[i]] = j;
        self.phys_row_to_log[self.log_row_to_phys[j]] = i;
        std.mem.swap(u32, &self.log_row_to_phys[i], &self.log_row_to_phys[j]);
    }

    /// O(1) column swap via indirection. start_row unused (DenseBinaryMatrix needs it).
    pub fn swapCols(self: *SparseBinaryMatrix, i: u32, j: u32, _start_row: u32) void {
        _ = _start_row;
        if (i == j) return;
        self.phys_col_to_log[self.log_col_to_phys[i]] = @intCast(j);
        self.phys_col_to_log[self.log_col_to_phys[j]] = @intCast(i);
        std.mem.swap(u16, &self.log_col_to_phys[i], &self.log_col_to_phys[j]);
    }

    /// XOR src row into dst row for columns >= start_col (logical).
    /// If start_col >= V/U boundary: XOR only dense words (Errata 11 fast path).
    /// If start_col == 0: full sparse XOR + dense XOR.
    pub fn xorRowRange(self: *SparseBinaryMatrix, src_log: u32, dst_log: u32, start_col: u32) !void {
        const src_phys = self.log_row_to_phys[src_log];
        const dst_phys = self.log_row_to_phys[dst_log];

        // XOR dense section
        const wpr = self.denseWordsUsed();
        if (wpr > 0) {
            const src_words = self.denseRowConst(src_phys)[0..wpr];
            const dst_words = self.denseRow(dst_phys)[0..wpr];
            gf2.xorSlice(dst_words, src_words);
        }

        // XOR sparse section (entries with logical col >= start_col)
        const boundary = self.width - self.num_dense_cols;
        if (start_col >= boundary) return;

        const src_indices = self.sparse_rows[src_phys].indices.items;
        if (src_indices.len == 0) return;

        if (start_col == 0) {
            try self.sparse_rows[dst_phys].xorWith(self.sparse_rows[src_phys]);
        } else {
            // Filtered: only entries with logical col >= start_col
            for (src_indices) |phys_col| {
                const log_col = self.phys_col_to_log[phys_col];
                if (log_col < start_col) continue;
                const find = self.sparse_rows[dst_phys].findIndex(phys_col);
                if (find.found) {
                    _ = self.sparse_rows[dst_phys].indices.orderedRemove(find.pos);
                } else {
                    try self.sparse_rows[dst_phys].indices.insert(self.allocator, find.pos, phys_col);
                }
            }
        }
    }

    /// Count set bits in [start, end) logical column range for a logical row.
    /// Operates on sparse section only (caller ensures range is within V region).
    pub fn countOnesInRange(self: SparseBinaryMatrix, logical_row: u32, start: u32, end: u32) u32 {
        const phys_row = self.log_row_to_phys[logical_row];
        const indices = self.sparse_rows[phys_row].indices.items;
        var count: u32 = 0;
        for (indices) |phys_col| {
            const log_col = self.phys_col_to_log[phys_col];
            if (log_col >= start and log_col < end) count += 1;
        }
        return count;
    }

    /// Count bits set in both row_a AND row_b within [start, end) logical column range.
    pub fn andCountOnesInRange(self: SparseBinaryMatrix, row_a: u32, row_b: u32, start: u32, end: u32) u32 {
        const phys_a = self.log_row_to_phys[row_a];
        const phys_b = self.log_row_to_phys[row_b];
        const a_indices = self.sparse_rows[phys_a].indices.items;
        const b_indices = self.sparse_rows[phys_b].indices.items;

        var ia: usize = 0;
        var ib: usize = 0;
        var count: u32 = 0;
        while (ia < a_indices.len and ib < b_indices.len) {
            if (a_indices[ia] < b_indices[ib]) {
                ia += 1;
            } else if (a_indices[ia] > b_indices[ib]) {
                ib += 1;
            } else {
                const log_col = self.phys_col_to_log[a_indices[ia]];
                if (log_col >= start and log_col < end) count += 1;
                ia += 1;
                ib += 1;
            }
        }
        return count;
    }

    /// Write logical column indices of set bits in [start, end) into buf.
    pub fn nonzeroColsInRange(self: SparseBinaryMatrix, logical_row: u32, start: u32, end: u32, buf: []u32) u32 {
        const phys_row = self.log_row_to_phys[logical_row];
        const indices = self.sparse_rows[phys_row].indices.items;
        var count: u32 = 0;
        for (indices) |phys_col| {
            const log_col: u32 = self.phys_col_to_log[phys_col];
            if (log_col >= start and log_col < end) {
                if (count >= buf.len) break;
                buf[count] = log_col;
                count += 1;
            }
        }
        return count;
    }

    /// Migrate a column from sparse to dense representation.
    /// Scans all physical rows to find and migrate entries.
    pub fn hintColumnDenseAndFrozen(self: *SparseBinaryMatrix, logical_col: u32) void {
        const phys_col = self.log_col_to_phys[logical_col];
        const dense_bit: u16 = @intCast(self.num_dense_cols);
        self.phys_col_to_dense_bit[phys_col] = dense_bit;
        self.dense_bit_to_phys_col[dense_bit] = phys_col;
        self.num_dense_cols += 1;

        for (self.sparse_rows, 0..) |*row, phys_row| {
            const find = row.findIndex(phys_col);
            if (find.found) {
                _ = row.indices.orderedRemove(find.pos);
                gf2.setBit(self.denseRow(@intCast(phys_row)), dense_bit, true);
            }
        }
    }

    /// Build columnar index from current sparse data for O(nnz) column lookups.
    pub fn enableColumnAcceleration(self: *SparseBinaryMatrix) !void {
        self.columnar_index = try ColumnarIndex.build(self.allocator, self.width, self.sparse_rows);
    }

    /// Free the columnar index.
    pub fn disableColumnAcceleration(self: *SparseBinaryMatrix) void {
        if (self.columnar_index) |*ci| {
            ci.deinit();
            self.columnar_index = null;
        }
    }

    /// Get physical row indices with a 1 at the given logical column (via columnar index).
    /// The index may contain stale entries; caller should verify against current data.
    pub fn getOnesInColumn(self: SparseBinaryMatrix, log_col: u32) []const u32 {
        const phys_col = self.log_col_to_phys[log_col];
        if (self.columnar_index) |ci| {
            return ci.get(phys_col);
        }
        return &.{};
    }

    /// Clear a single bit by logical coordinates.
    pub fn clearBit(self: *SparseBinaryMatrix, logical_row: u32, logical_col: u32) void {
        const phys_row = self.log_row_to_phys[logical_row];
        const phys_col = self.log_col_to_phys[logical_col];
        const dense_bit = self.phys_col_to_dense_bit[phys_col];
        if (dense_bit != DENSE_BIT_NONE) {
            gf2.setBit(self.denseRow(phys_row), dense_bit, false);
        } else {
            self.sparse_rows[phys_row].unset(phys_col);
        }
    }

    pub fn numRows(self: SparseBinaryMatrix) u32 {
        return self.height;
    }

    pub fn numCols(self: SparseBinaryMatrix) u32 {
        return self.width;
    }
};

// -- Tests --

test "SparseBinaryMatrix get/set" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 3, 10, 0);
    defer m.deinit();

    try std.testing.expect(!m.get(0, 0));
    try m.set(0, 0, true);
    try std.testing.expect(m.get(0, 0));

    try m.set(2, 9, true);
    try std.testing.expect(m.get(2, 9));

    try m.set(0, 0, false);
    try std.testing.expect(!m.get(0, 0));
}

test "SparseBinaryMatrix get/set with initial dense cols" {
    // 3 rows, 10 cols, last 3 cols start dense
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 3, 10, 3);
    defer m.deinit();

    // Sparse column
    try m.set(0, 2, true);
    try std.testing.expect(m.get(0, 2));

    // Dense column
    try m.set(1, 8, true);
    try std.testing.expect(m.get(1, 8));

    try m.set(1, 8, false);
    try std.testing.expect(!m.get(1, 8));
}

test "SparseBinaryMatrix swapRows" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10, 0);
    defer m.deinit();

    try m.set(0, 1, true);
    try m.set(0, 5, true);
    try m.set(1, 3, true);

    m.swapRows(0, 1);
    try std.testing.expect(!m.get(0, 1));
    try std.testing.expect(!m.get(0, 5));
    try std.testing.expect(m.get(0, 3));
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(m.get(1, 5));
}

test "SparseBinaryMatrix swapCols" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10, 0);
    defer m.deinit();

    try m.set(0, 2, true);
    try m.set(1, 5, true);

    m.swapCols(2, 5, 0);
    // Row 0: had col 2 -> now at logical col 5 (via indirection)
    try std.testing.expect(!m.get(0, 2));
    try std.testing.expect(m.get(0, 5));
    // Row 1: had col 5 -> now at logical col 2
    try std.testing.expect(m.get(1, 2));
    try std.testing.expect(!m.get(1, 5));
}

test "SparseBinaryMatrix xorRowRange full" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10, 0);
    defer m.deinit();

    try m.set(0, 1, true);
    try m.set(0, 3, true);
    try m.set(1, 3, true);
    try m.set(1, 5, true);

    try m.xorRowRange(0, 1, 0);
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(!m.get(1, 3));
    try std.testing.expect(m.get(1, 5));
}

test "SparseBinaryMatrix xorRowRange dense only" {
    // 2 rows, 10 cols, last 5 are dense
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10, 5);
    defer m.deinit();

    // Set some sparse bits
    try m.set(0, 2, true);
    try m.set(1, 2, true);
    // Set some dense bits
    try m.set(0, 7, true);
    try m.set(0, 9, true);
    try m.set(1, 7, true);

    // XOR from col 5 onward (boundary = 10 - 5 = 5, so dense only)
    try m.xorRowRange(0, 1, 5);

    // Sparse unchanged
    try std.testing.expect(m.get(1, 2));
    // Dense: col 7 was in both -> XOR clears it
    try std.testing.expect(!m.get(1, 7));
    // Dense: col 9 was only in src -> appears in dst
    try std.testing.expect(m.get(1, 9));
}

test "SparseBinaryMatrix countOnesInRange" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 1, 20, 0);
    defer m.deinit();

    try m.set(0, 2, true);
    try m.set(0, 5, true);
    try m.set(0, 8, true);
    try m.set(0, 15, true);

    try std.testing.expectEqual(@as(u32, 3), m.countOnesInRange(0, 0, 10));
    try std.testing.expectEqual(@as(u32, 2), m.countOnesInRange(0, 2, 8));
    try std.testing.expectEqual(@as(u32, 0), m.countOnesInRange(0, 3, 5));
}

test "SparseBinaryMatrix andCountOnesInRange" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 20, 0);
    defer m.deinit();

    try m.set(0, 2, true);
    try m.set(0, 5, true);
    try m.set(0, 8, true);
    try m.set(1, 5, true);
    try m.set(1, 8, true);
    try m.set(1, 12, true);

    try std.testing.expectEqual(@as(u32, 2), m.andCountOnesInRange(0, 1, 0, 20));
    try std.testing.expectEqual(@as(u32, 1), m.andCountOnesInRange(0, 1, 0, 6));
}

test "SparseBinaryMatrix nonzeroColsInRange" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 1, 20, 0);
    defer m.deinit();

    try m.set(0, 3, true);
    try m.set(0, 7, true);
    try m.set(0, 12, true);

    var buf: [10]u32 = undefined;
    const count = m.nonzeroColsInRange(0, 0, 20, &buf);
    try std.testing.expectEqual(@as(u32, 3), count);
    // Verify all expected columns are present (order may vary due to physical mapping)
    var found: [3]bool = .{ false, false, false };
    for (buf[0..count]) |col| {
        if (col == 3) found[0] = true;
        if (col == 7) found[1] = true;
        if (col == 12) found[2] = true;
    }
    try std.testing.expect(found[0] and found[1] and found[2]);
}

test "SparseBinaryMatrix hintColumnDenseAndFrozen" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 3, 10, 0);
    defer m.deinit();

    try m.set(0, 5, true);
    try m.set(1, 5, true);
    try m.set(2, 3, true);

    // Freeze column 5 to dense
    m.hintColumnDenseAndFrozen(5);

    // Column 5 should still read correctly (now from dense)
    try std.testing.expect(m.get(0, 5));
    try std.testing.expect(m.get(1, 5));
    try std.testing.expect(!m.get(2, 5));

    // Column 3 still sparse
    try std.testing.expect(m.get(2, 3));

    try std.testing.expectEqual(@as(u32, 1), m.num_dense_cols);
}

test "SparseBinaryMatrix column acceleration" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 3, 10, 0);
    defer m.deinit();

    try m.set(0, 2, true);
    try m.set(1, 2, true);
    try m.set(1, 5, true);
    try m.set(2, 5, true);

    try m.enableColumnAcceleration();
    defer m.disableColumnAcceleration();

    // getOnesInColumn returns physical rows (identity mapping at this point)
    const col2_rows = m.getOnesInColumn(2);
    try std.testing.expectEqual(@as(usize, 2), col2_rows.len);

    const col5_rows = m.getOnesInColumn(5);
    try std.testing.expectEqual(@as(usize, 2), col5_rows.len);
}

test "SparseBinaryMatrix swapCols then freeze" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10, 0);
    defer m.deinit();

    try m.set(0, 3, true);
    try m.set(1, 7, true);

    // Swap columns 3 and 7
    m.swapCols(3, 7, 0);

    // After swap: logical col 3 has old col 7's data, logical col 7 has old col 3's data
    try std.testing.expect(!m.get(0, 3));
    try std.testing.expect(m.get(0, 7));
    try std.testing.expect(m.get(1, 3));
    try std.testing.expect(!m.get(1, 7));

    // Freeze logical column 3 (which physically holds old column 7's data)
    m.hintColumnDenseAndFrozen(3);
    try std.testing.expect(m.get(1, 3));
    try std.testing.expect(!m.get(0, 3));
}
