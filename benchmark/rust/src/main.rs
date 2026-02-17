// RaptorQ benchmark (Rust - cberner/raptorq)
//
// Mirrors the Zig benchmark for fair comparison.
// Run: cd benchmark/rust && cargo run --release
//
// Note: The Rust raptorq crate's decoder.decode(packet) both adds a packet AND
// attempts decoding on every call. The Zig API separates addPacket from decode().
// Both benchmarks use the natural API for their implementation.

use raptorq::{Encoder, EncodingPacket};
use std::time::Instant;

struct BenchCase {
    data_size: usize,
    symbol_size: u16,
    label: &'static str,
}

const CASES: &[BenchCase] = &[
    BenchCase { data_size: 256, symbol_size: 64, label: "256 B" },
    BenchCase { data_size: 1024, symbol_size: 64, label: "1 KB" },
    BenchCase { data_size: 10240, symbol_size: 64, label: "10 KB" },
    BenchCase { data_size: 16384, symbol_size: 64, label: "16 KB" },
    BenchCase { data_size: 65536, symbol_size: 64, label: "64 KB" },
    BenchCase { data_size: 131072, symbol_size: 256, label: "128 KB" },
    BenchCase { data_size: 262144, symbol_size: 256, label: "256 KB" },
    BenchCase { data_size: 524288, symbol_size: 1024, label: "512 KB" },
    BenchCase { data_size: 1048576, symbol_size: 1024, label: "1 MB" },
    BenchCase { data_size: 2097152, symbol_size: 2048, label: "2 MB" },
    BenchCase { data_size: 4194304, symbol_size: 2048, label: "4 MB" },
    BenchCase { data_size: 10485760, symbol_size: 4096, label: "10 MB" },
];

fn generate_data(size: usize) -> Vec<u8> {
    (0..size)
        .map(|i| ((i as u64 * 31 + 17) % 256) as u8)
        .collect()
}

fn median(samples: &mut [u128]) -> u128 {
    samples.sort();
    samples[samples.len() / 2]
}

fn bench_encode(data: &[u8], symbol_size: u16, warmup: usize, iters: usize) -> u128 {
    for _ in 0..warmup {
        let enc = Encoder::with_defaults(data, symbol_size);
        for block in enc.get_block_encoders() {
            let _src = block.source_packets();
        }
    }

    let mut samples = vec![0u128; iters];
    for sample in samples.iter_mut() {
        let start = Instant::now();
        let enc = Encoder::with_defaults(data, symbol_size);
        for block in enc.get_block_encoders() {
            // source_packets() triggers the full encode pipeline (constraint matrix + PI solver).
            let k = block.source_packets().len() as u32;
            let _rep = block.repair_packets(0, (k / 10).max(1));
        }
        *sample = start.elapsed().as_nanos();
    }

    median(&mut samples)
}

fn bench_decode(data: &[u8], symbol_size: u16, warmup: usize, iters: usize) -> u128 {
    // Pre-generate packets outside timed section
    let enc = Encoder::with_defaults(data, symbol_size);
    let config = enc.get_config();
    let blocks = enc.get_block_encoders();
    let block = &blocks[0];
    let src = block.source_packets();
    let k = src.len();
    let drop_count = (k / 10).max(1);

    // Keep source packets after dropping first 10%
    let kept_source: Vec<Vec<u8>> = src[drop_count..].iter().map(|p| p.serialize()).collect();

    // Generate enough repair packets to compensate
    let repair_count = drop_count as u32 + 2; // small overhead
    let repair: Vec<Vec<u8>> = block
        .repair_packets(0, repair_count)
        .iter()
        .map(|p| p.serialize())
        .collect();

    let transfer_length = config.transfer_length();

    // Warmup
    for _ in 0..warmup {
        let mut dec = raptorq::Decoder::new(config);
        for pkt_data in &kept_source {
            let pkt = EncodingPacket::deserialize(pkt_data);
            dec.decode(pkt);
        }
        for pkt_data in &repair {
            let pkt = EncodingPacket::deserialize(pkt_data);
            if let Some(_result) = dec.decode(pkt) {
                break;
            }
        }
    }

    let mut samples = vec![0u128; iters];
    for sample in samples.iter_mut() {
        let start = Instant::now();
        let mut dec = raptorq::Decoder::new(config);
        for pkt_data in &kept_source {
            let pkt = EncodingPacket::deserialize(pkt_data);
            dec.decode(pkt);
        }
        for pkt_data in &repair {
            let pkt = EncodingPacket::deserialize(pkt_data);
            if let Some(result) = dec.decode(pkt) {
                assert_eq!(result.len(), transfer_length as usize);
                break;
            }
        }
        *sample = start.elapsed().as_nanos();
    }

    median(&mut samples)
}

fn mbps(data_size: usize, median_ns: u128) -> f64 {
    if median_ns == 0 {
        return 0.0;
    }
    data_size as f64 * 1000.0 / median_ns as f64
}

fn main() {
    println!("raptorq benchmark (Rust - cberner/raptorq v2.0)");
    println!("Loss: 10%, Warmup: 3 (1 for >=1MB), Iterations: 11 (5 for >=1MB)\n");
    println!(
        "{:<11}| {:<7}| {:<12}| {:<12}",
        "Size", "T", "Encode MB/s", "Decode MB/s"
    );
    println!("{:-<11}|{:-<8}|{:-<13}|{:-<12}", "", "", "", "");

    for c in CASES {
        let data = generate_data(c.data_size);
        let warmup = if c.data_size >= 1_048_576 { 1 } else { 3 };
        let iters = if c.data_size >= 1_048_576 { 5 } else { 11 };

        let enc_ns = bench_encode(&data, c.symbol_size, warmup, iters);
        let dec_ns = bench_decode(&data, c.symbol_size, warmup, iters);

        let enc_mbps = mbps(c.data_size, enc_ns);
        let dec_mbps = mbps(c.data_size, dec_ns);

        println!(
            "{:<11}| {:<7}| {:<12.1}| {:<12.1}",
            c.label, c.symbol_size, enc_mbps, dec_mbps
        );
    }
}
