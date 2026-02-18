// Bulk GF(256) operations on byte slices
//
// SIMD acceleration via split-nibble GF(256) multiplication:
// Each byte x is split into lo (x & 0x0F) and hi (x >> 4). Two 16-entry
// lookup tables (one per nibble) fit in a single 128-bit SIMD register.
// gf256_mul(x, c) = lo_table[x & 0x0F] XOR hi_table[x >> 4]
// Uses TBL on aarch64, PSHUFB on x86_64+SSSE3, scalar fallback elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const octet_tables = @import("../tables/octet_tables.zig");
const Octet = @import("octet.zig").Octet;

const has_neon = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => true,
    else => false,
};

const has_ssse3 = switch (builtin.cpu.arch) {
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3),
    else => false,
};

const has_avx2 = switch (builtin.cpu.arch) {
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .avx2),
    else => false,
};

const use_simd = has_neon or has_ssse3;

const NibbleTables = struct {
    lo: @Vector(16, u8),
    hi: @Vector(16, u8),
};

fn buildNibbleTables(scalar: u8) NibbleTables {
    const log_s = @as(u16, octet_tables.OCT_LOG[scalar]);
    var lo: [16]u8 = undefined;
    var hi: [16]u8 = undefined;
    lo[0] = 0;
    hi[0] = 0;
    for (1..16) |i| {
        lo[i] = octet_tables.OCT_EXP[@as(u16, octet_tables.OCT_LOG[i]) + log_s];
        hi[i] = octet_tables.OCT_EXP[@as(u16, octet_tables.OCT_LOG[i << 4]) + log_s];
    }
    return .{ .lo = lo, .hi = hi };
}

fn tableLookup16(table: @Vector(16, u8), indices: @Vector(16, u8)) @Vector(16, u8) {
    if (has_neon) {
        return asm ("tbl %[out].16b, {%[tbl].16b}, %[idx].16b"
            : [out] "=w" (-> @Vector(16, u8)),
            : [tbl] "w" (table),
              [idx] "w" (indices),
        );
    } else if (has_ssse3) {
        return asm ("pshufb %[idx], %[out]"
            : [out] "=x" (-> @Vector(16, u8)),
            : [idx] "x" (indices),
              [tbl_in] "0" (table),
        );
    } else {
        const tbl: [16]u8 = table;
        const idx: [16]u8 = indices;
        var result: [16]u8 = undefined;
        for (&result, idx) |*r, i| {
            r.* = tbl[i & 0x0F];
        }
        return result;
    }
}

fn tableLookup32(table: @Vector(16, u8), indices: @Vector(32, u8)) @Vector(32, u8) {
    const table_arr: [16]u8 = table;
    const wide_table: @Vector(32, u8) = table_arr ++ table_arr;
    return asm ("vpshufb %[idx], %[tbl], %[out]"
        : [out] "=x" (-> @Vector(32, u8)),
        : [tbl] "x" (wide_table),
          [idx] "x" (indices),
    );
}

const mask_0f: @Vector(16, u8) = @splat(0x0F);
const shift_4: @Vector(16, u3) = @splat(4);

/// Apply split-nibble multiply in 2x16-byte unrolled chunks, returning bytes processed.
fn simdMulChunks2x16(dst: []u8, tables: NibbleTables) usize {
    var i: usize = 0;
    while (i + 32 <= dst.len) : (i += 32) {
        inline for ([_]usize{ 0, 16 }) |off| {
            const d: @Vector(16, u8) = dst[i + off ..][0..16].*;
            const lo_prod = tableLookup16(tables.lo, d & mask_0f);
            const hi_prod = tableLookup16(tables.hi, d >> shift_4);
            dst[i + off ..][0..16].* = lo_prod ^ hi_prod;
        }
    }
    if (i + 16 <= dst.len) {
        const d: @Vector(16, u8) = dst[i..][0..16].*;
        const lo_prod = tableLookup16(tables.lo, d & mask_0f);
        const hi_prod = tableLookup16(tables.hi, d >> shift_4);
        dst[i..][0..16].* = lo_prod ^ hi_prod;
        i += 16;
    }
    return i;
}

fn simdMulChunks32(dst: []u8, tables: NibbleTables) usize {
    var i: usize = 0;
    while (i + 32 <= dst.len) : (i += 32) {
        const d: @Vector(32, u8) = dst[i..][0..32].*;
        const mask: @Vector(32, u8) = @splat(0x0F);
        const shift: @Vector(32, u3) = @splat(4);
        const lo_prod = tableLookup32(tables.lo, d & mask);
        const hi_prod = tableLookup32(tables.hi, d >> shift);
        dst[i..][0..32].* = lo_prod ^ hi_prod;
    }
    return i;
}

fn simdFmaChunks32(dst: []u8, src: []const u8, tables: NibbleTables) usize {
    var i: usize = 0;
    while (i + 32 <= dst.len) : (i += 32) {
        const s: @Vector(32, u8) = src[i..][0..32].*;
        const mask: @Vector(32, u8) = @splat(0x0F);
        const shift: @Vector(32, u3) = @splat(4);
        const lo_prod = tableLookup32(tables.lo, s & mask);
        const hi_prod = tableLookup32(tables.hi, s >> shift);
        const d: @Vector(32, u8) = dst[i..][0..32].*;
        dst[i..][0..32].* = d ^ (lo_prod ^ hi_prod);
    }
    return i;
}

