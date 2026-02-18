# Optimization Plan V2: Closing the Rust Gap

Date: 2026-02-17
Baseline: commit 9e9b5a3 (dev-hotschmoe)
Target: Match or beat cberner/raptorq v2.0 throughput

## Implementation Status

| Item | Description                          | Status |
|------|--------------------------------------|--------|
| 1    | Contiguous SymbolBuffer              | DONE   |
| 2    | Incremental v_degree tracking        | DONE   |
| 3    | Logical row indirection              | DONE   |
| 4    | Direct binary matrix construction    | DONE   |
| 5    | Widen SIMD / optimize vector paths   | DONE   |

All items complete. Items 1-4 reduced gap from ~5-6x to ~2.5-4x.
Item 5 added AVX2 256-bit paths + 2x16 unrolled SSSE3 fallbacks + explicit
128-bit GF(2) vectors + SIMD symbol swap.

## Current Benchmark Results

Both benchmarks: identical parameters, same data sizes, symbol sizes, 10% loss,
median of 11 iterations (5 for >=1MB), ReleaseFast / --release.
Machine: QEMU x86_64 with SSSE3 (no AVX2).

```
Size     | T    | Zig Enc | Rust Enc | Gap   | Zig Dec | Rust Dec | Gap
---------|------|---------|----------|-------|---------|----------|-----
256 B    | 64   |     2.9 |      9.2 |  3.2x |     2.3 |     11.3 |  4.9x
1 KB     | 64   |     8.0 |     22.1 |  2.8x |     5.7 |     25.6 |  4.5x
10 KB    | 64   |    12.0 |     21.4 |  1.8x |     7.5 |     25.5 |  3.4x
16 KB    | 64   |    11.1 |     24.0 |  2.2x |     7.4 |     26.9 |  3.6x
64 KB    | 64   |     6.9 |     22.2 |  3.2x |     4.7 |     25.4 |  5.4x
128 KB   | 256  |    33.7 |     85.3 |  2.5x |    23.6 |     96.8 |  4.1x
256 KB   | 256  |    23.6 |     81.4 |  3.4x |    18.4 |     91.4 |  5.0x
512 KB   | 1024 |    95.5 |    244.6 |  2.6x |    71.3 |    264.0 |  3.7x
1 MB     | 1024 |    76.9 |    236.3 |  3.1x |    56.4 |    252.3 |  4.5x
2 MB     | 2048 |   127.1 |    341.1 |  2.7x |    93.6 |    281.3 |  3.0x
4 MB     | 2048 |    91.7 |    277.8 |  3.0x |    72.5 |    249.8 |  3.4x
10 MB    | 4096 |   113.3 |    312.1 |  2.8x |    89.6 |    300.2 |  3.4x
                                                          (MB/s -- higher is better)
```

Encode gap: 1.8x - 3.4x (avg ~2.7x). Decode gap: 3.0x - 5.4x (avg ~4.0x).


## Profiler Breakdown (10 MB encode, single pass)

```
Component              Time (ms)   % of Total
---------------------------------------------------------------
Phase 1 (elimination)    20.3       27%
Apply (symbol ops)       44.5       60%
Phase 2                   5.3        7%
Phase 3                   4.1        6%
---------------------------------------------------------------
Solver total             74.2      100%         Rust total: ~32ms

Encoder.init total       82.0                   (includes matrix build)
Symbol generation         8.2
Encoder total            90.2
```

Full profiler output across sizes:

```
Case           K'     L     Phase1      Phase2    Phase3    Apply    Total    P1%    Apply%
1 KB           18     39    25us        30us      0us       16us     72us     35%    22%
10 KB          160    193   212us       180us     19us      95us     507us    42%    19%
64 KB          1032   1101  3,633us     1,488us   516us     569us    6,207us  59%     9%
128 KB         526    577   1,152us     516us     134us     494us    2,298us  50%    21%
256 KB         1032   1101  3,705us     1,512us   510us     1,172us  6,900us  54%    17%
512 KB         526    577   1,146us     500us     129us     1,472us  3,249us  35%    45%
1 MB           1032   1101  3,563us     1,462us   512us     3,328us  8,866us  40%    38%
4 MB           2070   2170  13,438us    3,527us   2,566us   14,990us 34,522us 39%    43%
10 MB          2565   2673  20,257us    5,279us   4,136us   44,537us 74,210us 27%    60%
```


