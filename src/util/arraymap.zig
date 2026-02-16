// Specialized map types for codec operations

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;

/// Map from u16 keys to Octet values, backed by a sorted array.
pub const U16ArrayMap = struct {
    keys: std.ArrayList(u16),
    values: std.ArrayList(Octet),

    pub fn init(allocator: std.mem.Allocator) U16ArrayMap {
        return .{
            .keys = std.ArrayList(u16).init(allocator),
            .values = std.ArrayList(Octet).init(allocator),
        };
    }

    pub fn deinit(self: *U16ArrayMap) void {
        self.keys.deinit();
        self.values.deinit();
    }

    pub fn get(self: U16ArrayMap, key: u16) ?Octet {
        _ = .{ self, key };
        @panic("TODO");
    }

    pub fn put(self: *U16ArrayMap, key: u16, value: Octet) !void {
        _ = .{ self, key, value };
        @panic("TODO");
    }

    pub fn len(self: U16ArrayMap) usize {
        return self.keys.items.len;
    }
};
