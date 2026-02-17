// Edge case and boundary condition conformance tests
// Verifies correct behavior at parameter extremes defined by RFC 6330.

const std = @import("std");
const raptorq = @import("raptorq");
const Encoder = raptorq.Encoder;
const Decoder = raptorq.Decoder;
const base = raptorq.base;
const sc = raptorq.systematic_constants;

test "Minimum K (K=1)" {
    const allocator = std.testing.allocator;

    // Single source symbol: data fits in one symbol
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    var enc = try Encoder.init(allocator, &data, 4, 1, 4);
    defer enc.deinit();

    try std.testing.expectEqual(@as(u32, 1), enc.sourceBlockK(0));

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    // K=1 but K'=10, so we need K' symbols total (1 source + 9 repair)
    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }
    esi = k;
    while (esi < k + (k_prime - k)) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &data, decoded);
}

test "Maximum K (K=56403)" {
    // Full encode/decode at K=56403 is impractical (constraint matrix > 57000x57000).
    // Verify the table parameters and partitioning logic are correct at this scale.
    const kp = sc.ceilKPrime(56403);
    try std.testing.expectEqual(@as(u32, 56403), kp);

    const si = sc.findSystematicIndex(kp).?;
    try std.testing.expectEqual(@as(u32, 56403), si.k_prime);
    try std.testing.expectEqual(@as(u32, 56951), si.w);

    const l = sc.numIntermediateSymbols(kp);
    try std.testing.expectEqual(kp + si.s + si.h, l);

    // Verify OTI parameters for data that would produce K=56403 with T=4
    const data_len: u64 = 56403 * 4;
    const oti = base.ObjectTransmissionInformation{
        .transfer_length = data_len,
        .symbol_size = 4,
        .num_source_blocks = 1,
        .num_sub_blocks = 1,
        .alignment = 4,
    };

    // Roundtrip serialization
    const bytes = oti.serialize();
    const restored = base.ObjectTransmissionInformation.deserialize(bytes);
    try std.testing.expectEqual(data_len, restored.transfer_length);
}

test "Symbol size 1" {
    const allocator = std.testing.allocator;

    // Minimum practical symbol size with alignment 1
    // 10 bytes with T=1 gives K=10, which is exactly K'=10
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A };

    var enc = try Encoder.init(allocator, &data, 1, 1, 1);
    defer enc.deinit();

    try std.testing.expectEqual(@as(u32, 10), enc.sourceBlockK(0));

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    // K=10 = K'=10, so source symbols alone suffice
    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }
    // Add repair if K < K'
    esi = k;
    while (esi < k + (k_prime - k)) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &data, decoded);
}

test "Maximum transfer length" {
    // RFC 6330 allows transfer lengths up to 946270874880 bytes (40-bit field).
    // Verify OTI serialization handles this correctly.
    const max_tl: u64 = 946270874880;
    const oti = base.ObjectTransmissionInformation{
        .transfer_length = max_tl,
        .symbol_size = 1024,
        .num_source_blocks = 255,
        .num_sub_blocks = 1,
        .alignment = 4,
    };

    const bytes = oti.serialize();
    const restored = base.ObjectTransmissionInformation.deserialize(bytes);
    try std.testing.expectEqual(max_tl, restored.transfer_length);

    // Verify 40-bit encoding: max value fits in 5 bytes
    try std.testing.expect(max_tl <= 0xFFFFFFFFFF);
}

test "Alignment variations" {
    const allocator = std.testing.allocator;
    const data = "Alignment variation test data here!!";

    // Various alignment values: symbol_size must be divisible by alignment
    const cases = [_]struct { sym_size: u16, alignment: u8 }{
        .{ .sym_size = 4, .alignment = 1 },
        .{ .sym_size = 4, .alignment = 2 },
        .{ .sym_size = 4, .alignment = 4 },
        .{ .sym_size = 8, .alignment = 8 },
        .{ .sym_size = 16, .alignment = 4 },
        .{ .sym_size = 16, .alignment = 8 },
    };

    for (cases) |c| {
        var enc = try Encoder.init(allocator, data, c.sym_size, 1, c.alignment);
        defer enc.deinit();

        var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
        defer dec.deinit();

        const k = enc.sourceBlockK(0);
        const k_prime = enc.sub_encoders[0].k_prime;
        var esi: u32 = 0;
        while (esi < k) : (esi += 1) {
            const pkt = try enc.encode(0, esi);
            defer allocator.free(pkt.data);
            try dec.addPacket(pkt);
        }
        esi = k;
        while (esi < k + (k_prime - k)) : (esi += 1) {
            const pkt = try enc.encode(0, esi);
            defer allocator.free(pkt.data);
            try dec.addPacket(pkt);
        }

        const decoded = (try dec.decode()).?;
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, data, decoded);
    }
}

test "Single source block" {
    const allocator = std.testing.allocator;

    // Small data always produces Z=1
    const data = "Single block test data for RaptorQ!";
    const sym_size: u16 = 8;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    try std.testing.expectEqual(@as(u8, 1), enc.objectTransmissionInformation().num_source_blocks);

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }
    esi = k;
    while (esi < k + (k_prime - k)) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "Many source blocks" {
    // Full multi-block encode/decode requires Kt > 56403 symbols, which is
    // impractical for test execution. Verify the partitioning arithmetic
    // for large block counts.
    const helpers = raptorq.helpers;

    // Kt = 56403*2 = 112806 => Z = ceil(112806 / 56403) = 2
    const kt: u32 = 112806;
    const z = @max(@as(u32, 1), helpers.intDivCeil(kt, 56403));
    try std.testing.expectEqual(@as(u32, 2), z);

    const part = base.partition(kt, z);
    try std.testing.expectEqual(kt, part.count_large * part.size_large + part.count_small * part.size_small);
    try std.testing.expectEqual(z, part.count_large + part.count_small);

    // Z = 3 when Kt > 2*56403 = 112806
    const kt3: u32 = 112807;
    const z3 = @max(@as(u32, 1), helpers.intDivCeil(kt3, 56403));
    try std.testing.expectEqual(@as(u32, 3), z3);

    // Z = 4 when Kt > 3*56403 = 169209
    const kt4: u32 = 169210;
    const z4 = @max(@as(u32, 1), helpers.intDivCeil(kt4, 56403));
    try std.testing.expectEqual(@as(u32, 4), z4);
}

test "Sub-block partitioning" {
    const allocator = std.testing.allocator;

    // N=2 sub-blocks: encode and decode with sub-block interleaving
    const data = "Sub-block partitioning conformance test!";
    const sym_size: u16 = 16;

    var enc = try Encoder.init(allocator, data, sym_size, 2, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const kp = enc.sub_encoders[0].k_prime;
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }
    esi = k;
    while (esi < k + (kp - k)) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);

    // N=4 sub-blocks
    var enc4 = try Encoder.init(allocator, data, sym_size, 4, 4);
    defer enc4.deinit();

    var dec4 = try Decoder.init(allocator, enc4.objectTransmissionInformation());
    defer dec4.deinit();

    const k4 = enc4.sourceBlockK(0);
    const kp4 = enc4.sub_encoders[0].k_prime;
    esi = 0;
    while (esi < k4) : (esi += 1) {
        const pkt = try enc4.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec4.addPacket(pkt);
    }
    esi = k4;
    while (esi < k4 + (kp4 - k4)) : (esi += 1) {
        const pkt = try enc4.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec4.addPacket(pkt);
    }

    const decoded4 = (try dec4.decode()).?;
    defer allocator.free(decoded4);
    try std.testing.expectEqualSlices(u8, data, decoded4);
}
