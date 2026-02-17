# Performance Analysis: PI Solver Optimization

Date: 2026-02-17
Baseline: commit 024c80d (dev-hotschmoe)

## Benchmark Comparison: Zig vs Rust (cberner/raptorq v2.0)

Both benchmarks use identical parameters: same data sizes, symbol sizes, 10% loss,
median of 11 iterations (5 for >=1MB), ReleaseFast / --release.

```
Size     | T    | Zig Enc | Rust Enc | Ratio  | Zig Dec | Rust Dec | Ratio
---------|------|---------|----------|--------|---------|----------|------
256 B    | 64   |     0.9 |      9.3 |   10x  |     1.0 |     11.3 |  11x
1 KB     | 64   |     2.4 |     22.2 |    9x  |     2.4 |     26.0 |  11x
10 KB    | 64   |     2.5 |     22.4 |    9x  |     2.3 |     25.6 |  11x
16 KB    | 64   |     1.7 |     24.3 |   14x  |     1.5 |     27.8 |  19x
64 KB    | 64   |     0.6 |     22.3 |   37x  |     0.6 |     25.5 |  43x
128 KB   | 256  |     5.2 |     84.4 |   16x  |     5.6 |     96.9 |  17x
256 KB   | 256  |     2.6 |     81.5 |   31x  |     2.5 |     92.0 |  37x
512 KB   | 1024 |    19.9 |    247.3 |   12x  |    21.4 |    268.5 |  13x
1 MB     | 1024 |    10.2 |    231.3 |   23x  |    10.1 |    246.1 |  24x
2 MB     | 2048 |    19.2 |    350.1 |   18x  |    18.8 |    305.4 |  16x
4 MB     | 2048 |     6.5 |    310.8 |   48x  |     6.3 |    260.1 |  41x
10 MB    | 4096 |     9.5 |    325.9 |   34x  |     9.5 |    311.4 |  33x
                                                         (MB/s -- higher is better)
```

Gap ranges from 9x to 48x. The gap is K-dependent, not data-size-dependent:

```
K ~= data_size / T

K small (~256-512):   9-17x slower
K large (~1024-2560): 23-48x slower
```

Rust throughput scales with T (larger symbols = more SIMD throughput). Ours does not --
our throughput is dominated by solver overhead that scales with K, not T.


## Profiling: Per-Phase Solver Timing

Single encode pass with solver instrumentation, ReleaseFast:

```
Case           K'     L     Phase1      Phase2    Phase3    Apply    Total    P1%
1 KB           18     39    228us       12us      0us       14us     255us    89%
10 KB          160    193   2,347us     103us     12us      78us     2,542us  92%
64 KB          1032   1101  86,941us    3,309us   498us     706us    91,455us 95%
128 KB         526    577   18,427us    742us     127us     597us    19,894us 93%
256 KB         1032   1101  84,084us    3,209us   482us     1,462us  89,238us 94%
512 KB         526    577   18,442us    740us     131us     2,436us  21,751us 85%
1 MB           1032   1101  85,027us    3,258us   492us     4,722us  93,501us 91%
4 MB           2070   2170  573,790us   15,863us  2,023us   21,380us 613,058us 94%
10 MB          2565   2673  978,928us   22,656us  3,528us   51,942us 1,057ms  93%
```

**Phase 1 is 85-95% of total solver time.** Phase 2, 3, and apply are noise.

Phase 1 scaling is superquadratic:

```
L=193  ->  L=577   (3.0x L)  =>  2.3ms  -> 18.4ms  (8.0x time)  ~ O(L^2.7)
L=577  ->  L=1101  (1.9x L)  =>  18.4ms -> 85ms    (4.6x time)  ~ O(L^2.4)
L=1101 ->  L=2170  (2.0x L)  =>  85ms   -> 574ms   (6.7x time)  ~ O(L^2.7)
L=2170 ->  L=2673  (1.2x L)  =>  574ms  -> 979ms   (1.7x time)  ~ O(L^2.6)
```

Empirically O(L^2.6). For sparse binary elimination this should be closer to O(L^2).


## Root Cause: Dense GF(256) Matrix for Binary Data

The constraint matrix is ~95% binary (LDPC + LT rows). Only H HDPC rows have GF(256)
entries. Our solver uses a single OctetMatrix (dense, 1 byte per entry) for everything.

This causes three categories of overhead:

### 1. Pivot Selection (rowNonzerosInV) -- ~64x overhead

Every Phase 1 step scans remaining rows to count nonzeros in V. This is the inner loop
of an O(L^2) outer loop.

```
    Us:   Scan V_size bytes, compare each to zero    = O(V_size) per row
    Rust: count_ones() via popcount on u64 words      = O(V_size / 64) per row
```

