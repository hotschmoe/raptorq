# Rust-to-Zig Translation Notes

## Language Differences

### Memory Management
- Rust: Ownership + borrowing, Vec<u8> with implicit allocation
- Zig: Explicit allocator parameter, caller manages lifetime
- Impact: All constructors take `std.mem.Allocator`, all collections need explicit deinit

### Error Handling
- Rust: Result<T, E> with ? operator
- Zig: !T error union with try keyword
- Impact: Direct mapping, similar ergonomics

### Generics / Trait System
- Rust: Traits (BinaryMatrix, OctetMatrix traits)
- Zig: Comptime interfaces, duck typing
- Impact: May use tagged unions or comptime dispatch instead of trait objects

### SIMD
- Rust: Uses std::simd or manual intrinsics in octets.rs
- Zig: @Vector built-in for portable SIMD
- Impact: Can leverage Zig's first-class SIMD support

### Const Evaluation
- Rust: const fn (limited), lazy_static for tables
- Zig: Comprehensive comptime, @embedFile for large tables
- Impact: Tables can be computed or embedded at compile time

## Naming Conventions
- Rust snake_case functions -> Zig camelCase
- Rust PascalCase types -> Zig PascalCase (same)
- Rust SCREAMING_SNAKE constants -> Zig SCREAMING_SNAKE (same)
- Rust mod.rs -> Zig root.zig or directory imports

## Key Translation Patterns
- `Vec<T>` -> `std.ArrayList(T)`
- `HashMap<K,V>` -> `std.AutoHashMap(K,V)`
- `&[u8]` -> `[]const u8`
- `&mut [u8]` -> `[]u8`
- `impl Struct` -> methods inside `pub const Struct = struct { ... }`
- `trait Foo` -> consider comptime interface or tagged union
