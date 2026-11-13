# VHS Cam (iOS)

A camera app that runs the [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) VHS effect on live video.

- **Square 1:1 by default** (or Full frame), 480p / 720p / 1080p
- Portrait / landscape (Auto, or locked), back / front camera
- Frame rate: VHS (30), 23.976 or 29.97
- Looks: Classic, Clean SP, Home Video, RetroDann, RetroDann2, Muted, B&W, Worn Tape, plus film looks FunSaver, Gold 200, Tri-X B&W
- Live sliders: GRAIN, COLOR, DISTORTION, SOFTNESS, COMPOSITE noise, VIGNETTE, SNOW on/off + amount, lowpass filter (Butterworth / Constant-K)
- 3 custom preset slots (tap to load, long-press to save)
- Image stabilization toggle
- Photo and video capture (processed output saved to Photos, with audio)
- **Editor:** pick any photo/video from your library, preview it live with looks / presets / sliders, then Render to Photos
- **Presets:** 3 named slots, shown beside STAB when loaded

## How it works
`NtscCore/` is a small static library (`ntsc_ios`) that wraps the `ntsc-rs` crate behind a C API.
`VHSCam/` is a SwiftUI app: AVFoundation captures BGRA frames, they are center-cropped (1:1),
processed in place by Rust (VHS effect, then film grade / grain / vignette), shown via
`AVSampleBufferDisplayLayer` and optionally written with `AVAssetWriter`.

## Build
GitHub Actions (`.github/workflows/build.yml`) builds the Rust lib, generates the Xcode project with
XcodeGen, builds the app and uploads `VHSCam-unsigned.ipa`. Install it by re-signing with your Apple ID
(AltStore / Sideloadly).

Local build (macOS): `./build-rust.sh && brew install xcodegen && xcodegen generate && open VHSCam.xcodeproj`