With L=1101 and V_size ~550, we do ~550 byte comparisons per row. Rust does ~9 popcount
operations. This is the single largest performance gap.

### 2. Row Elimination (addAssignRow) -- ~4x overhead

Binary row XOR during Phase 1 elimination:

```
    Us:   XOR L bytes via SIMD, 16 bytes per op       = L/16 SIMD operations
    Rust: XOR L/64 u64 words (bit-packed)              = L/64 word operations
```

Our SIMD helps, but bit-packing is inherently 4x denser (8 bits per byte vs 1 bit per
element, with 8 elements per byte mapped to 1 u64 word of 64 elements).

### 3. Column Swaps (swapCols) -- ~2-4x overhead

```
    Us:   For each of L rows, swap 2 bytes             = O(L) with stride = cols
    Rust: For each row, swap 2 bits in u64 words       = O(L) but with start_row_hint
```

Rust also skips already-resolved rows via start_row_hint, reducing to O(L-i) per swap.

### 4. Memory Footprint / Cache Pressure -- 8x overhead

```
    Us:   L * L bytes                (L=1101: ~1.2 MB, L=2170: ~4.7 MB)
    Rust: L * L / 8 bytes bit-packed (L=1101: ~150 KB, L=2170: ~590 KB)
```

At L>500, our matrix exceeds L1 cache. At L>1500, it exceeds L2. This compounds every
other overhead because every matrix access is a cache miss instead of a hit.


## What Rust Does That We Don't

Analysis of cberner/raptorq v2.0 source code:

### Architectural Differences

1. **Hybrid sparse/dense binary matrix**
   Rust uses SparseBinaryMatrix with u64 bit-packed storage for binary rows. Dynamically
   converts sparse columns to dense as they become filled during elimination. HDPC rows
   stored in a separate DenseOctetMatrix (full GF(256)).

2. **popcount for nonzero counting**
   BinaryMatrix.count_ones() uses hardware popcount on u64 words. O(L/64) per row vs
   our O(L) byte scan. This is the dominant inner loop in Phase 1 pivot selection.

3. **Separate HDPC storage**
   HDPC rows (GF(256) entries) kept in their own DenseOctetMatrix. Never mixed into the
   binary matrix operations. Applied selectively via fma_sub_row() only on the U
   submatrix during Phase 1.

4. **Logical row indirection**
   Row permutations tracked via logical_row_to_physical / physical_row_to_logical index
   arrays. No physical row data movement on swapRows -- just swap two u32 indices.

### Algorithmic Optimizations

5. **Partial row updates (RFC Errata 11)**
   During Phase 1 elimination, only update columns in V+U region (not the full row).
   Columns left of i are guaranteed zero. Saves ~25% of elimination work.

6. **start_row_hint for column swaps**
   Column swaps skip rows [0, i) that are already resolved. At average Phase 1 step,
   this skips ~L/2 rows per swap.

7. **Persistent connected component graph**
   ConnectedComponentGraph allocated once and reset() between Phase 1 iterations.
   Uses union-find with merge-to-lowest for O(alpha(n)) amortized lookups.
   Our implementation allocates and deallocates a new Graph on every r=2 step.

8. **Columnar index acceleration**
   get_ones_in_column() backed by pre-built columnar index (which rows have 1s in each
   column). O(nonzeros) lookup instead of O(height) scan. Built lazily, destroyed when
   no longer needed.


## Implementation Plan

Priority order based on measured impact:

### P0: Bit-packed binary matrix for Phase 1 (addresses 64x pivot gap)

Replace OctetMatrix with DenseBinaryMatrix for the binary part of the constraint matrix
in the solver. We already have DenseBinaryMatrix at src/matrix/dense_binary_matrix.zig.

Key changes:
- SolverState holds DenseBinaryMatrix (binary rows) + small OctetMatrix (HDPC rows)
- rowNonzerosInV becomes popcount over u64 words
- addAssignRow becomes XOR over u64 words (already in DenseBinaryMatrix.xorRow)
- swapCols operates on bits instead of bytes
- Phase 2 extracts the u x u submatrix into a separate OctetMatrix for GF(256) GE

Expected impact: 10-30x improvement in Phase 1 (from 64x popcount gain minus overhead
of managing two matrices). This alone should close most of the gap with Rust.

### P1: HDPC row separation (removes GF(256) from binary path)

Store HDPC rows in their own OctetMatrix. During Phase 1 elimination, apply GF(256) FMA
only to the HDPC rows (not mixed into the binary matrix).

Expected impact: cleaner code paths, removes conditional branching in eliminateColumn.

### P2: Partial row updates / Errata 11 (saves ~25% elimination work)

During eliminateColumn, only XOR columns [i, L) instead of [0, L). Left columns are
guaranteed zero after the pivot column is established.

