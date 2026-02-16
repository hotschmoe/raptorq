// RFC 6330 Section 5.5 - Pseudo-random number generator

const rng_tables = @import("../tables/rng_tables.zig");

/// Rand(y, i, m) as defined in RFC 6330 Section 5.3.5.1
/// Returns a value in [0, m)
pub fn rand(y: u32, i: u32, m: u32) u32 {
    _ = .{ y, i, m };
    @panic("TODO");
}

/// Deg(v) - degree distribution function (RFC 6330 Section 5.3.5.2)
pub fn deg(v: u32) u32 {
    _ = v;
    @panic("TODO");
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
    _ = .{ k_prime, x };
    @panic("TODO");
}
