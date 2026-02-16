<!-- BEGIN:header -->
# CLAUDE.md

we love you, Claude! do your best today
<!-- END:header -->

<!-- BEGIN:rule-1-no-delete -->
## RULE 1 - NO DELETIONS (ARCHIVE INSTEAD)

You may NOT delete any file or directory. Instead, move deprecated files to `.archive/`.

**When you identify files that should be removed:**
1. Create `.archive/` directory if it doesn't exist
2. Move the file: `mv path/to/file .archive/`
3. Notify me: "Moved `path/to/file` to `.archive/` - deprecated because [reason]"

**Rules:**
- This applies to ALL files, including ones you just created (tests, tmp files, scripts, etc.)
- You do not get to decide that something is "safe" to delete
- The `.archive/` directory is gitignored - I will review and permanently delete when ready
- If `.archive/` doesn't exist and you can't create it, ask me before proceeding

**Only I can run actual delete commands** (`rm`, `git clean`, etc.) after reviewing `.archive/`.
<!-- END:rule-1-no-delete -->

<!-- BEGIN:irreversible-actions -->
### IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.
<!-- END:irreversible-actions -->

<!-- BEGIN:code-discipline -->
### Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.
- **NO EMOJIS** - do not use emojis or non-textual characters.
- ASCII diagrams are encouraged for visualizing flows.
- Keep in-line comments to a minimum. Use external documentation for complex logic.
- In-line commentary should be value-add, concise, and focused on info not easily gleaned from the code.
<!-- END:code-discipline -->

<!-- BEGIN:no-legacy -->
### No Legacy Code - Full Migrations Only

We optimize for clean architecture, not backwards compatibility. **When we refactor, we fully migrate.**

- No "compat shims", "v2" file clones, or deprecation wrappers
- When changing behavior, migrate ALL callers and remove old code **in the same commit**
- No `_legacy` suffixes, no `_old` prefixes, no "will remove later" comments
- New files are only for genuinely new domains that don't fit existing modules
- The bar for adding files is very high

**Rationale**: Legacy compatibility code creates technical debt that compounds. A clean break is always better than a gradual migration that never completes.
<!-- END:no-legacy -->

<!-- BEGIN:dev-philosophy -->
## Development Philosophy

**Make it work, make it right, make it fast** - in that order.

**This codebase will outlive you** - every shortcut becomes someone else's burden. Patterns you establish will be copied. Corners you cut will be cut again.

**Fight entropy** - leave the codebase better than you found it.

**Inspiration vs. Recreation** - take the opportunity to explore unconventional or new ways to accomplish tasks. Do not be afraid to challenge assumptions or propose new ideas. BUT we also do not want to reinvent the wheel for the sake of it. If there is a well-established pattern or library take inspiration from it and make it your own. (or suggest it for inclusion in the codebase)
<!-- END:dev-philosophy -->

<!-- BEGIN:testing-philosophy -->
## Testing Philosophy: Diagnostics, Not Verdicts

**Tests are diagnostic tools, not success criteria.** A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

**When a test fails, ask three questions in order:**
1. Is the test itself correct and valuable?
2. Does the test align with our current design vision?
3. Is the code actually broken?

Only if all three answers are "yes" should you fix the code.

**Why this matters:**
- Tests encode assumptions. Assumptions can be wrong or outdated.
- Changing code to pass a bad test makes the codebase worse, not better.
- Evolving projects explore new territory - legacy testing assumptions don't always apply.

**What tests ARE good for:**
- **Regression detection**: Did a refactor break dependent modules? Did API changes break integrations?
- **Sanity checks**: Does initialization complete? Do core operations succeed? Does the happy path work?
- **Behavior documentation**: Tests show what the code currently does, not necessarily what it should do.

**What tests are NOT:**
- A definition of correctness
- A measure of code quality
- Something to "make pass" at all costs
- A specification to code against

**The real success metric**: Does the code further our project's vision and goals?

### Running Tests

```bash
# Run all tests via build system (RECOMMENDED)
zig build test

# Run specific module tests (only if module has no external deps)
zig test src/root.zig
```
<!-- END:testing-philosophy -->

<!-- BEGIN:footer -->
---

we love you, Claude! do your best today
<!-- END:footer -->


