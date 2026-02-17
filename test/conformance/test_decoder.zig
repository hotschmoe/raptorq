// RFC 6330 Section 5.4 - Decoder conformance tests
// Verifies source recovery, repair substitution, error handling,
// and robustness to symbol ordering and duplication.

const std = @import("std");
const raptorq = @import("raptorq");
const Encoder = raptorq.Encoder;
const Decoder = raptorq.Decoder;

test "Decoder all-source recovery" {
    const allocator = std.testing.allocator;
    const data = "All-source recovery test data for decoder!";
    const sym_size: u16 = 8;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    // Feed all K source symbols plus enough repair to reach K'
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

test "Decoder repair substitution" {
    const allocator = std.testing.allocator;
    const data = "Repair substitution test data!!";
    const sym_size: u16 = 4;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    // Drop first 3 source symbols
    const drop_count: u32 = 3;
    var esi: u32 = drop_count;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    // Add enough repair symbols to reach K' total
    const repair_needed = k_prime - (k - drop_count);
    esi = k;
    var sent: u32 = 0;
    while (sent < repair_needed) : (sent += 1) {
        const pkt = try enc.encode(0, esi + sent);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "Decoder insufficient symbols" {
    const allocator = std.testing.allocator;
    const data = "Insufficient symbols test!";
    const sym_size: u16 = 4;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    // Feed only 1 symbol when K > 1
    const pkt = try enc.encode(0, 0);
    defer allocator.free(pkt.data);
    try dec.addPacket(pkt);

    // decode() should return null
    const result = try dec.decode();
    try std.testing.expect(result == null);
}

test "Decoder out-of-order symbols" {
    const allocator = std.testing.allocator;
    const data = "Out-of-order symbol test data!!";
    const sym_size: u16 = 4;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    // Feed symbols in reverse order, mixing source and repair.
    // We drop 2 source symbols so add enough repair to compensate.
    const drop_count: u32 = 2;
    const repair_count: u32 = k_prime - k + drop_count;
    var esi: u32 = k + repair_count;
    while (esi > k) {
        esi -= 1;
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    // Then add source symbols in reverse, skipping first 2
    esi = k;
    while (esi > drop_count) {
        esi -= 1;
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "Decoder duplicate symbols" {
    const allocator = std.testing.allocator;
    const data = "Duplicate symbol handling test!";
    const sym_size: u16 = 4;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    // Feed each source symbol twice - duplicates should be silently ignored
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt1 = try enc.encode(0, esi);
        defer allocator.free(pkt1.data);
        try dec.addPacket(pkt1);

        const pkt2 = try enc.encode(0, esi);
        defer allocator.free(pkt2.data);
        try dec.addPacket(pkt2);
    }

    // Add repair symbols to reach K' (duplicates don't count)
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

test "Decoder with overhead" {
    const allocator = std.testing.allocator;
    const data = "Overhead symbol test data for decoder!";
    const sym_size: u16 = 4;

    var enc = try Encoder.init(allocator, data, sym_size, 1, 4);
    defer enc.deinit();

    var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
    defer dec.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    // Feed all source symbols plus extra repair (overhead)
    var esi: u32 = 0;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    // Add 5 extra repair symbols beyond what's needed
    const overhead: u32 = k_prime - k + 5;
    esi = k;
    var sent: u32 = 0;
    while (sent < overhead) : (sent += 1) {
        const pkt = try enc.encode(0, esi + sent);
        defer allocator.free(pkt.data);
        try dec.addPacket(pkt);
    }

    const decoded = (try dec.decode()).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}
