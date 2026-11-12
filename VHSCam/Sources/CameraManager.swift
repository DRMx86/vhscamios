import AVFoundation
import Photos
import UIKit
import CoreImage

/// Captures camera frames, optionally center-crops them to a square, runs each through the
/// ntsc-rs VHS effect + film grade (Rust, via C FFI), shows the result live, and can save the
/// processed output as a photo or video.
final class CameraManager: NSObject, ObservableObject,
                           AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {

    enum CaptureMode { case photo, video }

    // MARK: Published UI state (main thread)
    @Published var settings: Settings = CameraManager.load(Settings.self, key: "vhscam.settings.v2") ?? Settings() {
        didSet { settingsDidChange(from: oldValue) }
    }
    /// Three named preset slots (full settings: format + tape). Exportable as ".drm" files.
    @Published var slots: [Preset?] = CameraManager.load([Preset?].self, key: "vhscam.presets.v1") ?? [nil, nil, nil] {
        didSet { Self.save(slots, key: "vhscam.presets.v1") }
    }
    /// The preset slot that was last loaded or saved (nil after picking a look).
    @Published var activeSlot: Int?
    @Published var captureMode: CaptureMode = .video
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var statusMessage: String?
    @Published var cameraDenied = false

    /// Displays processed frames.
    let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: Capture plumbing
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "vhscam.session")
    /// Video and audio callbacks share one serial queue so writer access needs no extra locking.
    private let mediaQueue = DispatchQueue(label: "vhscam.media", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAdded = false
    private var micAvailable = false

    // sessionQueue only
    private var captureOrientation: AVCaptureVideoOrientation = .portrait
    private var wantsStabilization = false

    // main thread only
    private var applyingLook = false
    private var lastDeviceOrientation: UIDeviceOrientation = .portrait
    private var timer: Timer?

    // MARK: ntsc-rs
    private let processor = VHSProcessor()
    private var frameCounter: UInt64 = 0

    // MARK: mediaQueue-only state
    private var mediaFormat = FormatSettings()
    private var wantsRecording = false
    private var wantsPhoto = false
    private var writer: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private let ciContext = CIContext()
    private var cropPool: CVPixelBufferPool?
    private var cropSide = 0

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        pushParams()
        let f = settings.format
        mediaQueue.async { self.mediaFormat = f }

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        noteDeviceOrientation()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceOrientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // MARK: Persistence
    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
    private static func save<T: Encodable>(_ value: T, key: String) {
        if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: key) }
    }

    // MARK: Lifecycle

    func start() {
        noteDeviceOrientation()
        updateOrientation()
        refreshInterfaceMask()
        requestPermissions { [weak self] videoGranted in
            guard let self else { return }
            DispatchQueue.main.async {
                guard videoGranted else { self.cameraDenied = true; return }
                let f = self.settings.format
                self.mediaQueue.async { self.mediaFormat = f }
                self.sessionQueue.async {
                    self.wantsStabilization = f.stabilization
                    self.configureSession(format: f)
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    completion(videoOK)
                }
            }
        }
    }

    // MARK: Settings changes

    private func settingsDidChange(from old: Settings) {
        // Format changes would alter the recorded frame size / timing: ignore while recording.
        if isRecording && settings.format != old.format {
            settings.format = old.format
        }
        // Moving any tape control makes the look "custom".
        if !applyingLook && settings.tape.lookIndex != nil {
            var a = settings.tape, b = old.tape
            a.lookIndex = nil; b.lookIndex = nil
            if a != b { settings.tape.lookIndex = nil }
        }

        let new = settings
        Self.save(new, key: "vhscam.settings.v2")
        pushParams()

        let f = new.format
        let o = old.format
        if f != o { mediaQueue.async { self.mediaFormat = f } }

        if f.camera != o.camera || f.resolution != o.resolution {
            reconfigure()
        } else {
            if f.fps != o.fps {
                sessionQueue.async { self.applyFrameRate(f.fps) }
            }
            if f.stabilization != o.stabilization {
                sessionQueue.async {
                    self.wantsStabilization = f.stabilization
                    self.applyConnection()
                }
            }
        }
        if f.orientation != o.orientation {
            updateOrientation()
            refreshInterfaceMask()
        }
    }

    private func pushParams() {
        processor.update(settings.tape)
    }

    // MARK: Looks and presets

    func select(look index: Int) {
        guard Look.all.indices.contains(index) else { return }
        applyingLook = true
        var s = settings
        s.tape.apply(Look.all[index], index: index)
        settings = s
        applyingLook = false
        activeSlot = nil
    }

    func defaultName(_ i: Int) -> String { "Preset \(i + 1)" }

    /// Stores `s` in slot `i`, keeping the slot's name if it already has one.
    func storePreset(_ s: Settings, slot i: Int) {
        guard slots.indices.contains(i) else { return }
        slots[i] = Preset(name: slots[i]?.name ?? defaultName(i), settings: s)
        activeSlot = i
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        toast("Saved to P\(i + 1)")
    }

    func saveSlot(_ i: Int) { storePreset(settings, slot: i) }

    func loadSlot(_ i: Int) {
        guard slots.indices.contains(i) else { return }
        guard var s = slots[i]?.settings else { toast("P\(i + 1) is empty · long-press to save"); return }
        if isRecording { s.format = settings.format }   // keep the frame size while recording
        applyingLook = true
        settings = s
        applyingLook = false
        activeSlot = i
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        toast("Loaded P\(i + 1) · \(slots[i]?.displayName ?? "")")
    }

    func renameSlot(_ i: Int, _ name: String) {
        guard slots.indices.contains(i), slots[i] != nil else { return }
        slots[i]?.name = String(name.prefix(24))
    }

    func clearSlot(_ i: Int) {
        guard slots.indices.contains(i) else { return }
        slots[i] = nil
        if activeSlot == i { activeSlot = nil }
    }

    /// Writes the preset to a temporary ".drm" file for sharing / saving to Files.
    func presetFile(_ i: Int) -> URL? {
        guard slots.indices.contains(i), let p = slots[i], let data = p.fileData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(p.fileName)
        try? FileManager.default.removeItem(at: url)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Imports a ".drm" file into slot `i`.
    func importPreset(_ data: Data, into i: Int) -> Bool {
        guard slots.indices.contains(i), let p = Preset.decode(data) else { return false }
        slots[i] = p
        toast("Imported \(p.displayName) to P\(i + 1)")
        return true
    }

    func resetSettings() {
        applyingLook = true
        var s = Settings()
        if isRecording { s.format = settings.format }
        settings = s
        applyingLook = false
        activeSlot = nil
    }

    // MARK: Session configuration (sessionQueue)

    private func configureSession(format: FormatSettings) {
        session.beginConfiguration()

        if let old = videoInput { session.removeInput(old); videoInput = nil }
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: format.camera.position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoInput = input

        if session.canSetSessionPreset(format.resolution.preset) {
            session.sessionPreset = format.resolution.preset
        } else {
            toast("\(format.resolution.rawValue) isn't available on this camera")
        }

        if !outputsAdded {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: mediaQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                audioInput = micInput
                audioOutput.setSampleBufferDelegate(self, queue: mediaQueue)
                if session.canAddOutput(audioOutput) {
                    session.addOutput(audioOutput)
                    micAvailable = true
                }
            }
            outputsAdded = true
        }

        applyConnection()
        session.commitConfiguration()

        // A new preset/camera resets the frame duration, so set it again.
        applyFrameRate(format.fps)
    }

    private func reconfigure() {
        let f = settings.format
        sessionQueue.async {
            self.wantsStabilization = f.stabilization
            self.configureSession(format: f)
        }
    }

    private func supports(_ fps: Double, _ device: AVCaptureDevice) -> Bool {
        device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= fps + 0.01 && fps - 0.01 <= $0.maxFrameRate
        }
    }

    /// Must run on sessionQueue.
    private func applyFrameRate(_ rate: FrameRate) {
        guard let device = videoInput?.device else { return }
        var chosen = rate
        if !supports(rate.fps, device) {
            toast("\(rate.rawValue) fps isn't available at this resolution")
            chosen = .vhs
            guard supports(chosen.fps, device) else { return }
        }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = chosen.frameDuration
            device.activeVideoMaxFrameDuration = chosen.frameDuration
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: Orientation

    @objc private func deviceOrientationChanged() {
        noteDeviceOrientation()
        guard !isRecording else { return }   // keep buffer size constant while recording
        updateOrientation()
    }

    private func noteDeviceOrientation() {
        let o = UIDevice.current.orientation
        if o == .portrait || o == .landscapeLeft || o == .landscapeRight { lastDeviceOrientation = o }
    }

    private func windowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func deviceBasedOrientation() -> AVCaptureVideoOrientation {
        switch lastDeviceOrientation {
        case .landscapeLeft:  return .landscapeRight   // device/capture landscape names are mirrored
        case .landscapeRight: return .landscapeLeft
        default:              return .portrait
        }
    }

    private func computeCaptureOrientation() -> AVCaptureVideoOrientation {
        switch settings.format.orientation {
        case .portrait:
            return .portrait
        case .auto:
            return deviceBasedOrientation()
        case .landscape:
            let d = deviceBasedOrientation()
            if d != .portrait { return d }
            return windowScene()?.interfaceOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        }
    }

    private func updateOrientation() {
        let orientation = computeCaptureOrientation()
        sessionQueue.async {
            self.captureOrientation = orientation
            self.applyConnection()
        }
    }

    /// Must run on sessionQueue (or inside session configuration).
    private func applyConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = captureOrientation
        }
        // Never mirror: preview and saved media look the same, front camera included.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = wantsStabilization ? .auto : .off
        }
    }

    private func interfaceMask(_ o: UIInterfaceOrientation?) -> UIInterfaceOrientationMask {
        switch o {
        case .landscapeLeft:  return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    /// Decides which interface orientations the app allows: frozen while recording,
    /// otherwise driven by the Orientation setting.
    private func refreshInterfaceMask() {
        DispatchQueue.main.async {
            let scene = self.windowScene()
            let mask: UIInterfaceOrientationMask
            if self.isRecording {
                mask = self.interfaceMask(scene?.interfaceOrientation)
            } else {
                switch self.settings.format.orientation {
                case .auto:      mask = [.portrait, .landscapeLeft, .landscapeRight]
                case .portrait:  mask = .portrait
                case .landscape: mask = .landscape
                }
            }
            AppDelegate.orientationMask = mask
            scene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !self.isRecording, let scene, !mask.contains(self.interfaceMask(scene.interfaceOrientation)) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            }
            UIViewController.attemptRotationToDeviceOrientation()
            if !self.isRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.updateOrientation() }
            }
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        settings.format.camera = (settings.format.camera == .back) ? .front : .back
    }

    // MARK: Frame processing (mediaQueue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            appendAudio(sampleBuffer)
            return
        }
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var pixelBuffer = source
        var displayBuffer = sampleBuffer
        if mediaFormat.aspect == .square {
            let sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
            let side = min(sw, sh) & ~1
            if sw != side || sh != side {
                guard let cropped = croppedBuffer(from: source, side: side),
                      let sb = makeSampleBuffer(cropped, timing: sampleBuffer) else { return }
                pixelBuffer = cropped
                displayBuffer = sb
            }
        }

        processor.process(pixelBuffer, frame: frameCounter)
        frameCounter &+= 1

        show(displayBuffer)
        record(pixelBuffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        capturePhotoIfRequested(pixelBuffer)
    }

    /// Center-crops a BGRA buffer to `side` x `side`.
    private func croppedBuffer(from src: CVPixelBuffer, side: Int) -> CVPixelBuffer? {
        if cropPool == nil || cropSide != side {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            cropPool = pool
            cropSide = side
        }
        guard let cropPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, cropPool, &out)
        guard let dst = out else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src),
              let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sStride = CVPixelBufferGetBytesPerRow(src)
        let dStride = CVPixelBufferGetBytesPerRow(dst)
        let x0 = (CVPixelBufferGetWidth(src) - side) / 2
        let y0 = (CVPixelBufferGetHeight(src) - side) / 2
        for y in 0..<side {
            memcpy(dBase + y * dStride, sBase + (y + y0) * sStride + x0 * 4, side * 4)
        }
        return dst
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, timing source: CMSampleBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(source),
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &out)
        return out
    }

    private func show(_ sampleBuffer: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sampleBuffer) }
    }

    // MARK: Photo

    func takePhoto() {
        mediaQueue.async { self.wantsPhoto = true }
    }

    private func capturePhotoIfRequested(_ pixelBuffer: CVPixelBuffer) {
        guard wantsPhoto else { return }
        wantsPhoto = false
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) else { return }
        let name = Exporter.fileName("jpg")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        guard (try? data.write(to: tmp)) != nil else { toast("Couldn't save photo"); return }
        Exporter.shared.save(file: tmp, name: name, isVideo: false) { [weak self] in self?.toast($0) }
    }

    // MARK: Video recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        refreshInterfaceMask()
        recordingSeconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingSeconds += 1
        }
        mediaQueue.async { self.wantsRecording = true }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        refreshInterfaceMask()
        updateOrientation()
        timer?.invalidate()
        timer = nil
        mediaQueue.async {
            self.wantsRecording = false
            self.finishWriter()
        }
    }

    private func record(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        if wantsRecording && writer == nil {
            startWriter(width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer),
                        time: time)
        }
        guard wantsRecording, let writer, writer.status == .writing,
              let input = videoWriterInput, let adaptor, input.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    private func startWriter(width: Int, height: Int, time: CMTime) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vhs-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            wantsRecording = false
            toast("Couldn't start recording")
            DispatchQueue.main.async { self.isRecording = false }
            return
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 10)]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        w.add(vIn)

        if micAvailable {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 64000
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) { w.add(aIn); audioWriterInput = aIn }
        }

        guard w.startWriting() else {
            wantsRecording = false
            toast("Couldn't start recording")
            DispatchQueue.main.async { self.isRecording = false }
            return
        }
        w.startSession(atSourceTime: time)
        writer = w
        videoWriterInput = vIn
        adaptor = ad
        recordingURL = url
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard wantsRecording, let writer, writer.status == .writing,
              let input = audioWriterInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    private func finishWriter() {
        guard let w = writer, let url = recordingURL else { return }
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        writer = nil
        videoWriterInput = nil
        audioWriterInput = nil
        adaptor = nil
        recordingURL = nil
        w.finishWriting { [weak self] in
            guard w.status == .completed else {
                self?.toast("Recording failed")
                return
            }
            Exporter.shared.save(file: url, name: Exporter.fileName("mov"), isVideo: true) { self?.toast($0) }
        }
    }

    // MARK: Helpers

    func toast(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }
}
