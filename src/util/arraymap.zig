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
