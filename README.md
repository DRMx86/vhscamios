# VHS Cam (iOS)

A camera app that runs the [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) VHS effect on live video.

- **Back camera is the default** (flip button for the front camera)
- Live preview with the effect applied, 30 fps
- Photo and video capture (processed output saved to Photos, with audio)
- Looks: Light / Classic / Worn Tape, plus an intensity slider
- 480p (authentic, fastest) or 720p

## How it works
`NtscCore/` is a small static library (`ntsc_ios`) that wraps the `ntsc-rs` crate behind a C API.
`VHSCam/` is a SwiftUI app: AVFoundation captures BGRA frames, each frame is processed in place by Rust,
then shown via `AVSampleBufferDisplayLayer` and optionally written with `AVAssetWriter`.

## Build
GitHub Actions (`.github/workflows/build.yml`) builds the Rust lib for `aarch64-apple-ios`, generates the
Xcode project with XcodeGen, builds the app and uploads `VHSCam-unsigned.ipa` as an artifact.

The IPA is **unsigned**: install it by re-signing with your own Apple ID via AltStore / Sideloadly,
or add signing to the workflow.

Local build (macOS): `./build-rust.sh && brew install xcodegen && xcodegen generate && open VHSCam.xcodeproj`
