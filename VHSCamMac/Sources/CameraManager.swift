import AVFoundation
import AppKit
import CoreImage

/// macOS camera pipeline: any camera (built-in, USB/UVC, iPhone via Continuity Camera) and any
/// microphone -> ntsc-rs VHS effect (Rust, via C FFI) -> live preview -> photo / video saved to disk.
final class CameraManager: NSObject, ObservableObject,
                           AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {

    enum CaptureMode { case photo, video }

    struct Look {
        let name: String
        let grain, color, tracking, softness: Double
        let tape: Int   // 0 = SP, 1 = LP, 2 = EP
    }

    // Same presets as the iOS app (including RetroDann / RetroDann2).
    static let looks: [Look] = [
        Look(name: "Classic",    grain: 0.45, color: 1.00, tracking: 0.45, softness: 0.45, tape: 1),
        Look(name: "Clean SP",   grain: 0.15, color: 0.85, tracking: 0.15, softness: 0.25, tape: 0),
        Look(name: "Home Video", grain: 0.25, color: 1.15, tracking: 0.10, softness: 0.30, tape: 0),
        Look(name: "RetroDann",  grain: 0.80, color: 0.55, tracking: 0.24, softness: 0.35, tape: 0),
        Look(name: "RetroDann2", grain: 0.27, color: 0.44, tracking: 0.15, softness: 0.55, tape: 0),
        Look(name: "Muted",      grain: 0.35, color: 0.45, tracking: 0.35, softness: 0.50, tape: 1),
        Look(name: "B&W",        grain: 0.50, color: 0.00, tracking: 0.35, softness: 0.40, tape: 1),
        Look(name: "Worn Tape",  grain: 0.80, color: 0.80, tracking: 0.85, softness: 0.70, tape: 2)
    ]

    struct Source: Identifiable, Hashable {
        let id: String      // AVCaptureDevice.uniqueID
        let name: String
    }

    // MARK: Published UI state (main thread)
    @Published var cameras: [Source] = []
    @Published var mics: [Source] = []
    @Published var cameraID: String = ""
    @Published var micID: String = ""            // "" = no audio
    @Published var captureMode: CaptureMode = .video
    @Published var grain: Double = 0.45 { didSet { controlChanged() } }
    @Published var color: Double = 1.0 { didSet { controlChanged() } }
    @Published var tracking: Double = 0.45 { didSet { controlChanged() } }
    @Published var softness: Double = 0.45 { didSet { controlChanged() } }
    @Published var selectedLook: Int? = 0
    @Published var useHD = false
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var statusMessage: String?
    @Published var cameraDenied = false

    let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: Capture plumbing
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "vhscam.session")
    private let mediaQueue = DispatchQueue(label: "vhscam.media", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAdded = false
    private var started = false

    // MARK: ntsc-rs
    private var handle: OpaquePointer?
    private var frameCounter: UInt64 = 0
    private var tapeSpeed = 1
    private var applyingLook = false

    // MARK: Recording / photo state (mediaQueue only)
    private var wantsRecording = false
    private var wantsPhoto = false
    private var writer: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingHasAudio = false
    private let ciContext = CIContext()
    private var timer: Timer?

    override init() {
        super.init()
        handle = ntsc_create()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        select(look: 0)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged),
                       name: AVCaptureDevice.wasConnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged),
                       name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let handle { ntsc_destroy(handle) }
    }

    // MARK: Devices

    private static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        var list = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        // Also pick up anything else the system exposes (e.g. an iPhone's mic via Continuity).
        for d in AVCaptureDevice.devices(for: .audio) where !list.contains(where: { $0.uniqueID == d.uniqueID }) {
            list.append(d)
        }
        return list
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.async {
            self.refreshDevices()
            guard !self.isRecording, self.started else { return }
            self.reconfigure()
        }
    }

    /// Main thread. Keeps the current choice if it still exists, otherwise falls back to the
    /// system's preferred camera (which is the iPhone when Continuity Camera is active).
    private func refreshDevices() {
        let vids = Self.videoDevices()
        let auds = Self.audioDevices()
        cameras = vids.map { Source(id: $0.uniqueID, name: $0.localizedName) }
        mics = auds.map { Source(id: $0.uniqueID, name: $0.localizedName) }

        if !cameras.contains(where: { $0.id == cameraID }) {
            let preferred = AVCaptureDevice.userPreferredCamera ?? AVCaptureDevice.systemPreferredCamera
                ?? AVCaptureDevice.default(for: .video)
            cameraID = preferred?.uniqueID ?? cameras.first?.id ?? ""
        }
        if micID.isEmpty || !mics.contains(where: { $0.id == micID }) {
            // Prefer the mic that belongs to the chosen camera (iPhone / USB webcam), else the default mic.
            let camMic = auds.first { $0.uniqueID == cameraID || $0.modelID == AVCaptureDevice(uniqueID: cameraID)?.modelID }
            micID = (camMic ?? AVCaptureDevice.default(for: .audio))?.uniqueID ?? mics.first?.id ?? ""
        }
    }

    func selectCamera(_ id: String) {
        guard !isRecording, id != cameraID else { return }
        cameraID = id
        AVCaptureDevice.userPreferredCamera = AVCaptureDevice(uniqueID: id)
        reconfigure()
    }

    func selectMic(_ id: String) {
        guard !isRecording, id != micID else { return }
        micID = id
        reconfigure()
    }

    func setHD(_ hd: Bool) {
        guard !isRecording, hd != useHD else { return }
        useHD = hd
        reconfigure()
    }

    // MARK: Lifecycle

    func start() {
        refreshDevices()
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            guard videoOK else {
                DispatchQueue.main.async { self.cameraDenied = true }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self.started = true
                    self.refreshDevices()
                    let cam = self.cameraID, mic = self.micID, hd = self.useHD
                    self.sessionQueue.async {
                        self.configureSession(cameraID: cam, micID: mic, hd: hd)
                        if !self.session.isRunning { self.session.startRunning() }
                    }
                }
            }
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func reconfigure() {
        let cam = cameraID, mic = micID, hd = useHD
        sessionQueue.async { self.configureSession(cameraID: cam, micID: mic, hd: hd) }
    }

    // MARK: Session configuration (sessionQueue)

    private func configureSession(cameraID: String, micID: String, hd: Bool) {
        session.beginConfiguration()

        if let old = videoInput { session.removeInput(old); videoInput = nil }
        if let old = audioInput { session.removeInput(old); audioInput = nil }

        var device: AVCaptureDevice?
        if let dev = AVCaptureDevice(uniqueID: cameraID),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            device = dev
        }
        if !micID.isEmpty, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice(uniqueID: micID),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        // Low-res suits the VHS look and keeps it real-time. Not every camera offers every preset.
        let wanted: [AVCaptureSession.Preset] = hd ? [.hd1280x720, .high] : [.vga640x480, .medium, .low]
        if let p = wanted.first(where: { session.canSetSessionPreset($0) }) { session.sessionPreset = p }

        if !outputsAdded {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: mediaQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            audioOutput.setSampleBufferDelegate(self, queue: mediaQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            outputsAdded = true
        }
        session.commitConfiguration()

        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        // 30 fps keeps the effect real-time (only if the active format supports it).
        if let device,
           device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }),
           (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }
    }

    // MARK: Looks and tape controls

    func select(look index: Int) {
        guard Self.looks.indices.contains(index) else { return }
        let look = Self.looks[index]
        applyingLook = true
        grain = look.grain
        color = look.color
        tracking = look.tracking
        softness = look.softness
        tapeSpeed = look.tape
        applyingLook = false
        selectedLook = index
        pushParams()
    }

    private func controlChanged() {
        guard !applyingLook else { return }
        selectedLook = nil
        pushParams()
    }

    private func pushParams() {
        guard let handle else { return }
        ntsc_set_params(handle, Float(grain), Float(color), Float(tracking),
                        Float(softness), Int32(tapeSpeed))
    }

    // MARK: Frame processing (mediaQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            appendAudio(sampleBuffer)
            return
        }
        guard let handle, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            _ = ntsc_process_bgra(
                handle, base.assumingMemoryBound(to: UInt8.self),
                UInt32(CVPixelBufferGetWidth(pixelBuffer)),
                UInt32(CVPixelBufferGetHeight(pixelBuffer)),
                UInt32(CVPixelBufferGetBytesPerRow(pixelBuffer)),
                frameCounter)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        frameCounter &+= 1

        show(sampleBuffer)
        record(pixelBuffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        capturePhotoIfRequested(pixelBuffer)
    }

    private func show(_ sampleBuffer: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sampleBuffer) }
    }

    // MARK: Output folders

    private func outputFolder(_ dir: FileManager.SearchPathDirectory) -> URL? {
        guard let base = FileManager.default.urls(for: dir, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("VHS Cam", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    // MARK: Photo

    func takePhoto() { mediaQueue.async { self.wantsPhoto = true } }

    private func capturePhotoIfRequested(_ pixelBuffer: CVPixelBuffer) {
        guard wantsPhoto else { return }
        wantsPhoto = false
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.95]),
              let folder = outputFolder(.picturesDirectory) else {
            toast("Couldn't save photo"); return
        }
        let url = folder.appendingPathComponent("VHS_\(stamp()).jpg")
        do { try data.write(to: url); toast("Photo saved to Pictures/VHS Cam") }
        catch { toast("Couldn't save photo") }
    }

    // MARK: Video recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    private func startRecording() {
        isRecording = true
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
                        height: CVPixelBufferGetHeight(pixelBuffer), time: time)
        }
        guard wantsRecording, let writer, writer.status == .writing,
              let input = videoWriterInput, let adaptor, input.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    private func failRecording(_ message: String) {
        wantsRecording = false
        toast(message)
        DispatchQueue.main.async { self.isRecording = false; self.timer?.invalidate() }
    }

    private func startWriter(width: Int, height: Int, time: CMTime) {
        guard let folder = outputFolder(.moviesDirectory) else { failRecording("Couldn't start recording"); return }
        let url = folder.appendingPathComponent("VHS_\(stamp()).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            failRecording("Couldn't start recording"); return
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 10]
        ])
        vIn.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height])
        w.add(vIn)

        if audioInput != nil {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100, AVEncoderBitRateKey: 64000])
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) { w.add(aIn); audioWriterInput = aIn }
        }
        guard w.startWriting() else { failRecording("Couldn't start recording"); return }
        w.startSession(atSourceTime: time)
        writer = w; videoWriterInput = vIn; adaptor = ad; recordingURL = url
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
        writer = nil; videoWriterInput = nil; audioWriterInput = nil; adaptor = nil; recordingURL = nil
        w.finishWriting { [weak self] in
            if w.status == .completed {
                self?.toast("Video saved to Movies/VHS Cam")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                self?.toast("Recording failed")
            }
        }
    }

    private func toast(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }
}
