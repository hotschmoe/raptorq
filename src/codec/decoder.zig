// RaptorQ decoder (RFC 6330 Section 5.4)

const std = @import("std");
const base = @import("base.zig");
const Symbol = @import("symbol.zig").Symbol;
const systematic_constants = @import("../tables/systematic_constants.zig");
const constraint_matrix = @import("../matrix/constraint_matrix.zig");
const pi_solver = @import("../solver/pi_solver.zig");

pub const SourceBlockDecoder = struct {
    source_block_number: u8,
    num_source_symbols: u32,
    symbol_size: u16,
    received_symbols: std.AutoHashMap(u32, Symbol),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        source_block_number: u8,
        num_source_symbols: u32,
        symbol_size: u16,
    ) SourceBlockDecoder {
        _ = .{ allocator, source_block_number, num_source_symbols, symbol_size };
        @panic("TODO");
    }

    pub fn deinit(self: *SourceBlockDecoder) void {
        _ = self;
        @panic("TODO");
    }

    pub fn addEncodingSymbol(self: *SourceBlockDecoder, packet: base.EncodingPacket) !void {
        _ = .{ self, packet };
        @panic("TODO");
    }

    pub fn fullySpecified(self: SourceBlockDecoder) bool {
        _ = self;
        @panic("TODO");
    }

    pub fn decode(self: *SourceBlockDecoder) ![]Symbol {
        _ = self;
        @panic("TODO");
    }
};

pub const Decoder = struct {
    config: base.ObjectTransmissionInformation,
    blocks: std.AutoHashMap(u8, SourceBlockDecoder),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        config: base.ObjectTransmissionInformation,
    ) Decoder {
        _ = .{ allocator, config };
        @panic("TODO");
    }

    pub fn deinit(self: *Decoder) void {
        _ = self;
        @panic("TODO");
    }

    pub fn addPacket(self: *Decoder, packet: base.EncodingPacket) !void {
        _ = .{ self, packet };
        @panic("TODO");
    }

    pub fn decode(self: *Decoder) !?[]u8 {
        _ = self;
        @panic("TODO");
    }
};
