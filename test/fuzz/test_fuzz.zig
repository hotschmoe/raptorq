// Fuzz tests for the raptorq encoder/decoder pipeline.
//
// The sweep_* tests provide deterministic coverage on every `zig build test-fuzz`
// invocation. The fuzz_* tests wrap std.testing.fuzz for coverage-guided fuzzing
// (requires --fuzz flag and a Release build due to Zig 0.15.x Debug-mode bugs).

const std = @import("std");
const raptorq = @import("raptorq");
const Encoder = raptorq.Encoder;
const Decoder = raptorq.Decoder;
const PayloadId = raptorq.PayloadId;
const OTI = raptorq.ObjectTransmissionInformation;

const SYMBOL_SIZES = [_]u16{ 1, 2, 4, 8, 12, 16, 20, 24, 32, 48, 64 };

// Precomputed divisors for each symbol size (valid alignment values).
const DIVISORS = [_][]const u8{
    &.{1},                               // 1
    &.{ 1, 2 },                          // 2
    &.{ 1, 2, 4 },                       // 4
    &.{ 1, 2, 4, 8 },                    // 8
    &.{ 1, 2, 3, 4, 6, 12 },            // 12
    &.{ 1, 2, 4, 8, 16 },               // 16
    &.{ 1, 2, 4, 5, 10, 20 },           // 20
    &.{ 1, 2, 3, 4, 6, 8, 12, 24 },     // 24
    &.{ 1, 2, 4, 8, 16, 32 },           // 32
    &.{ 1, 2, 3, 4, 6, 8, 12, 16, 24, 48 }, // 48
    &.{ 1, 2, 4, 8, 16, 32, 64 },       // 64
};

// --- Sweep test infrastructure ---

const SWEEP_SEED: u64 = 0xDEAD_BEEF_CAFE_1337;

const SweepCase = struct {
    T: u16,
    Al: u8,
    data_len: usize,
};

const SWEEP_CASES = [_]SweepCase{
    // T=1: edge case, single-byte symbols
    .{ .T = 1, .Al = 1, .data_len = 1 },
    .{ .T = 1, .Al = 1, .data_len = 10 },
    .{ .T = 1, .Al = 1, .data_len = 50 },
    .{ .T = 1, .Al = 1, .data_len = 101 },
    // T=4: small symbols, various K values
    .{ .T = 4, .Al = 4, .data_len = 4 },
    .{ .T = 4, .Al = 2, .data_len = 40 },
    .{ .T = 4, .Al = 1, .data_len = 48 },
    .{ .T = 4, .Al = 4, .data_len = 100 },
    .{ .T = 4, .Al = 4, .data_len = 200 },
    // T=8: common small symbol size
    .{ .T = 8, .Al = 4, .data_len = 8 },
    .{ .T = 8, .Al = 8, .data_len = 88 },
    .{ .T = 8, .Al = 2, .data_len = 96 },
    .{ .T = 8, .Al = 4, .data_len = 400 },
    // T=12: non-power-of-two
    .{ .T = 12, .Al = 4, .data_len = 12 },
    .{ .T = 12, .Al = 3, .data_len = 132 },
    .{ .T = 12, .Al = 6, .data_len = 300 },
    // T=16: medium symbol
    .{ .T = 16, .Al = 4, .data_len = 16 },
    .{ .T = 16, .Al = 8, .data_len = 160 },
    .{ .T = 16, .Al = 16, .data_len = 400 },
    // T=24: larger non-power-of-two
    .{ .T = 24, .Al = 8, .data_len = 24 },
    .{ .T = 24, .Al = 4, .data_len = 264 },
    .{ .T = 24, .Al = 12, .data_len = 600 },
    // T=32: common medium
    .{ .T = 32, .Al = 4, .data_len = 32 },
    .{ .T = 32, .Al = 8, .data_len = 352 },
    .{ .T = 32, .Al = 16, .data_len = 800 },
    // T=48: larger symbol
    .{ .T = 48, .Al = 8, .data_len = 48 },
    .{ .T = 48, .Al = 16, .data_len = 528 },
    // T=64: largest symbol size tested
    .{ .T = 64, .Al = 8, .data_len = 64 },
    .{ .T = 64, .Al = 16, .data_len = 640 },
    .{ .T = 64, .Al = 32, .data_len = 1024 },
};

// --- Core helpers (shared by sweep and fuzz tests) ---

fn roundtripCore(allocator: std.mem.Allocator, data: []const u8, T: u16, N: u16, Al: u8) !void {
    var enc = try Encoder.init(allocator, data, T, N, Al);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k_prime = enc.sub_encoders[0].k_prime;

    var esi: u32 = 0;
    while (esi < k_prime) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()) orelse return error.DecodeFailed;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

