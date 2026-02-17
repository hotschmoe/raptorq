# Optimization Plan V2: Closing the Rust Gap

Date: 2026-02-17
Baseline: commit 9e9b5a3 (dev-hotschmoe)
Target: Match or beat cberner/raptorq v2.0 throughput

## Implementation Status

| Item | Description                          | Status    |
|------|--------------------------------------|-----------|
| 1    | Contiguous SymbolBuffer              | DONE      |
| 2    | Incremental v_degree tracking        | DONE      |
| 3    | Logical row indirection              | DONE      |
| 4    | Direct binary matrix construction    | DONE      |
| 5    | Widen SIMD to 256-bit (AVX2)        | Remaining |

Items 1-4 implemented in commits 047f3f8 and prior. Reduced gap from ~5-6x to ~2.5-4x (encode) and ~3-5x (decode).

Remaining work: Item 5 (SIMD widening) plus columnar index for Phase 1 elimination.

## Current Benchmark Results

Both benchmarks: identical parameters, same data sizes, symbol sizes, 10% loss,
median of 11 iterations (5 for >=1MB), ReleaseFast / --release.

```
Size     | T    | Zig Enc | Rust Enc | Gap   | Zig Dec | Rust Dec | Gap
---------|------|---------|----------|-------|---------|----------|-----
256 B    | 64   |     1.7 |      9.0 |  5.3x |     1.6 |     11.1 |  6.9x
1 KB     | 64   |     4.3 |     21.6 |  5.0x |     3.9 |     25.7 |  6.6x
10 KB    | 64   |     6.1 |     21.0 |  3.4x |     5.8 |     24.5 |  4.2x
16 KB    | 64   |     5.7 |     24.0 |  4.2x |     5.3 |     27.8 |  5.2x
64 KB    | 64   |     3.3 |     22.1 |  6.7x |     3.1 |     25.4 |  8.2x
128 KB   | 256  |    15.7 |     85.5 |  5.4x |    15.3 |     96.7 |  6.3x
256 KB   | 256  |    11.9 |     80.8 |  6.8x |    11.4 |     89.5 |  7.9x
512 KB   | 1024 |    59.4 |    242.0 |  4.1x |    53.0 |    262.5 |  5.0x
1 MB     | 1024 |    41.8 |    233.6 |  5.6x |    37.3 |    251.6 |  6.7x
2 MB     | 2048 |    69.7 |    339.4 |  4.9x |    66.6 |    290.5 |  4.4x
4 MB     | 2048 |    45.8 |    298.5 |  6.5x |    43.8 |    248.3 |  5.7x
10 MB    | 4096 |    66.8 |    320.0 |  4.8x |    64.4 |    308.3 |  4.8x
                                                          (MB/s -- higher is better)
```

Gap: 3.4x - 8.2x. Average ~5-6x behind Rust.


## Profiler Breakdown (10 MB encode, single pass)

```
Component              Time (ms)   % of Total   Root Cause
---------------------------------------------------------------
Phase 1 (elimination)    63.6       45%          Brute-force row scanning
Apply (symbol ops)       44.6       32%          Scattered symbol allocations
Matrix build             16.9       12%          Full OctetMatrix intermediate
Symbol generation         8.2        6%          Per-symbol heap alloc
Phase 2                   5.0        4%          (acceptable)
Phase 3                   2.3        2%          (acceptable)
---------------------------------------------------------------
Total                   140.6      100%          Rust total: ~31ms
```

Full profiler output across sizes:

