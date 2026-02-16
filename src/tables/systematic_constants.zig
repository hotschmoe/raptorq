// Systematic indices and parameters (RFC 6330 Table 2)

pub const SystematicIndices = struct {
    k_prime: u32,
    j: u32,
    s: u32,
    h: u32,
    w: u32,
};

// 477 entries mapping K' -> (J, S, H, W)
pub const TABLE_2: [0]SystematicIndices = .{}; // TODO: populate 477 entries

/// Find the systematic index entry for a given K' value.
pub fn findSystematicIndex(k_prime: u32) ?SystematicIndices {
    _ = k_prime;
    @panic("TODO");
}

/// Round K up to the nearest K' value in Table 2.
pub fn ceilKPrime(k: u32) u32 {
    _ = k;
    @panic("TODO");
}

/// Compute L = K' + S + H (number of intermediate symbols).
pub fn numIntermediateSymbols(k_prime: u32) u32 {
    _ = k_prime;
    @panic("TODO");
}

/// Compute the number of LT symbols: L - num_ldpc - num_hdpc.
pub fn numLTSymbols(k_prime: u32) u32 {
    _ = k_prime;
    @panic("TODO");
}

/// Compute the number of PI symbols.
pub fn numPISymbols(k_prime: u32) u32 {
    _ = k_prime;
    @panic("TODO");
}
