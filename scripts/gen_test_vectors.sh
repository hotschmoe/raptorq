#!/usr/bin/env bash
set -euo pipefail

# Generates golden test vectors from the Rust reference implementation.
# Requires: cargo, rust toolchain
# Output: test/fixtures/*.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REFERENCE_DIR="$PROJECT_DIR/test/fixtures/raptorq-reference"
OUTPUT_DIR="$PROJECT_DIR/test/fixtures"

if [ ! -d "$REFERENCE_DIR" ]; then
    echo "Reference submodule not found. Run: git submodule update --init"
    exit 1
fi

echo "TODO: Add Rust test vector generation commands"
echo "Reference project: $REFERENCE_DIR"
echo "Output directory: $OUTPUT_DIR"
