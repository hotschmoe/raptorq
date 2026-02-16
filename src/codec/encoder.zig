// RaptorQ encoder (RFC 6330 Section 5.3)

const std = @import("std");
const base = @import("base.zig");
const Symbol = @import("symbol.zig").Symbol;
const systematic_constants = @import("../tables/systematic_constants.zig");
const constraint_matrix = @import("../matrix/constraint_matrix.zig");
const pi_solver = @import("../solver/pi_solver.zig");
const rng = @import("../math/rng.zig");
const helpers = @import("../util/helpers.zig");

/// Generate one encoding symbol from intermediate symbols using LT/PI encoding.
/// Implements RFC 6330 Section 5.3.5.3.
pub fn ltEncode(allocator: std.mem.Allocator, k_prime: u32, intermediate_symbols: []const Symbol, isi: u32) !Symbol {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const w = si.w;
    const l = k_prime + si.s + si.h;
    const p = l - w;
    const p1 = helpers.nextPrime(p);

    const tuple = rng.genTuple(k_prime, isi);

    var result = try Symbol.fromSlice(allocator, intermediate_symbols[tuple.b].data);
    errdefer result.deinit();

    // LT component
    var b_val = tuple.b;
    var j: u32 = 1;
    while (j < tuple.d) : (j += 1) {
        b_val = (b_val + tuple.a) % w;
        result.addAssign(intermediate_symbols[b_val]);
    }

    // PI component
    var b1 = tuple.b1;
    while (b1 >= p) {
        b1 = (b1 + tuple.a1) % p1;
    }
    result.addAssign(intermediate_symbols[w + b1]);
    j = 1;
    while (j < tuple.d1) : (j += 1) {
        b1 = (b1 + tuple.a1) % p1;
        while (b1 >= p) {
            b1 = (b1 + tuple.a1) % p1;
        }
        result.addAssign(intermediate_symbols[w + b1]);
    }

    return result;
}

