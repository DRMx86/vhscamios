import SwiftUI
import AVFoundation

/// Hosts the AVSampleBufferDisplayLayer that shows the processed (VHS) frames.
struct CameraPreview: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.layer.addSublayer(displayLayer)
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {}
}

final class HostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers?.forEach {
            // bounds + position (not frame) so a mirroring transform stays valid
            $0.bounds = bounds
            $0.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }
}
