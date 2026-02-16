# Feature Inventory

Features identified from cberner/raptorq Rust implementation mapped to RFC 6330.

| ID | Feature | RFC Section | Zig Source | Status |
|----|---------|-------------|------------|--------|
| F01 | GF(256) field arithmetic | 5.7 | math/octet.zig | Complete |
| F02 | Bulk octet operations | 5.7 | math/octets.zig | Complete (scalar, no SIMD) |
| F03 | GF(2) binary operations | - | math/gf2.zig | Complete |
| F04 | PRNG (Rand function) | 5.5 | math/rng.zig | Complete |
| F05 | Systematic index lookup (Table 2) | 5.6 | tables/systematic_constants.zig | Complete |
| F06 | Degree distribution | 5.3.5.2 | math/rng.zig | Complete |
| F07 | Tuple generation | 5.3.5.4 | math/rng.zig | Complete |
| F08 | Partition function | 4.4.1.2 | codec/base.zig | Complete |
| F09 | PayloadId serialization | 3.2 | codec/base.zig | Complete |
| F10 | Object Transmission Information | 3.3 | codec/base.zig | Complete |
| F11 | Symbol type with field ops | 5.3 | codec/symbol.zig | Complete |
| F12 | Dense binary matrix | - | matrix/dense_binary_matrix.zig | Complete |
| F13 | Sparse binary matrix | - | matrix/sparse_matrix.zig | Complete |
| F14 | Octet (GF-256) matrix | - | matrix/octet_matrix.zig | Complete |
| F15 | Constraint matrix construction | 5.3.3 | matrix/constraint_matrix.zig | Complete |
| F16 | LDPC sub-matrix | 5.3.3.3 | matrix/constraint_matrix.zig | Complete |
| F17 | HDPC sub-matrix | 5.3.3.3 | matrix/constraint_matrix.zig | Complete |
| F18 | LT encoding relationships | 5.3.5.3 | matrix/constraint_matrix.zig | Complete |
| F19 | PI solver (inactivation decoding) | 5.4.2 | solver/pi_solver.zig | Complete |
| F20 | Connected component tracking | 5.4.2.2 | solver/graph.zig | Complete |
| F21 | Operation vector (deferred ops) | - | codec/operation_vector.zig | Complete |
| F22 | Source block encoder | 5.3 | codec/encoder.zig | Complete |
| F23 | Source block decoder | 5.4 | codec/decoder.zig | Complete |
| F24 | Multi-block encoder | 4.4 | codec/encoder.zig | Complete |
| F25 | Multi-block decoder | 4.4 | codec/decoder.zig | Complete |
| F26 | Sub-block partitioning | 4.4.1.1 | - | Not Implemented (N=1 only) |
