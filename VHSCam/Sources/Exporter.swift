import UIKit
import Photos
import UniformTypeIdentifiers

/// Decides where finished photos / videos / preset files go: Photos and/or a folder the user picked
/// in the Files picker (iCloud Drive, On My iPhone, or a USB drive plugged into the phone).
/// Files are copied after recording stops, never written to the drive mid-recording.
final class Exporter: ObservableObject {
    static let shared = Exporter()

    @Published var saveToPhotos: Bool {
        didSet { UserDefaults.standard.set(saveToPhotos, forKey: "vhscam.saveToPhotos") }
    }
    @Published var saveToFolder: Bool {
        didSet { UserDefaults.standard.set(saveToFolder, forKey: "vhscam.saveToFolder") }
    }
    @Published private(set) var folderName: String?
    private var bookmark: Data?

    private init() {
        let d = UserDefaults.standard
        saveToPhotos = d.object(forKey: "vhscam.saveToPhotos") as? Bool ?? true
        saveToFolder = d.bool(forKey: "vhscam.saveToFolder")
        bookmark = d.data(forKey: "vhscam.folderBookmark")
        folderName = d.string(forKey: "vhscam.folderName")
    }

    var hasFolder: Bool { bookmark != nil }

    /// Where the next save will go, for display.
    var destinationSummary: String {
        var parts: [String] = []
        if saveToPhotos || !(saveToFolder && hasFolder) { parts.append("Photos") }
        if saveToFolder && hasFolder { parts.append(folderName ?? "Folder") }
        return parts.joined(separator: " + ")
    }

    static func fileName(_ ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "VHS_\(f.string(from: Date())).\(ext)"
    }

    // MARK: Folder

    @discardableResult
    func setFolder(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        bookmark = data
        UserDefaults.standard.set(data, forKey: "vhscam.folderBookmark")
        UserDefaults.standard.set(url.lastPathComponent, forKey: "vhscam.folderName")
        folderName = url.lastPathComponent
        saveToFolder = true
        return true
    }

    func clearFolder() {
        bookmark = nil
        folderName = nil
        saveToFolder = false
        UserDefaults.standard.removeObject(forKey: "vhscam.folderBookmark")
        UserDefaults.standard.removeObject(forKey: "vhscam.folderName")
    }

    private func resolveFolder() -> URL? {
        guard let data = bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData() {
                bookmark = fresh
                UserDefaults.standard.set(fresh, forKey: "vhscam.folderBookmark")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    /// Copies a file into the chosen folder. Returns false if there's no folder or it isn't reachable
    /// (for example the USB drive was unplugged).
    func copyToFolder(_ src: URL, name: String) -> Bool {
        guard let folder = resolveFolder() else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var dest = folder.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            n += 1
            dest = folder.appendingPathComponent("\(base)-\(n).\(ext)")
        }
        var coordError: NSError?
        var ok = false
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { target in
            ok = (try? fm.copyItem(at: src, to: target)) != nil
        }
        return ok && coordError == nil
    }

    // MARK: Saving

    /// Saves a finished photo (JPEG) or video (.mov) file, then deletes the temp file.
    /// `done` is called on the main queue with a short message for the UI.
    func save(file url: URL, name: String, isVideo: Bool, done: @escaping (String) -> Void) {
        let wantFolder = saveToFolder
        var wantPhotos = saveToPhotos
        DispatchQueue.global(qos: .utility).async {
            var places: [String] = []
            var notes: [String] = []

            if wantFolder {
                if !self.hasFolder {
                    notes.append("no folder chosen")
                    wantPhotos = true
                } else if self.copyToFolder(url, name: name) {
                    places.append(self.folderName ?? "folder")
                } else {
                    notes.append("folder unavailable")
                    wantPhotos = true   // never lose a recording
                }
            }
            if !wantFolder && !wantPhotos { wantPhotos = true }

            let finish: () -> Void = {
                try? FileManager.default.removeItem(at: url)
                var msg = places.isEmpty ? "Couldn't save" : "Saved to " + places.joined(separator: " + ")
                if !notes.isEmpty { msg += " (" + notes.joined(separator: ", ") + ")" }
                DispatchQueue.main.async { done(msg) }
            }

            guard wantPhotos else { finish(); return }
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { ok, _ in
                if ok { places.insert("Photos", at: 0) } else { notes.append("Photos access denied?") }
                finish()
            }
        }
    }
}
