import AVFoundation
import Foundation
import Observation

/// Back camera preview session and its field of view.
@Observable
final class CameraService {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "peaker.camera")
    @ObservationIgnored private var configured = false
    /// Field of view across the sensor's long side (degrees), i.e. the screen height in portrait.
    private(set) var fieldOfView: Double = 65
    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)

    var isAuthorized: Bool { authorization == .authorized }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted { self.run() }
                }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func stop() {
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func run() {
        authorization = .authorized
        let session = session
        let needsConfig = !configured
        configured = true
        queue.async {
            var fov: Double?
            if needsConfig {
                session.beginConfiguration()
                session.sessionPreset = .high
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                    fov = Double(device.activeFormat.videoFieldOfView)
                }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
            if let fov, fov > 10 {
                DispatchQueue.main.async { self.fieldOfView = fov }
            }
        }
    }
}
