// RaptorQ base types (RFC 6330 Section 3)

const helpers = @import("../util/helpers.zig");

pub const PayloadId = struct {
    source_block_number: u8,
    encoding_symbol_id: u32,

    pub fn serialize(self: PayloadId) [4]u8 {
        _ = self;
        @panic("TODO");
    }

    pub fn deserialize(bytes: [4]u8) PayloadId {
        _ = bytes;
        @panic("TODO");
    }
};

pub const ObjectTransmissionInformation = struct {
    transfer_length: u64,
    symbol_size: u16,
    num_source_blocks: u8,
    num_sub_blocks: u16,
    alignment: u8,

    pub fn serialize(self: ObjectTransmissionInformation) [12]u8 {
        _ = self;
        @panic("TODO");
    }

    pub fn deserialize(bytes: [12]u8) ObjectTransmissionInformation {
        _ = bytes;
        @panic("TODO");
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
    _ = .{ i, j };
    @panic("TODO");
}