pub const SourceBlockEncoder = struct {
    source_block_number: u8,
    k: u32,
    k_prime: u32,
    symbol_size: u16,
    source_symbols: []const Symbol,
    intermediate_symbols: []Symbol,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        source_block_number: u8,
        symbol_size: u16,
        data: []const u8,
    ) !SourceBlockEncoder {
        const t: u32 = symbol_size;
        const k: u32 = helpers.intDivCeil(@intCast(data.len), t);
        const k_prime = systematic_constants.ceilKPrime(k);
        const si = systematic_constants.findSystematicIndex(k_prime).?;
        const s: usize = @intCast(si.s);
        const h: usize = @intCast(si.h);
        const l: usize = @intCast(k_prime + si.s + si.h);
        const sym_size: usize = symbol_size;

        const source_symbols = try allocator.alloc(Symbol, k);
        var src_init: usize = 0;
        errdefer {
            for (source_symbols[0..src_init]) |sym| sym.deinit();
            allocator.free(source_symbols);
        }

        for (0..k) |i| {
            const start = i * sym_size;
            const end = @min(start + sym_size, data.len);
            source_symbols[i] = try Symbol.init(allocator, sym_size);
            src_init += 1;
            if (end > start) {
                @memcpy(source_symbols[i].data[0 .. end - start], data[start..end]);
            }
        }

        // D vector: S+H zero constraint rows, K source, K'-K zero padding
        const d = try allocator.alloc(Symbol, l);
        var d_init: usize = 0;
        errdefer {
            for (d[0..d_init]) |sym| sym.deinit();
            allocator.free(d);
        }

        for (0..s + h) |i| {
            d[i] = try Symbol.init(allocator, sym_size);
            d_init += 1;
        }

        for (0..k) |i| {
            d[s + h + i] = try source_symbols[i].clone();
            d_init += 1;
        }

        for (k..@intCast(k_prime)) |i| {
            d[s + h + i] = try Symbol.init(allocator, sym_size);
            d_init += 1;
        }

        var a = try constraint_matrix.buildConstraintMatrix(allocator, k_prime);
        defer a.deinit();

        const result = try pi_solver.solve(allocator, &a, d, k);
        allocator.free(result.ops.ops);

        return .{
            .source_block_number = source_block_number,
            .k = k,
            .k_prime = k_prime,
            .symbol_size = symbol_size,
            .source_symbols = source_symbols,
            .intermediate_symbols = d,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SourceBlockEncoder) void {
        for (self.source_symbols) |sym| sym.deinit();
        self.allocator.free(self.source_symbols);
        for (self.intermediate_symbols) |sym| sym.deinit();
        self.allocator.free(self.intermediate_symbols);
    }

    /// Generate an encoding symbol by ESI (encoding symbol identifier).
    /// For ESI < K, returns a clone of the original source symbol.
    /// For ESI >= K, generates a repair symbol via LT encoding.
    pub fn encodeSymbol(self: *SourceBlockEncoder, esi: u32) !Symbol {
        if (esi < self.k) {
            return self.source_symbols[esi].clone();
        }
        // Repair symbol: ISI = K' + (ESI - K), skipping padding ISIs
        const isi = self.k_prime + (esi - self.k);
        return ltEncode(self.allocator, self.k_prime, self.intermediate_symbols, isi);
    }

    /// Generate an encoding packet (PayloadId + symbol data).
    /// Caller owns the returned data slice.
    pub fn encodePacket(self: *SourceBlockEncoder, esi: u32) !base.EncodingPacket {
        const sym = try self.encodeSymbol(esi);
        return .{
            .payload_id = .{
                .source_block_number = self.source_block_number,
                .encoding_symbol_id = esi,
            },
            .data = sym.data,
        };
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
        const t: u32 = symbol_size;
        const kt = helpers.intDivCeil(@intCast(data.len), t);
        const z: u32 = @max(1, helpers.intDivCeil(kt, 56403));
        const part = base.partition(kt, z);

        const blocks = try allocator.alloc(SourceBlockEncoder, z);
        var init_count: usize = 0;
        errdefer {
            for (blocks[0..init_count]) |*b| b.deinit();
            allocator.free(blocks);
        }

        var data_offset: usize = 0;
        for (0..z) |sbn_idx| {
            const num_symbols: u32 = if (sbn_idx < part.count_large) part.size_large else part.size_small;
            const block_data_size: usize = @as(usize, num_symbols) * @as(usize, symbol_size);
            const end = @min(data_offset + block_data_size, data.len);
            blocks[sbn_idx] = try SourceBlockEncoder.init(
                allocator,
                @intCast(sbn_idx),
                symbol_size,
                data[data_offset..end],
            );
            init_count += 1;
            data_offset = end;
        }

        return .{
            .config = .{
                .transfer_length = @intCast(data.len),
                .symbol_size = symbol_size,
                .num_source_blocks = @intCast(z),
                .num_sub_blocks = 1,
                .alignment = 4,
            },
            .blocks = blocks,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Encoder) void {
        for (self.blocks) |*b| b.deinit();
        self.allocator.free(self.blocks);
    }

    pub fn encode(self: *Encoder, sbn: u8, esi: u32) !base.EncodingPacket {
        return self.blocks[sbn].encodePacket(esi);
    }

    pub fn objectTransmissionInformation(self: Encoder) base.ObjectTransmissionInformation {
        return self.config;
    }
};

test "SourceBlockEncoder systematic property" {
    const allocator = std.testing.allocator;
    const data = "Hello, RaptorQ!";
    const symbol_size: u16 = 4;

    var enc = try SourceBlockEncoder.init(allocator, 0, symbol_size, data);
    defer enc.deinit();

    // Encoding symbols 0..K-1 should return original source data
    var reconstructed: [15]u8 = undefined;
    var offset: usize = 0;
    var esi: u32 = 0;
    while (esi < enc.k) : (esi += 1) {
        var sym = try enc.encodeSymbol(esi);
        defer sym.deinit();
        const copy_len = @min(sym.data.len, data.len - offset);
        @memcpy(reconstructed[offset .. offset + copy_len], sym.data[0..copy_len]);
        offset += copy_len;
    }
    try std.testing.expectEqualSlices(u8, data, &reconstructed);
}

test "SourceBlockEncoder generates repair symbols" {
    const allocator = std.testing.allocator;
    const data = "Test data for repair symbol generation!!";
    const symbol_size: u16 = 8;

    var enc = try SourceBlockEncoder.init(allocator, 0, symbol_size, data);
    defer enc.deinit();

    // Generate repair symbols (ESI >= K) without error
    var esi: u32 = enc.k;
    while (esi < enc.k + 5) : (esi += 1) {
        var sym = try enc.encodeSymbol(esi);
        defer sym.deinit();
        try std.testing.expectEqual(@as(usize, symbol_size), sym.data.len);
    }
}

test "Encoder init and encode" {
    const allocator = std.testing.allocator;
    const data = "RaptorQ FEC encoding test data for the Encoder struct";
    const symbol_size: u16 = 8;

    var enc = try Encoder.init(allocator, data, symbol_size);
    defer enc.deinit();

    try std.testing.expectEqual(@as(u8, 1), enc.config.num_source_blocks);
    try std.testing.expectEqual(@as(u16, 8), enc.config.symbol_size);

    // Encode a source packet
    const pkt = try enc.encode(0, 0);
    defer allocator.free(pkt.data);
    try std.testing.expectEqual(@as(u8, 0), pkt.payload_id.source_block_number);
    try std.testing.expectEqual(@as(u32, 0), pkt.payload_id.encoding_symbol_id);
}
