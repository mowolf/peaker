import Foundation
import Network
import Observation

/// Current network path, for download decisions: is there a connection, and is it "expensive"
/// (mobile data or a personal hotspot) or "constrained" (Low Data Mode)?
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isConnected = true
    /// Mobile data or a personal hotspot.
    private(set) var isExpensive = false
    /// Low Data Mode is on.
    private(set) var isConstrained = false

    /// Wi-Fi or wired, without Low Data Mode: fine for big downloads.
    var isUnmetered: Bool { isConnected && !isExpensive && !isConstrained }

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive, constrained = path.isConstrained
            // Delivered on the main queue (see `start` below).
            MainActor.assumeIsolated {
                self?.update(connected: connected, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: .main)
    }

    private func update(connected: Bool, expensive: Bool, constrained: Bool) {
        if isConnected != connected { isConnected = connected }
        if isExpensive != expensive { isExpensive = expensive }
        if isConstrained != constrained { isConstrained = constrained }
    }
}
