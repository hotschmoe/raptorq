// GF(256) exponential and logarithm tables
// Generator polynomial: x^8 + x^4 + x^3 + x^2 + 1 (0x11D)

// OCT_EXP[i] = g^i mod p(x) for i in 0..509
// Extended to 510 entries to avoid modular reduction during multiplication
pub const OCT_EXP: [510]u8 = undefined; // TODO: populate from RFC 6330

// OCT_LOG[i] = discrete log base g of i, for i in 1..255
// OCT_LOG[0] is unused (log(0) is undefined)
pub const OCT_LOG: [256]u8 = undefined; // TODO: populate from RFC 6330
