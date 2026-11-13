import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var cam: CameraManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var activeSlot: Int?

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLandscape {
                HStack(spacing: 0) {
                    previewArea
                    ScrollView(showsIndicators: false) { controls }.frame(width: 340)
                }
            } else {
                previewArea
                ScrollView(showsIndicators: false) { controls }.frame(maxHeight: 330)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button("Close") { dismiss() }.disabled(model.isRendering)
            Spacer()
            if model.isRendering {
                ProgressView(value: model.progress).frame(width: 110)
                Button("Cancel") { model.cancelRender() }.padding(.leading, 6)
            } else {
                Text("EDIT").font(.system(.headline, design: .monospaced))
                Spacer()
                Button { model.render() } label: {
                    Text("Render").font(.system(.callout, design: .monospaced).weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.red, in: Capsule()).foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var previewArea: some View {
        ZStack {
            Color.black
            if let img = model.previewImage {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                ProgressView()
            }
            if let msg = model.message {
                VStack { Spacer()
                    Text(msg).font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if model.isVideo {
                HStack(spacing: 8) {
                    Text("FRAME").font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 82, alignment: .leading)
                    Slider(value: $model.scrub, in: 0...1)
                }
            }
            Picker("Shape", selection: $model.aspect) {
                ForEach(AspectMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Resolution", selection: $model.resolution) {
                ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)

            PresetPicker(
                currentLook: model.tape.lookIndex, presets: cam.slots, activeSlot: activeSlot, grid: isLandscape,
                onLook: { model.select(look: $0); activeSlot = nil },
                onLoad: { i in
                    if let p = cam.slots[i] { model.apply(p.settings); activeSlot = i }
                    else { model.message = "P\(i + 1) is empty · hold to save" }
                },
                onSave: { i in
                    var s = cam.settings
                    s.tape = model.tape
                    s.format.aspect = model.aspect
                    s.format.resolution = model.resolution
                    cam.storePreset(s, slot: i)
                    activeSlot = i
                })

            TapeControlsView(tape: $model.tape, locked: model.isRendering)

            Text("Saves to: \(Exporter.shared.destinationSummary) · \(model.isVideo ? "preview shows one frame; Render does the whole clip" : "photo")")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
        .disabled(model.isRendering)
    }
}
