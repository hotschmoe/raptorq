# Intentional Deviations from Rust Reference

Deliberate differences between this Zig implementation and the cberner/raptorq Rust crate.
All deviations are design choices reflecting Zig idioms -- none are RFC 6330 violations.

### D-01: Explicit allocator injection
- **What**: Every struct carries an `std.mem.Allocator` field; all constructors accept an allocator parameter; all collections require explicit `deinit()`.
- **Why**: Zig has no ownership/borrowing system. Explicit allocator passing is idiomatic Zig and enables arena/pool strategies.
- **Rust behavior**: Ownership + borrowing, Vec/Box with implicit allocation.
- **Zig behavior**: Allocator parameter on init, caller manages lifetime via deinit.
- **RFC impact**: None.

### D-02: Concrete matrix types (no trait abstraction)
- **What**: `DenseBinaryMatrix`, `SparseBinaryMatrix`, and `OctetMatrix` are distinct structs with no shared interface. The solver and constraint matrix operate directly on `OctetMatrix`.
- **Why**: Zig lacks trait objects. Comptime dispatch or tagged unions would add complexity without clear benefit at current scale.
- **Rust behavior**: Trait objects (`dyn BinaryMatrix`, `dyn OctetMatrix`) for polymorphic matrix operations.
- **Zig behavior**: Concrete types with similar but independent APIs.
- **RFC impact**: None. Limits extensibility but not correctness.

### D-03: Scalar bulk operations (no SIMD)
- **What**: `math/octets.zig` uses scalar for-loops over byte slices. No `@Vector` usage.
- **Why**: Correctness-first approach. SIMD optimization deferred to Phase 10.
- **Rust behavior**: Vectorized or SIMD-intrinsic bulk GF(256) operations.
- **Zig behavior**: Scalar element-by-element loops.
- **RFC impact**: None. Performance gap only (estimated 2-8x for bulk operations).

### D-04: Comptime table generation
- **What**: GF(256) exp/log tables, PRNG V0-V3 tables, and systematic constants are all computed or embedded at compile time.
- **Why**: Zig's comptime is comprehensive. Zero runtime initialization cost.
- **Rust behavior**: lazy_static or runtime initialization.
- **Zig behavior**: Comptime evaluation, tables baked into binary.
- **RFC impact**: None. Identical results, different initialization strategy.

### D-05: Dense-only constraint matrix
- **What**: Constraint matrix is constructed entirely in dense `OctetMatrix` format. The LDPC and HDPC sub-matrices are written directly into the dense matrix without intermediate sparse representation.
- **Why**: Simpler implementation. Sparse optimization deferred.
- **Rust behavior**: May use sparse representation during construction, converting to dense for the solver.
- **Zig behavior**: Dense from the start (L x L allocation where L = K' + S + H).
- **RFC impact**: None for correctness. Memory overhead for large K'.

### D-06: Eager operation application (operation vector discarded)
- **What**: The PI solver produces an `OperationVector` recording matrix operations, but the encoder and decoder free it immediately rather than deferring symbol operations.
- **Why**: Simpler control flow. Operations are applied to symbols during the solve itself.
- **Rust behavior**: Likely defers operation application for shared computation paths.
- **Zig behavior**: Operations applied eagerly; the recorded vector is discarded.
- **RFC impact**: None. Same mathematical result, different evaluation order.
