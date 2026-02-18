# RFC 6330 Conformance Gaps

No known gaps between the current implementation and RFC 6330.

All algorithmic sections implemented and verified by 86/86 conformance tests.

Last audited: 2026-02-16

## Resolved

### G-01: Sub-block partitioning (N > 1)
- **Description**: RFC 6330 Section 4.4.1.1 sub-block partitioning now fully supported.
- **Resolution**: Encoder and Decoder accept num_sub_blocks and alignment parameters,
  deinterleave/interleave symbol data across N sub-block encoders/decoders.

### G-02: SIMD vectorization for bulk GF(256) operations
- **Description**: Scalar GF(256) operations in math/octets.zig. Not an RFC conformance
  gap -- reclassified as a performance optimization.
- **Resolution**: Split-nibble GF(256) multiplication via TBL (aarch64) / PSHUFB (x86_64)
  with scalar fallback. Implemented in math/octets.zig. (2026-02-17)

### G-03: Sparse matrix utilization in solver pipeline
- **Description**: SparseBinaryMatrix exists but unused in constraint matrix / PI solver.
  Not an RFC conformance gap -- reclassified as a performance optimization. Tracked in
  STATUS.md roadmap.

### G-04: PI solver fails for K' >= 18
- **Description**: Inactivation decoding returned SingularMatrix for K' >= 18.
- **Resolution**: Complete rewrite of pi_solver.zig with proper 3-phase algorithm.
  86/86 conformance tests passing.