```
Case           K'     L     Phase1      Phase2    Phase3    Apply    Total    P1%
1 KB           18     39    26us        30us      0us       21us     78us     33%
10 KB          160    193   207us       130us     10us      73us     421us    49%
64 KB          1032   1101  6,840us     1,361us   369us     673us    9,246us  74%
128 KB         526    577   1,417us     478us     97us      572us    2,564us  55%
256 KB         1032   1101  7,101us     1,374us   372us     1,382us  10,231us 69%
512 KB         526    577   1,415us     483us     97us      1,599us  3,595us  39%
1 MB           1032   1101  6,176us     1,359us   366us     3,853us  11,756us 53%
4 MB           2070   2170  37,194us    3,338us   1,477us   19,339us 61,350us 61%
10 MB          2565   2673  63,576us    4,986us   2,332us   44,612us 115,507us 55%
```


## Root Cause Analysis

### Problem 1: Apply phase -- scattered symbol allocations (44.6ms at 10 MB)

Every Symbol is an independent heap allocation:

```
d[i] = try Symbol.init(allocator, sym_size);  // malloc per symbol
```

For L=2673, T=4096: 2673 separate 4KB allocations scattered across the heap.
The apply phase executes ~20,000 XOR/FMA operations bouncing between random
memory addresses. Cache misses dominate.

Rust allocates one contiguous buffer of L*T bytes. Sequential access pattern.

Impact estimate:
  - Apply touches ~20,000 * 4096 * 2 = ~160 MB of data
  - At 44.6ms, effective bandwidth = ~3.6 GB/s (DDR4 peak: ~25 GB/s)
  - With contiguous buffer: expect 10-15 GB/s = 3-4x speedup on apply phase

### Problem 2: Phase 1 -- brute-force row scanning (63.6ms at 10 MB)

Every Phase 1 iteration does:

```
selectPivotRow:    scan ALL remaining rows, popcount each     O(R * W)
graphSubstep:      re-scan ALL remaining rows for r==2        O(R * W) [again]
                   scan AGAIN to find row touching target_col O(R * W) [third time]
eliminateColumn:   scan remaining rows for bit in pivot col   O(R)
```

Where R = remaining rows (~2600), W = words_per_row (42 u64s).
Three full matrix scans per r=2 iteration. Over ~2569 iterations with r=2
being the common LDPC case, that's ~7,700 full scans.

Rust avoids this with:
  - Incremental degree tracking: degree[row] updated on XOR, O(1) per affected row
  - Columnar index: cols_to_rows[col] -> set of rows with a 1 in that column
    eliminateColumn iterates only affected rows
    graphSubstep reads edges directly from columnar index

This transforms Phase 1 from O(L^2 * W) to O(L * avg_nonzeros).

### Problem 3: Physical row swaps in DenseBinaryMatrix

swapRows copies words_per_row u64s (42 words for L=2673). Called on every
Phase 1 iteration plus Phase 2 pivoting.

Rust uses logical row indirection: swap(index[r1], index[r2]) = two u32 swaps.

### Problem 4: Redundant OctetMatrix during constraint matrix build

buildConstraintMatrix creates a full L*L OctetMatrix (1 byte/entry = 7.1 MB at L=2673).
SolverState.init then extracts binary rows into DenseBinaryMatrix element-by-element:

```zig
while (row < hdpc_start) : (row += 1) {
    while (col < l) : (col += 1) {
        if (!a.get(row, col).isZero()) {
            binary.set(row, col, true);
        }
    }
}
```

This means: allocate 7.1 MB, fill it, allocate 0.9 MB (bit-packed), copy element
by element, then free the 7.1 MB. For L=2673, the copy loop touches 2650 * 2673
= 7 million elements.

Fix: build DenseBinaryMatrix directly in constraint_matrix.zig. Only the H
HDPC rows (~20 rows) need the OctetMatrix representation.

### Problem 5: 128-bit SIMD for symbol XOR/FMA

octets.zig processes 16 bytes at a time:

```zig
while (i + 16 <= dst.len) : (i += 16) {
    const s: @Vector(16, u8) = src[i..][0..16].*;
    const d: @Vector(16, u8) = dst[i..][0..16].*;
    dst[i..][0..16].* = d ^ s;
}
```

