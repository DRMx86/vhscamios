# VHS Cam (macOS)

Live VHS look for your Mac camera, powered by [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs).

- **Any camera**: built-in FaceTime camera, USB/UVC webcams and capture cards, and an **iPhone via Continuity Camera** (including Desk View). Pick the camera and microphone in the sidebar; hot-plugging is detected automatically.
- **Any microphone**: Mac mic, iPhone mic, USB camera/audio-interface mic, or "No audio".
- Eight looks (Classic, Clean SP, Home Video, **RetroDann**, **RetroDann2**, Muted, B&W, Worn Tape) plus GRAIN / COLOR / DISTORTION / SOFTNESS sliders
- 480p (authentic, fastest) or 720p, 30 fps
- Photo → `~/Pictures/VHS Cam`, video (with audio) → `~/Movies/VHS Cam`. Space bar is the shutter.

## Continuity Camera
Needs macOS 14+, an iPhone (XS or newer) signed into the same Apple ID, Wi-Fi + Bluetooth on, and the iPhone near the Mac.
It appears in the Camera menu as "<name>'s iPhone Camera". If it's your Mac's preferred camera it is chosen automatically.

## Build
GitHub Actions (`.github/workflows/build-macos.yml`) builds a universal (Apple Silicon + Intel) Rust lib, generates the Xcode project with XcodeGen and uploads `VHSCam-macOS.zip`.
Local: `./build-macos.sh`

The app is **ad-hoc signed, not notarized**. After unzipping: right-click → Open the first time, or
`xattr -dr com.apple.quarantine "VHS Cam.app"`. Grant Camera and Microphone when prompted.
