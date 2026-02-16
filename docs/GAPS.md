# Gap Inventory

Known gaps between the current implementation and full RFC 6330 conformance.

### G-01: Sub-block partitioning (N > 1)
- **Feature**: F26
- **Description**: RFC 6330 Section 4.4.1.1 defines sub-block partitioning where N (num_sub_blocks) can be > 1 to split source blocks into smaller transfer units. The Encoder hardcodes `num_sub_blocks = 1`. Systems requiring N > 1 are not supported.
- **Severity**: Major
- **Blocked by**: None

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
