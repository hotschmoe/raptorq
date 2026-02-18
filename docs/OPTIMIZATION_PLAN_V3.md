# Optimization Plan V3: Closing the Rust Gap

Date: 2026-02-18
Baseline: commit b17f98b (dev-hotschmoe), all V2 items complete
Target: Match cberner/raptorq v2.0 throughput (speed parity)
Status: **ALL ITEMS IMPLEMENTED** (2026-02-17)

## Correction: V2 Plan Was Wrong About Rust's Approach

V2 stated "Rust's PI solver applies symbol operations inline during elimination."
This is **incorrect**. Rust also uses fully deferred symbol operations -- a
`Vec<SymbolOps>` recorded during phases 1-5 and replayed at the end via
`apply_deferred_symbol_ops()`. Both codebases share the same deferred
architecture.

The real performance gap comes from structural differences in Phase 1 data
structures and algorithmic shortcuts (errata optimizations), not from the
apply phase architecture.

## Current State (V2 Complete)

```
Size     | T    | Zig Enc | Rust Enc | Gap   | Zig Dec | Rust Dec | Gap
---------|------|---------|----------|-------|---------|----------|-----
10 KB    | 64   |    12.0 |     21.4 |  1.8x |     7.5 |     25.5 |  3.4x
64 KB    | 64   |     6.9 |     22.2 |  3.2x |     4.7 |     25.4 |  5.4x
1 MB     | 1024 |    76.9 |    236.3 |  3.1x |    56.4 |    252.3 |  4.5x
10 MB    | 4096 |   113.3 |    312.1 |  2.8x |    89.6 |    300.2 |  3.4x
                                                         (MB/s -- higher is better)
```

Solver breakdown at 10 MB:
```
Phase 1 (elimination):  20.3ms  27%
Apply (symbol ops):     44.5ms  60%
Phase 2:                 5.3ms   7%
Phase 3:                 4.1ms   6%
Total:                  74.2ms        Rust total: ~32ms
```

## Verified Gaps: Zig vs cberner/raptorq

Source: direct analysis of cberner/raptorq Rust source (src/sparse_matrix.rs,
src/pi_solver.rs, src/encoder.rs, src/arraymap.rs, src/sparse_vec.rs).

### Gap 1: SparseBinaryMatrix with Progressive Densification [IMPLEMENTED]

Rust uses a hybrid sparse/dense matrix for K' >= 250 (SPARSE_MATRIX_THRESHOLD):

```
SparseBinaryMatrix {
    sparse_elements: Vec<SparseBinaryVec>,  // sorted Vec<u16> per row (V columns)
    dense_elements: Vec<u64>,               // bit-packed, right-aligned (U columns)
    num_dense_columns: usize,               // V/U boundary
    logical_col_to_physical: Vec<u16>,
    physical_col_to_logical: Vec<u16>,
    logical_row_to_physical: Vec<u32>,
    physical_row_to_logical: Vec<u32>,
    sparse_columnar_values: Option<ImmutableListMap>,  // columnar index
}
```

As Phase 1 inactivates columns (V -> U), `hint_column_dense_and_frozen()`
migrates them from sorted-u16 sparse to bit-packed dense representation.

Zig: pure `DenseBinaryMatrix` for all sizes. Every operation scans ceil(L/64)
words even when rows have 3 nonzeros (LDPC) or ~20 nonzeros (LT).

### Gap 2: O(1) Column Swaps via Column Indirection [IMPLEMENTED]

Rust: `logical_col_to_physical`/`physical_col_to_logical` arrays (u16).
Column swaps are two u16 swaps -- O(1). No data movement.

Zig: `swapCols()` iterates ALL physical binary rows (O(L-H) bit swaps per
row) plus ALL HDPC rows (O(H) byte swaps). Total per swap: O(L).
Phase 1 performs O(L) column swaps => O(L^2) total.

At K'=2565 (10 MB): each swap touches 2673 rows. ~2600 swaps total.

### Gap 3: Columnar Index (ImmutableListMap) [IMPLEMENTED]

Rust builds a CSC-like index before Phase 1:

```
ImmutableListMap {
    offsets: Vec<u32>,  // offsets[col] -> start in values
    values: Vec<u32>,   // physical row indices with 1s in that column
}
```

O(1) lookup: `values[offsets[col]..offsets[col+1]]` gives all rows with a 1
in the given column. Used by:
- `eliminateColumn`: iterate only affected rows (O(nnz) vs O(L))
- `inactivateColumn`: decrement v_degree for only affected rows (O(nnz) vs O(L))
- `hint_column_dense_and_frozen`: find rows to migrate (O(nnz) vs O(L))

Built once after constraint matrix construction, freed after Phase 1.

Zig: no columnar index. Both `eliminateColumn` and `inactivateColumn` scan
all rows [i, hdpc_start) checking each bit individually.

### Gap 4: Partial Row Operations (Errata 11) [IMPLEMENTED]

