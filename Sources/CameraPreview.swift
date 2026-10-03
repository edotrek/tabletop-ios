import AVFoundation
import SwiftUI

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Anteprima della fotocamera. Un tocco mette a fuoco ed espone su quel punto.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        if let conn = view.previewLayer.connection, conn.isVideoRotationAngleSupported(90), conn.videoRotationAngle != 90 {
            conn.videoRotationAngle = 90
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    final class Coordinator: NSObject {
        let camera: CameraController
        weak var view: PreviewUIView?

        init(camera: CameraController) { self.camera = camera }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            camera.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))

            // Quadratino giallo dove si è toccato.
            let marker = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
            marker.center = point
            marker.layer.borderColor = UIColor.systemYellow.cgColor
            marker.layer.borderWidth = 2
            marker.isUserInteractionEnabled = false
            view.addSubview(marker)
            UIView.animate(withDuration: 0.4, delay: 1.0, options: []) {
                marker.alpha = 0
            } completion: { _ in
                marker.removeFromSuperview()
            }
        }
    }
}
