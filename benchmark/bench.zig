// RaptorQ benchmark
//
// Measures encode and decode throughput across data sizes.
// Symbol size is scaled with data size to keep K in a practical range (256-4096).
//
// Run: zig build bench
// (Forces ReleaseFast optimization -- Debug mode results are meaningless.)

const std = @import("std");
const raptorq = @import("raptorq");
const Encoder = raptorq.Encoder;
const Decoder = raptorq.Decoder;

const BenchCase = struct {
    data_size: usize,
    symbol_size: u16,
    label: []const u8,
};

const PacketData = struct {
    payload_id: raptorq.PayloadId,
    data: []const u8,
};

const cases = [_]BenchCase{
    .{ .data_size = 256, .symbol_size = 64, .label = "256 B" },
    .{ .data_size = 1024, .symbol_size = 64, .label = "1 KB" },
    .{ .data_size = 10240, .symbol_size = 64, .label = "10 KB" },
    .{ .data_size = 16384, .symbol_size = 64, .label = "16 KB" },
    .{ .data_size = 65536, .symbol_size = 64, .label = "64 KB" },
    .{ .data_size = 131072, .symbol_size = 256, .label = "128 KB" },
    .{ .data_size = 262144, .symbol_size = 256, .label = "256 KB" },
    .{ .data_size = 524288, .symbol_size = 1024, .label = "512 KB" },
    .{ .data_size = 1048576, .symbol_size = 1024, .label = "1 MB" },
    .{ .data_size = 2097152, .symbol_size = 2048, .label = "2 MB" },
    .{ .data_size = 4194304, .symbol_size = 2048, .label = "4 MB" },
    .{ .data_size = 10485760, .symbol_size = 4096, .label = "10 MB" },
};

fn median(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

fn runEncode(allocator: std.mem.Allocator, data: []const u8, symbol_size: u16) !void {
    var enc = try Encoder.init(allocator, data, symbol_size, 1, 4);
    defer enc.deinit();
    const k_prime = enc.sub_encoders[0].k_prime;
    var esi: u32 = 0;
    while (esi < k_prime) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        allocator.free(pkt.data);
    }
}

fn benchEncode(allocator: std.mem.Allocator, data: []const u8, symbol_size: u16, warmup: usize, iters: usize) !u64 {
    var buf: [64]u64 = undefined;
    const samples = buf[0..iters];

    for (0..warmup) |_| try runEncode(allocator, data, symbol_size);

    for (0..iters) |i| {
        const start = std.time.Instant.now() catch unreachable;
        try runEncode(allocator, data, symbol_size);
        const end = std.time.Instant.now() catch unreachable;
        samples[i] = end.since(start);
    }

    return median(samples);
}

fn benchDecode(allocator: std.mem.Allocator, data: []const u8, symbol_size: u16, warmup: usize, iters: usize) !u64 {
    var buf: [64]u64 = undefined;
    const samples = buf[0..iters];

    // Pre-generate packets outside timed section.
    // Drop 10% of source symbols, replace with repair.
    var enc = try Encoder.init(allocator, data, symbol_size, 1, 4);
    defer enc.deinit();

    const k = enc.sourceBlockK(0);
    const k_prime = enc.sub_encoders[0].k_prime;
    const drop_count = @max(k / 10, 1);
    const repair_needed = k_prime - (k - drop_count);

    const packets = try allocator.alloc(PacketData, k_prime);
    defer {
        for (packets) |p| allocator.free(p.data);
        allocator.free(packets);
    }

    var pkt_idx: usize = 0;
    // Source symbols (skipping first drop_count)
    var esi: u32 = drop_count;
    while (esi < k) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        packets[pkt_idx] = .{ .payload_id = pkt.payload_id, .data = pkt.data };
        pkt_idx += 1;
    }
    // Repair symbols
    esi = k;
    while (esi < k + repair_needed) : (esi += 1) {
        const pkt = try enc.encode(0, esi);
        packets[pkt_idx] = .{ .payload_id = pkt.payload_id, .data = pkt.data };
        pkt_idx += 1;
    }

    const oti = enc.objectTransmissionInformation();

    for (0..warmup) |_| try runDecode(allocator, oti, packets);

    for (0..iters) |i| {
        const start = std.time.Instant.now() catch unreachable;
        try runDecode(allocator, oti, packets);
        const end = std.time.Instant.now() catch unreachable;
        samples[i] = end.since(start);
    }

    return median(samples);
}

fn runDecode(allocator: std.mem.Allocator, oti: raptorq.ObjectTransmissionInformation, packets: []const PacketData) !void {
    var dec = try Decoder.init(allocator, oti);
    defer dec.deinit();
    for (packets) |p| {
        try dec.addPacket(.{ .payload_id = p.payload_id, .data = p.data });
    }
    const decoded = (try dec.decode()).?;
    allocator.free(decoded);
}

fn mbps(data_size: usize, median_ns: u64) f64 {
    if (median_ns == 0) return 0;
    return @as(f64, @floatFromInt(data_size)) * 1000.0 / @as(f64, @floatFromInt(median_ns));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("raptorq benchmark (Zig)\n", .{});
    try stdout.print("Loss: 10%, Warmup: 3 (1 for >=1MB), Iterations: 11 (5 for >=1MB)\n\n", .{});
    try stdout.print("{s:<11}| {s:<7}| {s:<12}| {s:<12}\n", .{ "Size", "T", "Encode MB/s", "Decode MB/s" });
    try stdout.print("{s:-<11}|{s:-<8}|{s:-<13}|{s:-<12}\n", .{ "", "", "", "" });

    for (cases) |c| {
        const data = try allocator.alloc(u8, c.data_size);
        defer allocator.free(data);
        for (data, 0..) |*d, i| d.* = @intCast((i * 31 + 17) % 256);

        const warmup: usize = if (c.data_size >= 1048576) 1 else 3;
        const iters: usize = if (c.data_size >= 1048576) 5 else 11;

        const enc_ns = try benchEncode(allocator, data, c.symbol_size, warmup, iters);
        const dec_ns = try benchDecode(allocator, data, c.symbol_size, warmup, iters);

        const enc_mbps = mbps(c.data_size, enc_ns);
        const dec_mbps = mbps(c.data_size, dec_ns);

        try stdout.print("{s:<11}| {d:<7}| {d:<12.1}| {d:<12.1}\n", .{ c.label, c.symbol_size, enc_mbps, dec_mbps });
    }
}
