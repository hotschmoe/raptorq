# Feature Inventory

Features identified from cberner/raptorq Rust implementation mapped to RFC 6330.

| ID | Feature | RFC Section | Rust Source | Status |
|----|---------|-------------|-------------|--------|
| F01 | GF(256) field arithmetic | 5.7 | octet.rs | Not Started |
| F02 | Bulk octet operations (SIMD) | 5.7 | octets.rs | Not Started |
| F03 | GF(2) binary operations | - | gf2.rs | Not Started |
| F04 | PRNG (Rand function) | 5.5 | rng.rs | Not Started |
| F05 | Systematic index lookup (Table 2) | 5.6 | systematic_constants.rs | Not Started |
| F06 | Degree distribution | 5.3.5.2 | rng.rs | Not Started |
| F07 | Tuple generation | 5.3.5.4 | rng.rs | Not Started |
| F08 | Partition function | 4.4.1.2 | base.rs | Not Started |
| F09 | PayloadId serialization | 3.2 | base.rs | Not Started |
| F10 | Object Transmission Information | 3.3 | base.rs | Not Started |
| F11 | Symbol type with field ops | 5.3 | symbol.rs | Not Started |
| F12 | Dense binary matrix | - | matrix.rs | Not Started |
| F13 | Sparse binary matrix | - | sparse_matrix.rs | Not Started |
| F14 | Octet (GF-256) matrix | - | octet_matrix.rs | Not Started |
| F15 | Constraint matrix construction | 5.3.3 | constraint_matrix.rs | Not Started |
| F16 | LDPC sub-matrix | 5.3.3.3 | constraint_matrix.rs | Not Started |
| F17 | HDPC sub-matrix | 5.3.3.3 | constraint_matrix.rs | Not Started |
| F18 | LT encoding relationships | 5.3.5.3 | constraint_matrix.rs | Not Started |
| F19 | PI solver (inactivation decoding) | 5.4.2 | pi_solver.rs | Not Started |
| F20 | Connected component tracking | 5.4.2.2 | graph.rs | Not Started |
| F21 | Operation vector (deferred ops) | - | operation_vector.rs | Not Started |
| F22 | Source block encoder | 5.3 | encoder.rs | Not Started |
| F23 | Source block decoder | 5.4 | decoder.rs | Not Started |
| F24 | Multi-block encoder | 4.4 | encoder.rs | Not Started |
| F25 | Multi-block decoder | 4.4 | decoder.rs | Not Started |
| F26 | Sub-block partitioning | 4.4.1.1 | base.rs | Not Started |
