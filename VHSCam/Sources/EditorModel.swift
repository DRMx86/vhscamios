import UIKit
import AVFoundation
import CoreImage

/// Re-renders an existing photo or video from the library with the VHS effect:
/// live preview (a still frame, processed on every change) and a full render to Photos.
final class EditorModel: ObservableObject, Identifiable {
    let id = UUID()
    let isVideo: Bool
    let duration: Double
    private let videoURL: URL?
    private let photoCI: CIImage?

    @Published var tape: TapeSettings { didSet { tapeChanged(from: oldValue) } }
    @Published var aspect: AspectMode { didSet { schedulePreview() } }
    @Published var resolution: Resolution { didSet { schedulePreview() } }
    /// 0...1 position of the preview frame (video only).
    @Published var scrub: Double = 0 { didSet { schedulePreview(reloadFrame: true) } }
    @Published var previewImage: UIImage?
    @Published var isRendering = false
    @Published var progress = 0.0
    @Published var message: String?
    var applyingLook = false

    // Preview pipeline (queue only)
    private let queue = DispatchQueue(label: "vhscam.editor.preview", qos: .userInitiated)
    private let previewProcessor = VHSProcessor()
    private let previewFitter = FrameFitter()
    private var frameCI: CIImage?
    private var generator: AVAssetImageGenerator?
    private let lock = NSLock()
    private var generation = 0
    private var cancelFlag = false

    init?(photo: UIImage, settings: Settings) {
        guard let ci = FrameFitter.prepare(photo) else { return nil }
        isVideo = false; duration = 0; videoURL = nil; photoCI = ci
        tape = settings.tape; aspect = settings.format.aspect; resolution = settings.format.resolution
        schedulePreview()
    }

    init(video url: URL, settings: Settings) {
        isVideo = true; videoURL = url; photoCI = nil
        duration = max(0.1, AVURLAsset(url: url).duration.seconds)
        tape = settings.tape; aspect = settings.format.aspect; resolution = settings.format.resolution
        schedulePreview(reloadFrame: true)
    }

    deinit {
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
    }

    // MARK: Editing

    private func tapeChanged(from old: TapeSettings) {
        if !applyingLook && tape.lookIndex != nil {
            var a = tape, b = old
            a.lookIndex = nil; b.lookIndex = nil
            if a != b { tape.lookIndex = nil }
        }
        schedulePreview()
    }

    func select(look index: Int) {
        guard Look.all.indices.contains(index) else { return }
        applyingLook = true
        var t = tape
        t.apply(Look.all[index], index: index)
        tape = t
        applyingLook = false
    }

    /// A preset sets the look, tape controls, shape and resolution (not camera / fps / orientation).
    func apply(_ settings: Settings) {
        applyingLook = true
        aspect = settings.format.aspect
        resolution = settings.format.resolution
        tape = settings.tape
        applyingLook = false
    }

    // MARK: Preview