## Progression Summary

```
Version     | 10 MB Enc | 10 MB Dec | Enc Gap | Dec Gap
------------|-----------|-----------|---------|--------
Baseline    |    ~20    |    ~20    |  ~16x   |  ~15x
Items 1-4   |     67    |     64    |   4.8x  |   4.8x
Item 5      |    113    |     90    |   2.8x  |   3.4x
Rust ref    |    312    |    300    |    --   |    --
```

## Remaining Gap Analysis

With all 5 items complete, the gap is ~2.8x encode / ~3.4x decode. Both Zig and
Rust run with SSSE3 (128-bit SIMD) on this machine -- the gap is NOT about SIMD
width. The remaining difference is algorithmic/structural.


## Next Investigation: Apply Phase Memory Access Pattern

The apply phase is now the dominant bottleneck: 60% of solver time at 10 MB
(44.5ms out of 74.2ms). It runs ~20,000 XOR/FMA operations on 4096-byte symbols
stored in a 10.9 MB contiguous SymbolBuffer.

### The problem

Each operation touches a (src, dst) pair of symbol rows. The OperationVector
records operations in solver execution order, which means row access is
essentially random across the buffer. For L=2673, T=4096:

```
SymbolBuffer: 2673 * 4096 = 10.9 MB (fits L3, not L2)
Each op: read src row (4 KB) + read/write dst row (4 KB) = 8 KB touched
~20,000 ops * 8 KB = ~160 MB total memory traffic
Effective bandwidth: 160 MB / 44.5ms = ~3.6 GB/s
DDR4 theoretical: ~25 GB/s
L3 sequential read: ~15 GB/s
```

We're at ~24% of L3 bandwidth. The gap is cache miss latency from the random
access pattern -- each op likely evicts cache lines that a later op will need.

### What Rust does differently

Rust's PI solver applies symbol operations inline during elimination rather than
recording them for deferred application. This means the symbol data for the
current pivot row and elimination targets is likely still hot in cache when the
XOR happens.

Our deferred OperationVector approach means ALL elimination ops are batched and
replayed after the entire PI solve completes. By then, no symbol data is in
cache.

### Potential approaches

1. **Inline symbol ops during solve** (match Rust's approach)
   - Apply XOR/FMA immediately during eliminateColumn instead of recording
   - Pros: symbol data is cache-hot, eliminates OperationVector overhead
   - Cons: couples solver to symbol buffer, increases solve() complexity
   - Expected impact: large -- eliminates the random replay entirely

2. **Operation reordering for locality**
   - Sort/group operations by dst row to improve temporal locality
   - Same dst row accessed by consecutive ops stays in L1/L2
   - Pros: keeps deferred approach, simpler change
   - Cons: sorting has overhead, may not help if src rows are still random

3. **Software prefetching**
   - Prefetch next operation's src/dst rows while processing current op
   - `@prefetch(buf.get(next_src), .{ .locality = 1 })`
   - Pros: hides latency, minimal code change
   - Cons: limited win if access pattern is truly random (prefetch queue depth)

4. **Cache-blocked replay**
   - Partition operations into blocks where all referenced rows fit in L2
   - Process each block completely before moving to next
   - Pros: maximizes cache reuse within each block
   - Cons: complex implementation, operations may have dependencies

### Recommended approach

Option 1 (inline symbol ops) is the highest-impact change and matches what Rust
does. The deferred OperationVector was a design choice for separation of concerns
but it creates the exact access pattern problem we're seeing. Inlining would let
us leverage the solver's natural locality: during eliminateColumn, the pivot row
and each target row are accessed in sequence, and the pivot row stays hot across
all targets in that column.

### Phase 1 (secondary)

Phase 1 is 50-60% at mid-range K' (1032). The columnar index (deferred from
Item 2) would let eliminateColumn iterate only affected rows instead of scanning
all rows.

### Decode overhead (tertiary)

Decode consistently ~1.3x slower than encode at same data size. Worth profiling
the decoder separately to identify decode-specific bottlenecks.
