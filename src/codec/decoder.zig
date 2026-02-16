// RaptorQ decoder (RFC 6330 Section 5.4)

const std = @import("std");
const base = @import("base.zig");
const Symbol = @import("symbol.zig").Symbol;
const systematic_constants = @import("../tables/systematic_constants.zig");
const constraint_matrix = @import("../matrix/constraint_matrix.zig");
const pi_solver = @import("../solver/pi_solver.zig");
const encoder = @import("encoder.zig");
const helpers = @import("../util/helpers.zig");

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
        return .{
            .source_block_number = source_block_number,
            .num_source_symbols = num_source_symbols,
            .symbol_size = symbol_size,
            .received_symbols = std.AutoHashMap(u32, Symbol).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SourceBlockDecoder) void {
        var it = self.received_symbols.valueIterator();
        while (it.next()) |sym| sym.deinit();
        self.received_symbols.deinit();
    }

    /// Add a received encoding symbol. Duplicates (same ESI) are ignored.
    pub fn addEncodingSymbol(self: *SourceBlockDecoder, packet: base.EncodingPacket) !void {
        const esi = packet.payload_id.encoding_symbol_id;
        if (self.received_symbols.contains(esi)) return;
        const sym = try Symbol.fromSlice(self.allocator, packet.data);
        errdefer sym.deinit();
        try self.received_symbols.put(esi, sym);
    }

    /// Returns true when enough symbols have been received to attempt decoding.
    pub fn fullySpecified(self: SourceBlockDecoder) bool {
        return self.received_symbols.count() >= systematic_constants.ceilKPrime(self.num_source_symbols);
    }

    /// Decode the source block, returning K source symbols.
    /// Caller owns the returned slice and each Symbol within it.
    pub fn decode(self: *SourceBlockDecoder) ![]Symbol {
        const k = self.num_source_symbols;
        const k_prime = systematic_constants.ceilKPrime(k);
        const si = systematic_constants.findSystematicIndex(k_prime).?;
        const s: usize = @intCast(si.s);
        const h: usize = @intCast(si.h);
        const l: usize = @intCast(k_prime + si.s + si.h);
        const sym_size: usize = self.symbol_size;

        const isis = try self.allocator.alloc(u32, k_prime);
        defer self.allocator.free(isis);

        // D vector: S+H zero constraint rows, K' received symbols
        const d = try self.allocator.alloc(Symbol, l);
        var d_init: usize = 0;
        errdefer {
            for (d[0..d_init]) |sym| sym.deinit();
            self.allocator.free(d);
        }

        for (0..s + h) |i| {
            d[i] = try Symbol.init(self.allocator, sym_size);
            d_init += 1;
        }

        var it = self.received_symbols.iterator();
        var count: usize = 0;
        while (it.next()) |entry| {
            if (count >= k_prime) break;
            const esi = entry.key_ptr.*;
            // ESI-to-ISI mapping (RFC 5.3.1)
            isis[count] = if (esi < k) esi else k_prime + (esi - k);
            d[s + h + count] = try entry.value_ptr.clone();
            d_init += 1;
            count += 1;
        }

        var a = try constraint_matrix.buildDecodingMatrix(self.allocator, k_prime, isis[0..count]);
        defer a.deinit();

        const result = try pi_solver.solve(self.allocator, &a, d, k);
        self.allocator.free(result.ops.ops);

        // Reconstruct source symbols 0..K-1 from intermediate symbols
        const source = try self.allocator.alloc(Symbol, k);
        var src_init: usize = 0;
        errdefer {
            for (source[0..src_init]) |sym| sym.deinit();
            self.allocator.free(source);
        }

        for (0..k) |i| {
            source[i] = try encoder.ltEncode(self.allocator, k_prime, d, @intCast(i));
            src_init += 1;
        }

        for (d) |sym| sym.deinit();
        self.allocator.free(d);

        return source;
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
        return .{
            .config = config,
            .blocks = std.AutoHashMap(u8, SourceBlockDecoder).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Decoder) void {
        var it = self.blocks.valueIterator();
        while (it.next()) |block| block.deinit();
        self.blocks.deinit();
    }

    /// Add a received encoding packet. Routes to the appropriate SourceBlockDecoder
    /// by SBN, lazily creating decoders as needed.
    pub fn addPacket(self: *Decoder, packet: base.EncodingPacket) !void {
        const sbn = packet.payload_id.source_block_number;
        if (!self.blocks.contains(sbn)) {
            const kt = helpers.intDivCeil(
                @intCast(self.config.transfer_length),
                @as(u32, self.config.symbol_size),
            );
            const z: u32 = self.config.num_source_blocks;
            const part = base.partition(kt, z);
            const num_symbols: u32 = if (sbn < part.count_large) part.size_large else part.size_small;
            try self.blocks.put(sbn, SourceBlockDecoder.init(
                self.allocator,
                sbn,
                num_symbols,
                self.config.symbol_size,
            ));
        }
        const block = self.blocks.getPtr(sbn).?;
        try block.addEncodingSymbol(packet);
    }

    /// Attempt to decode the full transfer object.
    /// Returns null if not all blocks have received enough symbols.
    /// Returns the decoded data (truncated to transfer_length) on success.
    /// Caller owns the returned slice.
    pub fn decode(self: *Decoder) !?[]u8 {
        const z: u32 = self.config.num_source_blocks;
        if (self.blocks.count() < z) return null;
        {
            var it = self.blocks.valueIterator();
            while (it.next()) |block| {
                if (!block.fullySpecified()) return null;
            }
        }

        const transfer_length: usize = @intCast(self.config.transfer_length);
        const result = try self.allocator.alloc(u8, transfer_length);
        errdefer self.allocator.free(result);

        var offset: usize = 0;
        var sbn: u8 = 0;
        while (sbn < z) : (sbn += 1) {
            const block = self.blocks.getPtr(sbn).?;
            const source_symbols = try block.decode();
            defer {
                for (source_symbols) |sym| sym.deinit();
                self.allocator.free(source_symbols);
            }
            for (source_symbols) |sym| {
                const copy_len = @min(sym.data.len, transfer_length - offset);
                if (copy_len > 0) {
                    @memcpy(result[offset .. offset + copy_len], sym.data[0..copy_len]);
                    offset += copy_len;
                }
            }
        }

        return result;
    }
};

