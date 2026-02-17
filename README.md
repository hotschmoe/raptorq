# raptorq

Pure Zig implementation of [RFC 6330](https://www.rfc-editor.org/rfc/rfc6330) -- RaptorQ Forward Error Correction.

Zero dependencies. Pure Zig.

## Overview

RaptorQ is a fountain code that enables reliable data delivery over lossy channels. A sender encodes source data into encoding symbols (source + repair). A receiver can reconstruct the original data from **any** sufficiently large subset of those symbols -- it does not matter *which* symbols are lost, only *how many*.

This library provides a complete RFC 6330 implementation:

- Source block partitioning and sub-block interleaving
- GF(256) arithmetic with SIMD-accelerated bulk operations
- Constraint matrix construction (LDPC, HDPC, LT, PI sub-matrices)
- Inactivation decoding (5-phase PI solver)
- Systematic encoding (source symbols are transmitted unmodified)

Spec-complete with 86/86 conformance tests, interop tests against the Rust [cberner/raptorq](https://github.com/cberner/raptorq) crate, and fuzz tests all passing.

## Quick Start

Add raptorq to your Zig project:

```bash
zig fetch --save git+https://github.com/hotschmoe/raptorq
```

Then in your `build.zig`:

```zig
const raptorq_dep = b.dependency("raptorq", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("raptorq", raptorq_dep.module("raptorq"));
```

## Usage

```zig
const std = @import("std");
const raptorq = @import("raptorq");

// Encode
var enc = try raptorq.Encoder.init(allocator, data, symbol_size, 1, 4);
defer enc.deinit();

const k = enc.sourceBlockK(0);           // number of source symbols
const k_prime = enc.sub_encoders[0].k_prime; // padded symbol count (decode threshold)

// Generate source packets (ESI 0..K-1)
var esi: u32 = 0;
while (esi < k) : (esi += 1) {
    const pkt = try enc.encode(0, esi);
    defer allocator.free(pkt.data);
    // send pkt over network...
}

// Generate repair packets (ESI >= K) to compensate for loss
esi = k;
while (esi < k + repair_count) : (esi += 1) {
    const pkt = try enc.encode(0, esi);
    defer allocator.free(pkt.data);
    // send pkt over network...
}

// Decode
var dec = try raptorq.Decoder.init(allocator, enc.objectTransmissionInformation());
defer dec.deinit();

// Feed received packets (any K' packets suffice)
for (received_packets) |pkt| {
    try dec.addPacket(pkt);
}

const decoded = (try dec.decode()).?;
defer allocator.free(decoded);
// decoded == original data
```

See `examples/encode_decode.zig` for a complete working example with loss recovery.

## API

### Encoder

```zig
// Create encoder. T=symbol_size, N=num_sub_blocks, Al=alignment.
pub fn Encoder.init(allocator, data: []const u8, symbol_size: u16, num_sub_blocks: u16, alignment: u8) !Encoder

// Encode symbol by source block number and encoding symbol ID.
pub fn Encoder.encode(self, sbn: u8, esi: u32) !EncodingPacket

// Number of source symbols in a source block.
pub fn Encoder.sourceBlockK(self, sbn: u8) u32

// Get OTI for transmission to decoder.
pub fn Encoder.objectTransmissionInformation(self) ObjectTransmissionInformation
```

### Decoder

```zig
// Create decoder from OTI received from encoder.
pub fn Decoder.init(allocator, config: ObjectTransmissionInformation) !Decoder

// Add a received encoding packet.
pub fn Decoder.addPacket(self, packet: EncodingPacket) !void

// Attempt decoding. Returns null if insufficient symbols received.
pub fn Decoder.decode(self) !?[]u8
```

### Key Types

```zig
pub const EncodingPacket = struct {
    payload_id: PayloadId,
    data: []const u8,
};

pub const ObjectTransmissionInformation = struct {
    transfer_length: u64,
    symbol_size: u16,
    num_source_blocks: u8,
    num_sub_blocks: u16,
    alignment: u8,

    pub fn serialize(self) [12]u8;
    pub fn deserialize(bytes: [12]u8) ObjectTransmissionInformation;
};
```

## Build

```bash
zig build                  # Build library
zig build test             # Run unit tests
zig build test-conformance # Run conformance tests (86/86 RFC sections)
zig build test-interop     # Run interop tests (Rust-generated vectors)
zig build test-fuzz        # Run fuzz tests
zig build example          # Build and run encode/decode example
zig build bench            # Build and run benchmarks (ReleaseFast)

# Cross-compile
zig build -Dtarget=aarch64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
```

### Rust Benchmark (for comparison)

```bash
cd benchmark/rust && cargo run --release
```

## Architecture

```
Layer 6: API (root.zig)
    |
Layer 5: Codec (encoder.zig, decoder.zig)
    |
Layer 4: Solver (pi_solver.zig, graph.zig)
    |
Layer 3: Matrix (dense_binary_matrix, sparse_matrix, octet_matrix, constraint_matrix)
    |
Layer 2: Data Structures (base.zig, symbol.zig, operation_vector.zig)
    |
Layer 1: Math (octet.zig, octets.zig, gf2.zig, rng.zig)
    |
Layer 0: Tables (octet_tables.zig, rng_tables.zig, systematic_constants.zig)
```

See [docs/discovery/ARCHITECTURE.md](docs/discovery/ARCHITECTURE.md) for the full dependency diagram.

## References

- [RFC 6330](https://www.rfc-editor.org/rfc/rfc6330) -- RaptorQ Forward Error Correction Scheme for Object Delivery
- [RFC 5053](https://www.rfc-editor.org/rfc/rfc5053) -- Raptor Forward Error Correction Scheme (predecessor)

## License

[MIT](LICENSE)
