// RFC 6330 Section 3 - Base types and partitioning conformance tests
// Verifies PayloadId/OTI wire format serialization and the partition function
// that divides source data into blocks and sub-blocks.

const std = @import("std");
const raptorq = @import("raptorq");
const base = raptorq.base;

test "PayloadId serialization roundtrip" {
    const cases = [_]base.PayloadId{
        .{ .source_block_number = 0, .encoding_symbol_id = 0 },
        .{ .source_block_number = 1, .encoding_symbol_id = 1 },
        .{ .source_block_number = 255, .encoding_symbol_id = 0xFFFFFF },
        .{ .source_block_number = 42, .encoding_symbol_id = 12345 },
        .{ .source_block_number = 0, .encoding_symbol_id = 256 },
    };

    for (cases) |pid| {
        const bytes = pid.serialize();
        const restored = base.PayloadId.deserialize(bytes);
        try std.testing.expectEqual(pid.source_block_number, restored.source_block_number);
        try std.testing.expectEqual(pid.encoding_symbol_id, restored.encoding_symbol_id);
    }
}

test "PayloadId wire format" {
    // RFC: 4-byte big-endian: SBN (8 bits) | ESI (24 bits)
    const pid = base.PayloadId{ .source_block_number = 0xAB, .encoding_symbol_id = 0x123456 };
    const bytes = pid.serialize();

    // Byte 0: SBN
    try std.testing.expectEqual(@as(u8, 0xAB), bytes[0]);
    // Bytes 1-3: ESI in big-endian
    try std.testing.expectEqual(@as(u8, 0x12), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x34), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x56), bytes[3]);
}

test "ObjectTransmissionInformation serialization roundtrip" {
    const cases = [_]base.ObjectTransmissionInformation{
        .{ .transfer_length = 100, .symbol_size = 8, .num_source_blocks = 1, .num_sub_blocks = 1, .alignment = 4 },
        .{ .transfer_length = 0, .symbol_size = 1, .num_source_blocks = 1, .num_sub_blocks = 1, .alignment = 1 },
        .{ .transfer_length = 0xFFFFFFFFFF, .symbol_size = 0xFFFF, .num_source_blocks = 255, .num_sub_blocks = 0xFFFF, .alignment = 255 },
        .{ .transfer_length = 946270874880, .symbol_size = 1024, .num_source_blocks = 128, .num_sub_blocks = 4, .alignment = 8 },
    };

    for (cases) |oti| {
        const bytes = oti.serialize();
        const restored = base.ObjectTransmissionInformation.deserialize(bytes);
        try std.testing.expectEqual(oti.transfer_length, restored.transfer_length);
        try std.testing.expectEqual(oti.symbol_size, restored.symbol_size);
        try std.testing.expectEqual(oti.num_source_blocks, restored.num_source_blocks);
        try std.testing.expectEqual(oti.num_sub_blocks, restored.num_sub_blocks);
        try std.testing.expectEqual(oti.alignment, restored.alignment);
    }
}

test "ObjectTransmissionInformation wire format" {
    // RFC: 12-byte layout
    // Bytes 0-4: transfer_length (40-bit big-endian)
    // Byte 5: reserved (0)
    // Bytes 6-7: symbol_size (16-bit big-endian)
    // Byte 8: num_source_blocks
    // Bytes 9-10: num_sub_blocks (16-bit big-endian)
    // Byte 11: alignment
    const oti = base.ObjectTransmissionInformation{
        .transfer_length = 0x0102030405,
        .symbol_size = 0x0607,
        .num_source_blocks = 0x08,
        .num_sub_blocks = 0x090A,
        .alignment = 0x0B,
    };
    const bytes = oti.serialize();

    try std.testing.expectEqual(@as(u8, 0x01), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x02), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x03), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x04), bytes[3]);
    try std.testing.expectEqual(@as(u8, 0x05), bytes[4]);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[5]); // reserved
    try std.testing.expectEqual(@as(u8, 0x06), bytes[6]);
    try std.testing.expectEqual(@as(u8, 0x07), bytes[7]);
    try std.testing.expectEqual(@as(u8, 0x08), bytes[8]);
    try std.testing.expectEqual(@as(u8, 0x09), bytes[9]);
    try std.testing.expectEqual(@as(u8, 0x0A), bytes[10]);
    try std.testing.expectEqual(@as(u8, 0x0B), bytes[11]);
}

test "Partition function basic" {
    // partition(12, 5): dividing 12 items into 5 groups
    // floor(12/5)=2, ceil(12/5)=3
    // 12 = 2*3 + 3*2 => JL=2 large of size 3, JS=3 small of size 2
    const p = base.partition(12, 5);
    try std.testing.expectEqual(@as(u32, 2), p.count_large);
    try std.testing.expectEqual(@as(u32, 3), p.size_large);
    try std.testing.expectEqual(@as(u32, 3), p.count_small);
    try std.testing.expectEqual(@as(u32, 2), p.size_small);

    // partition(10, 3): 10 = 1*4 + 2*3 => JL=1 large(4), JS=2 small(3)
    const p2 = base.partition(10, 3);
    try std.testing.expectEqual(@as(u32, 1), p2.count_large);
    try std.testing.expectEqual(@as(u32, 4), p2.size_large);
    try std.testing.expectEqual(@as(u32, 2), p2.count_small);
    try std.testing.expectEqual(@as(u32, 3), p2.size_small);
}

test "Partition function edge cases" {
    // partition(1, 1): single item, single group
    const p1 = base.partition(1, 1);
    try std.testing.expectEqual(@as(u32, 0), p1.count_large);
    try std.testing.expectEqual(@as(u32, 1), p1.count_small);
    try std.testing.expectEqual(@as(u32, 1), p1.size_small);

    // partition(n, n): each group has exactly 1 item
    const p2 = base.partition(5, 5);
    try std.testing.expectEqual(@as(u32, 0), p2.count_large);
    try std.testing.expectEqual(@as(u32, 5), p2.count_small);
    try std.testing.expectEqual(@as(u32, 1), p2.size_small);

    // partition(7, 1): one group with all items
    const p3 = base.partition(7, 1);
    try std.testing.expectEqual(@as(u32, 0), p3.count_large);
    try std.testing.expectEqual(@as(u32, 1), p3.count_small);
    try std.testing.expectEqual(@as(u32, 7), p3.size_small);
}

test "Partition function covers all items" {
    // JL * IL + JS * IS == I for a range of (I, J) pairs
    const cases = [_][2]u32{
        .{ 1, 1 },   .{ 2, 1 },   .{ 10, 3 },  .{ 12, 5 },
        .{ 100, 7 }, .{ 100, 100 }, .{ 1000, 13 }, .{ 56403, 1 },
        .{ 56403, 2 }, .{ 1024, 64 },
    };

    for (cases) |c| {
        const p = base.partition(c[0], c[1]);
        const total = p.count_large * p.size_large + p.count_small * p.size_small;
        try std.testing.expectEqual(c[0], total);
        try std.testing.expectEqual(c[1], p.count_large + p.count_small);
        // Large >= small
        try std.testing.expect(p.size_large >= p.size_small);
        // Sizes differ by at most 1
        try std.testing.expect(p.size_large - p.size_small <= 1);
    }
}
