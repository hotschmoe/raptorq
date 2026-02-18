# RaptorQ Zig Port - Status

## Current Phase: Phase 10 - Optimization & Hardening

Core encode/decode pipeline is complete and fully conformant. All layers (0-6) implemented
with end-to-end roundtrip verification including repair symbol generation and reconstruction.
86/86 conformance tests passing across all K' values. No known RFC 6330 conformance gaps
(see GAPS.md).

### Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Scaffolding - project structure, build system, test framework | Complete |
| 2 | Tables - populate GF(256), PRNG, and systematic constant tables | Complete |
| 3 | Math - GF(256) arithmetic, bulk operations, PRNG | Complete |
| 4 | Data structures - Symbol, Matrix types, sparse vectors | Complete |
| 5 | Constraint matrix - RFC 5.3.3 matrix construction | Complete |
| 6 | PI Solver - Inactivation decoding (RFC 5.4) | Complete |
| 7 | Encoder - Source block encoding (RFC 5.3) | Complete |
| 8 | Decoder - Source block decoding | Complete |
| 9 | Integration - Multi-block encode/decode, public API | Complete |
| 10 | Optimization & Hardening | In Progress |

### Build Status

- `zig build` - compiles library
- `zig build test` - runs unit tests (passing)
- `zig build test-conformance` - runs conformance tests (86/86 passing, 12 test files)

### Recent Changes

- **V3 optimization (all 9 steps)** - Comptime-generic solver over DenseBinaryMatrix /
  SparseBinaryMatrix. SparseBinaryMatrix: hybrid sparse V / dense U with progressive
  densification, O(1) row+column indirection, columnar index (CSC) for O(nnz) Phase 1.
  Degree histogram for O(1) pivot selection. Errata 11: Phase 1 XOR skips V section.
  Encoding plan caching via SolverPlan (pre-solve + replay). In-place cycle decomposition
  for symbol permutation. See docs/OPTIMIZATION_PLAN_V3.md.
- **SIMD vectorization** - Split-nibble GF(256) multiplication in `math/octets.zig` using
  TBL (aarch64 NEON), PSHUFB (x86_64 SSSE3), and scalar fallback. Vectorized `addAssign`,
  `fmaSlice`, and `mulAssignScalar`. Fixed O(n^2) BFS queue in `solver/graph.zig`.
- **PI solver rewrite** - Complete rewrite of inactivation decoding for RFC 6330 conformance.
  Fixed HDPC row handling (Errata 2), PI symbol inactivation, connected component graph
  substep, and decoder padding symbols. Resolved all 15 SingularMatrix failures for K'>=18.

---

## Roadmap

### Performance Optimizations

Leverage Zig's strengths for high-throughput FEC.

- [x] **SIMD vectorization** (former G-02) - Split-nibble GF(256) multiplication in
  `math/octets.zig`. 16 parallel byte lookups per instruction via TBL (aarch64 NEON) /
  PSHUFB (x86_64 SSSE3). `addAssign` uses `@Vector` XOR (auto-lowers on all targets).
  Scalar fallback for other architectures. (2026-02-17)
- [x] **P0: Bit-packed binary matrix for Phase 1** - Replace OctetMatrix with
  DenseBinaryMatrix for binary rows in the PI solver. Enables popcount-based nonzero
  counting (64x faster pivot selection) and u64-word XOR (4x faster elimination).
  See docs/PERFORMANCE_ANALYSIS.md for full profiling data. (2026-02-17)
- [x] **P1: HDPC row separation** - Store HDPC rows in their own OctetMatrix. Apply
  GF(256) FMA only where needed via set-bit iteration on binary pivot rows. (2026-02-17)
- [x] **P2: Partial row updates (Errata 11)** - During Phase 1 elimination, only XOR
  columns [i, L) instead of full row via xorRowRange. (2026-02-17)
- [x] **P3: Persistent graph** - ConnectedComponentGraph with union-find allocated once
  per solve and reset between iterations. O(alpha(n)) amortized edge operations. (2026-02-17)
