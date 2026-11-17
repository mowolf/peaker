import CoreLocation
import Foundation
import Observation

/// GPS position. The horizon is computed from the DEM height at this position, not GPS altitude.
///
/// Main actor: the manager is created on the main thread, so Core Location calls the delegate there too.
/// The delegate conformance is isolated to the main actor (Swift 6.2), so no hops are needed.
@MainActor
@Observable
final class LocationService: NSObject {
    @ObservationIgnored private let manager = CLLocationManager()
    private(set) var location: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @ObservationIgnored var onUpdate: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // No distance filter: a more accurate fix at the same spot must still be delivered.
        // AppModel decides when a new fix is worth recomputing (RecomputePolicy).
        manager.distanceFilter = kCLDistanceFilterNone
        authorization = manager.authorizationStatus
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func requestAndStart() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    /// Restart updates to get a fresh fix right away.
    func refresh() {
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }
}

extension LocationService: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if authorization != status { authorization = status }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0, last.horizontalAccuracy < 500 else { return }
        location = last
        onUpdate?(last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
