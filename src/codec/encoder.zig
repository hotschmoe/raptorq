// RaptorQ encoder (RFC 6330 Section 5.3)

const std = @import("std");
const base = @import("base.zig");
const SymbolBuffer = @import("symbol.zig").SymbolBuffer;
const systematic_constants = @import("../tables/systematic_constants.zig");
const constraint_matrix = @import("../matrix/constraint_matrix.zig");
const DenseBinaryMatrix = @import("../matrix/dense_binary_matrix.zig").DenseBinaryMatrix;
const pi_solver = @import("../solver/pi_solver.zig");
const rng = @import("../math/rng.zig");
const octets = @import("../math/octets.zig");
const helpers = @import("../util/helpers.zig");

/// Generate one encoding symbol from intermediate symbols using LT/PI encoding.
/// Returns caller-owned slice. Implements RFC 6330 Section 5.3.5.3.
pub fn ltEncode(allocator: std.mem.Allocator, k_prime: u32, buf: *const SymbolBuffer, isi: u32) ![]u8 {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const w = si.w;
    const l = k_prime + si.s + si.h;
    const p = l - w;
    const p1 = helpers.nextPrime(p);

    const tuple = rng.genTuple(k_prime, isi);

    const result = try allocator.alloc(u8, buf.symbol_size);
    errdefer allocator.free(result);
    @memcpy(result, buf.getConst(tuple.b));

    // LT component
    var b_val = tuple.b;
    var j: u32 = 1;
    while (j < tuple.d) : (j += 1) {
        b_val = (b_val + tuple.a) % w;
        octets.addAssign(result, buf.getConst(b_val));
    }

    // PI component
    var b1 = tuple.b1;
    while (b1 >= p) {
        b1 = (b1 + tuple.a1) % p1;
    }
    octets.addAssign(result, buf.getConst(w + b1));
    j = 1;
    while (j < tuple.d1) : (j += 1) {
        b1 = (b1 + tuple.a1) % p1;
        while (b1 >= p) {
            b1 = (b1 + tuple.a1) % p1;
        }
        octets.addAssign(result, buf.getConst(w + b1));
    }

    return result;
}

pub const SourceBlockEncoder = struct {
    source_block_number: u8,
    k: u32,
    k_prime: u32,
    symbol_size: u16,
    source_buf: SymbolBuffer,
    intermediate_buf: SymbolBuffer,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        source_block_number: u8,
        symbol_size: u16,
        data: []const u8,
        plan: ?*const pi_solver.SolverPlan,
    ) !SourceBlockEncoder {
        const t: u32 = symbol_size;
        const k: u32 = helpers.intDivCeil(@intCast(data.len), t);
        const k_prime = systematic_constants.ceilKPrime(k);
        const si = systematic_constants.findSystematicIndex(k_prime).?;
        const s: usize = @intCast(si.s);
        const h: usize = @intCast(si.h);
        const l: u32 = k_prime + si.s + si.h;
        const sym_size: usize = symbol_size;

        var source_buf = try SymbolBuffer.init(allocator, k, symbol_size);
        errdefer source_buf.deinit();

        for (0..k) |i| {
            const start = i * sym_size;
            const end = @min(start + sym_size, data.len);
            if (end > start) {
                @memcpy(source_buf.get(@intCast(i))[0 .. end - start], data[start..end]);
            }
        }

        // D vector: S+H zero constraint rows, K source, K'-K zero padding
        var d = try SymbolBuffer.init(allocator, l, symbol_size);
        errdefer d.deinit();

        for (0..k) |i| {
            @memcpy(d.get(@intCast(s + h + i)), source_buf.getConst(@intCast(i)));
        }

        if (plan) |p| {
            std.debug.assert(p.l == l);
            try p.apply(&d);
        } else {
            var cm = try constraint_matrix.buildConstraintMatrices(DenseBinaryMatrix, allocator, k_prime);
            defer cm.deinit();
            try pi_solver.solve(DenseBinaryMatrix, allocator, &cm, &d, k_prime);
        }

        return .{
            .source_block_number = source_block_number,
            .k = k,
            .k_prime = k_prime,
            .symbol_size = symbol_size,
            .source_buf = source_buf,
            .intermediate_buf = d,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SourceBlockEncoder) void {
        self.source_buf.deinit();
        self.intermediate_buf.deinit();
    }

    /// Generate an encoding symbol by ESI. Returns caller-owned byte slice.
    /// For ESI < K, returns a copy of the original source symbol.
    /// For ESI >= K, generates a repair symbol via LT encoding.
    pub fn encodeSymbol(self: *SourceBlockEncoder, esi: u32) ![]u8 {
        if (esi < self.k) {
            const result = try self.allocator.alloc(u8, self.symbol_size);
            @memcpy(result, self.source_buf.getConst(esi));
            return result;
        }
        const isi = self.k_prime + (esi - self.k);
        return ltEncode(self.allocator, self.k_prime, &self.intermediate_buf, isi);
    }

    /// Generate an encoding packet (PayloadId + symbol data).
    /// Caller owns the returned data slice.
    pub fn encodePacket(self: *SourceBlockEncoder, esi: u32) !base.EncodingPacket {
        const data = try self.encodeSymbol(esi);
        return .{
            .payload_id = .{
                .source_block_number = self.source_block_number,
                .encoding_symbol_id = esi,
            },
            .data = data,
        };
    }
};

