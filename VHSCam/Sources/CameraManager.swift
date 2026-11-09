import AVFoundation
import Photos
import UIKit
import CoreImage

/// Captures camera frames, runs each through the ntsc-rs VHS effect (Rust, via C FFI),
/// shows the result live, and can save the processed output as a photo or video.
final class CameraManager: NSObject, ObservableObject,
                           AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {

    enum CaptureMode { case photo, video }

    // MARK: Published UI state (main thread)
    @Published var position: AVCaptureDevice.Position = .back   // back camera is the default
    @Published var captureMode: CaptureMode = .video
    @Published var preset: Int = 1 { didSet { pushEffectSettings() } }        // 0 light, 1 classic, 2 worn
    @Published var intensity: Double = 0.7 { didSet { pushEffectSettings() } }
    @Published var useHD = false
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

    // MARK: ntsc-rs
    private var handle: OpaquePointer?
    private var frameCounter: UInt64 = 0

    // MARK: Recording / photo state (touched only on mediaQueue)
    private var wantsRecording = false
    private var wantsPhoto = false
    private var writer: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private let ciContext = CIContext()
    private var timer: Timer?

    override init() {
        super.init()
        handle = ntsc_create(Int32(preset), Float(intensity))
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    deinit {
        if let handle { ntsc_destroy(handle) }
    }

    // MARK: Lifecycle

    func start() {
        requestPermissions { [weak self] videoGranted in
            guard let self else { return }
            guard videoGranted else {
                DispatchQueue.main.async { self.cameraDenied = true }
                return
            }
            let pos = self.position
            let hd = self.useHD
            self.sessionQueue.async {
                self.configureSession(position: pos, hd: hd)
                if !self.session.isRunning { self.session.startRunning() }
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

    // MARK: Session configuration

    private func configureSession(position: AVCaptureDevice.Position, hd: Bool) {
        session.beginConfiguration()

        if let old = videoInput { session.removeInput(old); videoInput = nil }
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoInput = input

        let preset: AVCaptureSession.Preset = hd ? .hd1280x720 : .vga640x480
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }

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

        // Upright portrait buffers, so VHS scanlines run horizontally on screen.
        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()

        // 30 fps keeps the effect real-time.
        if (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }

        DispatchQueue.main.async {
            // Mirror the selfie preview only; saved media is not mirrored.
            self.displayLayer.transform = position == .front
                ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        }
    }

    private func reconfigure() {
        let pos = position
        let hd = useHD
        sessionQueue.async { self.configureSession(position: pos, hd: hd) }
    }

    func switchCamera() {
        guard !isRecording else { return }
        position = (position == .back) ? .front : .back
        reconfigure()
    }

    func setHD(_ hd: Bool) {
        guard !isRecording, hd != useHD else { return }
        useHD = hd
        reconfigure()
    }

    private func pushEffectSettings() {
        guard let handle else { return }
        ntsc_set_preset(handle, Int32(preset), Float(intensity))
    }

    // MARK: Frame processing

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            appendAudio(sampleBuffer)
            return
        }
        guard let handle, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            _ = ntsc_process_bgra(
                handle,
                base.assumingMemoryBound(to: UInt8.self),
                UInt32(CVPixelBufferGetWidth(pixelBuffer)),
                UInt32(CVPixelBufferGetHeight(pixelBuffer)),
                UInt32(CVPixelBufferGetBytesPerRow(pixelBuffer)),
                frameCounter
            )
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
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }) { [weak self] ok, _ in
            self?.toast(ok ? "Photo saved" : "Couldn't save photo (check Photos access)")
        }
    }

    // MARK: Video recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

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
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 10]
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
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                try? FileManager.default.removeItem(at: url)
                self?.toast(ok ? "Video saved" : "Couldn't save video (check Photos access)")
            }
        }
    }

    // MARK: Helpers

    private func toast(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }
}
