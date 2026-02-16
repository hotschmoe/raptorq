# RaptorQ Zig Port - Status

## Current Phase: Phase 1 - Scaffolding

### Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Scaffolding - project structure, build system, test framework | In Progress |
| 2 | Tables - populate GF(256), PRNG, and systematic constant tables | Not Started |
| 3 | Math - GF(256) arithmetic, bulk operations, PRNG | Not Started |
| 4 | Data structures - Symbol, Matrix types, sparse vectors | Not Started |
| 5 | Constraint matrix - RFC 5.3.3 matrix construction | Not Started |
| 6 | PI Solver - Inactivation decoding (RFC 5.4) | Not Started |
| 7 | Encoder - Source block encoding (RFC 5.3) | Not Started |
| 8 | Decoder - Source block decoding | Not Started |
| 9 | Integration - Multi-block encode/decode, public API | Not Started |
| 10 | Optimization - SIMD, memory layout, performance | Not Started |

### Build Status

- `zig build` - compiles library
- `zig build test` - runs unit tests
- `zig build test-conformance` - runs conformance tests
