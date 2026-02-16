// RaptorQ encoder (RFC 6330 Section 5.3)

const std = @import("std");
const base = @import("base.zig");
const Symbol = @import("symbol.zig").Symbol;
const systematic_constants = @import("../tables/systematic_constants.zig");
const constraint_matrix = @import("../matrix/constraint_matrix.zig");
const pi_solver = @import("../solver/pi_solver.zig");

pub const SourceBlockEncoder = struct {
    source_block_number: u8,
    source_symbols: []const Symbol,
    intermediate_symbols: []Symbol,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        source_block_number: u8,
        symbol_size: u16,
        data: []const u8,
    ) !SourceBlockEncoder {
        _ = .{ allocator, source_block_number, symbol_size, data };
        @panic("TODO");
    }

    pub fn deinit(self: *SourceBlockEncoder) void {
        _ = self;
        @panic("TODO");
    }

    /// Generate an encoding symbol by ESI (encoding symbol identifier).
    pub fn encodeSymbol(self: *SourceBlockEncoder, esi: u32) !Symbol {
        _ = .{ self, esi };
        @panic("TODO");
    }

    /// Generate an encoding packet.
    pub fn encodePacket(self: *SourceBlockEncoder, esi: u32) !base.EncodingPacket {
        _ = .{ self, esi };
        @panic("TODO");
    }
};

pub const Encoder = struct {
    config: base.ObjectTransmissionInformation,
    blocks: []SourceBlockEncoder,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        data: []const u8,
        symbol_size: u16,
    ) !Encoder {
        _ = .{ allocator, data, symbol_size };
        @panic("TODO");
    }

    pub fn deinit(self: *Encoder) void {
        _ = self;
        @panic("TODO");
    }

    pub fn encode(self: *Encoder, sbn: u8, esi: u32) !base.EncodingPacket {
        _ = .{ self, sbn, esi };
        @panic("TODO");
    }

    pub fn objectTransmissionInformation(self: Encoder) base.ObjectTransmissionInformation {
        return self.config;
    }
};