During Phase 1 elimination, Rust only XORs the U (dense) section:

```rust
// Release builds: skip V section, only update U
self.fma_rows(temp, row, Octet::one(), self.A.width() - (self.u + (r - 1)));
```

Why this works: after swapping the pivot column to position i and the r-1
extra nonzero columns to the U boundary, the pivot row has exactly one nonzero
in V (column i, being zeroed) and zeros everywhere else in V. XORing zeros
is a no-op that wastes cycles scanning words.

Rust records Phase 1 row ops as `Vec<RowOp>` and replays them:
- Forward in Phase 5 (on symbol data only, no matrix update)
- Reversed in Phase 3 (back-substitution on U section)

Zig: `binaryXorRowRange(src, dst, col)` XORs from column i through the end,
scanning the entire V+U region even though V bits in the pivot row are zero.

### Gap 5: Degree Histogram + r=1 Fast Path [IMPLEMENTED]

Rust maintains:
- `ones_histogram[degree]`: count of rows with each degree value
- `rows_with_single_one: Vec<usize>`: fast path for the common r=1 case

Finding minimum r: scan histogram from degree 1 upward (typically O(1) since
degree-1 rows are very common during Phase 1).

Zig: `selectPivotRow` linearly scans all v_degree[i..hdpc_start] to find the
minimum. O(L-H-i) per iteration, ~2600 comparisons per iteration at K'=2565.

### Gap 6: Encoding Plan Caching [IMPLEMENTED]

Rust pre-computes the operation vector with 1-byte dummy symbols:

```rust
SourceBlockEncodingPlan::generate(symbol_count) {
    let symbols = vec![Symbol::new(vec![0]); symbol_count];
    let (_, ops) = gen_intermediate_symbols(&symbols, 1, threshold);
    // ops is cached and replayed for actual data
}
```

The solver runs once with trivial 1-byte symbols (fast), then the recorded ops
are replayed on real data (just XOR/FMA on symbol buffers, no matrix work).

Zig: runs the full solver with actual full-size symbols every time.

### Gap 7: In-Place Reorder [IMPLEMENTED]

Rust: symbols are `Vec<Symbol>` where each Symbol wraps a `Vec<u8>`. Reorder
ops are O(1) pointer swaps per symbol.

Zig: `applyAndRemap` allocates a second SymbolBuffer(L, T), copies all symbols
to reorder, then copies back. At 10 MB: 2 x 10.9 MB memcpy.

---

## Implementation Plan

### Item 1: SparseBinaryMatrix + Column Indirection + Columnar Index [DONE]
**Gaps addressed: 1, 2, 3**
**Expected impact: Phase 1 time reduced 3-5x for K' >= 250**

New `src/matrix/sparse_binary_matrix.zig` implementing a hybrid representation:

```
SparseBinaryMatrix
    sparse_rows: []SparseBinaryVec     // sorted u16 arrays (V columns)
    dense_words: []u64                 // bit-packed, right-aligned (U columns)
    words_per_row: u32                 // dense section width in words
    num_dense_cols: u32                // grows as columns freeze
    height, width: u32
    log_col_to_phys: []u16
    phys_col_to_log: []u16
    columnar_index: ?ColumnarIndex     // ImmutableListMap equivalent
```

Where SparseBinaryVec is a sorted `[]u16` (column indices where value = 1).

Key operations and their costs (vs DenseBinaryMatrix):

```
Operation           Dense O(...)      Sparse O(...)
-----------------------------------------------------
Column swap         O(L)              O(1) indirection
Row get(col)        O(1)              O(log nnz) binary search
Row XOR (full)      O(L/64)           O(nnz_src + nnz_dst) merge
Row XOR (U only)    O(u/64)           O(u/64) dense words only
count_ones(V)       O(L/64)           O(nnz) filter by range
Column lookup       O(L) scan         O(nnz) via columnar index
Densify column      N/A               O(nnz) via columnar index
```

Implementation steps:
1. SparseBinaryVec: sorted u16 vector with insert, remove, add_assign (XOR)
2. ColumnarIndex: flat CSC structure (offsets[] + values[])
3. SparseBinaryMatrix: hybrid sparse/dense with row+column indirection
4. Progressive densification: hint_column_dense_and_frozen()
5. Trait/interface: SolverState uses SparseBinaryMatrix for K' >= 250,
   DenseBinaryMatrix for K' < 250
6. Update constraint_matrix.zig to build sparse format
7. Update pi_solver.zig SolverState to work with new matrix type

The columnar index is built once via `enableColumnAcceleration()` before
Phase 1 and freed via `disableColumnAcceleration()` after Phase 1.

### Item 2: Partial Row Operations (Errata 11) [DONE]
**Gap addressed: 4**
**Expected impact: Phase 1 XOR bandwidth reduced ~50%**
**Dependency: compounds with Item 1 (sparse section skipped entirely)**