- [x] **P4: Logical row indirection** - Row+column permutation via index arrays. DenseBinaryMatrix
  uses SolverState-managed log_to_phys/phys_to_log. SparseBinaryMatrix manages its own
  internally. swapRows/swapCols O(1). (2026-02-17)
- [x] **V3: SparseBinaryMatrix** - Hybrid sparse V / dense U with progressive densification,
  columnar index (CSC), degree histogram, Errata 11 U-only XOR, encoding plan caching,
  in-place cycle decomposition. Comptime-generic SolverState and ConstraintMatrices over
  matrix type. See docs/OPTIMIZATION_PLAN_V3.md for details. (2026-02-17)
- [ ] **Memory layout optimization** - Cache-friendly data layout for symbol storage and
  matrix rows. Profile and minimize allocator pressure in hot paths.

### Interop Testing

Validate wire-compatibility with other RFC 6330 implementations.

- [ ] **Encode here, decode elsewhere** - Generate encoding symbols and verify a reference
  implementation (e.g. Qualcomm's libRaptorQ, or the Rust raptorq crate) can decode them.
- [ ] **Decode foreign symbols** - Feed encoding symbols from a reference implementation
  into our decoder and verify correct reconstruction.
- [ ] **OTI serialization cross-check** - Verify our 12-byte OTI format matches other
  implementations byte-for-byte.

### Fuzz Testing

Discover edge cases through randomized inputs.

- [ ] **Encode/decode roundtrip fuzzer** - Random data sizes, symbol sizes, alignment
  values, sub-block counts. Verify roundtrip correctness for every combination.
- [ ] **Loss pattern fuzzer** - Random subsets of encoding symbols (varying loss rates,
  burst loss, systematic-only loss, repair-only recovery).
- [ ] **Malformed input fuzzer** - Corrupt packets, truncated data, out-of-range ESI/SBN
  values. Verify graceful error handling, no panics or undefined behavior.

### Benchmarking

Separate `benchmark/` directory with reproducible, measurable scenarios.

- [x] **Throughput benchmarks** - Encode and decode MB/s across 12 data sizes (256B to
  10MB). Zig benchmark at benchmark/bench.zig. (2026-02-17)
- [ ] **Memory profiling** - Peak allocation for encode/decode by K'. Identify where
  dense matrix O(K'^2) memory dominates.
- [x] **Comparative benchmarks** - Zig vs Rust (cberner/raptorq v2.0) side-by-side with
  matched parameters. Rust benchmark at benchmark/rust/. Gap: 9-48x depending on K.
  Full analysis in docs/PERFORMANCE_ANALYSIS.md. (2026-02-17)
- [x] **Solver profiling** - Per-phase timing instrumentation in PI solver. Phase 1 is
  85-95% of total solver time. Root cause: dense GF(256) matrix for binary data.
  See docs/PERFORMANCE_ANALYSIS.md. (2026-02-17)

### Baremetal Target

Goal: build and run on aarch64-freestanding (no OS, no libc).

- [x] **Cross-compile verification** - `zig build -Dtarget=aarch64-freestanding` compiles
  clean. No implicit libc or OS dependencies found. (2026-02-16)
- [x] **Allocator abstraction audit** - All allocation goes through injected
  `std.mem.Allocator`. No global state, no static buffers, no thread-locals. std types
  used (ArrayList, AutoHashMap) all accept an allocator parameter. (2026-02-16)
- [x] **No-std audit** - No std.fs, std.os, std.io, std.log, std.process, std.posix, or
  std.Thread in production code. Only std.debug.assert (becomes @trap on freestanding),
  std.mem, std.math.maxInt (comptime), std.ArrayList, std.AutoHashMap. std.testing is
  confined to test blocks. (2026-02-16)
- [ ] **Freestanding allocator example** - Provide or document a fixed-buffer allocator
  setup for embedded use (e.g. `std.heap.FixedBufferAllocator`).
