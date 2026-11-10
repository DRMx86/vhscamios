import SwiftUI
import AVFoundation
import AppKit

/// Hosts the AVSampleBufferDisplayLayer that shows the processed (VHS) frames.
struct CameraPreview: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(displayLayer)
        return view
    }

    func updateNSView(_ nsView: HostView, context: Context) {}
}

final class HostView: NSView {
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }
}
