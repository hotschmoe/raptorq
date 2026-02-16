const std = @import("std");
const raptorq = @import("raptorq");
const Octet = raptorq.octet.Octet;

test "GF(256) addition is commutative" {
    // TODO: implement
    // For random a, b: a + b == b + a
}

test "GF(256) addition is associative" {
    // TODO: implement
    // For random a, b, c: (a + b) + c == a + (b + c)
}

test "GF(256) multiplication is commutative" {
    // TODO: implement
    // For random a, b: a * b == b * a
}

test "GF(256) multiplication is associative" {
    // TODO: implement
    // For random a, b, c: (a * b) * c == a * (b * c)
}

test "GF(256) distributivity" {
    // TODO: implement
    // For random a, b, c: a * (b + c) == a*b + a*c
}

test "GF(256) additive identity" {
    // TODO: implement
    // For all a: a + 0 == a
}

test "GF(256) multiplicative identity" {
    // TODO: implement
    // For all a: a * 1 == a
}

test "GF(256) additive inverse (self-inverse)" {
    // TODO: implement
    // In GF(256): a + a == 0 for all a
}

test "GF(256) multiplicative inverse" {
    // TODO: implement
    // For all non-zero a: a * a^(-1) == 1
}

test "GF(256) known multiplication values" {
    // TODO: implement
    // Spot-check specific products against RFC/reference
}

test "GF(256) exp/log table consistency" {
    // TODO: implement
    // OCT_EXP[OCT_LOG[x]] == x for x in 1..255
}

test "GF(256) division by self" {
    // TODO: implement
    // For all non-zero a: a / a == 1
}
