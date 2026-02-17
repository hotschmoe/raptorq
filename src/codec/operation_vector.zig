// Symbol operation recording for deferred application

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const SymbolBuffer = @import("symbol.zig").SymbolBuffer;

pub const SymbolOp = union(enum) {
    add_assign: struct { src: u32, dst: u32 },
    mul_assign: struct { index: u32, scalar: Octet },
    fma: struct { src: u32, dst: u32, scalar: Octet },
    reorder: struct { src: u32, dst: u32 },
};

pub const OperationVector = struct {
    ops: []const SymbolOp,

    pub fn applyBuf(self: OperationVector, buf: *SymbolBuffer) void {
        for (self.ops) |op| {
            switch (op) {
                .add_assign => |o| buf.addAssign(o.dst, o.src),
                .mul_assign => |o| buf.mulAssign(o.index, o.scalar),
                .fma => |o| buf.fma(o.dst, o.src, o.scalar),
                .reorder => |o| {
                    const a = buf.get(o.src);
                    const b = buf.get(o.dst);
                    for (a, b) |*x, *y| std.mem.swap(u8, x, y);
                },
            }
        }
    }
};
