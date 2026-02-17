// Encoding symbol with GF(256) field arithmetic

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const octets = @import("../math/octets.zig");

pub const Symbol = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Symbol {
        const data = try allocator.alloc(u8, size);
        @memset(data, 0);
        return .{ .data = data, .allocator = allocator };
    }

    pub fn fromSlice(allocator: std.mem.Allocator, src: []const u8) !Symbol {
        const data = try allocator.alloc(u8, src.len);
        @memcpy(data, src);
        return .{ .data = data, .allocator = allocator };
    }

    pub fn deinit(self: Symbol) void {
        self.allocator.free(self.data);
    }

    pub fn clone(self: Symbol) !Symbol {
        return fromSlice(self.allocator, self.data);
    }

    pub fn addAssign(self: *Symbol, other: Symbol) void {
        octets.addAssign(self.data, other.data);
    }

    pub fn mulAssign(self: *Symbol, scalar: Octet) void {
        octets.mulAssignScalar(self.data, scalar);
    }

    pub fn fma(self: *Symbol, other: Symbol, scalar: Octet) void {
        octets.fmaSlice(self.data, other.data, scalar);
    }

    pub fn len(self: Symbol) usize {
        return self.data.len;
    }
};

/// Contiguous buffer holding count symbols of equal size in a single allocation.
pub const SymbolBuffer = struct {
    data: []align(64) u8,
    symbol_size: u32,
    count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, count: u32, symbol_size: u32) !SymbolBuffer {
        const total = @as(usize, count) * @as(usize, symbol_size);
        const data = try allocator.alignedAlloc(u8, .@"64", total);
        @memset(data, 0);
        return .{
            .data = data,
            .symbol_size = symbol_size,
            .count = count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: SymbolBuffer) void {
        self.allocator.free(self.data);
    }

    pub fn get(self: SymbolBuffer, index: u32) []u8 {
        const off = @as(usize, index) * @as(usize, self.symbol_size);
        return self.data[off..][0..self.symbol_size];
    }

    pub fn getConst(self: SymbolBuffer, index: u32) []const u8 {
        const off = @as(usize, index) * @as(usize, self.symbol_size);
        return self.data[off..][0..self.symbol_size];
    }

    pub fn addAssign(self: SymbolBuffer, dst: u32, src: u32) void {
        octets.addAssign(self.get(dst), self.getConst(src));
    }

    pub fn mulAssign(self: SymbolBuffer, index: u32, scalar: Octet) void {
        octets.mulAssignScalar(self.get(index), scalar);
    }

    pub fn fma(self: SymbolBuffer, dst: u32, src: u32, scalar: Octet) void {
        octets.fmaSlice(self.get(dst), self.getConst(src), scalar);
    }

    pub fn copyFrom(self: SymbolBuffer, index: u32, src: []const u8) void {
        @memcpy(self.get(index)[0..src.len], src);
    }
};
