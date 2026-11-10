# VHS Cam (Android)

Live VHS look on your phone camera, powered by [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) (same Rust core as the iOS and macOS apps).

- Back camera by default, flip for the front camera
- Live preview with the effect at ~30 fps, portrait and landscape (VHS noise band always at the bottom)
- Photo → `Pictures/VHS Cam`, video with audio → `Movies/VHS Cam` (processed output)
- Eight looks (Classic, Clean SP, Home Video, **RetroDann**, **RetroDann2**, Muted, B&W, Worn Tape) plus GRAIN / COLOR / DISTORTION / SOFTNESS sliders
- 480p (authentic, fastest) or 720p

## How it works
`NtscCore/` is the shared Rust effect library. `NtscAndroid/` is a tiny JNI crate (`libntsc_android.so`) on top of it.
The Kotlin/Compose app uses CameraX `ImageAnalysis` (RGBA frames), rotates them upright, runs them through Rust in place,
shows the result, and feeds it to a MediaCodec H.264 + AAC encoder (`Recorder.kt`) when recording.

## Build
GitHub Actions (`.github/workflows/build-android.yml`) builds the Rust lib with `cargo-ndk` and a **debug-signed APK**
(`app-debug.apk`, installable directly: enable "install unknown apps" on the phone). arm64 devices only; Android 10+.

Local: `rustup target add aarch64-linux-android && cargo install cargo-ndk`, then
`cd NtscAndroid && cargo ndk -t arm64-v8a -P 29 -o ../app/src/main/jniLibs build --release`, then open the folder in Android Studio.
