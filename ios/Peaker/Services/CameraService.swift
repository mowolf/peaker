import AVFoundation
import Foundation
import Observation

/// Back camera preview session and its field of view.
///
/// Switching the camera on should feel instant, so the session is configured ahead of time
/// (`prepare()`, at launch when access was already granted) and only started/stopped on toggle.
/// `isRunning` turns true when frames flow, so the UI can fade the preview in instead of showing black.
///
/// Concurrency: the observable state lives on the main actor; the capture session and device are only
/// touched on `Capture.queue` (configuration, start/stop and zoom block, so they must stay off the main thread).
@MainActor
@Observable
final class CameraService {
    /// AVFoundation objects confined to `queue`, Apple's recommended pattern for capture sessions.
    /// `@unchecked Sendable` because the confinement is by convention: every use goes through `queue`
    /// (except handing `session` to the preview layer, which AVFoundation allows from the main thread).
    private final class Capture: @unchecked Sendable {
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "peaker.camera")
        /// Set and used on `queue` only.
        var device: AVCaptureDevice?
        var configured = false
    }

    /// Removes the notification observers when the service goes away (no main-actor deinit needed).
    private final class Observers: @unchecked Sendable {
        var tokens: [any NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    @ObservationIgnored private let capture = Capture()
    @ObservationIgnored private let observers = Observers()
    /// Called once the real field of view and zoom range are known.
    @ObservationIgnored var onConfigured: (() -> Void)?
    @ObservationIgnored private var configurationRequested = false

    /// The preview layer's session.
    var session: AVCaptureSession { capture.session }
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
            let started = name == AVCaptureSession.didStartRunningNotification
            observers.tokens.append(center.addObserver(forName: name, object: capture.session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRunning(started) }
            })
        }
    }

    private func setRunning(_ running: Bool) {
        if isRunning != running { isRunning = running }
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
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                authorization = AVCaptureDevice.authorizationStatus(for: .video)
                if granted { configureIfNeeded(thenStart: true) }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func stop() {
        let capture = capture
        capture.queue.async {
            if capture.session.isRunning { capture.session.stopRunning() }
        }
    }

    /// Optical/digital zoom of the preview (1 = widest). The overlay uses the same factor.
    func setZoom(_ factor: Double) {
        let clamped = CGFloat(max(1, min(factor, maxZoom)))
        let capture = capture
        capture.queue.async {
            guard let device = capture.device, (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }
    }

    private func configureIfNeeded(thenStart start: Bool) {
        let needsConfig = !configurationRequested
        configurationRequested = true
        let capture = capture
        capture.queue.async { [weak self] in
            if needsConfig, !capture.configured {
                capture.configured = true
                let lens = Self.configure(capture)
                Task { @MainActor in self?.didConfigure(fieldOfView: lens?.fieldOfView, maxZoom: lens?.maxZoom) }
            }
            if start, !capture.session.isRunning { capture.session.startRunning() }
        }
    }

    /// Add the back wide-angle camera to the session. Runs on the capture queue.
    nonisolated private static func configure(_ capture: Capture) -> (fieldOfView: Double, maxZoom: Double)? {
        let session = capture.session
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        capture.device = device
        return (Double(device.activeFormat.videoFieldOfView), min(6, Double(device.maxAvailableVideoZoomFactor)))
    }

    private func didConfigure(fieldOfView fov: Double?, maxZoom zoom: Double?) {
        if let fov, fov > 10 { fieldOfView = fov }
        maxZoom = zoom ?? 1
        onConfigured?()
    }
}
