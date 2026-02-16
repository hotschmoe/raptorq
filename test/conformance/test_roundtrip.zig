const std = @import("std");
const raptorq = @import("raptorq");

test "Roundtrip small data (100 bytes)" {
    // TODO: implement
    // Encode, decode all source symbols, verify
}

test "Roundtrip medium data (10KB)" {
    // TODO: implement
}

test "Roundtrip large data (1MB)" {
    // TODO: implement
}

test "Roundtrip with 10% symbol loss" {
    // TODO: implement
    // Drop 10% of source symbols, add repair, decode
}

test "Roundtrip with 50% symbol loss" {
    // TODO: implement
    // Drop 50% of source symbols, add repair, decode
}

test "Roundtrip with padding" {
    // TODO: implement
    // Data size not evenly divisible by symbol size
}

test "Roundtrip multi-block" {
    // TODO: implement
    // Data spanning multiple source blocks
}

test "Roundtrip various symbol sizes" {
    // TODO: implement
    // Test with T = 4, 64, 256, 1024
}
