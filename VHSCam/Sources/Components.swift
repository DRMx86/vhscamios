import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tape sliders (shared by the camera screen and the editor)

struct TapeSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 82, alignment: .leading)
            Slider(value: $value, in: range)
            Text("\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 100))")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 32, alignment: .trailing)
        }
        .disabled(dimmed)
        .opacity(dimmed ? 0.4 : 1)
    }
}

struct TapeControlsView: View {
    @Binding var tape: TapeSettings
    var locked = false

    var body: some View {
        let vhs = tape.vhsOn
        VStack(spacing: 6) {
            Toggle(isOn: $tape.vhsOn) {
                Text("VHS EFFECT").font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            TapeSlider(label: "GRAIN", value: $tape.grain, dimmed: !vhs)
            TapeSlider(label: "COLOR", value: $tape.color, range: 0...1.5)
            TapeSlider(label: "DISTORTION", value: $tape.tracking, dimmed: !vhs)
            TapeSlider(label: "SOFTNESS", value: $tape.softness, dimmed: !vhs)
            TapeSlider(label: "COMPOSITE", value: $tape.compositeNoise, dimmed: !vhs)
            TapeSlider(label: "VIGNETTE", value: $tape.vignette)

            HStack(spacing: 8) {
                Text("SNOW")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 82, alignment: .leading)
                Toggle("Snow", isOn: $tape.snowOn).labelsHidden()
                Slider(value: $tape.snow, in: 0...0.02).disabled(!tape.snowOn)
            }
            .disabled(!vhs).opacity(vhs ? 1 : 0.4)

            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text("LOWPASS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 82, alignment: .leading)
                    Picker("Lowpass filter", selection: $tape.filter) {
                        ForEach(LowpassFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Text(tape.filter.hint)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .disabled(!vhs).opacity(vhs ? 1 : 0.4)
        }
        .disabled(locked)
    }
}

// MARK: - Looks + 3 preset slots

/// Looks (one tap) and the three custom preset slots (tap = load, long-press = save).
/// In landscape both become grids and the preset buttons get bigger.
struct PresetPicker: View {
    let currentLook: Int?
    let presets: [Preset?]
    let activeSlot: Int?
    let grid: Bool
    var onLook: (Int) -> Void
    var onLoad: (Int) -> Void
    var onSave: (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            if grid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(Look.all.indices, id: \.self) { lookChip($0) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(Look.all.indices, id: \.self) { lookChip($0) } }
                }
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { presetButton($0) }
            }
            Text("Presets: tap to load · hold to save")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func lookChip(_ index: Int) -> some View {
        let selected = currentLook == index
        return Button { onLook(index) } label: {
            Text(Look.all[index].name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: grid ? .infinity : nil)
                .background(selected ? Color.white : Color.white.opacity(0.15), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.white)
        }
    }

    private func presetButton(_ i: Int) -> some View {
        let preset = presets[i]
        let filled = preset != nil
        let active = activeSlot == i && filled
        return VStack(spacing: 2) {
            Text("P\(i + 1)").font(.system(size: 17, weight: .heavy, design: .monospaced))
            Text(preset?.displayName ?? "Empty")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: grid ? 60 : 50)
        .background(filled ? Color.yellow : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: active ? 3 : 0))
        .foregroundStyle(filled ? Color.black : Color.white.opacity(0.55))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onLoad(i) }
        .onLongPressGesture(minimumDuration: 0.6) { onSave(i) }
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Misc

/// A video picked from the photo library, copied to a temp file so AVFoundation can read it.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}
