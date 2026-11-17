import AVFoundation
import SwiftUI

/// Aspect-filled live preview of the back camera, rotated for the interface orientation.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Preview rotation for the interface orientation (90 portrait, 0 / 180 landscape).
    var rotationAngle: CGFloat = 90

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        // Only shows the image: it stays in the view tree (invisible while the camera is off) and must never
        // take touches meant for the controls and gestures on top of it.
        view.isUserInteractionEnabled = false
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        applyRotation(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        applyRotation(uiView)
    }

    private func applyRotation(_ view: PreviewView) {
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(rotationAngle),
           connection.videoRotationAngle != rotationAngle {
            connection.videoRotationAngle = rotationAngle
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
