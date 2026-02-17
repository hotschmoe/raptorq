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
- [ ] **P0: Bit-packed binary matrix for Phase 1** - Replace OctetMatrix with
  DenseBinaryMatrix for binary rows in the PI solver. Enables popcount-based nonzero
  counting (64x faster pivot selection) and u64-word XOR (4x faster elimination).
  See docs/PERFORMANCE_ANALYSIS.md for full profiling data and implementation plan.
- [ ] **P1: HDPC row separation** - Store HDPC rows in their own OctetMatrix. Apply
  GF(256) FMA only where needed, not mixed into binary matrix operations.
- [ ] **P2: Partial row updates (Errata 11)** - During Phase 1 elimination, only XOR
  columns [i, L) instead of full row. Saves ~25% of elimination work.
- [ ] **P3: Persistent graph** - Pre-allocate ConnectedComponentGraph once per solve
  and reset between iterations. Eliminates per-iteration alloc/dealloc churn.
- [ ] **P4: Logical row indirection** - Track row permutations via index arrays instead
  of physically swapping row data. swapRows becomes O(1) instead of O(L).
- [ ] **Memory layout optimization** - Cache-friendly data layout for symbol storage and
  matrix rows. Profile and minimize allocator pressure in hot paths.
- [ ] **Comptime specialization** - Explore comptime-specialized paths for common K' values
  or symbol sizes where the compiler can unroll/optimize aggressively.

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
