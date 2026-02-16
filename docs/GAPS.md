# Gap Inventory

Known gaps between the current implementation and full RFC 6330 conformance.

### ~~G-01: Sub-block partitioning (N > 1)~~ RESOLVED
- **Feature**: F26
- **Description**: RFC 6330 Section 4.4.1.1 sub-block partitioning now fully supported. Encoder and Decoder accept `num_sub_blocks` and `alignment` parameters, deinterleave/interleave symbol data across N sub-block encoders/decoders, and concatenate results.
- **Resolution**: Encoder.init and Decoder.init now accept N and Al. Each source block spawns N independent SourceBlockEncoder/SourceBlockDecoder instances operating on sub-symbol-sized data. Roundtrip tested with N=2 including repair symbols.

### G-02: SIMD vectorization for bulk GF(256) operations
- **Feature**: F02
- **Description**: `math/octets.zig` uses scalar element-by-element loops for addAssign, mulAssignScalar, and fmaSlice. Zig's `@Vector` built-in could provide 2-8x speedups on modern CPUs. This is a performance gap, not a correctness gap.
- **Severity**: Minor (performance only)
- **Blocked by**: None

### G-03: Sparse matrix utilization in solver pipeline
- **Feature**: F13, F15, F19
- **Description**: `SparseBinaryMatrix` exists as a standalone utility but is not used in the constraint matrix construction or PI solver. The constraint matrix is built entirely in dense `OctetMatrix` format. For large K' values, exploiting LDPC row sparsity during construction and early solver phases could reduce memory and improve performance.
- **Severity**: Minor (performance/memory only)
- **Blocked by**: None
