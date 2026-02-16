// Sparse binary vector using sorted index list

const std = @import("std");

pub const SparseBinaryVec = struct {
    indices: std.ArrayList(u32) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SparseBinaryVec {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SparseBinaryVec) void {
        self.indices.deinit(self.allocator);
    }

    const FindResult = struct { found: bool, pos: usize };

    fn findIndex(self: SparseBinaryVec, index: u32) FindResult {
        const items = self.indices.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < index) {
                lo = mid + 1;
            } else if (items[mid] > index) {
                hi = mid;
            } else {
                return .{ .found = true, .pos = mid };
            }
        }
        return .{ .found = false, .pos = lo };
    }

    pub fn get(self: SparseBinaryVec, index: u32) bool {
        return self.findIndex(index).found;
    }

    pub fn set(self: *SparseBinaryVec, index: u32) !void {
        const result = self.findIndex(index);
        if (!result.found) {
            try self.indices.insert(self.allocator, result.pos, index);
        }
    }

    pub fn unset(self: *SparseBinaryVec, index: u32) void {
        const result = self.findIndex(index);
        if (result.found) {
            _ = self.indices.orderedRemove(result.pos);
        }
    }

    pub fn count(self: SparseBinaryVec) usize {
        return self.indices.items.len;
    }

    pub fn xorWith(self: *SparseBinaryVec, other: SparseBinaryVec) !void {
        var result: std.ArrayList(u32) = .empty;
        errdefer result.deinit(self.allocator);

        const a = self.indices.items;
        const b = other.indices.items;
        var ia: usize = 0;
        var ib: usize = 0;

        while (ia < a.len and ib < b.len) {
            if (a[ia] < b[ib]) {
                try result.append(self.allocator, a[ia]);
                ia += 1;
            } else if (a[ia] > b[ib]) {
                try result.append(self.allocator, b[ib]);
                ib += 1;
            } else {
                ia += 1;
                ib += 1;
            }
        }
        while (ia < a.len) : (ia += 1) {
            try result.append(self.allocator, a[ia]);
        }
        while (ib < b.len) : (ib += 1) {
            try result.append(self.allocator, b[ib]);
        }

        self.indices.deinit(self.allocator);
        self.indices = result;
    }
};

test "SparseBinaryVec get/set/unset" {
    var v = SparseBinaryVec.init(std.testing.allocator);
    defer v.deinit();

    try std.testing.expect(!v.get(5));
    try v.set(5);
    try std.testing.expect(v.get(5));
    try std.testing.expectEqual(@as(usize, 1), v.count());

    try v.set(3);
    try v.set(10);
    try std.testing.expectEqual(@as(usize, 3), v.count());
    try std.testing.expect(v.get(3));
    try std.testing.expect(v.get(5));
    try std.testing.expect(v.get(10));

    try v.set(5);
    try std.testing.expectEqual(@as(usize, 3), v.count());

    v.unset(5);
    try std.testing.expect(!v.get(5));
    try std.testing.expectEqual(@as(usize, 2), v.count());

    v.unset(99);
    try std.testing.expectEqual(@as(usize, 2), v.count());
}

test "SparseBinaryVec xorWith" {
    var a = SparseBinaryVec.init(std.testing.allocator);
    defer a.deinit();
    var b = SparseBinaryVec.init(std.testing.allocator);
    defer b.deinit();

    try a.set(1);
    try a.set(3);
    try a.set(5);

    try b.set(2);
    try b.set(3);
    try b.set(4);

    try a.xorWith(b);
    try std.testing.expectEqual(@as(usize, 4), a.count());
    try std.testing.expect(a.get(1));
    try std.testing.expect(a.get(2));
    try std.testing.expect(!a.get(3));
    try std.testing.expect(a.get(4));
    try std.testing.expect(a.get(5));
}

test "SparseBinaryVec sorted order" {
    var v = SparseBinaryVec.init(std.testing.allocator);
    defer v.deinit();

    try v.set(10);
    try v.set(2);
    try v.set(7);
    try v.set(1);

    const items = v.indices.items;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 7, 10 }, items);
}
