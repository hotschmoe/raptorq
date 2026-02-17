// Symbol operation recording for deferred application

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const symbol_mod = @import("symbol.zig");
const Symbol = symbol_mod.Symbol;
const SymbolBuffer = symbol_mod.SymbolBuffer;

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

    pub fn applyBuf(self: OperationVector, buf: *SymbolBuffer) void {
        for (self.ops) |op| {
            switch (op) {
                .add_assign => |o| buf.addAssign(o.dst, o.src),
                .mul_assign => |o| buf.mulAssign(o.index, o.scalar),
                .fma => |o| buf.fma(o.dst, o.src, o.scalar),
                .reorder => |o| {
                    const sym_size = buf.symbol_size;
                    const a = buf.get(o.src);
                    const b = buf.get(o.dst);
                    var i: usize = 0;
                    while (i < sym_size) : (i += 1) {
                        const tmp = a[i];
                        a[i] = b[i];
                        b[i] = tmp;
                    }
                },
            }
        }
    }
};
