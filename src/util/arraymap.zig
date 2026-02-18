// Specialized map types for codec operations

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;

/// Map from u16 keys to Octet values, backed by a sorted array.
pub const U16ArrayMap = struct {
    keys: std.ArrayList(u16) = .empty,
    values: std.ArrayList(Octet) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) U16ArrayMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *U16ArrayMap) void {
        self.keys.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    fn findKey(self: U16ArrayMap, key: u16) struct { found: bool, pos: usize } {
        const items = self.keys.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < key) {
                lo = mid + 1;
            } else if (items[mid] > key) {
                hi = mid;
            } else {
                return .{ .found = true, .pos = mid };
            }
        }
        return .{ .found = false, .pos = lo };
    }

    pub fn get(self: U16ArrayMap, key: u16) ?Octet {
        const result = self.findKey(key);
        if (result.found) return self.values.items[result.pos];
        return null;
    }

    pub fn put(self: *U16ArrayMap, key: u16, value: Octet) !void {
        const result = self.findKey(key);
        if (result.found) {
            self.values.items[result.pos] = value;
        } else {
            try self.keys.insert(self.allocator, result.pos, key);
            errdefer _ = self.keys.orderedRemove(result.pos);
            try self.values.insert(self.allocator, result.pos, value);
        }
    }

    pub fn len(self: U16ArrayMap) usize {
        return self.keys.items.len;
    }
};

/// CSC-like columnar index for O(1) column lookups into sparse rows.
/// Built once via two-pass (count, prefix-sum, fill). Query is a slice lookup.
pub const ColumnarIndex = struct {
    offsets: []u32, // offsets[col] -> start in values[], offsets[num_cols] = total nnz
    values: []u32, // physical row indices with a 1 in that column
    num_cols: u32,
    allocator: std.mem.Allocator,

    const SparseBinaryVec = @import("sparse_vec.zig").SparseBinaryVec;

    pub fn build(allocator: std.mem.Allocator, num_cols: u32, sparse_rows: []const SparseBinaryVec) !ColumnarIndex {
        // Pass 1: count nonzeros per column
        const counts = try allocator.alloc(u32, @as(usize, num_cols) + 1);
        defer allocator.free(counts);
        @memset(counts, 0);

        for (sparse_rows) |row| {
            for (row.indices.items) |col| {
                counts[col] += 1;
            }
        }

        // Convert counts to prefix sums (offsets)
        const offsets = try allocator.alloc(u32, @as(usize, num_cols) + 1);
        errdefer allocator.free(offsets);
        offsets[0] = 0;
        for (0..num_cols) |c| {
            offsets[c + 1] = offsets[c] + counts[c];
        }
        const total_nnz = offsets[num_cols];

        // Pass 2: fill values using offsets as write cursors
        const values = try allocator.alloc(u32, total_nnz);
        errdefer allocator.free(values);
        // Reuse counts as write positions (reset to offsets)
        for (0..num_cols) |c| {
            counts[c] = offsets[c];
        }

        for (sparse_rows, 0..) |row, row_idx| {
            for (row.indices.items) |col| {
                values[counts[col]] = @intCast(row_idx);
                counts[col] += 1;
            }
        }

        return .{
            .offsets = offsets,
            .values = values,
            .num_cols = num_cols,
            .allocator = allocator,
        };
    }

    pub fn get(self: ColumnarIndex, col: u16) []const u32 {
        return self.values[self.offsets[col]..self.offsets[@as(u32, col) + 1]];
    }

    pub fn deinit(self: *ColumnarIndex) void {
        self.allocator.free(self.offsets);
        self.allocator.free(self.values);
    }
};

test "U16ArrayMap get/put" {
    var m = U16ArrayMap.init(std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(?Octet, null), m.get(10));

    try m.put(10, Octet.init(42));
    try std.testing.expectEqual(Octet.init(42), m.get(10).?);
    try std.testing.expectEqual(@as(usize, 1), m.len());

    try m.put(10, Octet.init(99));
    try std.testing.expectEqual(Octet.init(99), m.get(10).?);
    try std.testing.expectEqual(@as(usize, 1), m.len());

    try m.put(5, Octet.init(1));
    try m.put(20, Octet.init(2));
    try m.put(15, Octet.init(3));

    try std.testing.expectEqual(@as(usize, 4), m.len());
    try std.testing.expectEqualSlices(u16, &.{ 5, 10, 15, 20 }, m.keys.items);
    try std.testing.expectEqual(Octet.init(1), m.get(5).?);
    try std.testing.expectEqual(Octet.init(3), m.get(15).?);
    try std.testing.expectEqual(Octet.init(2), m.get(20).?);
}

test "ColumnarIndex build and get" {
    const SparseBinaryVec = @import("sparse_vec.zig").SparseBinaryVec;
    const allocator = std.testing.allocator;

    // 3 rows, 5 columns
    var rows: [3]SparseBinaryVec = undefined;
    for (&rows) |*r| r.* = SparseBinaryVec.init(allocator);
    defer for (&rows) |*r| r.deinit();

    // Row 0: cols {1, 3}
    try rows[0].set(1);
    try rows[0].set(3);
    // Row 1: cols {0, 1, 4}
    try rows[1].set(0);
    try rows[1].set(1);
    try rows[1].set(4);
    // Row 2: cols {1, 2}
    try rows[2].set(1);
    try rows[2].set(2);

    var idx = try ColumnarIndex.build(allocator, 5, &rows);
    defer idx.deinit();

    // Col 0: row 1
    try std.testing.expectEqualSlices(u32, &.{1}, idx.get(0));
    // Col 1: rows 0, 1, 2
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, idx.get(1));
    // Col 2: row 2
    try std.testing.expectEqualSlices(u32, &.{2}, idx.get(2));
    // Col 3: row 0
    try std.testing.expectEqualSlices(u32, &.{0}, idx.get(3));
    // Col 4: row 1
    try std.testing.expectEqualSlices(u32, &.{1}, idx.get(4));
}
