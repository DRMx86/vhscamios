import UIKit
import Photos

/// Saves finished photos / videos to the Photos library.
final class Exporter {
    static let shared = Exporter()
    private init() {}

    /// Where saves go, for display.
    var destinationSummary: String { "Photos" }

    static func fileName(_ ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "VHS_\(f.string(from: Date())).\(ext)"
    }

    /// Saves a finished photo (JPEG) or video (.mov) file to Photos, then deletes the temp file.
    /// `done` is called on the main queue with a short message for the UI.
    func save(file url: URL, name: String, isVideo: Bool, done: @escaping (String) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            if isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        }) { ok, _ in
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                done(ok ? "Saved to Photos" : "Couldn't save (check Photos access)")
            }
        }
    }
}
