# RaptorQ Implementation Layers

## Layer 0: Tables
- [x] `src/tables/octet_tables.zig` -- GF(256) exp/log tables (comptime)
- [x] `src/tables/rng_tables.zig` -- PRNG V0-V3 tables (RFC 6330 Section 5.5)
- [x] `src/tables/systematic_constants.zig` -- Table 2 (477 entries) + lookup functions

## Layer 1: Math
- [x] `src/math/octet.zig` -- GF(256) single-element arithmetic
- [x] `src/math/octets.zig` -- Bulk GF(256) slice operations
- [x] `src/math/gf2.zig` -- GF(2) bit-packed operations
- [x] `src/math/rng.zig` -- PRNG, degree distribution, tuple generation

## Layer 2: Codec Basics
- [x] `src/codec/base.zig` -- PayloadId, OTI, partition
- [x] `src/codec/symbol.zig` -- Symbol with field arithmetic
- [x] `src/codec/operation_vector.zig` -- Deferred symbol operations

## Layer 3: Matrices
- [x] `src/matrix/dense_binary_matrix.zig` -- u64-packed binary matrix
- [x] `src/matrix/sparse_matrix.zig` -- Hybrid sparse/dense binary matrix
- [x] `src/matrix/octet_matrix.zig` -- Dense GF(256) matrix
- [x] `src/matrix/constraint_matrix.zig` -- RFC 5.3.3 constraint matrix construction

## Layer 4: Solver
- [x] `src/solver/graph.zig` -- Connected component tracking
- [x] `src/solver/pi_solver.zig` -- 5-phase inactivation decoding

## Layer 5: Codec High-Level
- [x] `src/codec/encoder.zig` -- SourceBlockEncoder, Encoder
- [x] `src/codec/decoder.zig` -- SourceBlockDecoder, Decoder

## Layer 6: Public API
- [x] `src/root.zig` -- Library entry point, re-exports

## Utilities
- [x] `src/util/helpers.zig` -- intDivCeil, isPrime, nextPrime
- [x] `src/util/arraymap.zig` -- Specialized map types
- [x] `src/util/sparse_vec.zig` -- Sparse binary vector
