import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showTape = true

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLandscape {
                HStack(spacing: 0) {
                    preview
                        .overlay(alignment: .top) { topBar }
                    controlsPanel
                        .frame(width: 310)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
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
            Menu {
                Picker("Resolution", selection: Binding(
                    get: { cam.useHD },
                    set: { cam.setHD($0) })) {
                    Text("480p (authentic, fastest)").tag(false)
                    Text("720p").tag(true)
                }
            } label: {
                Label(cam.useHD ? "720p" : "480p", systemImage: "gearshape")
                    .font(.system(.callout, design: .monospaced))
            }
            .disabled(cam.isRecording)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: Controls

    private var controlsPanel: some View {
        VStack(spacing: 12) {
            if isLandscape {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) { lookChips; if showTape { tapeSliders } }
                }
            } else {
                lookChips
                if showTape { tapeSliders }
            }
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var lookChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CameraManager.looks.indices, id: \.self) { index in
                    let selected = cam.selectedLook == index
                    Button {
                        cam.select(look: index)
                    } label: {
                        Text(CameraManager.looks[index].name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selected ? Color.white : Color.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(selected ? Color.black : Color.white)
                    }
                }
            }
        }
    }

    private var tapeSliders: some View {
        VStack(spacing: 6) {
            tapeSlider("GRAIN", $cam.grain)
            tapeSlider("COLOR", $cam.color, range: 0...1.5)
            tapeSlider("DISTORTION", $cam.tracking)
            tapeSlider("SOFTNESS", $cam.softness)
        }
    }

    private func tapeSlider(_ label: String, _ value: Binding<Double>,
                            range: ClosedRange<Double> = 0...1) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 32, alignment: .trailing)
        }
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

            smallButton(icon: "arrow.triangle.2.circlepath.camera", title: "FLIP") {
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
            .frame(width: 48, height: 52)
        }
        .foregroundStyle(.white)
    }

    private var shutterButton: some View {
        Button {
            switch cam.captureMode {
            case .photo: cam.takePhoto()
            case .video: cam.toggleRecording()
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
