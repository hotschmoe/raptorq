# Architecture - Layer Dependency

Dependency layers from foundation to API surface.

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

### Module Map

```
src/
  root.zig                          Layer 6 - Public API re-exports
  tables/
    octet_tables.zig                Layer 0 - GF(256) exp/log tables
    rng_tables.zig                  Layer 0 - PRNG V0..V3 tables
    systematic_constants.zig        Layer 0 - RFC Table 2 (K'->J,S,H,W)
  math/
    octet.zig                       Layer 1 - GF(256) single-element ops
    octets.zig                      Layer 1 - Bulk GF(256) slice ops
    gf2.zig                         Layer 1 - GF(2) binary bit ops
    rng.zig                         Layer 1 - RFC 5.5 PRNG + tuple gen
  codec/
    base.zig                        Layer 2 - PayloadId, OTI, partition
    symbol.zig                      Layer 2 - Symbol with field arithmetic
    operation_vector.zig            Layer 2 - Deferred symbol operations
    encoder.zig                     Layer 5 - Encoder, SourceBlockEncoder
    decoder.zig                     Layer 5 - Decoder, SourceBlockDecoder
  matrix/
    dense_binary_matrix.zig         Layer 3 - Bit-packed u64 matrix
    sparse_matrix.zig               Layer 3 - Hybrid sparse/dense
    octet_matrix.zig                Layer 3 - Dense GF(256) matrix
    constraint_matrix.zig           Layer 3 - RFC 5.3.3 construction
  solver/
    pi_solver.zig                   Layer 4 - 5-phase inactivation decoding
    graph.zig                       Layer 4 - Connected components
  util/
    sparse_vec.zig                  Utility - Sparse binary vector
    arraymap.zig                    Utility - Specialized map types
    helpers.zig                     Utility - intDivCeil, isPrime, etc.
```

### Key Dependencies

- encoder.zig -> pi_solver.zig -> constraint_matrix.zig -> octet_matrix.zig -> octet.zig -> octet_tables.zig
- decoder.zig -> pi_solver.zig (same chain)
- constraint_matrix.zig -> rng.zig -> rng_tables.zig
- constraint_matrix.zig -> systematic_constants.zig
- sparse_matrix.zig -> sparse_vec.zig
