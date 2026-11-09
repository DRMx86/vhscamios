#!/usr/bin/env bash
# Local helper: build the Rust static libs, then `xcodegen generate` and open the project.
set -euo pipefail
cd "$(dirname "$0")/Rust"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
