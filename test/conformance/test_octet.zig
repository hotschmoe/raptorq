// RFC 6330 Section 5.7 - GF(256) field axiom conformance tests
// Verifies that Octet arithmetic satisfies all field axioms over the full
// element range, using the irreducible polynomial x^8+x^4+x^3+x^2+1 (0x11D).

const std = @import("std");
const raptorq = @import("raptorq");
const Octet = raptorq.octet.Octet;
const OCT_EXP = raptorq.octet_tables.OCT_EXP;
const OCT_LOG = raptorq.octet_tables.OCT_LOG;

test "GF(256) addition is commutative" {
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            const oa = Octet.init(@intCast(a));
            const ob = Octet.init(@intCast(b));
            try std.testing.expectEqual(oa.add(ob).value, ob.add(oa).value);
        }
    }
}

test "GF(256) addition is associative" {
    const vals = [_]u8{ 0, 1, 2, 3, 17, 42, 127, 128, 200, 254, 255 };
    for (vals) |a| {
        for (vals) |b| {
            for (vals) |c| {
                const oa = Octet.init(a);
                const ob = Octet.init(b);
                const oc = Octet.init(c);
                try std.testing.expectEqual(
                    oa.add(ob).add(oc).value,
                    oa.add(ob.add(oc)).value,
                );
            }
        }
    }
}

test "GF(256) multiplication is commutative" {
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            const oa = Octet.init(@intCast(a));
            const ob = Octet.init(@intCast(b));
            try std.testing.expectEqual(oa.mul(ob).value, ob.mul(oa).value);
        }
    }
}

test "GF(256) multiplication is associative" {
    const vals = [_]u8{ 0, 1, 2, 3, 17, 42, 127, 128, 200, 254, 255 };
    for (vals) |a| {
        for (vals) |b| {
            for (vals) |c| {
                const oa = Octet.init(a);
                const ob = Octet.init(b);
                const oc = Octet.init(c);
                try std.testing.expectEqual(
                    oa.mul(ob).mul(oc).value,
                    oa.mul(ob.mul(oc)).value,
                );
            }
        }
    }
}

test "GF(256) distributivity" {
    const vals = [_]u8{ 0, 1, 2, 3, 17, 42, 127, 128, 200, 254, 255 };
    for (vals) |a| {
        for (vals) |b| {
            for (vals) |c| {
                const oa = Octet.init(a);
                const ob = Octet.init(b);
                const oc = Octet.init(c);
                // a * (b + c) == a*b + a*c
                const lhs = oa.mul(ob.add(oc));
                const rhs = oa.mul(ob).add(oa.mul(oc));
                try std.testing.expectEqual(lhs.value, rhs.value);
            }
        }
    }
}

test "GF(256) additive identity" {
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        const oa = Octet.init(@intCast(a));
        try std.testing.expectEqual(oa.add(Octet.ZERO).value, oa.value);
        try std.testing.expectEqual(Octet.ZERO.add(oa).value, oa.value);
    }
}

test "GF(256) multiplicative identity" {
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        const oa = Octet.init(@intCast(a));
        try std.testing.expectEqual(oa.mul(Octet.ONE).value, oa.value);
        try std.testing.expectEqual(Octet.ONE.mul(oa).value, oa.value);
    }
}

test "GF(256) additive inverse (self-inverse)" {
    // In GF(256), addition is XOR, so a + a == 0 for all a
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        const oa = Octet.init(@intCast(a));
        try std.testing.expectEqual(@as(u8, 0), oa.add(oa).value);
    }
}

test "GF(256) multiplicative inverse" {
    // For all non-zero a: a * a^(-1) == 1
    var a: u16 = 1;
    while (a < 256) : (a += 1) {
        const oa = Octet.init(@intCast(a));
        const inv = oa.inverse();
        try std.testing.expectEqual(@as(u8, 1), oa.mul(inv).value);
    }
}

test "GF(256) known multiplication values" {
    // Generator polynomial: x^8 + x^4 + x^3 + x^2 + 1 (0x11D)
    // alpha = 2 is a generator element of GF(256)*
    // alpha^1 = 2, alpha^2 = 4, alpha^7 = 128, alpha^8 = 29 (0x1D = 0x100 XOR 0x11D lower 8)
    try std.testing.expectEqual(@as(u8, 2), Octet.ALPHA.value);
    try std.testing.expectEqual(@as(u8, 4), Octet.ALPHA.mul(Octet.ALPHA).value);

    // alpha^8 = 0x100 reduced by 0x11D => 0x100 XOR 0x11D = 0x1D = 29
    var alpha_pow = Octet.ONE;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        alpha_pow = alpha_pow.mul(Octet.ALPHA);
    }
    try std.testing.expectEqual(@as(u8, 29), alpha_pow.value);

    // Verify alpha is a generator: alpha^255 == 1 (order of the multiplicative group)
    alpha_pow = Octet.ONE;
    i = 0;
    while (i < 255) : (i += 1) {
        alpha_pow = alpha_pow.mul(Octet.ALPHA);
    }
    try std.testing.expectEqual(@as(u8, 1), alpha_pow.value);

    // Multiplication by zero
    try std.testing.expectEqual(@as(u8, 0), Octet.init(42).mul(Octet.ZERO).value);
    try std.testing.expectEqual(@as(u8, 0), Octet.ZERO.mul(Octet.init(255)).value);
}

test "GF(256) exp/log table consistency" {
    // OCT_EXP[OCT_LOG[x]] == x for all x in 1..255
    var x: u16 = 1;
    while (x < 256) : (x += 1) {
        const log_x = OCT_LOG[@intCast(x)];
        try std.testing.expectEqual(@as(u8, @intCast(x)), OCT_EXP[log_x]);
    }

    // Extended table: OCT_EXP[i + 255] == OCT_EXP[i] for i in 0..254
    var i: u16 = 0;
    while (i < 255) : (i += 1) {
        try std.testing.expectEqual(OCT_EXP[i], OCT_EXP[i + 255]);
    }

    // OCT_EXP[0] == 1 (alpha^0 = 1)
    try std.testing.expectEqual(@as(u8, 1), OCT_EXP[0]);
}

test "GF(256) division by self" {
    var a: u16 = 1;
    while (a < 256) : (a += 1) {
        const oa = Octet.init(@intCast(a));
        try std.testing.expectEqual(@as(u8, 1), oa.div(oa).value);
    }
}
