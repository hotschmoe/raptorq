const std = @import("std");
const raptorq = @import("raptorq");

const Decoder = raptorq.Decoder;
const PayloadId = raptorq.PayloadId;
const OTI = raptorq.ObjectTransmissionInformation;

fn verifyVector(comptime raw: []const u8) !void {
    const allocator = std.testing.allocator;

    if (!std.mem.eql(u8, raw[0..4], "RQ01"))
        return error.InvalidMagic;

    const oti = OTI.deserialize(raw[4..16].*);

    const data_len: usize = @as(usize, std.mem.readInt(u32, raw[16..20], .big));
    const source_data = raw[20..][0..data_len];

    var offset: usize = 20 + data_len;
    const num_packets: usize = @as(usize, std.mem.readInt(u32, raw[offset..][0..4], .big));
    offset += 4;

    const T: usize = @intCast(oti.symbol_size);

    var decoder = try Decoder.init(allocator, oti);
    defer decoder.deinit();

    for (0..num_packets) |_| {
        const pid = PayloadId.deserialize(raw[offset..][0..4].*);
        offset += 4;
        const sym_data = raw[offset..][0..T];
        offset += T;

        try decoder.addPacket(.{
            .payload_id = pid,
            .data = sym_data,
        });
    }

    const decoded = try decoder.decode() orelse return error.DecodeFailed;
    defer allocator.free(decoded);

    try std.testing.expectEqual(source_data.len, decoded.len);
    try std.testing.expectEqualSlices(u8, source_data, decoded);
}

test "v01: small source only (64B, T=16, systematic decode)" {
    try verifyVector(@embedFile("fixtures/v01_small_source_only.bin"));
}

test "v02: medium with repair (1024B, T=32, source + repair)" {
    try verifyVector(@embedFile("fixtures/v02_medium_with_repair.bin"));
}

test "v03: large symbol (4096B, T=256)" {
    try verifyVector(@embedFile("fixtures/v03_large_symbol.bin"));
}

test "v04: 10% loss (512B, T=32, light loss recovery)" {
    try verifyVector(@embedFile("fixtures/v04_loss_10pct.bin"));
}

test "v05: 50% loss (512B, T=32, heavy loss recovery)" {
    try verifyVector(@embedFile("fixtures/v05_loss_50pct.bin"));
}

test "v06: non-aligned data (100B, T=32, uneven padding)" {
    try verifyVector(@embedFile("fixtures/v06_padding_uneven.bin"));
}

test "v07: minimum K (16B, T=16, K=1 boundary)" {
    try verifyVector(@embedFile("fixtures/v07_minimum_k.bin"));
}

test "v08: repair only (128B, T=32, no source symbols)" {
    try verifyVector(@embedFile("fixtures/v08_repair_only.bin"));
}
