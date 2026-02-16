// Symbol operation recording for deferred application

const Octet = @import("../math/octet.zig").Octet;

pub const SymbolOp = union(enum) {
    add_assign: struct { src: u32, dst: u32 },
    mul_assign: struct { index: u32, scalar: Octet },
    fma: struct { src: u32, dst: u32, scalar: Octet },
    reorder: struct { src: u32, dst: u32 },
};

pub const OperationVector = struct {
    ops: []const SymbolOp,

    pub fn apply(self: OperationVector) void {
        _ = self;
        @panic("TODO");
    }
};