fn lossRecoveryCore(allocator: std.mem.Allocator, data: []const u8, T: u16, Al: u8, drop: u32, extra: u32) !void {
    var enc = try Encoder.init(allocator, data, T, 1, Al);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    if (k < 2) return;

    const drop_count = @min(drop, k - 1);

    // Send source symbols, skipping the first drop_count
    var esi: u32 = drop_count;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    // Send repair symbols to compensate
    const received_source = k - drop_count;
    const repair_needed = (k_prime - received_source) + extra;
    var sent: u32 = 0;
    while (sent < repair_needed) : (sent += 1) {
        const pkt = try enc.encode(0, k + sent);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()) orelse return error.DecodeFailed;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

// --- Sweep tests ---

test "sweep_roundtrip" {
    const allocator = std.testing.allocator;
    var prng = std.Random.Xoshiro256.init(SWEEP_SEED);

    for (SWEEP_CASES) |case| {
        const buf = try allocator.alloc(u8, case.data_len);
        defer allocator.free(buf);
        prng.fill(buf);

        // N=1: single sub-block
        try roundtripCore(allocator, buf, case.T, 1, case.Al);

        // N=2 when T/Al >= 2 (valid sub-block partitioning)
        const t_al: u16 = case.T / @as(u16, case.Al);
        if (t_al >= 2) {
            try roundtripCore(allocator, buf, case.T, 2, case.Al);
        }
    }
}

test "sweep_loss_recovery" {
    const allocator = std.testing.allocator;
    var prng = std.Random.Xoshiro256.init(SWEEP_SEED +% 1);

    for (SWEEP_CASES) |case| {
        const buf = try allocator.alloc(u8, case.data_len);
        defer allocator.free(buf);
        prng.fill(buf);

        // Pattern 1: drop 1 source symbol, 0 extra repair
        try lossRecoveryCore(allocator, buf, case.T, case.Al, 1, 0);

        // Pattern 2: drop ~25% of source symbols, 1 extra repair
        const k_approx: u32 = @intCast((@max(case.data_len, 1) + case.T - 1) / case.T);
        const drop25 = @max(1, k_approx / 4);
        try lossRecoveryCore(allocator, buf, case.T, case.Al, drop25, 1);
    }
}

test "sweep_serialization" {
    var prng = std.Random.Xoshiro256.init(SWEEP_SEED +% 2);

    for (0..200) |_| {
        // PayloadId roundtrip
        var pid_bytes: [4]u8 = undefined;
        prng.fill(&pid_bytes);
        const pid = PayloadId.deserialize(pid_bytes);
        try std.testing.expectEqual(pid_bytes, pid.serialize());

        // OTI roundtrip
        var oti_bytes: [12]u8 = undefined;
        prng.fill(&oti_bytes);
        oti_bytes[5] = 0; // reserved byte
        const oti = OTI.deserialize(oti_bytes);
        try std.testing.expectEqual(oti_bytes, oti.serialize());
    }
}

test "sweep_malformed_input" {
    const allocator = std.testing.allocator;
    var prng = std.Random.Xoshiro256.init(SWEEP_SEED +% 3);

    for (0..50) |_| {
        // Pick a random valid symbol size and alignment for the OTI
        const sym_idx = prng.random().uintLessThan(usize, SYMBOL_SIZES.len);
        const symbol_size = SYMBOL_SIZES[sym_idx];
        const divisors = DIVISORS[sym_idx];
        const alignment = divisors[prng.random().uintLessThan(usize, divisors.len)];

        const transfer_len: u64 = @as(u64, prng.random().uintLessThan(u16, 512)) + 1;

        const config = OTI{
            .transfer_length = transfer_len,
            .symbol_size = symbol_size,
            .num_source_blocks = 1,
            .num_sub_blocks = 1,
            .alignment = alignment,
        };

        var dec = Decoder.init(allocator, config) catch continue;
        defer dec.deinit();

        // Feed random packets
        const num_packets = prng.random().uintLessThan(u8, 20) + 1;
        for (0..num_packets) |_| {
            const pkt_data = try allocator.alloc(u8, symbol_size);
            defer allocator.free(pkt_data);
            prng.fill(pkt_data);

            const esi = prng.random().uintLessThan(u32, 256);
            dec.addPacket(.{
                .payload_id = .{
                    .source_block_number = 0,
                    .encoding_symbol_id = esi,
                },
                .data = pkt_data,
            }) catch continue;
        }

        // Attempt decode -- must not panic
        if (dec.decode()) |maybe_result| {
            if (maybe_result) |result| allocator.free(result);
        } else |_| {}
    }
}

// --- Fuzz wrappers (coverage-guided, require --fuzz flag) ---

const FuzzParams = struct {
    symbol_size: u16,
    alignment: u8,
    num_sub_blocks: u16,
    data: []const u8,
};

fn parseParams(input: []const u8) ?FuzzParams {
    if (input.len < 5) return null;

    const sym_idx = input[0] % SYMBOL_SIZES.len;
    const symbol_size = SYMBOL_SIZES[sym_idx];
    const divisors = DIVISORS[sym_idx];
    const alignment = divisors[input[1] % divisors.len];

    const t_al: u16 = symbol_size / @as(u16, alignment);
    const num_sub_blocks: u16 = (input[2] % t_al) + 1;

    const raw_len = @as(u16, input[3]) | (@as(u16, input[4]) << 8);
    const data_len: usize = @as(usize, (raw_len % 512)) + 1;

    const payload = input[5..];
    if (payload.len == 0) return null;

    return .{
        .symbol_size = symbol_size,
        .alignment = alignment,
        .num_sub_blocks = num_sub_blocks,
        .data = payload[0..@min(payload.len, data_len)],
    };
}

fn fuzzRoundtrip(_: void, input: []const u8) anyerror!void {
    const params = parseParams(input) orelse return;
    try roundtripCore(std.testing.allocator, params.data, params.symbol_size, params.num_sub_blocks, params.alignment);
}

test "fuzz_roundtrip" {
    try std.testing.fuzz({}, fuzzRoundtrip, .{});
}

fn fuzzLossRecovery(_: void, input: []const u8) anyerror!void {
    if (input.len < 7) return;
    const params = parseParams(input) orelse return;

    const max_drop = @max(1, @as(u32, input[5]) % 128);
    const extra_repair: u32 = input[6] % 4;

    try lossRecoveryCore(std.testing.allocator, params.data, params.symbol_size, params.alignment, max_drop, extra_repair);
}

test "fuzz_loss_recovery" {
    try std.testing.fuzz({}, fuzzLossRecovery, .{});
}

fn fuzzSerialization(_: void, input: []const u8) anyerror!void {
    if (input.len >= 4) {
        const pid_bytes: [4]u8 = input[0..4].*;
        const pid = PayloadId.deserialize(pid_bytes);
        try std.testing.expectEqual(pid_bytes, pid.serialize());
    }

    if (input.len >= 12) {
        var oti_bytes: [12]u8 = input[0..12].*;
        oti_bytes[5] = 0; // reserved byte always serialized as 0
        const oti = OTI.deserialize(oti_bytes);
        try std.testing.expectEqual(oti_bytes, oti.serialize());
    }
}

test "fuzz_serialization" {
    try std.testing.fuzz({}, fuzzSerialization, .{});
}

fn fuzzMalformedInput(_: void, input: []const u8) anyerror!void {
    if (input.len < 6) return;
    const allocator = std.testing.allocator;

    const params = parseParams(input) orelse return;
    const symbol_size: usize = @intCast(params.symbol_size);

    const config = OTI{
        .transfer_length = @intCast(params.data.len),
        .symbol_size = params.symbol_size,
        .num_source_blocks = 1,
        .num_sub_blocks = 1,
        .alignment = params.alignment,
    };

    var dec = Decoder.init(allocator, config) catch return;
    defer dec.deinit();

    // Feed arbitrary data as packets -- the decoder must not panic
    const remaining = input[5..];
    var offset: usize = 0;
    while (offset + 2 < remaining.len) {
        const sbn = remaining[offset];
        const esi_byte = remaining[offset + 1];
        offset += 2;

        const pkt_len = @min(symbol_size, remaining.len - offset);
        if (pkt_len == 0) break;

        const pkt_data = remaining[offset .. offset + pkt_len];
        offset += pkt_len;

        if (sbn != 0) continue;

        // Pad short packets to full symbol size
        const data = if (pkt_data.len == symbol_size) pkt_data else blk: {
            const padded = allocator.alloc(u8, symbol_size) catch continue;
            @memset(padded, 0);
            @memcpy(padded[0..pkt_data.len], pkt_data);
            break :blk padded;
        };
        defer if (pkt_data.len != symbol_size) allocator.free(data);

        dec.addPacket(.{
            .payload_id = .{
                .source_block_number = 0,
                .encoding_symbol_id = @as(u32, esi_byte),
            },
            .data = data,
        }) catch continue;
    }

    // Attempt decode -- may fail, but must not panic
    if (dec.decode()) |maybe_result| {
        if (maybe_result) |result| allocator.free(result);
    } else |_| {}
}

test "fuzz_malformed_input" {
    try std.testing.fuzz({}, fuzzMalformedInput, .{});
}
