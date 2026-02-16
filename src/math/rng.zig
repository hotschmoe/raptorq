// RFC 6330 Section 5.5 - Pseudo-random number generator

const rng_tables = @import("../tables/rng_tables.zig");
const systematic_constants = @import("../tables/systematic_constants.zig");
const helpers = @import("../util/helpers.zig");

/// Rand(y, i, m) as defined in RFC 6330 Section 5.3.5.1
/// Returns a value in [0, m)
pub fn rand(y: u32, i: u32, m: u32) u32 {
    const yi = y +% i;
    const x0 = yi % 256;
    const x1 = (yi >> 8) % 256;
    const x2 = (yi >> 16) % 256;
    const x3 = (yi >> 24) % 256;
    return (rng_tables.V0[x0] ^ rng_tables.V1[x1] ^ rng_tables.V2[x2] ^ rng_tables.V3[x3]) % m;
}

/// Deg(v) - degree distribution function (RFC 6330 Section 5.3.5.2)
pub fn deg(v: u32) u32 {
    const f = [_]u32{
        0,       5243,    529531,  704294,  791675,
        844104,  879057,  904023,  922747,  937311,
        948962,  958494,  966438,  973160,  978921,
        983914,  988283,  992138,  995565,  998631,
        1001391, 1003887, 1006157, 1008229, 1010129,
        1011876, 1013490, 1014983, 1016370, 1017662,
        1048576,
    };
    var d: u32 = 1;
    while (d < f.len - 1) : (d += 1) {
        if (v < f[d]) return d;
    }
    return f.len - 1;
}

/// Generate the tuple (d, a, b, d1, a1, b1) for encoding symbol ISI=X
/// RFC 6330 Section 5.3.5.4
pub const Tuple = struct {
    d: u32,
    a: u32,
    b: u32,
    d1: u32,
    a1: u32,
    b1: u32,
};

pub fn genTuple(k_prime: u32, x: u32) Tuple {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const w = si.w;
    const p1 = helpers.nextPrime(w);

    const big_a: u32 = (53591 + si.j * 997) | 1;
    const big_b: u32 = 10267 *% (si.j + 1);
    const y: u32 = big_b +% x *% big_a;

    const v = rand(y, 0, 1 << 20);
    const d = @min(deg(v), w - 2);
    const a = 1 + rand(y, 1, w - 1);
    const b = rand(y, 2, w);
    const d1: u32 = if (d < 4) 2 + rand(y, 3, 2) else 2;
    const a1 = 1 + rand(y, 4, p1 - 1);
    const b1 = rand(y, 5, p1);

    return .{ .d = d, .a = a, .b = b, .d1 = d1, .a1 = a1, .b1 = b1 };
}
