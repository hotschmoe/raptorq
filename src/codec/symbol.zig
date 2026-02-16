// Encoding symbol with GF(256) field arithmetic

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const octets = @import("../math/octets.zig");

pub const Symbol = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Symbol {
        _ = .{ allocator, size };
        @panic("TODO");
    }

    pub fn fromSlice(allocator: std.mem.Allocator, src: []const u8) !Symbol {
        _ = .{ allocator, src };
        @panic("TODO");
    }

    pub fn deinit(self: Symbol) void {
        self.allocator.free(self.data);
    }

    pub fn clone(self: Symbol) !Symbol {
        _ = self;
        @panic("TODO");
    }

    pub fn addAssign(self: *Symbol, other: Symbol) void {
        _ = .{ self, other };
        @panic("TODO");
    }

    pub fn mulAssign(self: *Symbol, scalar: Octet) void {
        _ = .{ self, scalar };
        @panic("TODO");
    }

    pub fn fma(self: *Symbol, other: Symbol, scalar: Octet) void {
        _ = .{ self, other, scalar };
        @panic("TODO");
    }

    pub fn len(self: Symbol) usize {
        return self.data.len;
    }
};