---

## Project-Specific Content

### raptorq - Zig Implementation of RFC 6330

**raptorq is a Zig implementation of the RaptorQ forward error correction (FEC) scheme defined in RFC 6330.** RaptorQ is a fountain code that enables reliable data delivery over lossy channels by generating repair symbols from source data. A receiver can reconstruct the original data from any sufficiently large subset of encoding symbols.

#### RFC 6330 Overview

RaptorQ (technically "RaptorQ Forward Error Correction Scheme for Object Delivery") provides:

1. **Source block partitioning** - Divides transfer objects into source blocks and sub-blocks
2. **Intermediate symbol generation** - Solves a system of linear equations over GF(256) to produce intermediate symbols
3. **Encoding** - Generates encoding symbols (source + repair) from intermediate symbols using LT and PI codes
4. **Decoding** - Reconstructs source symbols from any K' received encoding symbols (where K' >= K)

Key parameters from the RFC:
- **K** - Number of source symbols in a source block
- **T** - Symbol size in octets
- **Z** - Number of source blocks
- **N** - Number of sub-blocks per source block
- **Al** - Symbol alignment (typically 4)

#### Architecture

Layered from foundations (Layer 0) to public API (Layer 6). See `docs/discovery/ARCHITECTURE.md` for full dependency diagram.

```
src/
  root.zig                          # Library entry point / public API re-exports
  tables/
    octet_tables.zig                # GF(256) exp/log tables (Layer 0)
    rng_tables.zig                  # PRNG V0..V3 tables (Layer 0)
    systematic_constants.zig        # RFC Table 2: K' -> J,S,H,W (Layer 0)
  math/
    octet.zig                       # GF(256) single-element arithmetic (Layer 1)
    octets.zig                      # Bulk GF(256) slice operations (Layer 1)
    gf2.zig                         # GF(2) binary bit operations (Layer 1)
    rng.zig                         # RFC 5.5 PRNG + tuple generation (Layer 1)
  codec/
    base.zig                        # PayloadId, OTI, partition (Layer 2)
    symbol.zig                      # Symbol with field arithmetic (Layer 2)
    operation_vector.zig            # Deferred symbol operations (Layer 2)
    encoder.zig                     # Encoder, SourceBlockEncoder (Layer 5)
    decoder.zig                     # Decoder, SourceBlockDecoder (Layer 5)
  matrix/
    dense_binary_matrix.zig         # Bit-packed u64 matrix (Layer 3)
    sparse_matrix.zig               # Hybrid sparse/dense (Layer 3)
    octet_matrix.zig                # Dense GF(256) matrix (Layer 3)
    constraint_matrix.zig           # RFC 5.3.3 construction (Layer 3)
  solver/
    pi_solver.zig                   # 5-phase inactivation decoding (Layer 4)
    graph.zig                       # Connected components (Layer 4)
  util/
    sparse_vec.zig                  # Sparse binary vector
    arraymap.zig                    # Specialized map types
    helpers.zig                     # intDivCeil, isPrime, etc.
```

#### Key Algorithms

- **Partition function** `partition[I, J]` - divides I items into J near-equal pieces
- **Degree distribution** - Table 1 maps random values to LT code degrees
- **Tuple generator** `Tuple[K', X]` - produces (d, a, b, d1, a1, b1) for encoding symbol generation
- **Constraint matrix construction** - builds the A matrix from LDPC, HDPC, LT, and PI sub-matrices
- **Inactivation decoding** - Gaussian elimination variant for solving A * C = D

#### Build and Test

```bash
zig build                  # Build library
zig build test             # Run unit tests
zig build test-conformance # Run conformance tests (RFC section coverage)

# Cross-compile
zig build -Dtarget=aarch64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
```

#### Dependencies

None. Pure Zig implementation with no external dependencies (by design -- RFC 6330 requires only GF(256) arithmetic and matrix operations).

#### Reference Materials

- [RFC 6330](https://www.rfc-editor.org/rfc/rfc6330) - RaptorQ Forward Error Correction Scheme for Object Delivery
- [RFC 5053](https://www.rfc-editor.org/rfc/rfc5053) - Raptor Forward Error Correction Scheme (predecessor)