    private func schedulePreview(reloadFrame: Bool = false) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let tape = self.tape, square = aspect == .square
        let shortSide = Int(resolution.shortSide)
        let t = scrub * duration
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.generation; self.lock.unlock()
            guard gen == current else { return }   // a newer change is already queued
            if self.isVideo, reloadFrame || self.frameCI == nil { self.loadFrame(at: t) }
            guard let src = self.isVideo ? self.frameCI : self.photoCI,
                  let pb = self.previewFitter.fit(src, shortSide: shortSide, square: square) else { return }
            self.previewProcessor.update(tape)
            self.previewProcessor.process(pb, frame: 0)
            let image = self.previewFitter.uiImage(from: pb)
            DispatchQueue.main.async { self.previewImage = image }
        }
    }

    private func loadFrame(at seconds: Double) {
        guard let videoURL else { return }
        if generator == nil {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 1920, height: 1920)
            g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            generator = g
        }
        let time = CMTime(seconds: min(max(0, seconds), max(0, duration - 0.05)), preferredTimescale: 600)
        if let cg = try? generator?.copyCGImage(at: time, actualTime: nil) { frameCI = CIImage(cgImage: cg) }
    }

    // MARK: Render

    func cancelRender() {
        lock.lock(); cancelFlag = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelFlag
    }

    func render() {
        guard !isRendering else { return }
        lock.lock(); cancelFlag = false; lock.unlock()
        isRendering = true; progress = 0; message = nil
        let tape = self.tape, square = aspect == .square, shortSide = Int(resolution.shortSide)
        DispatchQueue.global(qos: .userInitiated).async {
            if self.isVideo, let url = self.videoURL {
                self.renderVideo(url: url, tape: tape, square: square, shortSide: shortSide)
            } else {
                self.renderPhoto(tape: tape, square: square, shortSide: shortSide)
            }
        }
    }

    private func finishRender(_ text: String) {
        DispatchQueue.main.async {
            self.isRendering = false
            self.message = text
        }
    }

    private func renderPhoto(tape: TapeSettings, square: Bool, shortSide: Int) {
        let fitter = FrameFitter(), proc = VHSProcessor()
        guard let src = photoCI, let pb = fitter.fit(src, shortSide: shortSide, square: square) else {
            finishRender("Couldn't render photo"); return
        }
        proc.update(tape)
        proc.process(pb, frame: 0)
        guard let data = fitter.jpegData(from: pb) else { finishRender("Couldn't encode photo"); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        guard (try? data.write(to: tmp)) != nil else { finishRender("Couldn't save photo"); return }
        Exporter.shared.save(file: tmp, name: Exporter.fileName("jpg"), isVideo: false) { [weak self] in
            self?.isRendering = false; self?.progress = 1; self?.message = $0
        }
    }

    private func renderVideo(url: URL, tape: TapeSettings, square: Bool, shortSide: Int) {
        let asset = AVURLAsset(url: url)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { finishRender("No video track found"); return }
        let comp = AVVideoComposition(propertiesOf: asset)   // applies the clip's rotation
        guard comp.renderSize.width > 1, comp.renderSize.height > 1 else { finishRender("Unreadable video"); return }
        let (tw, th) = FrameFitter.targetSize(width: Int(comp.renderSize.width), height: Int(comp.renderSize.height),
                                              shortSide: shortSide, square: square)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString).mov")
        let total = max(asset.duration.seconds, 0.001)

        do {
            let reader = try AVAssetReader(asset: asset)
            let vOut = AVAssetReaderVideoCompositionOutput(
                videoTracks: [vTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            vOut.videoComposition = comp
            guard reader.canAdd(vOut) else { finishRender("Couldn't read video"); return }
            reader.add(vOut)

            let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: tw, AVVideoHeightKey: th,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, tw * th * 10)]])
            vIn.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: tw, kCVPixelBufferHeightKey as String: th])
            writer.add(vIn)

            // Audio is copied through untouched.
            var aOut: AVAssetReaderTrackOutput?
            var aIn: AVAssetWriterInput?
            if let aTrack = asset.tracks(withMediaType: .audio).first {
                let hint = aTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                input.expectsMediaDataInRealTime = false
                let output = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
                if writer.canAdd(input), reader.canAdd(output) {
                    writer.add(input); reader.add(output); aIn = input; aOut = output
                }
            }

            guard reader.startReading(), writer.startWriting() else { finishRender("Couldn't start render"); return }
            writer.startSession(atSourceTime: vTrack.timeRange.start)

            let fitter = FrameFitter(), proc = VHSProcessor()
            proc.update(tape)
            let group = DispatchGroup()
            var frame: UInt64 = 0

            let vq = DispatchQueue(label: "vhscam.render.video")
            group.enter()
            vIn.requestMediaDataWhenReady(on: vq) {
                while vIn.isReadyForMoreMediaData {
                    guard !self.isCancelled, let sb = vOut.copyNextSampleBuffer() else {
                        vIn.markAsFinished(); group.leave(); return
                    }
                    autoreleasepool {
                        guard let src = CMSampleBufferGetImageBuffer(sb),
                              let out = fitter.fit(CIImage(cvPixelBuffer: src), shortSide: shortSide, square: square) else { return }
                        proc.process(out, frame: frame)
                        frame &+= 1
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                        adaptor.append(out, withPresentationTime: pts)
                        let p = min(1, pts.seconds / total)
                        DispatchQueue.main.async { self.progress = p }
                    }
                }
            }

            if let aIn, let aOut {
                let aq = DispatchQueue(label: "vhscam.render.audio")
                group.enter()
                aIn.requestMediaDataWhenReady(on: aq) {
                    while aIn.isReadyForMoreMediaData {
                        guard !self.isCancelled, let sb = aOut.copyNextSampleBuffer() else {
                            aIn.markAsFinished(); group.leave(); return
                        }
                        aIn.append(sb)
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                if self.isCancelled || reader.status == .failed {
                    reader.cancelReading(); writer.cancelWriting()
                    try? FileManager.default.removeItem(at: tmp)
                    self.finishRender(self.isCancelled ? "Render cancelled" : "Render failed")
                    return
                }
                writer.finishWriting {
                    guard writer.status == .completed else {
                        try? FileManager.default.removeItem(at: tmp)
                        self.finishRender("Render failed")
                        return
                    }
                    Exporter.shared.save(file: tmp, name: Exporter.fileName("mov"), isVideo: true) { [weak self] in
                        self?.isRendering = false; self?.progress = 1; self?.message = $0
                    }
                }
            }
        } catch {
            finishRender("Couldn't set up render")
        }
    }
}

extension Resolution {
    /// Short side of the output in pixels (matches the camera's 480p / 720p / 1080p).
    var shortSide: CGFloat {
        switch self {
        case .vga: return 480
        case .hd720: return 720
        case .hd1080: return 1080
        }
    }
}