test "encode-decode roundtrip with source symbols only" {
    const allocator = std.testing.allocator;
    const data = "Hello, RaptorQ! This is a roundtrip test.";
    const symbol_size: u16 = 8;

    // Encode
    var enc = try encoder.Encoder.init(allocator, data, symbol_size);
    defer enc.deinit();

    // Decode using only source symbols
    var dec = Decoder.init(allocator, enc.config);
    defer dec.deinit();

    const k = enc.blocks[0].k;
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "encode-decode roundtrip with repair symbols" {
    const allocator = std.testing.allocator;
    const data = "Repair symbol roundtrip test data!!";
    const symbol_size: u16 = 4;

    var enc = try encoder.Encoder.init(allocator, data, symbol_size);
    defer enc.deinit();

    var dec = Decoder.init(allocator, enc.config);
    defer dec.deinit();

    // Send all source symbols except the first two, plus repair symbols to compensate
    const k = enc.blocks[0].k;
    const k_prime = enc.blocks[0].k_prime;
    var esi: u32 = 2;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    // Add repair symbols to reach K' total
    const needed = k_prime - (k - 2);
    esi = k;
    var sent: u32 = 0;
    while (sent < needed) : (sent += 1) {
        const pkt = try enc.encode(0, esi + sent);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "decoder returns null when insufficient symbols" {
    const allocator = std.testing.allocator;

    const config = base.ObjectTransmissionInformation{
        .transfer_length = 40,
        .symbol_size = 8,
        .num_source_blocks = 1,
        .num_sub_blocks = 1,
        .alignment = 4,
    };

    var dec = Decoder.init(allocator, config);
    defer dec.deinit();

    const result = try dec.decode();
    try std.testing.expect(result == null);
}
