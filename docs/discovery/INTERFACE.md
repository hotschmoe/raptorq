# Public API Surface

Exposed through `src/root.zig` for consumers importing the `raptorq` module.

## Primary API

### Encoder
- `Encoder.init(allocator, data, symbol_size, num_sub_blocks, alignment) -> !Encoder`
- `Encoder.deinit(*Encoder) -> void`
- `Encoder.encode(*Encoder, sbn, esi) -> !EncodingPacket`
- `Encoder.sourceBlockK(Encoder, sbn) -> u32`
- `Encoder.objectTransmissionInformation(Encoder) -> ObjectTransmissionInformation`

### Decoder
- `Decoder.init(allocator, config) -> !Decoder`
- `Decoder.deinit(*Decoder) -> void`
- `Decoder.addPacket(*Decoder, packet) -> !void`
- `Decoder.decode(*Decoder) -> !?[]u8`

### Types
- `ObjectTransmissionInformation` - Transfer parameters (serializable)
- `PayloadId` - Source block number + encoding symbol ID
- `EncodingPacket` - PayloadId + symbol data

## Advanced API

### Source Block Level
- `SourceBlockEncoder` - Encode individual source blocks
- `SourceBlockDecoder` - Decode individual source blocks

### Math (for custom applications)
- `Octet` - GF(256) element with field operations
- `Symbol` - Byte vector with GF(256) arithmetic