/// Apply split-nibble fused multiply-add in 2x16-byte unrolled chunks, returning bytes processed.
fn simdFmaChunks2x16(dst: []u8, src: []const u8, tables: NibbleTables) usize {
    var i: usize = 0;
    while (i + 32 <= dst.len) : (i += 32) {
        inline for ([_]usize{ 0, 16 }) |off| {
            const s: @Vector(16, u8) = src[i + off ..][0..16].*;
            const lo_prod = tableLookup16(tables.lo, s & mask_0f);
            const hi_prod = tableLookup16(tables.hi, s >> shift_4);
            const d: @Vector(16, u8) = dst[i + off ..][0..16].*;
            dst[i + off ..][0..16].* = d ^ (lo_prod ^ hi_prod);
        }
    }
    if (i + 16 <= dst.len) {
        const s: @Vector(16, u8) = src[i..][0..16].*;
        const lo_prod = tableLookup16(tables.lo, s & mask_0f);
        const hi_prod = tableLookup16(tables.hi, s >> shift_4);
        const d: @Vector(16, u8) = dst[i..][0..16].*;
        dst[i..][0..16].* = d ^ (lo_prod ^ hi_prod);
        i += 16;
    }
    return i;
}

/// dst[i] ^= src[i] for all i
pub fn addAssign(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    // @Vector(32, u8) XOR: AVX2 emits single vpxor, SSE2 splits into 2x pxor
    while (i + 32 <= dst.len) : (i += 32) {
        const s: @Vector(32, u8) = src[i..][0..32].*;
        const d: @Vector(32, u8) = dst[i..][0..32].*;
        dst[i..][0..32].* = d ^ s;
    }
    if (i + 16 <= dst.len) {
        const s: @Vector(16, u8) = src[i..][0..16].*;
        const d: @Vector(16, u8) = dst[i..][0..16].*;
        dst[i..][0..16].* = d ^ s;
        i += 16;
    }
    for (dst[i..], src[i..]) |*d, s| {
        d.* ^= s;
    }
}

/// dst[i] = dst[i] * scalar for all i
pub fn mulAssignScalar(dst: []u8, scalar: Octet) void {
    if (scalar.value == 0) {
        @memset(dst, 0);
        return;
    }
    if (scalar.value == 1) return;

    var i: usize = 0;
    if (use_simd) {
        const tables = buildNibbleTables(scalar.value);
        if (has_avx2) {
            i = simdMulChunks32(dst, tables);
        }
        i += simdMulChunks2x16(dst[i..], tables);
    }

    const log_scalar = @as(u16, octet_tables.OCT_LOG[scalar.value]);
    for (dst[i..]) |*d| {
        if (d.* != 0) {
            d.* = octet_tables.OCT_EXP[@as(u16, octet_tables.OCT_LOG[d.*]) + log_scalar];
        }
    }
}

/// dst[i] += src[i] * scalar for all i (fused multiply-add)
pub fn fmaSlice(dst: []u8, src: []const u8, scalar: Octet) void {
    if (scalar.value == 0) return;
    if (scalar.value == 1) {
        addAssign(dst, src);
        return;
    }

    var i: usize = 0;
    if (use_simd) {
        const tables = buildNibbleTables(scalar.value);
        if (has_avx2) {
            i = simdFmaChunks32(dst, src, tables);
        }
        i += simdFmaChunks2x16(dst[i..], src[i..], tables);
    }

    const log_scalar = @as(u16, octet_tables.OCT_LOG[scalar.value]);
    for (dst[i..], src[i..]) |*d, s| {
        if (s != 0) {
            d.* ^= octet_tables.OCT_EXP[@as(u16, octet_tables.OCT_LOG[s]) + log_scalar];
        }
    }
}

test "addAssign across sizes" {
    const sizes = [_]usize{ 0, 1, 7, 15, 16, 17, 31, 32, 64, 100, 1024 };
    for (sizes) |size| {
        const dst = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(dst);
        const src = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(src);
        const expected = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(expected);

        for (0..size) |j| {
            dst[j] = @truncate(j * 37 + 13);
            src[j] = @truncate(j * 53 + 7);
            expected[j] = dst[j] ^ src[j];
        }

        addAssign(dst, src);
        try std.testing.expectEqualSlices(u8, expected, dst);
    }
}

test "fmaSlice across scalars and sizes" {
    const scalars = [_]u8{ 0, 1, 2, 42, 127, 128, 254, 255 };
    const sizes = [_]usize{ 0, 1, 15, 16, 17, 32, 100 };

    for (scalars) |sv| {
        const scalar = Octet.init(sv);
        for (sizes) |size| {
            const dst = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(dst);
            const src = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(src);
            const expected = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(expected);

            for (0..size) |j| {
                dst[j] = @truncate(j * 37 + 13);
                src[j] = @truncate(j * 53 + 7);
                expected[j] = dst[j] ^ Octet.init(src[j]).mul(scalar).value;
            }

            fmaSlice(dst, src, scalar);
            try std.testing.expectEqualSlices(u8, expected, dst);
        }
    }
}

test "mulAssignScalar across scalars and sizes" {
    const scalars = [_]u8{ 0, 1, 2, 42, 127, 128, 254, 255 };
    const sizes = [_]usize{ 0, 1, 15, 16, 17, 32, 100 };

    for (scalars) |sv| {
        const scalar = Octet.init(sv);
        for (sizes) |size| {
            const dst = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(dst);
            const expected = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(expected);

            for (0..size) |j| {
                dst[j] = @truncate(j * 37 + 13);
                expected[j] = Octet.init(dst[j]).mul(scalar).value;
            }

            mulAssignScalar(dst, scalar);
            try std.testing.expectEqualSlices(u8, expected, dst);
        }
    }
}