pub const Encoder = struct {
    config: base.ObjectTransmissionInformation,
    sub_encoders: []SourceBlockEncoder,
    sub_block_partition: base.SubBlockPartition,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        data: []const u8,
        symbol_size: u16,
        num_sub_blocks: u16,
        alignment: u8,
    ) !Encoder {
        const t: u32 = symbol_size;
        const n: usize = num_sub_blocks;
        const sbp = try base.SubBlockPartition.init(t, num_sub_blocks, alignment);

        const kt = helpers.intDivCeil(@intCast(data.len), t);
        const z: u32 = @max(1, helpers.intDivCeil(kt, 56403));
        const part = base.partition(kt, z);

        // Pre-generate solver plans for unique K' values (at most 2 from partition)
        const k_prime_large = systematic_constants.ceilKPrime(part.size_large);
        const k_prime_small = systematic_constants.ceilKPrime(part.size_small);

        var plans: [2]pi_solver.SolverPlan = undefined;
        var plan_count: u8 = 0;
        defer for (plans[0..plan_count]) |*p| p.deinit();

        plans[0] = try pi_solver.generatePlan(DenseBinaryMatrix, allocator, k_prime_large);
        plan_count = 1;

        if (k_prime_small != k_prime_large) {
            plans[1] = try pi_solver.generatePlan(DenseBinaryMatrix, allocator, k_prime_small);
            plan_count = 2;
        }

        const sub_encs = try allocator.alloc(SourceBlockEncoder, z * n);
        var init_count: usize = 0;
        errdefer {
            for (sub_encs[0..init_count]) |*enc| enc.deinit();
            allocator.free(sub_encs);
        }

        var data_offset: usize = 0;
        for (0..z) |sbn_idx| {
            const num_symbols: u32 = if (sbn_idx < part.count_large) part.size_large else part.size_small;
            const block_len: usize = @as(usize, num_symbols) * @as(usize, t);
            const end = @min(data_offset + block_len, data.len);
            const block_data = data[data_offset..end];

            const plan_ptr: *const pi_solver.SolverPlan = if (sbn_idx < part.count_large)
                &plans[0]
            else if (plan_count == 2)
                &plans[1]
            else
                &plans[0];

            if (n == 1) {
                sub_encs[sbn_idx] = try SourceBlockEncoder.init(
                    allocator,
                    @intCast(sbn_idx),
                    symbol_size,
                    block_data,
                    plan_ptr,
                );
                init_count += 1;
            } else {
                for (0..n) |j| {
                    const sub_sym_size: usize = sbp.subSymbolSize(@intCast(j));
                    const sub_offset: usize = sbp.subSymbolOffset(@intCast(j));

                    const buf = try allocator.alloc(u8, num_symbols * sub_sym_size);
                    defer allocator.free(buf);
                    @memset(buf, 0);

                    for (0..num_symbols) |sym_idx| {
                        const src_start = sym_idx * @as(usize, t) + sub_offset;
                        const dst_start = sym_idx * sub_sym_size;
                        if (src_start < block_data.len) {
                            const src_end = @min(src_start + sub_sym_size, block_data.len);
                            @memcpy(buf[dst_start .. dst_start + (src_end - src_start)], block_data[src_start..src_end]);
                        }
                    }

                    sub_encs[sbn_idx * n + j] = try SourceBlockEncoder.init(
                        allocator,
                        @intCast(sbn_idx),
                        @intCast(sub_sym_size),
                        buf,
                        plan_ptr,
                    );
                    init_count += 1;
                }
            }

            data_offset = end;
        }

        return .{
            .config = .{
                .transfer_length = @intCast(data.len),
                .symbol_size = symbol_size,
                .num_source_blocks = @intCast(z),
                .num_sub_blocks = num_sub_blocks,
                .alignment = alignment,
            },
            .sub_encoders = sub_encs,
            .sub_block_partition = sbp,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Encoder) void {
        for (self.sub_encoders) |*enc| enc.deinit();
        self.allocator.free(self.sub_encoders);
    }

    pub fn encode(self: *Encoder, sbn: u8, esi: u32) !base.EncodingPacket {
        const n: usize = self.config.num_sub_blocks;
        if (n == 1) {
            return self.sub_encoders[sbn].encodePacket(esi);
        }

        const t: usize = self.config.symbol_size;
        const result = try self.allocator.alloc(u8, t);
        errdefer self.allocator.free(result);

        for (0..n) |j| {
            const sym_data = try self.sub_encoders[@as(usize, sbn) * n + j].encodeSymbol(esi);
            defer self.allocator.free(sym_data);
            const offset: usize = self.sub_block_partition.subSymbolOffset(@intCast(j));
            const size: usize = self.sub_block_partition.subSymbolSize(@intCast(j));
            @memcpy(result[offset .. offset + size], sym_data[0..size]);
        }

        return .{
            .payload_id = .{
                .source_block_number = sbn,
                .encoding_symbol_id = esi,
            },
            .data = result,
        };
    }

    pub fn sourceBlockK(self: Encoder, sbn: u8) u32 {
        const n: usize = self.config.num_sub_blocks;
        return self.sub_encoders[@as(usize, sbn) * n].k;
    }

    pub fn objectTransmissionInformation(self: Encoder) base.ObjectTransmissionInformation {
        return self.config;
    }
};

