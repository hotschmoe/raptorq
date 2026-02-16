// Common utility functions

/// Integer division rounding up: ceil(a / b)
pub fn intDivCeil(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

/// Check if n is prime.
pub fn isPrime(n: u32) bool {
    if (n < 2) return false;
    if (n < 4) return true;
    if (n % 2 == 0 or n % 3 == 0) return false;
    var i: u32 = 5;
    while (i * i <= n) {
        if (n % i == 0 or n % (i + 2) == 0) return false;
        i += 6;
    }
    return true;
}

/// Find the smallest prime >= n.
pub fn nextPrime(n: u32) u32 {
    var candidate = n;
    while (!isPrime(candidate)) {
        candidate += 1;
    }
    return candidate;
}
