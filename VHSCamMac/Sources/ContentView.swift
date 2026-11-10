import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var showTape = true

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                CameraPreview(displayLayer: cam.displayLayer)
                topBar
                if let message = cam.statusMessage {
                    Text(message)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .background(Color.black)

            Divider()
            sidebar.frame(width: 310)
        }
        .frame(minWidth: 900, minHeight: 580)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: cam.statusMessage)
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
        .alert("Camera access needed", isPresented: $cam.cameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable camera access for VHS Cam in System Settings > Privacy & Security > Camera.")
        }
    }

    // MARK: VCR-style on-screen display

    private var topBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(cam.isRecording ? Color.red : Color.gray.opacity(0.5))
                .frame(width: 10, height: 10)
            Text(cam.isRecording ? "REC \(timecode(cam.recordingSeconds))" : "STBY")
                .font(.system(.callout, design: .monospaced).weight(.bold))
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourcePickers
                Divider()
                Text("LOOK").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                lookGrid
                DisclosureGroup("TAPE", isExpanded: $showTape) {
                    VStack(spacing: 8) {
                        tapeSlider("GRAIN", $cam.grain)
                        tapeSlider("COLOR", $cam.color, range: 0...1.5)
                        tapeSlider("DISTORTION", $cam.tracking)
                        tapeSlider("SOFTNESS", $cam.softness)
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                Divider()
                actionRow
            }
            .padding(16)
        }
    }

    private var sourcePickers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SOURCE").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Picker("Camera", selection: Binding(get: { cam.cameraID }, set: { cam.selectCamera($0) })) {
                if cam.cameras.isEmpty { Text("No camera found").tag("") }
                ForEach(cam.cameras) { Text($0.name).tag($0.id) }
            }
            Picker("Mic", selection: Binding(get: { cam.micID }, set: { cam.selectMic($0) })) {
                Text("No audio").tag("")
                ForEach(cam.mics) { Text($0.name).tag($0.id) }
            }
            Picker("Size", selection: Binding(get: { cam.useHD }, set: { cam.setHD($0) })) {
                Text("480p (authentic)").tag(false)
                Text("720p").tag(true)
            }
            .pickerStyle(.segmented)
        }
        .disabled(cam.isRecording)
    }

    private var lookGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
            ForEach(CameraManager.looks.indices, id: \.self) { index in
                let selected = cam.selectedLook == index
                Button { cam.select(look: index) } label: {
                    Text(CameraManager.looks[index].name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selected ? Color.white : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(selected ? Color.black : Color.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tapeSlider(_ label: String, _ value: Binding<Double>,
                            range: ClosedRange<Double> = 0...1) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))").font(.system(size: 11, design: .monospaced))
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $cam.captureMode) {
                Text("VIDEO").tag(CameraManager.CaptureMode.video)
                Text("PHOTO").tag(CameraManager.CaptureMode.photo)
            }
            .pickerStyle(.segmented)
            .disabled(cam.isRecording)

            Button {
                switch cam.captureMode {
                case .photo: cam.takePhoto()
                case .video: cam.toggleRecording()
                }
            } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 64, height: 64)
                    if cam.captureMode == .video {
                        RoundedRectangle(cornerRadius: cam.isRecording ? 7 : 25)
                            .fill(Color.red)
                            .frame(width: cam.isRecording ? 26 : 50, height: cam.isRecording ? 26 : 50)
                            .animation(.easeInOut(duration: 0.15), value: cam.isRecording)
                    } else {
                        Circle().fill(Color.white).frame(width: 52, height: 52)
                    }
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .frame(maxWidth: .infinity)

            Text("Space = shutter  ·  saved to Movies / Pictures › VHS Cam")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func timecode(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
