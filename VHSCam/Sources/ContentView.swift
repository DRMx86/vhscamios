import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showTape = false
    @State private var showSettings = false

    private var isLandscape: Bool { verticalSizeClass == .compact }
    private var tape: TapeSettings { cam.settings.tape }
    private var format: FormatSettings { cam.settings.format }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLandscape {
                HStack(spacing: 0) {
                    preview
                        .overlay(alignment: .top) {
                            VStack(spacing: 4) { topBar; quickChips }
                        }
                    controlsPanel
                        .frame(width: 330)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    quickChips
                    preview
                    controlsPanel
                }
            }

            if let message = cam.statusMessage {
                Text(message)
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: cam.statusMessage)
        .onAppear { cam.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { cam.start() } else { cam.stop() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(cam: cam).presentationDetents([.medium, .large])
        }
        .alert("Camera access needed", isPresented: $cam.cameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable camera access for VHS Cam in Settings.")
        }
    }

    private var preview: some View {
        CameraPreview(displayLayer: cam.displayLayer)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Top bar (VCR-style on-screen display)

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(cam.isRecording ? Color.red : Color.gray.opacity(0.5))
                    .frame(width: 10, height: 10)
                Text(cam.isRecording ? "REC \(timecode(cam.recordingSeconds))" : "STBY")
                    .font(.system(.callout, design: .monospaced).weight(.bold))
            }
            Spacer()
            Text("\(format.resolution.rawValue) · \(format.aspect.rawValue)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).frame(width: 36, height: 32)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    /// One-tap toggles that matter most while shooting.
    private var quickChips: some View {
        HStack(spacing: 8) {
            chip("VHS", on: tape.vhsOn) { cam.settings.tape.vhsOn.toggle() }
            chip(format.aspect == .square ? "1:1" : "FULL", on: format.aspect == .square) {
                cam.settings.format.aspect = format.aspect.next
            }
            .disabled(cam.isRecording)
            chip(format.fps.shortLabel, on: format.fps != .vhs) {
                cam.settings.format.fps = format.fps.next
            }
            .disabled(cam.isRecording)
            chip("STAB", on: format.stabilization) { cam.settings.format.stabilization.toggle() }
                .disabled(cam.isRecording)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .foregroundStyle(on ? Color.black : Color.white)
                .background(on ? Color.white : Color.white.opacity(0.15), in: Capsule())
        }
    }

    // MARK: Controls

    private var controlsPanel: some View {
        VStack(spacing: 10) {
            if isLandscape {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) { lookStrip; if showTape { tapeControls } }
                }
            } else {
                lookStrip
                if showTape {
                    ScrollView(showsIndicators: false) { tapeControls }
                        .frame(maxHeight: 210)
                }
            }
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var lookStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Look.all.indices, id: \.self) { index in
                    let selected = tape.lookIndex == index
                    Button {
                        cam.select(look: index)
                    } label: {
                        Text(Look.all[index].name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selected ? Color.white : Color.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(selected ? Color.black : Color.white)
                    }
                }
                Divider().frame(height: 20)
                // Tap = load, long-press = save current settings.
                ForEach(0..<3, id: \.self) { i in
                    let filled = cam.slots[i] != nil
                    Text("P\(i + 1)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(filled ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(filled ? Color.black : Color.white.opacity(0.6))
                        .onTapGesture { cam.loadSlot(i) }
                        .onLongPressGesture(minimumDuration: 0.6) { cam.saveSlot(i) }
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private var tapeControls: some View {
        let vhs = tape.vhsOn
        return VStack(spacing: 6) {
            tapeSlider("GRAIN", $cam.settings.tape.grain, vhsOnly: true)
            tapeSlider("COLOR", $cam.settings.tape.color, range: 0...1.5)
            tapeSlider("DISTORTION", $cam.settings.tape.tracking, vhsOnly: true)
            tapeSlider("SOFTNESS", $cam.settings.tape.softness, vhsOnly: true)
            tapeSlider("COMPOSITE", $cam.settings.tape.compositeNoise, range: 0...0.2, vhsOnly: true)
            tapeSlider("VIGNETTE", $cam.settings.tape.vignette)

            HStack(spacing: 8) {
                Text("SNOW")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 82, alignment: .leading)
                Toggle("Snow", isOn: $cam.settings.tape.snowOn).labelsHidden()
                Slider(value: $cam.settings.tape.snow, in: 0...0.02)
                    .disabled(!tape.snowOn)
            }
            .disabled(!vhs).opacity(vhs ? 1 : 0.4)

            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text("LOWPASS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 82, alignment: .leading)
                    Picker("Lowpass filter", selection: $cam.settings.tape.filter) {
                        ForEach(LowpassFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Text(tape.filter.hint)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .disabled(!vhs).opacity(vhs ? 1 : 0.4)
        }
    }

    private func tapeSlider(_ label: String, _ value: Binding<Double>,
                            range: ClosedRange<Double> = 0...1, vhsOnly: Bool = false) -> some View {
        let dim = vhsOnly && !tape.vhsOn
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound)) * 100))")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 32, alignment: .trailing)
        }
        .disabled(dim).opacity(dim ? 0.4 : 1)
    }

    private var actionRow: some View {
        HStack {
            HStack(spacing: 0) {
                smallButton(icon: cam.captureMode == .video ? "video.fill" : "camera.fill",
                            title: cam.captureMode == .video ? "VIDEO" : "PHOTO") {
                    guard !cam.isRecording else { return }
                    cam.captureMode = (cam.captureMode == .video) ? .photo : .video
                }
                smallButton(icon: "slider.vertical.3", title: "TAPE") { showTape.toggle() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            shutterButton

            smallButton(icon: "arrow.triangle.2.circlepath.camera", title: format.camera == .back ? "BACK" : "FRONT") {
                cam.switchCamera()
            }
            .disabled(cam.isRecording)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func smallButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .frame(width: 52, height: 52)
        }
        .foregroundStyle(.white)
    }

    private var shutterButton: some View {
        Button {
            switch cam.captureMode {
            case .photo:
                cam.takePhoto()
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            case .video:
                cam.toggleRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 72, height: 72)
                if cam.captureMode == .video {
                    RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 28)
                        .fill(Color.red)
                        .frame(width: cam.isRecording ? 30 : 56, height: cam.isRecording ? 30 : 56)
                        .animation(.easeInOut(duration: 0.15), value: cam.isRecording)
                } else {
                    Circle().fill(Color.white).frame(width: 58, height: 58)
                }
            }
        }
    }

    private func timecode(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Settings sheet

struct SettingsView: View {
    @ObservedObject var cam: CameraManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Shape", selection: $cam.settings.format.aspect) {
                        ForEach(AspectMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Orientation", selection: $cam.settings.format.orientation) {
                        ForEach(OrientationMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Resolution", selection: $cam.settings.format.resolution) {
                        ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Camera", selection: $cam.settings.format.camera) {
                        ForEach(CameraSide.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Frame rate", selection: $cam.settings.format.fps) {
                        ForEach(FrameRate.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("Image stabilization", isOn: $cam.settings.format.stabilization)
                } header: {
                    Text("Format")
                } footer: {
                    Text("VHS frame rate = 30 fps. 480p is the most authentic and the smoothest; 1080p may drop frames. Stabilization only works where the camera format supports it. Locked while recording.")
                }
                .disabled(cam.isRecording)

                Section {
                    ForEach(0..<3, id: \.self) { i in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Preset \(i + 1)").font(.headline)
                                Text(cam.slots[i]?.summary ?? "Empty")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Save") { cam.saveSlot(i) }.buttonStyle(.bordered)
                            Button("Load") { cam.loadSlot(i) }
                                .buttonStyle(.borderedProminent)
                                .disabled(cam.slots[i] == nil)
                        }
                        .swipeActions { Button("Clear", role: .destructive) { cam.clearSlot(i) } }
                    }
                } header: {
                    Text("My presets")
                } footer: {
                    Text("A preset stores the look, tape controls and format. Long-press P1–P3 on the camera screen to save. Swipe a row to clear it. Loading during a recording keeps the current format.")
                }

                Section {
                    Button("Reset all settings", role: .destructive) { cam.resetSettings() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
