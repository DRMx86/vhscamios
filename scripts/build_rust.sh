#!/bin/bash
set -e

# 1. Get the target architecture from the first argument
TARGET=$1
if [ -z "$TARGET" ]; then
    echo "Error: No target architecture specified."
    echo "Usage: ./scripts/build_rust.sh <target>"
    exit 1
fi

# 2. Add the Rust standard library for the target architecture
echo "Adding Rust target: $TARGET"
rustup target add $TARGET

# 3. Navigate to the Rust project directory
cd rust

# 4. Build the Rust library in release mode for the specific target
echo "Building Rust library for $TARGET..."
cargo build --release --target $TARGET

# 5. Define the path to the built static library
LIB_PATH="target/$TARGET/release/libvhs_ffi.a"

# 6. Verify the library was built successfully
if [ ! -f "$LIB_PATH" ]; then
    echo "Error: Build failed. Library not found at $LIB_PATH"
    exit 1
fi

# 7. Create an output directory for Xcode to find the library
echo "Copying library to iOS project..."
mkdir -p ../VHSCam/rust_libs

# 8. Copy the static library
cp "$LIB_PATH" ../VHSCam/rust_libs/libvhs_ffi.a

echo "Build complete! Library copied to VHSCam/rust_libs/libvhs_ffi.a"
