const std = @import("std");
const raptorq = @import("raptorq");
const base = raptorq.base;

test "PayloadId serialization roundtrip" {
    // TODO: implement
    // serialize then deserialize yields original
}

test "PayloadId wire format" {
    // TODO: implement
    // Verify 4-byte big-endian layout per RFC
}

test "ObjectTransmissionInformation serialization roundtrip" {
    // TODO: implement
}

test "ObjectTransmissionInformation wire format" {
    // TODO: implement
    // Verify 12-byte layout per RFC
}

test "Partition function basic" {
    // TODO: implement
    // partition(12, 5) yields correct (IL, IS, JL, JS)
}

test "Partition function edge cases" {
    // TODO: implement
    // partition(0, 1), partition(1, 1), partition(n, n)
}

test "Partition function covers all items" {
    // TODO: implement
    // JL * IL + JS * IS == I for various (I, J)
}
