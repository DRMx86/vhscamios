import UIKit
import AVFoundation
import Photos

final class CameraViewController: UIViewController,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: Capture
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vhscam.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back   // back camera is the default

    // State touched on `queue`
    private var frameCount: UInt64 = 0
    private var effectOn = true
    private var wantsRecording = false
    private var writer: AVAssetWriter?
    private var vInput: AVAssetWriterInput?
    private var aInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStarted = false
    private var latestImage: UIImage?

    // MARK: UI
    private let preview = UIImageView()
    private let tapeButton = UIButton(type: .system)
    private let flipButton = UIButton(type: .system)
    private let photoButton = UIButton(type: .system)
    private let recButton = UIButton(type: .system)

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.contentMode = .scaleAspectFill
        preview.clipsToBounds = true
        preview.frame = view.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(preview)
        buildControls()
        requestPermissionsAndStart()
    }

    private func buildControls() {
        func style(_ b: UIButton, _ symbol: String, _ size: CGFloat = 26) {
            let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
            b.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
            b.tintColor = .white
        }
        style(tapeButton, "recordingtape.circle.fill", 32)
        style(flipButton, "camera.rotate")
        style(photoButton, "circle.inset.filled", 64)
        style(recButton, "record.circle", 40)
        recButton.tintColor = .systemRed
        tapeButton.addTarget(self, action: #selector(toggleEffect), for: .touchUpInside)
        flipButton.addTarget(self, action: #selector(flipCamera), for: .touchUpInside)
        photoButton.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
        recButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [tapeButton, photoButton, recButton, flipButton])
        stack.axis = .horizontal
        stack.distribution = .equalCentering
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 80)
        ])
    }

    // MARK: Permissions / session
    private func requestPermissionsAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.queue.async { self.configureSession(); self.session.startRunning() }
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480   // low-res suits the VHS look and keeps it real-time

        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input); videoInput = input
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        session.commitConfiguration()
        applyConnectionSettings()
    }

    private func applyConnectionSettings() {
        guard let c = videoOutput.connection(with: .video) else { return }
        if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }  // portrait
        if c.isVideoMirroringSupported { c.isVideoMirrored = (position == .front) }
    }

    // MARK: Actions
    @objc private func toggleEffect() {
        queue.async { self.effectOn.toggle()
            let on = self.effectOn
            DispatchQueue.main.async { self.tapeButton.tintColor = on ? .white : .gray }
        }
    }

    @objc private func flipCamera() {
        queue.async {
            let newPos: AVCaptureDevice.Position = self.position == .back ? .front : .back
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPos),
                  let input = try? AVCaptureDeviceInput(device: dev) else { return }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }
            if self.session.canAddInput(input) { self.session.addInput(input); self.videoInput = input; self.position = newPos }
            self.session.commitConfiguration()
            self.applyConnectionSettings()
        }
    }

    @objc private func takePhoto() {
        queue.async {
            guard let img = self.latestImage else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            })
        }
    }

    @objc private func toggleRecording() {
        queue.async {
            if self.wantsRecording { self.stopRecording() } else { self.wantsRecording = true }
            let rec = self.wantsRecording
            DispatchQueue.main.async {
                let cfg = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
                self.recButton.setImage(UIImage(systemName: rec ? "stop.circle.fill" : "record.circle", withConfiguration: cfg), for: .normal)
            }
        }
    }

    // MARK: Recording (all on `queue`)
    private func startWriter(for pb: CVPixelBuffer) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vhs-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(url: url, fileType: .mov) else { wantsRecording = false; return }
        let w0 = CVPixelBufferGetWidth(pb), h0 = CVPixelBufferGetHeight(pb)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w0, AVVideoHeightKey: h0,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100, AVEncoderBitRateKey: 64000])
        a.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        if w.canAdd(v) { w.add(v) }
        if w.canAdd(a) { w.add(a) }
        writer = w; vInput = v; aInput = a; adaptor = ad; writerStarted = false
    }

    private func stopRecording() {
        wantsRecording = false
        guard let w = writer, writerStarted else { writer = nil; return }
        vInput?.markAsFinished(); aInput?.markAsFinished()
        let url = w.outputURL
        w.finishWriting {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { _, _ in try? FileManager.default.removeItem(at: url) }
        }
        writer = nil; vInput = nil; aInput = nil; adaptor = nil; writerStarted = false
    }

    // MARK: Sample buffers
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == audioOutput {
            if writerStarted, let a = aInput, a.isReadyForMoreMediaData { a.append(sb) }
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        guard let base = CVPixelBufferGetBaseAddress(pb) else { CVPixelBufferUnlockBaseAddress(pb, []); return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)

        if effectOn { _ = vhs_process(base.assumingMemoryBound(to: UInt8.self), w, h, stride, frameCount) }
        frameCount &+= 1

        let cg = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        CVPixelBufferUnlockBaseAddress(pb, [])

        if wantsRecording {
            if writer == nil { startWriter(for: pb) }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if let wr = writer, !writerStarted, wr.startWriting() { wr.startSession(atSourceTime: pts); writerStarted = true }
            if writerStarted, let v = vInput, v.isReadyForMoreMediaData { adaptor?.append(pb, withPresentationTime: pts) }
        }

        guard let cg else { return }
        let img = UIImage(cgImage: cg)
        latestImage = img
        DispatchQueue.main.async { self.preview.image = img }
    }
}
