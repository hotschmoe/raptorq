// RaptorQ encode/decode example
//
// Demonstrates:
//   1. Encoding 1KB of data into source + repair symbols
//   2. Decoding from all source symbols (no loss)
//   3. Decoding with 25% symbol loss, compensated by repair symbols

const std = @import("std");
const raptorq = @import("raptorq");
const Encoder = raptorq.Encoder;
const Decoder = raptorq.Decoder;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Generate 1KB of deterministic data
    const data_len = 1024;
    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);
    for (data, 0..) |*d, i| d.* = @intCast((i * 31 + 17) % 256);

    const symbol_size: u16 = 64;

    // Encode
    var enc = try Encoder.init(allocator, data, symbol_size, 1, 4);
    defer enc.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;

    try stdout.print("Data: {d} bytes, T={d}, K={d}, K'={d}\n", .{ data_len, symbol_size, k, k_prime });

    // -- Scenario 1: all source symbols, no loss --
    {
        var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
        defer dec.deinit();

        // Send all K source symbols
        var esi: u32 = 0;
        while (esi < k) : (esi += 1) {
            const pkt = try enc.encode(0, esi);
            defer allocator.free(pkt.data);
            try dec.addPacket(pkt);
        }
        // Send K'-K padding repair symbols to reach threshold
        while (esi < k_prime) : (esi += 1) {
            const pkt = try enc.encode(0, esi);
            defer allocator.free(pkt.data);
            try dec.addPacket(pkt);
        }

        const decoded = (try dec.decode()).?;
        defer allocator.free(decoded);

        if (std.mem.eql(u8, data, decoded)) {
            try stdout.print("Scenario 1 (no loss): SUCCESS\n", .{});
        } else {
            try stdout.print("Scenario 1 (no loss): FAILED\n", .{});
            return error.DecodeMismatch;
        }
    }

    // -- Scenario 2: 25% symbol loss, compensated with repair symbols --
    {
        var dec = try Decoder.init(allocator, enc.objectTransmissionInformation());
        defer dec.deinit();

        const drop_count = k / 4;

        // Send source symbols, skipping the first 25%
        var esi: u32 = drop_count;
        while (esi < k) : (esi += 1) {
            const pkt = try enc.encode(0, esi);
            defer allocator.free(pkt.data);
            try dec.addPacket(pkt);
        }

        // Add repair symbols to reach K' total received
        const received_source = k - drop_count;
        const repair_needed = k_prime - received_source;
        esi = k;
        var sent: u32 = 0;
        while (sent < repair_needed) : (sent += 1) {
            const pkt = try enc.encode(0, esi + sent);
            defer allocator.free(pkt.data);
            try dec.addPacket(pkt);
        }

        const decoded = (try dec.decode()).?;
        defer allocator.free(decoded);

        if (std.mem.eql(u8, data, decoded)) {
            try stdout.print("Scenario 2 (25% loss, {d} dropped, {d} repair): SUCCESS\n", .{ drop_count, repair_needed });
        } else {
            try stdout.print("Scenario 2 (25% loss): FAILED\n", .{});
            return error.DecodeMismatch;
        }
    }
}
