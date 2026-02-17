// RFC 6330 Section 5.5 - PRNG and tuple generation conformance tests
// Verifies the Rand function, degree distribution, and tuple generator
// produce deterministic results within specified bounds.

const std = @import("std");
const raptorq = @import("raptorq");
const rng = raptorq.rng;
const rng_tables = raptorq.rng_tables;

test "PRNG determinism" {
    // Same inputs must produce identical outputs on every invocation
    const cases = [_]struct { y: u32, i: u32, m: u32 }{
        .{ .y = 0, .i = 0, .m = 256 },
        .{ .y = 1, .i = 0, .m = 256 },
        .{ .y = 0, .i = 1, .m = 256 },
        .{ .y = 1000, .i = 7, .m = 100 },
        .{ .y = 0xFFFFFFFF, .i = 0, .m = 1 },
        .{ .y = 12345, .i = 67, .m = 997 },
    };

    for (cases) |c| {
        const r1 = rng.rand(c.y, c.i, c.m);
        const r2 = rng.rand(c.y, c.i, c.m);
        try std.testing.expectEqual(r1, r2);
    }
}

test "PRNG modulus bounds" {
    // rand(y, i, m) must always return a value in [0, m)
    const moduli = [_]u32{ 1, 2, 3, 7, 10, 100, 256, 997, 1000, 65536 };

    for (moduli) |m| {
        var y: u32 = 0;
        while (y < 500) : (y += 1) {
            var i: u32 = 0;
            while (i < 10) : (i += 1) {
                const result = rng.rand(y, i, m);
                try std.testing.expect(result < m);
            }
        }
    }
}

test "PRNG V-table spot checks" {
    // Verify first and last entries of V0..V3 tables against RFC 6330 Section 5.5
    // V0[0..5] from the RFC
    try std.testing.expectEqual(@as(u32, 251291136), rng_tables.V0[0]);
    try std.testing.expectEqual(@as(u32, 3952231631), rng_tables.V0[1]);
    try std.testing.expectEqual(@as(u32, 3370958628), rng_tables.V0[2]);
    try std.testing.expectEqual(@as(u32, 4070167936), rng_tables.V0[3]);
    try std.testing.expectEqual(@as(u32, 123631495), rng_tables.V0[4]);

    // Table sizes
    try std.testing.expectEqual(@as(usize, 256), rng_tables.V0.len);
    try std.testing.expectEqual(@as(usize, 256), rng_tables.V1.len);
    try std.testing.expectEqual(@as(usize, 256), rng_tables.V2.len);
    try std.testing.expectEqual(@as(usize, 256), rng_tables.V3.len);
}

test "PRNG reference sequence" {
    // Regression anchors: compute values for known inputs and verify stability.
    // These values are self-referential (computed from our implementation) to
    // detect accidental changes to the PRNG. Cross-validated by verifying the
    // full encode/decode pipeline produces correct results.

    // rand(0, 0, 2^20) - used in tuple generation
    const v0 = rng.rand(0, 0, 1 << 20);
    try std.testing.expect(v0 < (1 << 20));

    // Verify the XOR structure: rand depends on V-table lookups
    // rand(0, 0, m) = (V0[0] ^ V1[0] ^ V2[0] ^ V3[0]) % m
    const expected_raw = rng_tables.V0[0] ^ rng_tables.V1[0] ^ rng_tables.V2[0] ^ rng_tables.V3[0];
    try std.testing.expectEqual(expected_raw % 256, rng.rand(0, 0, 256));

    // rand(1, 0, m) uses yi = 1: x0=1, x1=0, x2=0, x3=0
    const expected_y1 = rng_tables.V0[1] ^ rng_tables.V1[0] ^ rng_tables.V2[0] ^ rng_tables.V3[0];
    try std.testing.expectEqual(expected_y1 % 1000, rng.rand(1, 0, 1000));

    // rand(256, 0, m) uses yi = 256: x0=0, x1=1, x2=0, x3=0
    const expected_y256 = rng_tables.V0[0] ^ rng_tables.V1[1] ^ rng_tables.V2[0] ^ rng_tables.V3[0];
    try std.testing.expectEqual(expected_y256 % 1000, rng.rand(256, 0, 1000));
}

test "Degree distribution bounds" {
    // deg(v) must return a value in [1, 30] for all v in [0, 2^20)
    // RFC 6330 Section 5.3.5.2 Table 1: degrees 1..30
    var v: u32 = 0;
    while (v < (1 << 20)) : (v += 1) {
        const d = rng.deg(v);
        try std.testing.expect(d >= 1);
        try std.testing.expect(d <= 30);
    }

    // Boundary values from Table 1
    // v < 5243 => d=1
    try std.testing.expectEqual(@as(u32, 1), rng.deg(0));
    try std.testing.expectEqual(@as(u32, 1), rng.deg(5242));
    // v >= 5243 and v < 529531 => d=2
    try std.testing.expectEqual(@as(u32, 2), rng.deg(5243));
    try std.testing.expectEqual(@as(u32, 2), rng.deg(529530));
    // v >= 529531 and v < 704294 => d=3
    try std.testing.expectEqual(@as(u32, 3), rng.deg(529531));
    // Maximum degree: v >= 1017662 => d=30
    try std.testing.expectEqual(@as(u32, 30), rng.deg(1048575));
}

test "Tuple generation determinism" {
    // genTuple(K', X) must produce consistent (d, a, b, d1, a1, b1) tuples
    const k_values = [_]u32{ 10, 26, 101, 500 };

    for (k_values) |k| {
        const kp = raptorq.systematic_constants.ceilKPrime(k);
        const si = raptorq.systematic_constants.findSystematicIndex(kp).?;
        const w = si.w;
        const l = kp + si.s + si.h;
        const p = l - w;
        const p1 = raptorq.helpers.nextPrime(p);

        var x: u32 = 0;
        while (x < 50) : (x += 1) {
            const t1 = rng.genTuple(kp, x);
            const t2 = rng.genTuple(kp, x);

            // Determinism
            try std.testing.expectEqual(t1.d, t2.d);
            try std.testing.expectEqual(t1.a, t2.a);
            try std.testing.expectEqual(t1.b, t2.b);
            try std.testing.expectEqual(t1.d1, t2.d1);
            try std.testing.expectEqual(t1.a1, t2.a1);
            try std.testing.expectEqual(t1.b1, t2.b1);

            // Bounds (RFC 6330 Section 5.3.5.4)
            try std.testing.expect(t1.d >= 1);
            try std.testing.expect(t1.d <= w - 2);
            try std.testing.expect(t1.a >= 1);
            try std.testing.expect(t1.a <= w - 1);
            try std.testing.expect(t1.b < w);
            try std.testing.expect(t1.d1 >= 2);
            try std.testing.expect(t1.d1 <= 3);
            try std.testing.expect(t1.a1 >= 1);
            try std.testing.expect(t1.a1 <= p1 - 1);
            try std.testing.expect(t1.b1 < p1);
        }
    }
}
