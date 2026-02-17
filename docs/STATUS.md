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

- **PI solver rewrite** - Complete rewrite of inactivation decoding for RFC 6330 conformance.
  Fixed HDPC row handling (Errata 2), PI symbol inactivation, connected component graph
  substep, and decoder padding symbols. Resolved all 15 SingularMatrix failures for K'>=18.

---

## Roadmap

### Performance Optimizations

Leverage Zig's strengths for high-throughput FEC.

- [ ] **SIMD vectorization** (former G-02) - `math/octets.zig` uses scalar loops for
  addAssign, mulAssignScalar, and fmaSlice. Zig's `@Vector` built-in can provide 2-8x
  speedups on modern CPUs. Should also specialize for NEON (aarch64) and SSE/AVX (x86_64).
- [ ] **Sparse matrix utilization** (former G-03) - `SparseBinaryMatrix` exists but is
  unused. Exploit LDPC row sparsity during constraint matrix construction and early solver
  phases to reduce memory and improve performance for large K'.
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

- [ ] **Throughput benchmarks** - Encode and decode MB/s across a range of K' values and
  symbol sizes. Track regressions over time.
- [ ] **Memory profiling** - Peak allocation for encode/decode by K'. Identify where
  dense matrix O(K'^2) memory dominates.
- [ ] **Comparative benchmarks** - Side-by-side with reference implementations where
  possible (same hardware, same parameters).

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
