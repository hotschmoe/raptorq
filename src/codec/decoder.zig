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
    blocks: std.AutoHashMap(u8, []SourceBlockDecoder),
    sub_block_partition: base.SubBlockPartition,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        config: base.ObjectTransmissionInformation,
    ) !Decoder {
        const sbp = try base.SubBlockPartition.init(
            @as(u32, config.symbol_size),
            @as(u32, config.num_sub_blocks),
            @as(u32, config.alignment),
        );
        return .{
            .config = config,
            .blocks = std.AutoHashMap(u8, []SourceBlockDecoder).init(allocator),
            .sub_block_partition = sbp,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Decoder) void {
        var it = self.blocks.valueIterator();
        while (it.next()) |decoders| {
            for (decoders.*) |*dec| dec.deinit();
            self.allocator.free(decoders.*);
        }
        self.blocks.deinit();
    }

    /// Add a received encoding packet. Routes to the appropriate SourceBlockDecoders
    /// by SBN, lazily creating decoders as needed. For N > 1, splits the received
    /// symbol into sub-symbols and routes each to the corresponding sub-block decoder.
    pub fn addPacket(self: *Decoder, packet: base.EncodingPacket) !void {
        const sbn = packet.payload_id.source_block_number;
        const n: usize = self.config.num_sub_blocks;

        if (!self.blocks.contains(sbn)) {
            const kt = helpers.intDivCeil(
                @intCast(self.config.transfer_length),
                @as(u32, self.config.symbol_size),
            );
            const part = base.partition(kt, @as(u32, self.config.num_source_blocks));
            const num_symbols: u32 = if (sbn < part.count_large) part.size_large else part.size_small;

            const decoders = try self.allocator.alloc(SourceBlockDecoder, n);
            for (0..n) |j| {
                const sub_sym_size = self.sub_block_partition.subSymbolSize(@intCast(j));
                decoders[j] = SourceBlockDecoder.init(
                    self.allocator,
                    sbn,
                    num_symbols,
                    @intCast(sub_sym_size),
                );
            }
            self.blocks.put(sbn, decoders) catch |err| {
                self.allocator.free(decoders);
                return err;
            };
        }

        const decoders = self.blocks.get(sbn).?;
        if (n == 1) {
            try decoders[0].addEncodingSymbol(packet);
        } else {
            for (0..n) |j| {
                const sub_offset: usize = self.sub_block_partition.subSymbolOffset(@intCast(j));
                const sub_size: usize = self.sub_block_partition.subSymbolSize(@intCast(j));
                try decoders[j].addEncodingSymbol(.{
                    .payload_id = packet.payload_id,
                    .data = packet.data[sub_offset .. sub_offset + sub_size],
                });
            }
        }
    }

    /// Attempt to decode the full transfer object.
    /// Returns null if not all blocks have received enough symbols.
    /// Returns the decoded data (truncated to transfer_length) on success.
    /// Caller owns the returned slice.
    pub fn decode(self: *Decoder) !?[]u8 {
        const z: u32 = self.config.num_source_blocks;
        const n: usize = self.config.num_sub_blocks;

        if (self.blocks.count() < z) return null;
        {
            var it = self.blocks.valueIterator();
            while (it.next()) |decoders| {
                for (decoders.*) |dec| {
                    if (!dec.fullySpecified()) return null;
                }
            }
        }

        const transfer_length: usize = @intCast(self.config.transfer_length);
        const result = try self.allocator.alloc(u8, transfer_length);
        errdefer self.allocator.free(result);

        var offset: usize = 0;
        var sbn: u8 = 0;
        while (sbn < z) : (sbn += 1) {
            const decoders = self.blocks.get(sbn).?;

            if (n == 1) {
                const source_symbols = try decoders[0].decode();
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
            } else {
                const k: usize = decoders[0].num_source_symbols;

                const sub_results = try self.allocator.alloc([]Symbol, n);
                defer self.allocator.free(sub_results);
                var decoded_count: usize = 0;
                defer {
                    for (sub_results[0..decoded_count]) |symbols| {
                        for (symbols) |sym| sym.deinit();
                        self.allocator.free(symbols);
                    }
                }

                for (0..n) |j| {
                    sub_results[j] = try decoders[j].decode();
                    decoded_count += 1;
                }

                // Interleave: reassemble full symbols from sub-block results
                for (0..k) |sym_idx| {
                    for (0..n) |j| {
                        const sub_size: usize = self.sub_block_partition.subSymbolSize(@intCast(j));
                        const copy_len = @min(sub_size, transfer_length - offset);
                        if (copy_len > 0) {
                            @memcpy(result[offset .. offset + copy_len], sub_results[j][sym_idx].data[0..copy_len]);
                            offset += copy_len;
                        }
                    }
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
    var enc = try encoder.Encoder.init(allocator, data, symbol_size, 1, 4);
    defer enc.deinit();

    // Decode using only source symbols
    var dec = try Decoder.init(allocator, enc.config);
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
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

    var enc = try encoder.Encoder.init(allocator, data, symbol_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.config);
    defer dec.deinit();

    // Send all source symbols except the first two, plus repair symbols to compensate
    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;
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

    var dec = try Decoder.init(allocator, config);
    defer dec.deinit();

    const result = try dec.decode();
    try std.testing.expect(result == null);
}

test "sub-block roundtrip N=2 source symbols only" {
    const allocator = std.testing.allocator;
    const data = "Sub-block test data with N equals two!";
    const symbol_size: u16 = 16;

    var enc = try encoder.Encoder.init(allocator, data, symbol_size, 2, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.config);
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
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

test "sub-block roundtrip N=2 with repair symbols" {
    const allocator = std.testing.allocator;
    const data = "Sub-block repair symbol test!!";
    const symbol_size: u16 = 16;

    var enc = try encoder.Encoder.init(allocator, data, symbol_size, 2, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.config);
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    // Skip first 2 source symbols
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
