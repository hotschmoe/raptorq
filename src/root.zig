// raptorq - Pure Zig implementation of RFC 6330 (RaptorQ FEC)

// Public API - modules
pub const encoder = @import("codec/encoder.zig");
pub const decoder = @import("codec/decoder.zig");
pub const base = @import("codec/base.zig");

// Public API - top-level type re-exports
pub const Encoder = encoder.Encoder;
pub const SourceBlockEncoder = encoder.SourceBlockEncoder;
pub const Decoder = decoder.Decoder;
pub const SourceBlockDecoder = decoder.SourceBlockDecoder;
pub const EncodingPacket = base.EncodingPacket;
pub const ObjectTransmissionInformation = base.ObjectTransmissionInformation;
pub const PayloadId = base.PayloadId;

// Advanced use
pub const symbol = @import("codec/symbol.zig");
pub const octet = @import("math/octet.zig");

// Ensure all modules are compiled and tested
comptime {
    _ = @import("tables/octet_tables.zig");
    _ = @import("tables/rng_tables.zig");
    _ = @import("tables/systematic_constants.zig");
    _ = @import("math/octets.zig");
    _ = @import("math/gf2.zig");
    _ = @import("math/rng.zig");
    _ = @import("codec/operation_vector.zig");
    _ = @import("matrix/dense_binary_matrix.zig");
    _ = @import("matrix/sparse_matrix.zig");
    _ = @import("matrix/octet_matrix.zig");
    _ = @import("matrix/constraint_matrix.zig");
    _ = @import("solver/pi_solver.zig");
    _ = @import("solver/graph.zig");
    _ = @import("util/sparse_vec.zig");
    _ = @import("util/arraymap.zig");
    _ = @import("util/helpers.zig");
}