On x86_64 with AVX2, 32-byte (256-bit) vectors are available. For pure XOR
(addAssign), we should use @Vector(32, u8). For FMA with VPSHUFB (AVX2),
the split-nibble technique works at 256-bit width.

This doubles SIMD throughput for all symbol operations.


## Implementation Items

### Item 1: Contiguous symbol buffer [DONE]

Replace per-symbol allocations with a single contiguous buffer.

New type: SymbolBuffer in codec/symbol.zig (or new file if needed).

```
SymbolBuffer {
    data: []align(64) u8,   // L * T bytes, cache-line aligned
    symbol_size: usize,
    count: usize,
}
```

Row access: `buf.data[row * T .. (row+1) * T]`

Changes needed:
  - Add SymbolBuffer type with init/deinit/get/addAssign/fma/mulAssign/swap
  - pi_solver.solve takes SymbolBuffer instead of []Symbol
  - OperationVector.apply takes SymbolBuffer instead of []Symbol
  - encoder.zig SourceBlockEncoder uses SymbolBuffer for D vector
  - decoder.zig SourceBlockDecoder uses SymbolBuffer for D vector
  - ltEncode uses SymbolBuffer for intermediate symbol reads

### Item 2: Incremental degree tracking [DONE] (columnar index deferred)

Add to SolverState:

```
col_index: []std.ArrayList(u32),  // col_index[c] = list of rows with a 1 in col c
row_degree: []u16,                // row_degree[r] = number of 1s in V range for row r
```

Maintained incrementally:
  - On eliminateColumn(col): for each row in col_index[col], decrement row_degree[row]
  - On xorRowRange(src, dst): update col_index entries and row_degree[dst]
  - On swapCols(c1, c2): swap col_index[c1] and col_index[c2]

selectPivotRow scans row_degree[] (O(R) u16 comparisons, no popcount).
graphSubstep reads col_index to build edges directly.
eliminateColumn iterates col_index[col] instead of scanning all rows.

### Item 3: Logical row indirection [DONE]

Add to SolverState:

```
logical_to_physical: []u32,  // logical row i maps to physical row logical_to_physical[i]
physical_to_logical: []u32,  // inverse mapping
```

All matrix access goes through indirection:
  - binary.get(logical_to_physical[row], col)
  - swapRows becomes: swap logical_to_physical entries + swap physical_to_logical entries

DenseBinaryMatrix methods that take row indices now receive physical indices.
The indirection is applied at the SolverState level.

### Item 4: Direct binary matrix construction [DONE]

Split buildConstraintMatrix into two functions:

```
buildBinaryConstraintMatrix(allocator, k_prime) -> DenseBinaryMatrix
buildHDPCMatrix(allocator, k_prime) -> OctetMatrix  // H rows x L cols
```

LDPC and LT rows write directly into DenseBinaryMatrix via set().
HDPC rows write into a small H x L OctetMatrix.

The full L x L OctetMatrix is never created.

Changes:
  - constraint_matrix.zig: add buildBinaryConstraintMatrix, buildHDPCMatrix
  - pi_solver.zig: SolverState.init takes both matrices directly
  - encoder.zig / decoder.zig: call the new construction functions

### Item 5: Widen SIMD to 256-bit (AVX2)

In octets.zig:
  - addAssign: use @Vector(32, u8) when AVX2 is available
  - fmaSlice: use @Vector(32, u8) with VPSHUFB for split-nibble multiply
  - mulAssignScalar: same treatment

Detection: check for .avx2 in builtin.cpu.features on x86_64.
Fallback: keep existing 128-bit path for non-AVX2 targets.

In gf2.zig:
  - xorSlice / xorSliceFrom: use @Vector(4, u64) = 256-bit for u64 XOR
  - Already benefits from auto-vectorization, but explicit vectors help

Expected impact: 1.5-2x on symbol operations (smaller than other items
because symbol ops are partly memory-bandwidth limited).
