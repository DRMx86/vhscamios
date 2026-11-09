#!/usr/bin/env bash
# Usage: scripts/build_rust.sh [aarch64-apple-ios | aarch64-apple-ios-sim]
set -euo pipefail
TARGET="${1:-aarch64-apple-ios}"
cd "$(dirname "$0")/../rust"
rustup target add "$TARGET"
cargo build --release --target "$TARGET"
mkdir -p lib
cp "target/$TARGET/release/libvhs_ffi.a" lib/
