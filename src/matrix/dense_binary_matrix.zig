// Bit-packed binary matrix using u64 words

const std = @import("std");
const gf2 = @import("../math/gf2.zig");

pub const DenseBinaryMatrix = struct {
    rows: u32,
    cols: u32,
    words_per_row: u32,
    data: []u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !DenseBinaryMatrix {
        const words_per_row = (cols + 63) / 64;
        const total = @as(usize, rows) * @as(usize, words_per_row);
        const data = try allocator.alloc(u64, total);
        @memset(data, 0);
        return .{
            .rows = rows,
            .cols = cols,
            .words_per_row = words_per_row,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: DenseBinaryMatrix) void {
        self.allocator.free(self.data);
    }

    pub fn rowSlice(self: DenseBinaryMatrix, row: u32) []u64 {
        const off = @as(usize, row) * @as(usize, self.words_per_row);
        return self.data[off..][0..self.words_per_row];
    }

    pub fn rowSliceConst(self: DenseBinaryMatrix, row: u32) []const u64 {
        const off = @as(usize, row) * @as(usize, self.words_per_row);
        return self.data[off..][0..self.words_per_row];
    }

    pub fn get(self: DenseBinaryMatrix, row: u32, col: u32) bool {
        return gf2.getBit(self.rowSliceConst(row), col);
    }

    pub fn set(self: *DenseBinaryMatrix, row: u32, col: u32, val: bool) void {
        gf2.setBit(self.rowSlice(row), col, val);
    }

    pub fn swapRows(self: *DenseBinaryMatrix, i: u32, j: u32) void {
        if (i == j) return;
        const row_i = self.rowSlice(i);
        const row_j = self.rowSlice(j);
        for (row_i, row_j) |*a, *b| {
            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;
        }
    }

    pub fn xorRow(self: *DenseBinaryMatrix, src: u32, dst: u32) void {
        gf2.xorSlice(self.rowSlice(dst), self.rowSliceConst(src));
    }

    /// XOR src row into dst row, but only for bits from start_col onward.
    pub fn xorRowRange(self: *DenseBinaryMatrix, src: u32, dst: u32, start_col: u32) void {
        gf2.xorSliceFrom(self.rowSlice(dst), self.rowSliceConst(src), start_col);
    }

    /// Count set bits in [start_col, end_col) for the given row.
    pub fn countOnesInRange(self: DenseBinaryMatrix, row: u32, start_col: u32, end_col: u32) u32 {
        return gf2.countOnesInRange(self.rowSliceConst(row), start_col, end_col);
    }

    /// Write column indices of set bits in [start_col, end_col) into buf.
    /// Returns the number of indices written.
    pub fn nonzeroColsInRange(self: DenseBinaryMatrix, row: u32, start_col: u32, end_col: u32, buf: []u32) u32 {
        const row_data = self.rowSliceConst(row);
        const first_word = start_col / 64;
        const last_word_inclusive = if (end_col == 0) return 0 else (end_col - 1) / 64;
        var count: u32 = 0;

        var w: u32 = first_word;
        while (w <= last_word_inclusive and w < self.words_per_row) : (w += 1) {
            var word = row_data[w];
            // Mask off bits outside [start_col, end_col)
            if (w == first_word) {
                const first_bit: u6 = @intCast(start_col % 64);
                if (first_bit != 0) word &= @as(u64, std.math.maxInt(u64)) << first_bit;
            }
            if (w == last_word_inclusive) {
                const end_mod: u7 = @intCast(end_col - w * 64);
                if (end_mod < 64) word &= (@as(u64, 1) << @intCast(end_mod)) - 1;
            }
            while (word != 0) {
                if (count >= buf.len) return count;
                const bit_pos: u32 = @intCast(@ctz(word));
                buf[count] = w * 64 + bit_pos;
                count += 1;
                word &= word - 1; // clear lowest set bit
            }
        }
        return count;
    }

    /// Swap two columns across all rows from start_row onward.
    pub fn swapCols(self: *DenseBinaryMatrix, col_i: u32, col_j: u32, start_row: u32) void {
        if (col_i == col_j) return;
        const wi = col_i / 64;
        const wj = col_j / 64;
        const bi: u6 = @intCast(col_i % 64);
        const bj: u6 = @intCast(col_j % 64);
        const mask_i: u64 = @as(u64, 1) << bi;
        const mask_j: u64 = @as(u64, 1) << bj;

        var row = start_row;
        while (row < self.rows) : (row += 1) {
            const s = self.rowSlice(row);
            const val_i = (s[wi] >> bi) & 1;
            const val_j = (s[wj] >> bj) & 1;
            if (val_i != val_j) {
                s[wi] ^= mask_i;
                s[wj] ^= mask_j;
            }
        }
    }

    pub fn numRows(self: DenseBinaryMatrix) u32 {
        return self.rows;
    }

    pub fn numCols(self: DenseBinaryMatrix) u32 {
        return self.cols;
    }
};

test "DenseBinaryMatrix get/set" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 4, 100);
    defer m.deinit();

    try std.testing.expect(!m.get(0, 0));
    m.set(0, 0, true);
    try std.testing.expect(m.get(0, 0));

    m.set(2, 99, true);
    try std.testing.expect(m.get(2, 99));
    try std.testing.expect(!m.get(2, 98));

    m.set(0, 0, false);
    try std.testing.expect(!m.get(0, 0));
}

