// GF(256) octet arithmetic (RFC 6330 Section 5.7)

const std = @import("std");
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
        return .{ .value = self.value ^ other.value };
    }

    /// Subtraction in GF(256) is identical to addition (XOR).
    pub fn sub(self: Octet, other: Octet) Octet {
        return .{ .value = self.value ^ other.value };
    }

    /// Multiplication using exp/log tables.
    pub fn mul(self: Octet, other: Octet) Octet {
        if (self.value == 0 or other.value == 0) return ZERO;
        const log_u = @as(u16, octet_tables.OCT_LOG[self.value]);
        const log_v = @as(u16, octet_tables.OCT_LOG[other.value]);
        return .{ .value = octet_tables.OCT_EXP[log_u + log_v] };
    }

    /// Division: self / other. other must be non-zero.
    pub fn div(self: Octet, other: Octet) Octet {
        std.debug.assert(other.value != 0);
        if (self.value == 0) return ZERO;
        const log_u = @as(u16, octet_tables.OCT_LOG[self.value]);
        const log_v = @as(u16, octet_tables.OCT_LOG[other.value]);
        return .{ .value = octet_tables.OCT_EXP[255 + log_u - log_v] };
    }

    /// Fused multiply-add: self += a * b
    pub fn fma(self: *Octet, a: Octet, b: Octet) void {
        self.value ^= a.mul(b).value;
    }

    /// Multiplicative inverse. self must be non-zero.
    pub fn inverse(self: Octet) Octet {
        std.debug.assert(self.value != 0);
        return .{ .value = octet_tables.OCT_EXP[255 - @as(u16, octet_tables.OCT_LOG[self.value])] };
    }

    pub fn isZero(self: Octet) bool {
        return self.value == 0;
    }

    pub fn isOne(self: Octet) bool {
        return self.value == 1;
    }
};
