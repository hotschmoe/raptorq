// RFC 6330 Table 2 - Systematic indices conformance tests
// Verifies the 477-entry lookup table mapping K' -> (J, S, H, W) satisfies
// all structural constraints required by the RFC.

const std = @import("std");
const raptorq = @import("raptorq");
const sc = raptorq.systematic_constants;
const helpers = raptorq.helpers;

test "Table 2 spot checks - small K'" {
    // First few entries from RFC 6330 Table 2
    const e0 = sc.findSystematicIndex(10).?;
    try std.testing.expectEqual(@as(u32, 10), e0.k_prime);
    try std.testing.expectEqual(@as(u32, 254), e0.j);
    try std.testing.expectEqual(@as(u32, 7), e0.s);
    try std.testing.expectEqual(@as(u32, 10), e0.h);
    try std.testing.expectEqual(@as(u32, 17), e0.w);

    const e1 = sc.findSystematicIndex(12).?;
    try std.testing.expectEqual(@as(u32, 12), e1.k_prime);
    try std.testing.expectEqual(@as(u32, 630), e1.j);
    try std.testing.expectEqual(@as(u32, 7), e1.s);
    try std.testing.expectEqual(@as(u32, 10), e1.h);
    try std.testing.expectEqual(@as(u32, 19), e1.w);

    const e2 = sc.findSystematicIndex(18).?;
    try std.testing.expectEqual(@as(u32, 18), e2.k_prime);
    try std.testing.expectEqual(@as(u32, 682), e2.j);
    try std.testing.expectEqual(@as(u32, 11), e2.s);
    try std.testing.expectEqual(@as(u32, 10), e2.h);
    try std.testing.expectEqual(@as(u32, 29), e2.w);

    // Invalid K' returns null
    try std.testing.expect(sc.findSystematicIndex(11) == null);
    try std.testing.expect(sc.findSystematicIndex(0) == null);
    try std.testing.expect(sc.findSystematicIndex(99999) == null);
}

test "Table 2 spot checks - large K'" {
    // Last few entries from RFC 6330 Table 2
    const last = sc.findSystematicIndex(56403).?;
    try std.testing.expectEqual(@as(u32, 56403), last.k_prime);
    try std.testing.expectEqual(@as(u32, 471), last.j);
    try std.testing.expectEqual(@as(u32, 907), last.s);
    try std.testing.expectEqual(@as(u32, 16), last.h);
    try std.testing.expectEqual(@as(u32, 56951), last.w);

    const second_last = sc.findSystematicIndex(55843).?;
    try std.testing.expectEqual(@as(u32, 55843), second_last.k_prime);
    try std.testing.expectEqual(@as(u32, 963), second_last.j);
}

test "K' rounding via ceilKPrime" {
    // ceilKPrime(K) >= K and is a valid K' in Table 2
    try std.testing.expectEqual(@as(u32, 10), sc.ceilKPrime(1));
    try std.testing.expectEqual(@as(u32, 10), sc.ceilKPrime(10));
    try std.testing.expectEqual(@as(u32, 12), sc.ceilKPrime(11));
    try std.testing.expectEqual(@as(u32, 12), sc.ceilKPrime(12));
    try std.testing.expectEqual(@as(u32, 18), sc.ceilKPrime(13));
    try std.testing.expectEqual(@as(u32, 56403), sc.ceilKPrime(56403));

    // Every returned K' must be a valid table entry
    var k: u32 = 1;
    while (k <= 56403) : (k += 1) {
        const kp = sc.ceilKPrime(k);
        try std.testing.expect(kp >= k);
        try std.testing.expect(sc.findSystematicIndex(kp) != null);
    }
}

test "Parameter relationship L = K' + S + H" {
    for (sc.TABLE_2) |entry| {
        const l = sc.numIntermediateSymbols(entry.k_prime);
        try std.testing.expectEqual(entry.k_prime + entry.s + entry.h, l);
    }
}

test "W is prime for all entries" {
    for (sc.TABLE_2) |entry| {
        try std.testing.expect(helpers.isPrime(entry.w));
    }
}

test "P1 primality" {
    // P1 = smallest prime >= L - W, where L = K' + S + H
    for (sc.TABLE_2) |entry| {
        const l = entry.k_prime + entry.s + entry.h;
        const p = l - entry.w;
        const p1 = sc.numPISymbols(entry.k_prime);

        try std.testing.expect(helpers.isPrime(p1));
        try std.testing.expect(p1 >= p);
        // P1 is the smallest prime >= P
        if (p1 > p) {
            try std.testing.expect(!helpers.isPrime(p1 - 1));
        }
    }
}

test "Table 2 monotonicity" {
    // K' values must be strictly increasing
    var i: usize = 1;
    while (i < sc.TABLE_2.len) : (i += 1) {
        try std.testing.expect(sc.TABLE_2[i].k_prime > sc.TABLE_2[i - 1].k_prime);
    }

    // Exactly 477 entries
    try std.testing.expectEqual(@as(usize, 477), sc.TABLE_2.len);
}
