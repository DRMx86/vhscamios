import SwiftUI

@main
struct VHSCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView().ignoresSafeArea().background(Color.black)
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CameraViewController { CameraViewController() }
    func updateUIViewController(_ vc: CameraViewController, context: Context) {}
}
