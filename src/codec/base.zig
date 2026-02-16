// RaptorQ base types (RFC 6330 Section 3)

const helpers = @import("../util/helpers.zig");

pub const PayloadId = struct {
    source_block_number: u8,
    encoding_symbol_id: u32,

    pub fn serialize(self: PayloadId) [4]u8 {
        // SBN (8 bits) | ESI (24 bits), big-endian
        const esi = self.encoding_symbol_id;
        return .{
            self.source_block_number,
            @intCast((esi >> 16) & 0xFF),
            @intCast((esi >> 8) & 0xFF),
            @intCast(esi & 0xFF),
        };
    }

    pub fn deserialize(bytes: [4]u8) PayloadId {
        return .{
            .source_block_number = bytes[0],
            .encoding_symbol_id = @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | @as(u32, bytes[3]),
        };
    }
};

pub const ObjectTransmissionInformation = struct {
    transfer_length: u64,
    symbol_size: u16,
    num_source_blocks: u8,
    num_sub_blocks: u16,
    alignment: u8,

    pub fn serialize(self: ObjectTransmissionInformation) [12]u8 {
        // Bytes 0-4: transfer_length (40-bit big-endian, top byte first)
        // Byte 5: reserved (0)
        // Bytes 6-7: symbol_size (16-bit big-endian)
        // Byte 8: num_source_blocks
        // Bytes 9-10: num_sub_blocks (16-bit big-endian)
        // Byte 11: alignment
        const tl = self.transfer_length;
        const ss = self.symbol_size;
        const nsb = self.num_sub_blocks;
        return .{
            @intCast((tl >> 32) & 0xFF),
            @intCast((tl >> 24) & 0xFF),
            @intCast((tl >> 16) & 0xFF),
            @intCast((tl >> 8) & 0xFF),
            @intCast(tl & 0xFF),
            0, // reserved
            @intCast((ss >> 8) & 0xFF),
            @intCast(ss & 0xFF),
            self.num_source_blocks,
            @intCast((nsb >> 8) & 0xFF),
            @intCast(nsb & 0xFF),
            self.alignment,
        };
    }

    pub fn deserialize(bytes: [12]u8) ObjectTransmissionInformation {
        return .{
            .transfer_length = @as(u64, bytes[0]) << 32 |
                @as(u64, bytes[1]) << 24 |
                @as(u64, bytes[2]) << 16 |
                @as(u64, bytes[3]) << 8 |
                @as(u64, bytes[4]),
            .symbol_size = @as(u16, bytes[6]) << 8 | @as(u16, bytes[7]),
            .num_source_blocks = bytes[8],
            .num_sub_blocks = @as(u16, bytes[9]) << 8 | @as(u16, bytes[10]),
            .alignment = bytes[11],
        };
    }
};

pub const EncodingPacket = struct {
    payload_id: PayloadId,
    data: []const u8,
};

pub const Partition = struct {
    count_large: u32,
    size_large: u32,
    count_small: u32,
    size_small: u32,
};

/// RFC 6330 Section 4.4.1.2 - partition[I, J]
pub fn partition(i: u32, j: u32) Partition {
    const il = helpers.intDivCeil(i, j); // ceil(I/J)
    const is = i / j; // floor(I/J)
    const jl = i - is * j; // I mod J
    const js = j - jl;
    return .{
        .count_large = jl,
        .size_large = il,
        .count_small = js,
        .size_small = is,
    };
}
