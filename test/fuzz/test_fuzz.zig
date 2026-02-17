// Fuzz tests for the raptorq encoder/decoder pipeline.

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
    const allocator = std.testing.allocator;

    var enc = try Encoder.init(
        allocator,
        params.data,
        params.symbol_size,
        params.num_sub_blocks,
        params.alignment,
    );
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k_prime = enc.sub_encoders[0].k_prime;

    // Send all K source symbols + K'-K repair symbols to cover padding
    var esi: u32 = 0;
    while (esi < k_prime) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()) orelse return error.DecodeFailed;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, params.data, decoded);
}

test "fuzz_roundtrip" {
    try std.testing.fuzz({}, fuzzRoundtrip, .{});
}

fn fuzzLossRecovery(_: void, input: []const u8) anyerror!void {
    if (input.len < 7) return;
    const params = parseParams(input) orelse return;
    const allocator = std.testing.allocator;

    var enc = try Encoder.init(allocator, params.data, params.symbol_size, 1, params.alignment);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    if (k < 2) return;

    const max_drop = @max(1, k / 2);
    const drop_count: u32 = (input[5] % max_drop) + 1;
    const extra_repair: u32 = if (input.len > 6) input[6] % 4 else 0;

    // Send source symbols, skipping the first drop_count
    var esi: u32 = drop_count;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    // Send repair symbols to compensate for dropped sources
    const received_source = k - drop_count;
    const repair_needed = (k_prime - received_source) + extra_repair;
    var sent: u32 = 0;
    while (sent < repair_needed) : (sent += 1) {
        const pkt = try enc.encode(0, k + sent);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()) orelse return error.DecodeFailed;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, params.data, decoded);
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
