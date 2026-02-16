// GF(256) octet arithmetic (RFC 6330 Section 5.7)

const octet_tables = @import("../tables/octet_tables.zig");

pub const Octet = struct {
    value: u8,

    pub const ZERO = Octet{ .value = 0 };
    pub const ONE = Octet{ .value = 1 };
    pub const ALPHA = Octet{ .value = 2 };

    pub fn init(value: u8) Octet {
        return .{ .value = value };
    }

    /// Addition in GF(256) is XOR.
    pub fn add(self: Octet, other: Octet) Octet {
        _ = .{ self, other };
        @panic("TODO");
    }

    /// Subtraction in GF(256) is identical to addition (XOR).
    pub fn sub(self: Octet, other: Octet) Octet {
        _ = .{ self, other };
        @panic("TODO");
    }

    /// Multiplication using exp/log tables.
    pub fn mul(self: Octet, other: Octet) Octet {
        _ = .{ self, other };
        @panic("TODO");
    }

    /// Division: self / other. other must be non-zero.
    pub fn div(self: Octet, other: Octet) Octet {
        _ = .{ self, other };
        @panic("TODO");
    }

    /// Fused multiply-add: self += a * b
    pub fn fma(self: *Octet, a: Octet, b: Octet) void {
        _ = .{ self, a, b };
        @panic("TODO");
    }

    /// Multiplicative inverse. self must be non-zero.
    pub fn inverse(self: Octet) Octet {
        _ = self;
        @panic("TODO");
    }

    pub fn isZero(self: Octet) bool {
        return self.value == 0;
    }

    pub fn isOne(self: Octet) bool {
        return self.value == 1;
    }
};
