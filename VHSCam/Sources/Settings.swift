import Foundation
import AVFoundation

extension CaseIterable where Self: Equatable {
    /// Next case, wrapping around (used by tap-to-cycle chips).
    var next: Self {
        let all = Array(Self.allCases)
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

enum AspectMode: String, Codable, CaseIterable, Identifiable {
    case square = "1:1", full = "Full"
    var id: String { rawValue }
}

enum OrientationMode: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto", portrait = "Portrait", landscape = "Landscape"
    var id: String { rawValue }
}

enum Resolution: String, Codable, CaseIterable, Identifiable {
    case vga = "480p", hd720 = "720p", hd1080 = "1080p"
    var id: String { rawValue }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .vga: return .vga640x480
        case .hd720: return .hd1280x720
        case .hd1080: return .hd1920x1080
        }
    }
}

enum CameraSide: String, Codable, CaseIterable, Identifiable {
    case back = "Back", front = "Front"
    var id: String { rawValue }
    var position: AVCaptureDevice.Position { self == .back ? .back : .front }
}

enum FrameRate: String, Codable, CaseIterable, Identifiable {
    case vhs = "VHS", film = "23.976", ntsc = "29.97"
    var id: String { rawValue }

    /// "VHS" is the app's original behaviour: a flat 30 fps.
    var fps: Double {
        switch self {
        case .vhs: return 30
        case .film: return 24000.0 / 1001.0
        case .ntsc: return 30000.0 / 1001.0
        }
    }
    var frameDuration: CMTime {
        switch self {
        case .vhs: return CMTime(value: 1, timescale: 30)
        case .film: return CMTime(value: 1001, timescale: 24000)
        case .ntsc: return CMTime(value: 1001, timescale: 30000)
        }
    }
    var shortLabel: String { self == .vhs ? "30 FPS" : rawValue }
}

enum LowpassFilter: Int, Codable, CaseIterable, Identifiable {
    case butterworth = 0, constantK = 1
    var id: Int { rawValue }
    var label: String { self == .butterworth ? "Butterworth" : "Constant-K" }
    var hint: String { self == .butterworth ? "Sharper roll-off" : "Softer, blurrier roll-off" }
}

/// A one-tap starting point for the tape controls.
struct Look {
    let name: String
    var vhsOn = true
    var grain = 0.45
    var color = 1.0
    var tracking = 0.45
    var softness = 0.45
    var tape = 1            // 0 = SP, 1 = LP, 2 = EP
    var composite = 0.22
    var vignette = 0.0
    var tintR = 1.0, tintG = 1.0, tintB = 1.0
    var contrast = 1.0
    var filmGrain = 0.0

    static let all: [Look] = [
        Look(name: "Classic",    grain: 0.45, color: 1.00, tracking: 0.45, softness: 0.45, tape: 1),
        Look(name: "Clean SP",   grain: 0.15, color: 0.85, tracking: 0.15, softness: 0.25, tape: 0, composite: 0.17),
        Look(name: "Home Video", grain: 0.25, color: 1.15, tracking: 0.10, softness: 0.30, tape: 0),
        Look(name: "RetroDann",  grain: 0.80, color: 0.55, tracking: 0.24, softness: 0.35, tape: 0, composite: 0.28),
        Look(name: "RetroDann2", grain: 0.27, color: 0.44, tracking: 0.15, softness: 0.55, tape: 0),
        Look(name: "Muted",      grain: 0.35, color: 0.45, tracking: 0.35, softness: 0.50, tape: 1),
        Look(name: "B&W",        grain: 0.50, color: 0.00, tracking: 0.35, softness: 0.40, tape: 1),
        Look(name: "Worn Tape",  grain: 0.80, color: 0.80, tracking: 0.85, softness: 0.70, tape: 2, composite: 0.32),
        // Film looks: VHS effect off by default (turn the VHS chip on to stack them).
        Look(name: "FunSaver", vhsOn: false, color: 1.28, vignette: 0.55,
             tintR: 1.07, tintG: 1.00, tintB: 0.88, contrast: 1.15, filmGrain: 0.35),
        Look(name: "Gold 200", vhsOn: false, color: 1.10, vignette: 0.25,
             tintR: 1.05, tintG: 1.00, tintB: 0.93, contrast: 1.05, filmGrain: 0.20),
        Look(name: "Tri-X B&W", vhsOn: false, color: 0.0, vignette: 0.30,
             contrast: 1.22, filmGrain: 0.50)
    ]
}

struct FormatSettings: Codable, Equatable {
    var aspect: AspectMode = .square
    var orientation: OrientationMode = .auto
    var resolution: Resolution = .vga
    var camera: CameraSide = .back
    var fps: FrameRate = .vhs
    var stabilization = false
}

struct TapeSettings: Codable, Equatable {
    var lookIndex: Int? = 0     // nil = custom (a control was moved)
    var vhsOn = true
    var grain = 0.45
    var color = 1.0
    var tracking = 0.45
    var softness = 0.45
    var tapeSpeed = 1
    var compositeNoise = 0.22
    var filter: LowpassFilter = .butterworth
    var snowOn = true
    var snow = 0.002
    var vignette = 0.0
    var tintR = 1.0, tintG = 1.0, tintB = 1.0
    var contrast = 1.0
    var filmGrain = 0.0

    mutating func apply(_ look: Look, index: Int) {
        lookIndex = index
        vhsOn = look.vhsOn
        grain = look.grain
        color = look.color
        tracking = look.tracking
        softness = look.softness
        tapeSpeed = look.tape
        compositeNoise = look.composite
        vignette = look.vignette
        tintR = look.tintR; tintG = look.tintG; tintB = look.tintB
        contrast = look.contrast
        filmGrain = look.filmGrain
    }
}

struct Settings: Codable, Equatable {
    var format = FormatSettings()
    var tape = TapeSettings()

    var summary: String {
        let name: String
        if let i = tape.lookIndex, Look.all.indices.contains(i) { name = Look.all[i].name } else { name = "Custom" }
        return "\(name) · \(format.aspect.rawValue) · \(format.resolution.rawValue)\(tape.vhsOn ? " · VHS" : "")"
    }
}

/// A named, saveable preset. Stored in the 3 slots and exported as a ".drm" file (JSON).
struct Preset: Codable, Equatable {
    var version = 1
    var name: String
    var settings: Settings

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Preset" : name }

    func fileData() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(self)
    }

    /// Accepts a .drm file, or a bare Settings JSON.
    static func decode(_ data: Data) -> Preset? {
        let d = JSONDecoder()
        if let p = try? d.decode(Preset.self, from: data) { return p }
        if let s = try? d.decode(Settings.self, from: data) { return Preset(name: "Imported", settings: s) }
        return nil
    }

    var fileName: String {
        let cleaned = displayName.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_")) + ".drm"
    }
}