During Phase 1 elimination, only XOR the U section (dense columns). The V
section of the pivot row has only one nonzero (column i, being zeroed), so
XORing it into other rows is wasted work except for that one bit.

Changes:
1. In `eliminateColumn`, clear column i in target rows directly (single bit
   set/clear), then XOR only U-section words of the pivot row.
2. Record Phase 1 row ops as `[]RowOp` (separate from deferred symbol ops).
3. In Phase 3: replay recorded row ops reversed on the matrix.
4. In Phase 5: replay recorded row ops forward (symbol ops only, no matrix
   update in release mode).

With Item 1's sparse matrix: `add_assign_rows(start_col=boundary)` naturally
skips the sparse section and only XORs dense words. Without Item 1: implement
a two-range XOR (bit i + U section).

### Item 3: Degree Histogram + r=1 Fast Path [DONE]
**Gap addressed: 5**
**Expected impact: selectPivotRow reduced from O(L) to O(1) typical**

Add to SolverState:
```
degree_histogram: []u32     // degree_histogram[d] = count of rows with v_degree == d
rows_with_one: ArrayList(u32)  // rows where v_degree == 1
```

Maintain incrementally:
- On v_degree change: decrement old bucket, increment new bucket
- On v_degree becoming 1: append to rows_with_one
- On v_degree leaving 1: (lazy cleanup -- scan and skip stale entries)

selectPivotRow becomes:
```
for d in 1..max_degree:
    if degree_histogram[d] > 0:
        min_r = d
        break
if min_r == 1:
    scan rows_with_one for best original_degree
```

### Item 4: Encoding Plan Caching [DONE]
**Gap addressed: 6**
**Expected impact: encoding throughput boost (solver runs once, plan replayed)**

New `EncodingPlan` struct:
```
EncodingPlan {
    ops: []SymbolOp       // recorded from dummy solve
    source_symbol_count: u16
}

fn generate(allocator, k: u16) -> EncodingPlan {
    // Build D vector with 1-byte symbols
    // Build constraint matrix
    // Run solver (fast -- 1-byte XOR/FMA)
    // Return captured ops
}

fn apply(plan, buf: *SymbolBuffer) void {
    for (plan.ops) |op| { ... apply to buf ... }
}
```

SourceBlockEncoder gains an optional plan parameter. Encoder caches plans
by K value across source blocks.

### Item 5: In-Place Reorder via Cycle Decomposition [DONE]
**Gap addressed: 7**
**Expected impact: saves ~2ms at 10 MB (2x memcpy eliminated)**

Replace the double-buffer copy in `applyAndRemap` with a cycle-walk permutation:

```
// Build permutation: perm[j] = d[j] for the source, c[j] for the dest
// Walk cycles: for each unvisited j, follow the permutation chain,
// rotating symbols through a single temp buffer.
var temp: [symbol_size]u8;
for j in 0..L:
    if visited[j]: continue
    copy buf[perm[j]] -> temp
    k = j
    while perm[k] != j:
        copy buf[perm[perm[k]]] -> buf[perm[k]]
        visited[perm[k]] = true
        k = perm[k]
    copy temp -> buf[perm[j]]
```

This uses O(T) temp space instead of O(L*T), and each symbol is copied exactly
once instead of twice.

---

## Priority and Dependencies

```
Phase A (highest impact, do first):
    Item 1: SparseBinaryMatrix + col indirection + columnar index
    Item 3: Degree histogram (can be done independently in parallel)

Phase B (medium impact, after Phase A):
    Item 2: Partial row ops / Errata 11 (benefits from Item 1's sparse/dense split)
    Item 4: Encoding plan caching (independent)

Phase C (small wins):
    Item 5: In-place reorder (independent, easy)
```

Item 1 is the critical path. It addresses three gaps simultaneously and
enables Item 2 to reach full effectiveness. Item 3 is independent and can
be implemented before, during, or after Item 1.

## Expected Outcome

Conservative estimates assuming Item 1 reduces Phase 1 by 3x and Items 2-5
provide incremental gains:

```
Component          Current    After V3    Savings
Phase 1            20.3ms     ~5-7ms      ~13-15ms
Apply              44.5ms     ~40-42ms    ~2-4ms (Items 5, marginal)
Phase 2             5.3ms     ~5ms        ~0.3ms
Phase 3             4.1ms     ~3-4ms      ~0.5-1ms
Total              74.2ms     ~55-58ms    ~16-19ms
```

For encoding specifically, Item 4 (plan caching) is a multiplier: the solver
runs once with 1-byte symbols (~1ms), then replay is pure symbol XOR/FMA
without any matrix work. This should match Rust's encoding throughput.

Remaining gap after V3: the apply phase at 60% is fundamentally
memory-bandwidth-limited by random L3 access. Both Zig and Rust have this
cost. Rust may be faster here due to smaller overhead per op or better
compiler optimization of the inner loop. Further investigation needed after
V3 items are complete.
