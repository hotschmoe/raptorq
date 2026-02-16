// Symbol operation recording for deferred application

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const Symbol = @import("symbol.zig").Symbol;

pub const SymbolOp = union(enum) {
    add_assign: struct { src: u32, dst: u32 },
    mul_assign: struct { index: u32, scalar: Octet },
    fma: struct { src: u32, dst: u32, scalar: Octet },
    reorder: struct { src: u32, dst: u32 },
};

pub const OperationVector = struct {
    ops: []const SymbolOp,

    pub fn apply(self: OperationVector, symbols: []Symbol) void {
        for (self.ops) |op| {
            switch (op) {
                .add_assign => |o| symbols[o.dst].addAssign(symbols[o.src]),
                .mul_assign => |o| symbols[o.index].mulAssign(o.scalar),
                .fma => |o| symbols[o.dst].fma(symbols[o.src], o.scalar),
                .reorder => |o| std.mem.swap(Symbol, &symbols[o.src], &symbols[o.dst]),
            }
        }
    }
};