test "DenseBinaryMatrix swapRows" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 3, 10);
    defer m.deinit();

    m.set(0, 1, true);
    m.set(0, 5, true);
    m.set(1, 3, true);

    m.swapRows(0, 1);
    try std.testing.expect(!m.get(0, 1));
    try std.testing.expect(!m.get(0, 5));
    try std.testing.expect(m.get(0, 3));
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(m.get(1, 5));
}

test "DenseBinaryMatrix xorRow" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 2, 10);
    defer m.deinit();

    m.set(0, 1, true);
    m.set(0, 3, true);
    m.set(1, 3, true);
    m.set(1, 5, true);

    m.xorRow(0, 1);
    // dst row 1: was {3,5}, XOR {1,3} = {1,5}
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(!m.get(1, 3));
    try std.testing.expect(m.get(1, 5));
}

test "DenseBinaryMatrix xorRowRange partial" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 2, 10);
    defer m.deinit();

    m.set(0, 1, true);
    m.set(0, 3, true);
    m.set(0, 7, true);
    m.set(1, 3, true);
    m.set(1, 5, true);

    m.xorRowRange(0, 1, 3);
    // XOR from col 3 onward: bits 3 and 7 from src
    // dst col 1: unchanged (below start_col)
    try std.testing.expect(!m.get(1, 1));
    // dst col 3: was 1, XOR 1 = 0
    try std.testing.expect(!m.get(1, 3));
    // dst col 5: was 1, XOR 0 = 1
    try std.testing.expect(m.get(1, 5));
    // dst col 7: was 0, XOR 1 = 1
    try std.testing.expect(m.get(1, 7));
}

test "DenseBinaryMatrix countOnesInRange" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 1, 200);
    defer m.deinit();

    m.set(0, 5, true);
    m.set(0, 63, true);
    m.set(0, 64, true);
    m.set(0, 100, true);
    m.set(0, 199, true);

    try std.testing.expectEqual(@as(u32, 5), m.countOnesInRange(0, 0, 200));
    try std.testing.expectEqual(@as(u32, 1), m.countOnesInRange(0, 0, 6));
    try std.testing.expectEqual(@as(u32, 0), m.countOnesInRange(0, 6, 63));
    try std.testing.expectEqual(@as(u32, 2), m.countOnesInRange(0, 63, 65));
    try std.testing.expectEqual(@as(u32, 1), m.countOnesInRange(0, 100, 101));
}

test "DenseBinaryMatrix nonzeroColsInRange" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 1, 200);
    defer m.deinit();

    m.set(0, 10, true);
    m.set(0, 70, true);
    m.set(0, 130, true);

    var buf: [10]u32 = undefined;
    const count = m.nonzeroColsInRange(0, 5, 140, &buf);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(u32, 10), buf[0]);
    try std.testing.expectEqual(@as(u32, 70), buf[1]);
    try std.testing.expectEqual(@as(u32, 130), buf[2]);
}

test "DenseBinaryMatrix swapCols" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 3, 10);
    defer m.deinit();

    m.set(0, 2, true);
    m.set(1, 5, true);
    m.set(2, 2, true);
    m.set(2, 5, true);

    m.swapCols(2, 5, 0);
    // Row 0: col 2 was 1, col 5 was 0 -> col 2=0, col 5=1
    try std.testing.expect(!m.get(0, 2));
    try std.testing.expect(m.get(0, 5));
    // Row 1: col 2 was 0, col 5 was 1 -> col 2=1, col 5=0
    try std.testing.expect(m.get(1, 2));
    try std.testing.expect(!m.get(1, 5));
    // Row 2: both were 1 -> both still 1 (swap of equal values)
    try std.testing.expect(m.get(2, 2));
    try std.testing.expect(m.get(2, 5));
}

test "DenseBinaryMatrix swapCols with start_row" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 3, 10);
    defer m.deinit();

    m.set(0, 2, true);
    m.set(1, 2, true);
    m.set(2, 5, true);

    m.swapCols(2, 5, 1);
    // Row 0: unaffected (below start_row)
    try std.testing.expect(m.get(0, 2));
    try std.testing.expect(!m.get(0, 5));
    // Row 1: col 2 was 1, col 5 was 0 -> swapped
    try std.testing.expect(!m.get(1, 2));
    try std.testing.expect(m.get(1, 5));
    // Row 2: col 2 was 0, col 5 was 1 -> swapped
    try std.testing.expect(m.get(2, 2));
    try std.testing.expect(!m.get(2, 5));
}
