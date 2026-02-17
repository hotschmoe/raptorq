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

fn generate_data(len: usize, a: u8, b: u8) -> Vec<u8> {
    (0..len)
        .map(|i| ((i as u64 * a as u64 + b as u64) % 256) as u8)
        .collect()
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

fn serialize_all(packets: &[EncodingPacket]) -> Vec<Vec<u8>> {
    packets.iter().map(|p| p.serialize()).collect()
}

fn serialize_range(packets: &[EncodingPacket], range: std::ops::Range<usize>) -> Vec<Vec<u8>> {
    packets[range].iter().map(|p| p.serialize()).collect()
}

fn log_case(name: &str, config: &ObjectTransmissionInformation, k: usize, num_packets: usize) {
    println!(
        "{name}: F={} T={} Z={} N={} Al={} K={k} packets={num_packets}",
        config.transfer_length(),
        config.symbol_size(),
        config.source_blocks(),
        config.sub_blocks(),
        config.symbol_alignment(),
    );
}

fn main() {
    let dir = "../fixtures";
    fs::create_dir_all(dir).unwrap_or_else(|e| panic!("create {dir}: {e}"));
    println!("Generating RQ01 interop test vectors...\n");

    gen_v01(dir);
    gen_v02(dir);
    gen_v03(dir);
    gen_v04(dir);
    gen_v05(dir);
    gen_v06(dir);
    gen_v07(dir);
    gen_v08(dir);

    println!("\nDone. Vectors written to {dir}/");
}

// v01: 64B, T=16, source only -- baseline systematic decode
fn gen_v01(dir: &str) {
    let data = generate_data(64, 7, 13);
    let enc = Encoder::with_defaults(&data, 16);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();
    let pkts = serialize_all(&src);
    log_case("v01", &cfg, k, pkts.len());
    write_vector(&format!("{dir}/v01_small_source_only.bin"), &cfg, &data, &pkts);
}

// v02: 1024B, T=32, source + 5 repair -- mixed source/repair decode
fn gen_v02(dir: &str) {
    let data = generate_data(1024, 11, 23);
    let enc = Encoder::with_defaults(&data, 32);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();
    let rep = blocks[0].repair_packets(0, 5);
    let mut pkts = serialize_all(&src);
    pkts.extend(serialize_all(&rep));
    log_case("v02", &cfg, k, pkts.len());
    write_vector(&format!("{dir}/v02_medium_with_repair.bin"), &cfg, &data, &pkts);
}

// v03: 4096B, T=256, source + 5 repair -- large symbol handling
fn gen_v03(dir: &str) {
    let data = generate_data(4096, 13, 37);
    let enc = Encoder::with_defaults(&data, 256);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();
    let rep = blocks[0].repair_packets(0, 5);
    let mut pkts = serialize_all(&src);
    pkts.extend(serialize_all(&rep));
    log_case("v03", &cfg, k, pkts.len());
    write_vector(&format!("{dir}/v03_large_symbol.bin"), &cfg, &data, &pkts);
}

// v04: 512B, T=32, drop 10% source, replace with repair + 2 overhead
fn gen_v04(dir: &str) {
    let data = generate_data(512, 17, 41);
    let enc = Encoder::with_defaults(&data, 32);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();
    let drop_count = std::cmp::max(k / 10, 1);
    let repair_count = (drop_count + 2) as u32;
    let rep = blocks[0].repair_packets(0, repair_count);
    let mut pkts = serialize_range(&src, 0..k - drop_count);
    pkts.extend(serialize_all(&rep));
    log_case("v04", &cfg, k, pkts.len());
    println!("  dropped={drop_count} repair={repair_count}");
    write_vector(&format!("{dir}/v04_loss_10pct.bin"), &cfg, &data, &pkts);
}

// v05: 512B, T=32, drop 50% source, replace with repair + 2 overhead
fn gen_v05(dir: &str) {
    let data = generate_data(512, 19, 43);
    let enc = Encoder::with_defaults(&data, 32);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();
    let drop_count = k / 2;
    let repair_count = (drop_count + 2) as u32;
    let rep = blocks[0].repair_packets(0, repair_count);
    let mut pkts = serialize_range(&src, 0..k - drop_count);
    pkts.extend(serialize_all(&rep));
    log_case("v05", &cfg, k, pkts.len());
    println!("  dropped={drop_count} repair={repair_count}");
    write_vector(&format!("{dir}/v05_loss_50pct.bin"), &cfg, &data, &pkts);
}

// v06: 100B, T=32, source + 6 repair -- non-aligned data (100/32 != integer)
fn gen_v06(dir: &str) {
    let data = generate_data(100, 23, 47);
    let enc = Encoder::with_defaults(&data, 32);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();
    let rep = blocks[0].repair_packets(0, 6);
    let mut pkts = serialize_all(&src);
    pkts.extend(serialize_all(&rep));
    log_case("v06", &cfg, k, pkts.len());
    write_vector(&format!("{dir}/v06_padding_uneven.bin"), &cfg, &data, &pkts);
}

// v07: 16B, T=16, 1 source + 9 repair -- minimum K boundary (K=1, K'=10)
fn gen_v07(dir: &str) {
    let data = generate_data(16, 29, 53);
    let enc = Encoder::with_defaults(&data, 16);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let src = blocks[0].source_packets();
    let k = src.len();
    let rep = blocks[0].repair_packets(0, 9);
    let mut pkts = serialize_all(&src);
    pkts.extend(serialize_all(&rep));
    log_case("v07", &cfg, k, pkts.len());
    write_vector(&format!("{dir}/v07_minimum_k.bin"), &cfg, &data, &pkts);
}

// v08: 128B, T=32, repair only (0 source, 10 repair) -- full repair decode
fn gen_v08(dir: &str) {
    let data = generate_data(128, 31, 59);
    let enc = Encoder::with_defaults(&data, 32);
    let cfg = enc.get_config();
    let blocks = enc.get_block_encoders();
    let k = blocks[0].source_packets().len();
    let rep = blocks[0].repair_packets(0, 10);
    let pkts = serialize_all(&rep);
    log_case("v08", &cfg, k, pkts.len());
    println!("  repair only (no source packets)");
    write_vector(&format!("{dir}/v08_repair_only.bin"), &cfg, &data, &pkts);
}
