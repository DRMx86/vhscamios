import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showTape = false
    @State private var showSettings = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var editor: EditorModel?

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
                        .frame(width: 340)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    quickChips
                    preview
                    controlsPanel
                }
            }

            if let message = cam.statusMessage, editor == nil {
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
            if phase == .active { if editor == nil { cam.start() } } else { cam.stop() }
        }
        .onChange(of: pickedItem) { item in loadPicked(item) }
        .sheet(isPresented: $showSettings) {
            SettingsView(cam: cam).presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $editor, onDismiss: { cam.start() }) { model in
            EditorView(model: model, cam: cam)
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

    // MARK: Import from the photo library -> editor

    private func loadPicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            defer { pickedItem = nil }
            cam.toast("Loading…")
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    open(EditorModel(video: movie.url, settings: cam.settings))
                    return
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let model = EditorModel(photo: image, settings: cam.settings) {
                open(model)
                return
            }
            cam.toast("Couldn't load that item")
        }
    }

    private func open(_ model: EditorModel) {
        cam.stop()
        editor = model
    }

    // MARK: Top bar (VCR-style on-screen display)

    private var topBar: some View {
        HStack(spacing: 6) {
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
            PhotosPicker(selection: $pickedItem, matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo.on.rectangle").font(.title3).frame(width: 36, height: 32)
            }
            .foregroundStyle(.white)
            .disabled(cam.isRecording)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).frame(width: 36, height: 32)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    /// One-tap toggles that matter most while shooting, plus the loaded preset.
    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
                presetChip
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    /// Shows the loaded preset beside STAB ("*" = changed since loading); otherwise the current look.
    private var presetChip: some View {
        var text: String
        var isPreset = false
        if let i = cam.activeSlot, let p = cam.slots[i] {
            text = "P\(i + 1) \(p.displayName)" + (p.settings == cam.settings ? "" : "*")
            isPreset = true
        } else if let l = tape.lookIndex, Look.all.indices.contains(l) {
            text = Look.all[l].name
        } else {
            text = "Custom"
        }
        return Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(isPreset ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
            .foregroundStyle(isPreset ? Color.black : Color.white.opacity(0.8))
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

    private var picker: some View {
        PresetPicker(
            currentLook: tape.lookIndex, presets: cam.slots, activeSlot: cam.activeSlot, grid: isLandscape,
            onLook: { cam.select(look: $0) },
            onLoad: { cam.loadSlot($0) },
            onSave: { cam.saveSlot($0) })
    }

    private var controlsPanel: some View {
        VStack(spacing: 10) {
            if isLandscape {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        picker
                        if showTape { TapeControlsView(tape: $cam.settings.tape) }
                    }
                }
            } else {
                picker
                if showTape {
                    ScrollView(showsIndicators: false) { TapeControlsView(tape: $cam.settings.tape) }
                        .frame(maxHeight: 200)
                }
            }
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
    @ObservedObject private var exporter = Exporter.shared
    @Environment(\.dismiss) private var dismiss

    private enum ImportTarget { case folder, preset(Int) }
    @State private var showImporter = false
    @State private var importTarget: ImportTarget = .folder
    @State private var shareItem: ShareItem?

    private var importTypes: [UTType] {
        if case .folder = importTarget { return [.folder] }
        return [.data]   // .drm is a custom extension, so allow any file and validate the contents
    }

    var body: some View {
        NavigationStack {
            Form {
                if let m = cam.statusMessage {
                    Section { Text(m).font(.footnote) }
                }

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
                    Text("VHS frame rate = 30 fps. 480p is the most authentic and the smoothest; 1080p may drop frames. Locked while recording.")
                }
                .disabled(cam.isRecording)

                Section {
                    Toggle("Save to Photos", isOn: $exporter.saveToPhotos)
                    Toggle("Save to folder", isOn: $exporter.saveToFolder).disabled(!exporter.hasFolder)
                    Button {
                        importTarget = .folder
                        showImporter = true
                    } label: {
                        HStack {
                            Text(exporter.hasFolder ? "Folder: \(exporter.folderName ?? "")" : "Choose folder…")
                            Spacer()
                            Image(systemName: "folder")
                        }
                    }
                    if exporter.hasFolder {
                        Button("Stop using this folder", role: .destructive) { exporter.clearFolder() }
                    }
                } header: {
                    Text("Save location")
                } footer: {
                    Text("Pick any folder in Files: iCloud Drive, On My iPhone, or a USB drive plugged into the phone. Recordings are copied there after you stop. If the folder can't be reached (drive unplugged), the file goes to Photos instead so nothing is lost.")
                }

                Section {
                    ForEach(0..<3, id: \.self) { presetRow($0) }
                } header: {
                    Text("My presets")
                } footer: {
                    Text("A preset stores the look, tape controls and format. Rename it here, or use the ⋯ menu to save it as a .drm file (to Files / a USB drive / AirDrop) or import one. Long-press P1–P3 on the camera screen to save.")
                }

                Section {
                    Button("Reset all settings", role: .destructive) { cam.resetSettings() }
                }

                Section {
                    NavigationLink("About") { AboutView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { handleImport($0) }
            .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        }
    }

    private func presetRow(_ i: Int) -> some View {
        let preset = cam.slots[i]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("P\(i + 1)").font(.system(.headline, design: .monospaced)).frame(width: 34, alignment: .leading)
                if preset != nil {
                    TextField("Name", text: Binding(
                        get: { cam.slots[i]?.name ?? "" },
                        set: { cam.renameSlot(i, $0) }))
                } else {
                    Text("Empty").foregroundStyle(.secondary)
                    Spacer()
                }
                Menu {
                    if let p = preset {
                        Button { if let url = cam.presetFile(i) { shareItem = ShareItem(url: url) } } label: {
                            Label("Save / share .drm file…", systemImage: "square.and.arrow.up")
                        }
                        if exporter.hasFolder {
                            Button {
                                if let url = cam.presetFile(i) {
                                    let ok = exporter.copyToFolder(url, name: p.fileName)
                                    cam.toast(ok ? "Saved \(p.fileName) to \(exporter.folderName ?? "folder")" : "Folder unavailable")
                                }
                            } label: { Label("Save .drm to \(exporter.folderName ?? "folder")", systemImage: "folder") }
                        }
                    }
                    Button {
                        importTarget = .preset(i)
                        showImporter = true
                    } label: { Label("Import .drm file…", systemImage: "square.and.arrow.down") }
                    if preset != nil {
                        Button(role: .destructive) { cam.clearSlot(i) } label: { Label("Clear", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            if let p = preset {
                Text(p.settings.summary).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save current") { cam.saveSlot(i) }.buttonStyle(.bordered)
                Button("Load") { cam.loadSlot(i) }
                    .buttonStyle(.borderedProminent)
                    .disabled(preset == nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch importTarget {
        case .folder:
            if !exporter.setFolder(url) { cam.toast("Couldn't use that folder") }
        case .preset(let i):
            if let data = try? Data(contentsOf: url), cam.importPreset(data, into: i) { return }
            cam.toast("That isn't a valid .drm preset")
        }
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("VHS RetroCam")
                .font(.system(.title2, design: .monospaced).weight(.bold))
            Text("2026 drmascarina")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
