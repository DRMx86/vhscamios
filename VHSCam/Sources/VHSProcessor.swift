import CoreVideo

/// Swift wrapper around one ntsc-rs processor instance (Rust, via C FFI).
/// The camera, the editor preview and the editor render each use their own instance.
final class VHSProcessor {
    private var handle: OpaquePointer?

    init() { handle = ntsc_create() }

    deinit { if let handle { ntsc_destroy(handle) } }

    func update(_ t: TapeSettings) {
        guard let handle else { return }
        var p = NtscParams(
            vhs_on: t.vhsOn ? 1 : 0,
            tape_speed: Int32(t.tapeSpeed),
            filter_type: Int32(t.filter.rawValue),
            snow_on: t.snowOn ? 1 : 0,
            grain: Float(t.grain),
            color: Float(t.color),
            tracking: Float(t.tracking),
            softness: Float(t.softness),
            composite_noise: Float(t.compositeNoise),
            snow: Float(t.snow),
            vignette: Float(t.vignette),
            tint_r: Float(t.tintR), tint_g: Float(t.tintG), tint_b: Float(t.tintB),
            contrast: Float(t.contrast),
            film_grain: Float(t.filmGrain))
        ntsc_set_params(handle, &p)
    }

    /// Processes a BGRA pixel buffer in place.
    @discardableResult
    func process(_ pixelBuffer: CVPixelBuffer, frame: UInt64) -> Bool {
        guard let handle else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        return ntsc_process_bgra(
            handle,
            base.assumingMemoryBound(to: UInt8.self),
            UInt32(CVPixelBufferGetWidth(pixelBuffer)),
            UInt32(CVPixelBufferGetHeight(pixelBuffer)),
            UInt32(CVPixelBufferGetBytesPerRow(pixelBuffer)),
            frame) == 0
    }
}
