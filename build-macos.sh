#!/usr/bin/env bash
# Local macOS build: universal (arm64 + x86_64) Rust lib -> Xcode project -> .app
set -euo pipefail
cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=14.0

rustup target add aarch64-apple-darwin x86_64-apple-darwin
( cd NtscCore
  cargo build --release --target aarch64-apple-darwin
  cargo build --release --target x86_64-apple-darwin
  mkdir -p target/universal/release
  lipo -create \
    target/aarch64-apple-darwin/release/libntsc_ios.a \
    target/x86_64-apple-darwin/release/libntsc_ios.a \
    -output target/universal/release/libntsc_ios.a )

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
xcodebuild -project VHSCamMac.xcodeproj -scheme VHSCamMac -configuration Release \
  -derivedDataPath build build
echo "App: build/Build/Products/Release/VHS Cam.app"
open build/Build/Products/Release
