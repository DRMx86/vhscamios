# VHS Cam iOS

A camera app that runs every frame through the [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) VHS effect.
Back camera by default; photo, video (with audio), front/back flip, and an effect on/off toggle.

- `rust/` – static library wrapping the `ntscrs` crate behind one C function (`vhs_process`)
- `Sources/` – SwiftUI shell + AVFoundation camera pipeline
- `project.yml` – XcodeGen spec (the `.xcodeproj` is generated)
- `.github/workflows/ios.yml` – builds Rust + the app on every push and uploads an unsigned `.ipa`

Install the unsigned IPA with Sideloadly / AltStore, or sign it with your own certificate.

Local build (macOS): `scripts/build_rust.sh && brew install xcodegen && xcodegen && open VHSCam.xcodeproj`
