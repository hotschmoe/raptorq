// Symbol arithmetic conformance tests
// Verifies that Symbol operations (XOR, scalar multiply, FMA) correctly
// implement GF(256) field arithmetic on byte vectors.

const std = @import("std");
const raptorq = @import("raptorq");
const Symbol = raptorq.symbol.Symbol;
const Octet = raptorq.octet.Octet;

test "Symbol XOR (addAssign)" {
    const allocator = std.testing.allocator;

    var a = try Symbol.fromSlice(allocator, &[_]u8{ 0x0A, 0x0B, 0x0C, 0x0D });
    defer a.deinit();
    const b = try Symbol.fromSlice(allocator, &[_]u8{ 0x01, 0x02, 0x03, 0x04 });
    defer b.deinit();

    a.addAssign(b);

    // XOR element-wise
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0B, 0x09, 0x0F, 0x09 }, a.data);
}

test "Symbol scalar multiply" {
    const allocator = std.testing.allocator;

    var a = try Symbol.fromSlice(allocator, &[_]u8{ 1, 2, 3, 4 });
    defer a.deinit();

    // Multiply by alpha (2): each element multiplied in GF(256)
    a.mulAssign(Octet.ALPHA);

    // Verify against element-wise Octet multiplication
    try std.testing.expectEqual(Octet.init(1).mul(Octet.ALPHA).value, a.data[0]);
    try std.testing.expectEqual(Octet.init(2).mul(Octet.ALPHA).value, a.data[1]);
    try std.testing.expectEqual(Octet.init(3).mul(Octet.ALPHA).value, a.data[2]);
    try std.testing.expectEqual(Octet.init(4).mul(Octet.ALPHA).value, a.data[3]);
}

test "Symbol fused multiply-add" {
    const allocator = std.testing.allocator;

    var a = try Symbol.fromSlice(allocator, &[_]u8{ 10, 20, 30, 40 });
    defer a.deinit();
    const b = try Symbol.fromSlice(allocator, &[_]u8{ 1, 2, 3, 4 });
    defer b.deinit();

    const scalar = Octet.init(5);
    a.fma(b, scalar);

    // a[i] = original_a[i] XOR (b[i] * scalar)
    try std.testing.expectEqual(Octet.init(10).add(Octet.init(1).mul(scalar)).value, a.data[0]);
    try std.testing.expectEqual(Octet.init(20).add(Octet.init(2).mul(scalar)).value, a.data[1]);
    try std.testing.expectEqual(Octet.init(30).add(Octet.init(3).mul(scalar)).value, a.data[2]);
    try std.testing.expectEqual(Octet.init(40).add(Octet.init(4).mul(scalar)).value, a.data[3]);
}

test "Symbol operations with various sizes" {
    const allocator = std.testing.allocator;
    const sizes = [_]usize{ 1, 4, 16, 64, 256, 1024 };

    for (sizes) |size| {
        var a = try Symbol.init(allocator, size);
        defer a.deinit();
        var b = try Symbol.init(allocator, size);
        defer b.deinit();

        // Fill with known pattern
        for (a.data, 0..) |*v, i| v.* = @intCast(i % 256);
        for (b.data, 0..) |*v, i| v.* = @intCast((i * 7 + 3) % 256);

        // Save original a
        var orig = try a.clone();
        defer orig.deinit();

        // XOR with b and verify size is preserved
        a.addAssign(b);
        try std.testing.expectEqual(size, a.data.len);

        // XOR again to restore original
        a.addAssign(b);
        try std.testing.expectEqualSlices(u8, orig.data, a.data);
    }
}

test "Symbol XOR is self-inverse" {
    const allocator = std.testing.allocator;

    const original = [_]u8{ 42, 137, 255, 0, 1, 99, 200, 17 };
    var a = try Symbol.fromSlice(allocator, &original);
    defer a.deinit();
    const b = try Symbol.fromSlice(allocator, &[_]u8{ 11, 22, 33, 44, 55, 66, 77, 88 });
    defer b.deinit();

    a.addAssign(b);
    // After one XOR, a should differ from original (unless b is all zeros)
    try std.testing.expect(!std.mem.eql(u8, a.data, &original));

    a.addAssign(b);
    // After second XOR, a should be restored to original
    try std.testing.expectEqualSlices(u8, &original, a.data);
}

test "Symbol multiply by one is identity" {
    const allocator = std.testing.allocator;

    const original = [_]u8{ 42, 137, 255, 0, 1, 99, 200, 17 };
    var a = try Symbol.fromSlice(allocator, &original);
    defer a.deinit();

    a.mulAssign(Octet.ONE);
    try std.testing.expectEqualSlices(u8, &original, a.data);
}

test "Symbol multiply by zero clears" {
    const allocator = std.testing.allocator;

    var a = try Symbol.fromSlice(allocator, &[_]u8{ 42, 137, 255, 0, 1, 99, 200, 17 });
    defer a.deinit();

    a.mulAssign(Octet.ZERO);

    for (a.data) |v| {
        try std.testing.expectEqual(@as(u8, 0), v);
    }
}
