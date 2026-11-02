import AVFoundation
import Foundation
import Observation

/// Back camera preview session and its field of view.
///
/// Switching the camera on should feel instant, so the session is configured ahead of time
/// (`prepare()`, at launch when access was already granted) and only started/stopped on toggle.
/// `isRunning` turns true when frames flow, so the UI can fade the preview in instead of showing black.
@Observable
final class CameraService {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "peaker.camera")
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Called on the main queue once the real field of view and zoom range are known.
    @ObservationIgnored var onConfigured: (() -> Void)?

    /// Field of view across the sensor's long side (degrees), i.e. the screen height in portrait.
    private(set) var fieldOfView: Double = 65
    /// Largest useful zoom factor of the back camera.
    private(set) var maxZoom: Double = 1
    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    /// True while the session delivers frames.
    private(set) var isRunning = false

    var isAuthorized: Bool { authorization == .authorized }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    init() {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.didStartRunningNotification, AVCaptureSession.didStopRunningNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.isRunning = self.session.isRunning
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Configure the session in the background without starting it (no camera indicator, no battery use).
    func prepare() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        authorization = .authorized
        configureIfNeeded(thenStart: false)
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorization = .authorized
            configureIfNeeded(thenStart: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted { self.configureIfNeeded(thenStart: true) }
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

    /// Optical/digital zoom of the preview (1 = widest). The overlay uses the same factor.
    func setZoom(_ factor: Double) {
        guard let device else { return }
        let clamped = CGFloat(max(1, min(factor, maxZoom)))
        queue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }
    }

    private func configureIfNeeded(thenStart start: Bool) {
        let session = session
        let needsConfig = !configured
        configured = true
        queue.async {
            if needsConfig {
                session.beginConfiguration()
                session.sessionPreset = .high
                var fov: Double?
                var zoomLimit: Double?
                var chosen: AVCaptureDevice?
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                    fov = Double(device.activeFormat.videoFieldOfView)
                    zoomLimit = min(6, Double(device.maxAvailableVideoZoomFactor))
                    chosen = device
                }
                session.commitConfiguration()
                DispatchQueue.main.async {
                    if let fov, fov > 10 { self.fieldOfView = fov }
                    self.maxZoom = zoomLimit ?? 1
                    self.device = chosen
                    self.onConfigured?()
                }
            }
            if start, !session.isRunning { session.startRunning() }
        }
    }
}