Expected impact: ~25% reduction in Phase 1 elimination time.

### P3: Persistent graph / allocation reduction

Pre-allocate ConnectedComponentGraph once per solve and reset between iterations.
Eliminate per-iteration alloc/dealloc overhead in the r=2 graph substep.

Expected impact: minor for small K', measurable for large K' where r=2 steps are
frequent.

### P4: Logical row indirection (avoid physical row swaps)

Track row permutations via index arrays instead of physically swapping row data.
swapRows becomes O(1) instead of O(L).

Expected impact: moderate reduction in Phase 1 and Phase 2 row swap overhead.


## Implementation Status (2026-02-17)

P0-P3 implemented in a single commit. The PI solver now uses:

- **DenseBinaryMatrix** (u64 bit-packed) for all non-HDPC rows (L-H rows)
- **OctetMatrix** (GF(256)) for HDPC rows only (H rows, typically 10-20)
- **ConnectedComponentGraph** with union-find (reset between iterations, no alloc churn)
- **Partial row XOR** (xorRowRange) for Errata 11 elimination optimization
- **start_row hint** for column swaps (skip resolved rows)
- **Set-bit iteration** via @ctz for HDPC FMA (avoids full GF(256) row multiply)


## Post-Optimization Results

### Solver Profiling (ReleaseFast, single encode pass)

```
Case           K'     L     Phase1      Phase2    Phase3    Apply    Total    P1%
1 KB           18     39    19us        20us      0us       13us     54us     35%
10 KB          160    193   194us       132us     12us      75us     415us    47%
64 KB          1032   1101  6,482us     1,405us   1,117us   690us    9,695us  67%
128 KB         526    577   2,674us     501us     128us     537us    3,841us  70%
256 KB         1032   1101  6,190us     1,386us   482us     1,328us  9,387us  66%
512 KB         526    577   1,412us     552us     147us     1,654us  3,766us  37%
1 MB           1032   1101  6,286us     2,912us   490us     3,864us  13,553us 46%
4 MB           2070   2170  37,190us    3,454us   1,982us   19,818us 62,445us 60%
10 MB          2565   2673  65,191us    5,030us   3,067us   45,489us 118,779us 55%
```

Phase 1 improvement vs pre-optimization baseline:

```
K'=1032 (L=1101): 85ms -> 6.2ms   (13.7x faster)
K'=2070 (L=2170): 574ms -> 37ms   (15.5x faster)
K'=2565 (L=2673): 979ms -> 65ms   (15.1x faster)
```

Phase 1 is no longer the dominant bottleneck for large symbol sizes (apply/remap
takes over due to O(L*T) symbol copy cost).

### Benchmark Throughput (ReleaseFast, 10% loss)

```
Size     | T    | Zig Enc | Rust Enc | Ratio  | Zig Dec | Rust Dec | Ratio
---------|------|---------|----------|--------|---------|----------|------
256 B    | 64   |     1.8 |      9.3 |    5x  |     1.5 |     11.3 |   8x
1 KB     | 64   |     4.1 |     22.2 |    5x  |     4.1 |     26.0 |   6x
10 KB    | 64   |     6.1 |     22.4 |    4x  |     5.8 |     25.6 |   4x
64 KB    | 64   |     3.2 |     22.3 |    7x  |     3.0 |     25.5 |   9x
128 KB   | 256  |    16.8 |     84.4 |    5x  |    15.7 |     96.9 |   6x
256 KB   | 256  |    11.6 |     81.5 |    7x  |    11.7 |     92.0 |   8x
512 KB   | 1024 |    59.1 |    247.3 |    4x  |    52.0 |    268.5 |   5x
1 MB     | 1024 |    40.5 |    231.3 |    6x  |    38.1 |    246.1 |   6x
2 MB     | 2048 |    72.2 |    350.1 |    5x  |    67.6 |    305.4 |   5x
4 MB     | 2048 |    45.1 |    310.8 |    7x  |    43.7 |    260.1 |   6x
10 MB    | 4096 |    67.2 |    325.9 |    5x  |    63.6 |    311.4 |   5x
                                                         (MB/s -- higher is better)
```

Gap narrowed from 9-48x to 4-9x. Largest improvements at high K' where Phase 1
was the bottleneck.


## Remaining Optimization Opportunities

- **P4: Logical row indirection** - Track row permutations via index arrays instead
  of physically swapping row data. swapRows becomes O(1) instead of O(L).
- **Memory layout optimization** - Cache-friendly data layout, minimize allocator
  pressure in hot paths.
- **Phase 2 optimization** - Phase 2 now consumes a larger fraction of total time.
  Consider optimized GF(256) GE for the small inactivated submatrix.
- **Apply/remap optimization** - Symbol copy/permutation is significant at large T.
  Consider in-place permutation or swap-based remap.
