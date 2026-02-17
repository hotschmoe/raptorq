// PI solver profiler
//
// Runs single encode passes at representative K values with solver profiling
// enabled. Outputs per-phase timing to stderr for analysis.
//
// Run: zig build profile

const std = @import("std");
const raptorq = @import("raptorq");
const Encoder = raptorq.Encoder;

const ProfileCase = struct {
    data_size: usize,
    symbol_size: u16,
    label: []const u8,
};

const cases = [_]ProfileCase{
    .{ .data_size = 1024, .symbol_size = 64, .label = "1 KB (K~16)" },
    .{ .data_size = 10240, .symbol_size = 64, .label = "10 KB (K~160)" },
    .{ .data_size = 65536, .symbol_size = 64, .label = "64 KB (K~1024)" },
    .{ .data_size = 131072, .symbol_size = 256, .label = "128 KB (K~512)" },
    .{ .data_size = 262144, .symbol_size = 256, .label = "256 KB (K~1024)" },
    .{ .data_size = 524288, .symbol_size = 1024, .label = "512 KB (K~512)" },
    .{ .data_size = 1048576, .symbol_size = 1024, .label = "1 MB (K~1024)" },
    .{ .data_size = 4194304, .symbol_size = 2048, .label = "4 MB (K~2048)" },
    .{ .data_size = 10485760, .symbol_size = 4096, .label = "10 MB (K~2560)" },
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    try stdout.print("PI Solver Profiler (ReleaseFast)\n", .{});
    try stdout.print("Per-phase timing for single encode pass\n\n", .{});

    // Enable solver profiling
    raptorq.pi_solver.profile_enabled = true;

    for (cases) |c| {
        const data = try allocator.alloc(u8, c.data_size);
        defer allocator.free(data);
        for (data, 0..) |*d, i| d.* = @intCast((i * 31 + 17) % 256);

        try stderr.print("\n--- {s} ---\n", .{c.label});

        // Warmup (1 pass, not profiled)
        raptorq.pi_solver.profile_enabled = false;
        {
            var enc = try Encoder.init(allocator, data, c.symbol_size, 1, 4);
            enc.deinit();
        }
        raptorq.pi_solver.profile_enabled = true;

        // Profiled pass: time the full encode (init triggers the solve)
        const start = std.time.Instant.now() catch unreachable;
        var enc = try Encoder.init(allocator, data, c.symbol_size, 1, 4);
        const after_init = std.time.Instant.now() catch unreachable;

        const k = enc.sourceBlockK(0);
        const repair_count = @max(k / 10, 1);
        var esi: u32 = 0;
        while (esi < k + repair_count) : (esi += 1) {
            const pkt = try enc.encode(0, esi);
            allocator.free(pkt.data);
        }
        const after_encode = std.time.Instant.now() catch unreachable;
        enc.deinit();

        const init_us = after_init.since(start) / 1000;
        const sym_gen_us = after_encode.since(after_init) / 1000;
        const total_us = after_encode.since(start) / 1000;

        try stderr.print("  Encoder.init (matrix build + solve): {d}us\n", .{init_us});
        try stderr.print("  Symbol generation ({d} source + {d} repair): {d}us\n", .{ k, repair_count, sym_gen_us });
        try stderr.print("  Total: {d}us\n", .{total_us});
    }
}
