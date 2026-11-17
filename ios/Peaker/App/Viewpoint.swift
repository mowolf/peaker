import PeakerKit

/// Fixed viewpoints inside the bundled packs, for trying the app anywhere (and as fallback without GPS).
struct Viewpoint: Identifiable, Hashable {
    let id: String
    let name: String
    let region: String
    let coordinate: GeoCoordinate
    /// Direction the touch-mode view starts in (towards the famous view).
    let initialYaw: Double

    static let gornergrat = Viewpoint(id: "gornergrat", name: "Gornergrat", region: "Zermatt, Switzerland",
                                      coordinate: GeoCoordinate(latitude: 45.9832, longitude: 7.7849), initialYaw: 255)
    static let kalaPatthar = Viewpoint(id: "kala-patthar", name: "Kala Patthar", region: "Everest, Nepal",
                                       coordinate: GeoCoordinate(latitude: 27.9958, longitude: 86.8285), initialYaw: 85)
    static let poonHill = Viewpoint(id: "poon-hill", name: "Poon Hill", region: "Annapurna, Nepal",
                                    coordinate: GeoCoordinate(latitude: 28.4005, longitude: 83.6969), initialYaw: 10)
    static let all = [gornergrat, kalaPatthar, poonHill]

    static func with(id: String) -> Viewpoint? { all.first { $0.id == id } }
}
