// RaptorQ decoder (RFC 6330 Section 5.4)

const std = @import("std");
const base = @import("base.zig");
const SymbolBuffer = @import("symbol.zig").SymbolBuffer;
const systematic_constants = @import("../tables/systematic_constants.zig");
const constraint_matrix = @import("../matrix/constraint_matrix.zig");
const DenseBinaryMatrix = @import("../matrix/dense_binary_matrix.zig").DenseBinaryMatrix;
const SparseBinaryMatrix = @import("../matrix/sparse_matrix.zig").SparseBinaryMatrix;
const pi_solver = @import("../solver/pi_solver.zig");
const encoder = @import("encoder.zig");
const helpers = @import("../util/helpers.zig");

pub const SourceBlockDecoder = struct {
    source_block_number: u8,
    num_source_symbols: u32,
    symbol_size: u16,
    received_symbols: std.AutoHashMap(u32, []u8),
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
            .received_symbols = std.AutoHashMap(u32, []u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SourceBlockDecoder) void {
        var it = self.received_symbols.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.received_symbols.deinit();
    }

    /// Add a received encoding symbol. Duplicates (same ESI) are ignored.
    pub fn addEncodingSymbol(self: *SourceBlockDecoder, packet: base.EncodingPacket) !void {
        const esi = packet.payload_id.encoding_symbol_id;
        if (self.received_symbols.contains(esi)) return;
        const data = try self.allocator.alloc(u8, packet.data.len);
        errdefer self.allocator.free(data);
        @memcpy(data, packet.data);
        try self.received_symbols.put(esi, data);
    }

    /// Returns true when enough symbols have been received to attempt decoding.
    pub fn fullySpecified(self: SourceBlockDecoder) bool {
        return self.received_symbols.count() >= self.num_source_symbols;
    }

    /// Decode the source block, returning K source symbols as a flat byte buffer.
    /// Caller owns the returned slice (K * symbol_size bytes, truncate to actual data).
    pub fn decode(self: *SourceBlockDecoder) ![]u8 {
        const k = self.num_source_symbols;
        const k_prime = systematic_constants.ceilKPrime(k);
        const si = systematic_constants.findSystematicIndex(k_prime).?;
        const s: usize = @intCast(si.s);
        const h: usize = @intCast(si.h);
        const l: u32 = k_prime + si.s + si.h;
        const sym_size: u32 = self.symbol_size;

        const isis = try self.allocator.alloc(u32, k_prime);
        defer self.allocator.free(isis);

        var d = try SymbolBuffer.init(self.allocator, l, sym_size);
        defer d.deinit();

        // Collect received symbols
        var count: usize = 0;
        var it = self.received_symbols.iterator();
        while (it.next()) |entry| {
            if (count >= k_prime) break;
            const esi = entry.key_ptr.*;
            isis[count] = if (esi < k) esi else k_prime + (esi - k);
            d.copyFrom(@intCast(s + h + count), entry.value_ptr.*);
            count += 1;
        }

        // Add padding symbols (ISI = K..K'-1, zero data)
        var pad: u32 = k;
        while (pad < k_prime and count < k_prime) : (pad += 1) {
            isis[count] = pad;
            // Already zeroed by SymbolBuffer.init
            count += 1;
        }

        if (k_prime >= pi_solver.sparse_matrix_threshold) {
            var cm = try constraint_matrix.buildDecodingMatrices(SparseBinaryMatrix, self.allocator, k_prime, isis[0..count]);
            defer cm.deinit();
            try pi_solver.solve(SparseBinaryMatrix, self.allocator, &cm, &d, k_prime);
        } else {
            var cm = try constraint_matrix.buildDecodingMatrices(DenseBinaryMatrix, self.allocator, k_prime, isis[0..count]);
            defer cm.deinit();
            try pi_solver.solve(DenseBinaryMatrix, self.allocator, &cm, &d, k_prime);
        }

        // Reconstruct source symbols 0..K-1 from intermediate symbols
        const result = try self.allocator.alloc(u8, @as(usize, k) * @as(usize, sym_size));
        errdefer self.allocator.free(result);

        for (0..k) |i| {
            const sym_data = try encoder.ltEncode(self.allocator, k_prime, &d, @intCast(i));
            defer self.allocator.free(sym_data);
            @memcpy(result[i * sym_size ..][0..sym_size], sym_data);
        }

        return result;
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
            config.symbol_size,
            config.num_sub_blocks,
            config.alignment,
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

    pub fn addPacket(self: *Decoder, packet: base.EncodingPacket) !void {
        const sbn = packet.payload_id.source_block_number;
        const n: usize = self.config.num_sub_blocks;

        if (!self.blocks.contains(sbn)) {
            const kt = helpers.intDivCeil(
                @intCast(self.config.transfer_length),
                self.config.symbol_size,
            );
            const part = base.partition(kt, self.config.num_source_blocks);
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
            const sym_size: usize = decoders[0].symbol_size;

            if (n == 1) {
                const source_data = try decoders[0].decode();
                defer self.allocator.free(source_data);
                const k: usize = decoders[0].num_source_symbols;
                for (0..k) |i| {
                    const sym_start = i * sym_size;
                    const copy_len = @min(sym_size, transfer_length - offset);
                    if (copy_len > 0) {
                        @memcpy(result[offset .. offset + copy_len], source_data[sym_start..][0..copy_len]);
                        offset += copy_len;
                    }
                }
            } else {
                const k: usize = decoders[0].num_source_symbols;

                const sub_results = try self.allocator.alloc([]u8, n);
                defer self.allocator.free(sub_results);
                var decoded_count: usize = 0;
                defer {
                    for (sub_results[0..decoded_count]) |data| {
                        self.allocator.free(data);
                    }
                }

                for (0..n) |j| {
                    sub_results[j] = try decoders[j].decode();
                    decoded_count += 1;
                }

                for (0..k) |sym_idx| {
                    for (0..n) |j| {
                        const sub_sym_size: usize = self.sub_block_partition.subSymbolSize(@intCast(j));
                        const sub_start = sym_idx * sub_sym_size;
                        const copy_len = @min(sub_sym_size, transfer_length - offset);
                        if (copy_len > 0) {
                            @memcpy(result[offset .. offset + copy_len], sub_results[j][sub_start..][0..copy_len]);
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

    var enc = try encoder.Encoder.init(allocator, data, symbol_size, 1, 4);
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

test "encode-decode roundtrip with repair symbols" {
    const allocator = std.testing.allocator;
    const data = "Repair symbol roundtrip test data!!";
    const symbol_size: u16 = 4;

    var enc = try encoder.Encoder.init(allocator, data, symbol_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.config);
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;
    var esi: u32 = 2;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

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

    var esi: u32 = 2;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

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