test "SourceBlockEncoder systematic property" {
    const allocator = std.testing.allocator;
    const data = "Hello, RaptorQ!";
    const symbol_size: u16 = 4;

    var enc = try SourceBlockEncoder.init(allocator, 0, symbol_size, data, null);
    defer enc.deinit();

    var reconstructed: [15]u8 = undefined;
    var offset: usize = 0;
    var esi: u32 = 0;
    while (esi < enc.k) : (esi += 1) {
        const sym_data = try enc.encodeSymbol(esi);
        defer allocator.free(sym_data);
        const copy_len = @min(sym_data.len, data.len - offset);
        @memcpy(reconstructed[offset .. offset + copy_len], sym_data[0..copy_len]);
        offset += copy_len;
    }
    try std.testing.expectEqualSlices(u8, data, &reconstructed);
}

test "SourceBlockEncoder generates repair symbols" {
    const allocator = std.testing.allocator;
    const data = "Test data for repair symbol generation!!";
    const symbol_size: u16 = 8;

    var enc = try SourceBlockEncoder.init(allocator, 0, symbol_size, data, null);
    defer enc.deinit();

    var esi: u32 = enc.k;
    while (esi < enc.k + 5) : (esi += 1) {
        const sym_data = try enc.encodeSymbol(esi);
        defer allocator.free(sym_data);
        try std.testing.expectEqual(@as(usize, symbol_size), sym_data.len);
    }
}

test "Encoder init and encode" {
    const allocator = std.testing.allocator;
    const data = "RaptorQ FEC encoding test data for the Encoder struct";
    const symbol_size: u16 = 8;

    var enc = try Encoder.init(allocator, data, symbol_size, 1, 4);
    defer enc.deinit();

    try std.testing.expectEqual(@as(u8, 1), enc.config.num_source_blocks);
    try std.testing.expectEqual(@as(u16, 8), enc.config.symbol_size);

    const pkt = try enc.encode(0, 0);
    defer allocator.free(pkt.data);
    try std.testing.expectEqual(@as(u8, 0), pkt.payload_id.source_block_number);
    try std.testing.expectEqual(@as(u32, 0), pkt.payload_id.encoding_symbol_id);
}
