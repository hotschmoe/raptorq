//! Generates RQ01 binary test vectors using the cberner/raptorq Rust crate.
//!
//! Run:    cd test/interop/rust_gen && cargo run
//! Output: test/fixtures/interop/*.bin
//!
//! Binary format (RQ01):
//!   [4B]  magic "RQ01"
//!   [12B] OTI (RFC 6330 wire format)
//!   [4B]  source_data_length (u32 big-endian)
//!   [N B] source_data
//!   [4B]  num_packets (u32 big-endian)
//!   For each packet:
//!     [4B]  PayloadId (8-bit SBN + 24-bit ESI, big-endian)
//!     [T B] symbol_data

#![allow(deprecated)]

use raptorq::{Encoder, EncodingPacket, ObjectTransmissionInformation};
use std::fs::{self, File};
use std::io::Write;

enum PacketStrategy {
    SourceOnly,
    SourcePlusRepair(u32),
    LossReplace { loss_pct: usize, overhead: u32 },
    RepairOnly(u32),
}

struct VectorSpec {
    name: &'static str,
    filename: &'static str,
    data_len: usize,
    data_a: u8,
    data_b: u8,
    symbol_size: u16,
    strategy: PacketStrategy,
}

fn generate_data(len: usize, a: u8, b: u8) -> Vec<u8> {
    (0..len)
        .map(|i| ((i as u64 * a as u64 + b as u64) % 256) as u8)
        .collect()
}

fn serialize_packets(packets: &[EncodingPacket]) -> Vec<Vec<u8>> {
    packets.iter().map(|p| p.serialize()).collect()
}

fn write_vector(
    path: &str,
    config: &ObjectTransmissionInformation,
    source_data: &[u8],
    packets: &[Vec<u8>],
) {
    let mut f = File::create(path).unwrap_or_else(|e| panic!("create {path}: {e}"));
    f.write_all(b"RQ01").unwrap();
    f.write_all(&config.serialize()).unwrap();
    f.write_all(&(source_data.len() as u32).to_be_bytes()).unwrap();
    f.write_all(source_data).unwrap();
    f.write_all(&(packets.len() as u32).to_be_bytes()).unwrap();
    for pkt in packets {
        f.write_all(pkt).unwrap();
    }
}

fn generate_vector(dir: &str, spec: &VectorSpec) {
    let data = generate_data(spec.data_len, spec.data_a, spec.data_b);
    let enc = Encoder::with_defaults(&data, spec.symbol_size);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();

    let pkts = match spec.strategy {
        PacketStrategy::SourceOnly => serialize_packets(&src),
        PacketStrategy::SourcePlusRepair(n) => {
            let rep = blocks[0].repair_packets(0, n);
            let mut pkts = serialize_packets(&src);
            pkts.extend(serialize_packets(&rep));
            pkts
        }
        PacketStrategy::LossReplace { loss_pct, overhead } => {
            let drop_count = std::cmp::max(k * loss_pct / 100, 1);
            let repair_count = (drop_count as u32) + overhead;
            let rep = blocks[0].repair_packets(0, repair_count);
            let mut pkts = serialize_packets(&src[..k - drop_count]);
            pkts.extend(serialize_packets(&rep));
            println!("  dropped={drop_count} repair={repair_count}");
            pkts
        }
        PacketStrategy::RepairOnly(n) => {
            let rep = blocks[0].repair_packets(0, n);
            println!("  repair only (no source packets)");
            serialize_packets(&rep)
        }
    };

    println!(
        "{}: F={} T={} Z={} N={} Al={} K={k} packets={}",
        spec.name,
        cfg.transfer_length(),
        cfg.symbol_size(),
        cfg.source_blocks(),
        cfg.sub_blocks(),
        cfg.symbol_alignment(),
        pkts.len(),
    );
    write_vector(&format!("{dir}/{}", spec.filename), &cfg, &data, &pkts);
}

fn main() {
    let dir = "../fixtures";
    fs::create_dir_all(dir).unwrap_or_else(|e| panic!("create {dir}: {e}"));
    println!("Generating RQ01 interop test vectors...\n");

    let specs = [
        VectorSpec {
            name: "v01",
            filename: "v01_small_source_only.bin",
            data_len: 64, data_a: 7, data_b: 13, symbol_size: 16,
            strategy: PacketStrategy::SourceOnly,
        },
        VectorSpec {
            name: "v02",
            filename: "v02_medium_with_repair.bin",
            data_len: 1024, data_a: 11, data_b: 23, symbol_size: 32,
            strategy: PacketStrategy::SourcePlusRepair(5),
        },
        VectorSpec {
            name: "v03",
            filename: "v03_large_symbol.bin",
            data_len: 4096, data_a: 13, data_b: 37, symbol_size: 256,
            strategy: PacketStrategy::SourcePlusRepair(5),
        },
        VectorSpec {
            name: "v04",
            filename: "v04_loss_10pct.bin",
            data_len: 512, data_a: 17, data_b: 41, symbol_size: 32,
            strategy: PacketStrategy::LossReplace { loss_pct: 10, overhead: 2 },
        },
        VectorSpec {
            name: "v05",
            filename: "v05_loss_50pct.bin",
            data_len: 512, data_a: 19, data_b: 43, symbol_size: 32,
            strategy: PacketStrategy::LossReplace { loss_pct: 50, overhead: 2 },
        },
        VectorSpec {
            name: "v06",
            filename: "v06_padding_uneven.bin",
            data_len: 100, data_a: 23, data_b: 47, symbol_size: 32,
            strategy: PacketStrategy::SourcePlusRepair(6),
        },
        VectorSpec {
            name: "v07",
            filename: "v07_minimum_k.bin",
            data_len: 16, data_a: 29, data_b: 53, symbol_size: 16,
            strategy: PacketStrategy::SourcePlusRepair(9),
        },
        VectorSpec {
            name: "v08",
            filename: "v08_repair_only.bin",
            data_len: 128, data_a: 31, data_b: 59, symbol_size: 32,
            strategy: PacketStrategy::RepairOnly(10),
        },
    ];

    for spec in &specs {
        generate_vector(dir, spec);
    }

    println!("\nDone. Vectors written to {dir}/");
}
