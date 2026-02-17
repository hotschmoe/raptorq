// RFC 6330 Section 5.3 - Encoder conformance tests
// Verifies the systematic property, determinism, and repair symbol generation
// of the RaptorQ encoder.

const std = @import("std");
const raptorq = @import("raptorq");
const Encoder = raptorq.Encoder;
const SourceBlockEncoder = raptorq.SourceBlockEncoder;

test "Encoder systematic property" {
    const allocator = std.testing.allocator;

    // Test with several data+symbol_size combinations
    const cases = [_]struct { data: []const u8, sym_size: u16 }{
        .{ .data = "Hello, RaptorQ!", .sym_size = 4 },
        .{ .data = "ABCDEFGHIJKLMNOP", .sym_size = 8 },
        .{ .data = "A", .sym_size = 4 },
    };

    for (cases) |c| {
        var enc = try Encoder.init(allocator, c.data, c.sym_size, 1, 4);
        defer enc.deinit();

        // First K source symbols should reconstruct original data
        const k = enc.sourceBlockK(0);
        var offset: usize = 0;
        var reconstructed = try allocator.alloc(u8, c.data.len);
        defer allocator.free(reconstructed);

        var esi: u32 = 0;
        while (esi < k) : (esi += 1) {
            const pkt = try enc.encode(0, esi);
            defer allocator.free(pkt.data);
            const copy_len = @min(pkt.data.len, c.data.len - offset);
            if (copy_len > 0) {
                @memcpy(reconstructed[offset .. offset + copy_len], pkt.data[0..copy_len]);
                offset += copy_len;
            }
        }
        try std.testing.expectEqualSlices(u8, c.data, reconstructed);
    }
}

test "Encoder determinism" {
    const allocator = std.testing.allocator;
    const data = "Determinism test data for RaptorQ encoder!";
    const sym_size: u16 = 8;

    // Two independent encoder instances with same parameters
    var enc1 = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc1.deinit();
    var enc2 = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc2.deinit();

    // Source and repair symbols must be identical
    const k = enc1.sourceBlockK(0);
    var esi: u32 = 0;
    while (esi < k + 5) : (esi += 1) {
        const pkt1 = try enc1.encode(0, esi);
        defer allocator.free(pkt1.data);
        const pkt2 = try enc2.encode(0, esi);
        defer allocator.free(pkt2.data);

        try std.testing.expectEqualSlices(u8, pkt1.data, pkt2.data);
        try std.testing.expectEqual(pkt1.payload_id.source_block_number, pkt2.payload_id.source_block_number);
        try std.testing.expectEqual(pkt1.payload_id.encoding_symbol_id, pkt2.payload_id.encoding_symbol_id);
    }
}

test "Encoder packet IDs" {
    const allocator = std.testing.allocator;
    const data = "Packet ID verification test data!";
    const sym_size: u16 = 4;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    // SBN should be 0 for single-block data
    const k = enc.sourceBlockK(0);

    // Source symbol ESIs: 0..K-1
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try std.testing.expectEqual(@as(u8, 0), pkt.payload_id.source_block_number);
        try std.testing.expectEqual(esi, pkt.payload_id.encoding_symbol_id);
    }

    // Repair symbol ESIs: K, K+1, ...
    esi = k;
    while (esi < k + 3) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try std.testing.expectEqual(@as(u8, 0), pkt.payload_id.source_block_number);
        try std.testing.expectEqual(esi, pkt.payload_id.encoding_symbol_id);
        try std.testing.expectEqual(@as(usize, sym_size), pkt.data.len);
    }
}

test "Encoder multi-block" {
    const allocator = std.testing.allocator;

    // Verify OTI reflects correct block count for small data
    const data = "Short data";
    const sym_size: u16 = 4;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    const oti = enc.objectTransmissionInformation();
    try std.testing.expectEqual(@as(u64, data.len), oti.transfer_length);
    try std.testing.expectEqual(@as(u16, 4), oti.symbol_size);
    try std.testing.expectEqual(@as(u8, 1), oti.num_source_blocks);
    try std.testing.expectEqual(@as(u16, 1), oti.num_sub_blocks);
    try std.testing.expectEqual(@as(u8, 4), oti.alignment);
}

test "Encoder symbol size alignment" {
    const allocator = std.testing.allocator;
    const data = "Alignment test data for encoder!!";

    // Different symbol sizes, all aligned to their respective Al
    const cases = [_]struct { sym_size: u16, alignment: u8 }{
        .{ .sym_size = 4, .alignment = 4 },
        .{ .sym_size = 8, .alignment = 4 },
        .{ .sym_size = 8, .alignment = 8 },
        .{ .sym_size = 16, .alignment = 4 },
        .{ .sym_size = 4, .alignment = 2 },
        .{ .sym_size = 4, .alignment = 1 },
    };

    for (cases) |c| {
        var enc = try Encoder.init(allocator, data, c.sym_size, 1, c.alignment);
        defer enc.deinit();

        const pkt = try enc.encode(0, 0);
        defer allocator.free(pkt.data);
        try std.testing.expectEqual(@as(usize, c.sym_size), pkt.data.len);
    }
}

test "SourceBlockEncoder repair generation" {
    const allocator = std.testing.allocator;
    const data = "Test data for repair symbol generation!!";
    const sym_size: u16 = 8;

    var enc = try SourceBlockEncoder.init(allocator, 0, sym_size, data);
    defer enc.deinit();

    // Generate 20 repair symbols without error
    var esi: u32 = enc.k;
    while (esi < enc.k + 20) : (esi += 1) {
        var sym = try enc.encodeSymbol(esi);
        defer sym.deinit();
        try std.testing.expectEqual(@as(usize, sym_size), sym.data.len);
    }

    // Repair symbols should not all be identical (statistical check)
    var first_repair = try enc.encodeSymbol(enc.k);
    defer first_repair.deinit();
    var found_different = false;
    esi = enc.k + 1;
    while (esi < enc.k + 10) : (esi += 1) {
        var other = try enc.encodeSymbol(esi);
        defer other.deinit();
        if (!std.mem.eql(u8, first_repair.data, other.data)) {
            found_different = true;
            break;
        }
    }
    try std.testing.expect(found_different);
}
