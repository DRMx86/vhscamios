#!/bin/bash
set -e

TARGET=$1

if [ -z "$TARGET" ]; then
    echo "Error: No target specified."
    echo "Usage: $0 <target>"
    exit 1
fi

echo "Adding Rust target $TARGET..."
rustup target add $TARGET

echo "Building Rust library for $TARGET..."
cd rust
cargo build --release --target $TARGET
