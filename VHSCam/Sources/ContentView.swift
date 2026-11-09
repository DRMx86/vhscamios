import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    private let presetNames = ["Light", "Classic", "Worn"]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                CameraPreview(displayLayer: cam.displayLayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomPanel
            }

            if let message = cam.statusMessage {
                Text(message)
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .center)
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
                Label(cam.useHD ? "720p" : "480p", systemImage: "slider.horizontal.3")
                    .font(.system(.callout, design: .monospaced))
            }
            .disabled(cam.isRecording)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: Bottom controls

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            Picker("Look", selection: $cam.preset) {
                ForEach(0..<presetNames.count, id: \.self) { Text(presetNames[$0]).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Image(systemName: "waveform.path")
                Slider(value: $cam.intensity, in: 0...1)
                Text("\(Int(cam.intensity * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Button {
                    guard !cam.isRecording else { return }
                    cam.captureMode = (cam.captureMode == .video) ? .photo : .video
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: cam.captureMode == .video ? "video.fill" : "camera.fill")
                            .font(.title3)
                        Text(cam.captureMode == .video ? "VIDEO" : "PHOTO")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 64, height: 56)
                }
                .foregroundStyle(.white)

                Spacer()
                shutterButton
                Spacer()

                Button {
                    cam.switchCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .frame(width: 64, height: 56)
                }
                .foregroundStyle(.white)
                .disabled(cam.isRecording)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var shutterButton: some View {
        Button {
            switch cam.captureMode {
            case .photo: cam.takePhoto()
            case .video: cam.toggleRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                if cam.captureMode == .video {
                    RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 30)
                        .fill(Color.red)
                        .frame(width: cam.isRecording ? 32 : 60, height: cam.isRecording ? 32 : 60)
                        .animation(.easeInOut(duration: 0.15), value: cam.isRecording)
                } else {
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                }
            }
        }
    }

    private func timecode(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
