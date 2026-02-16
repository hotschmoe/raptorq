// GF(256) exponential and logarithm tables
// Generator polynomial: x^8 + x^4 + x^3 + x^2 + 1 (0x11D)

const gen = blk: {
    var exp: [510]u8 = undefined;
    var log: [256]u8 = undefined;
    log[0] = 0; // unused; log(0) is undefined

    var val: u16 = 1;
    for (0..255) |i| {
        exp[i] = @intCast(val);
        log[@intCast(val)] = @intCast(i);
        val <<= 1;
        if (val & 0x100 != 0) val ^= 0x11D;
    }
    // Extend: exp[i+255] = exp[i] for i in 0..254
    for (0..255) |i| {
        exp[i + 255] = exp[i];
    }
    break :blk .{ exp, log };
};

// OCT_EXP[i] = g^i mod p(x) for i in 0..509
// Extended to 510 entries to avoid modular reduction during multiplication
pub const OCT_EXP: [510]u8 = gen[0];

// OCT_LOG[i] = discrete log base g of i, for i in 1..255
// OCT_LOG[0] is unused (log(0) is undefined)
pub const OCT_LOG: [256]u8 = gen[1];
