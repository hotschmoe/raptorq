// raptorq - Pure Zig implementation of RFC 6330 (RaptorQ FEC)

// Public API - codec modules
pub const encoder = @import("codec/encoder.zig");
pub const decoder = @import("codec/decoder.zig");
pub const base = @import("codec/base.zig");
pub const symbol = @import("codec/symbol.zig");
pub const operation_vector = @import("codec/operation_vector.zig");

// Public API - math modules
pub const octet = @import("math/octet.zig");
pub const octets = @import("math/octets.zig");
pub const gf2 = @import("math/gf2.zig");
pub const rng = @import("math/rng.zig");

// Public API - table modules
pub const octet_tables = @import("tables/octet_tables.zig");
pub const rng_tables = @import("tables/rng_tables.zig");
pub const systematic_constants = @import("tables/systematic_constants.zig");

// Public API - matrix modules
pub const dense_binary_matrix = @import("matrix/dense_binary_matrix.zig");
pub const sparse_matrix = @import("matrix/sparse_matrix.zig");
pub const octet_matrix = @import("matrix/octet_matrix.zig");
pub const constraint_matrix = @import("matrix/constraint_matrix.zig");

// Public API - solver modules
pub const pi_solver = @import("solver/pi_solver.zig");
pub const graph = @import("solver/graph.zig");

// Public API - utility modules
pub const sparse_vec = @import("util/sparse_vec.zig");
pub const arraymap = @import("util/arraymap.zig");
pub const helpers = @import("util/helpers.zig");

// Top-level type re-exports for convenience
pub const Encoder = encoder.Encoder;
pub const SourceBlockEncoder = encoder.SourceBlockEncoder;
pub const Decoder = decoder.Decoder;
pub const SourceBlockDecoder = decoder.SourceBlockDecoder;
pub const EncodingPacket = base.EncodingPacket;
pub const ObjectTransmissionInformation = base.ObjectTransmissionInformation;
pub const PayloadId = base.PayloadId;
