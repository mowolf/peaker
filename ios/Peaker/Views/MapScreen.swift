import PeakerKit
import RealityKit
import SwiftUI
import UIKit

/// The 3D map: our own terrain from the elevation tiles, peaks labelled where they can be seen.
/// Drag to move, pinch to zoom, twist to turn; 2D/3D tilts between a flat map and a bird's-eye view.
/// Zoomed out past the flat map's range it becomes a globe of the whole Earth.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: MapCamera?
    @State private var globeDragStart: GlobeCamera?
    /// Zoom value (flat: distance; globe: altitude) and magnification when the pinch started or changed mode.
    @State private var pinchBase: (value: Float, magnification: CGFloat)?
    @State private var rotateStart: Float?
    @State private var showsSearch = false
    @State private var labelMemory = MapLabelMemory()

    var body: some View {
        let map = model.map
        GeometryReader { geo in
            let size = geo.size
            let labels = layoutLabels(size: size)
            ZStack {
                MapSceneView(camera: map.sceneCamera,
                             entities: map.mode == .globe ? (map.globeEntity.map { [$0] } ?? []) : map.sceneEntities,
                             background: map.mode == .globe ? Self.space : backgroundColor)
                    .allowsHitTesting(false)
                Canvas(rendersAsynchronously: false) { context, _ in
                    drawBookMarkers(&context, size: size)
                    drawPosition(&context, size: size)
                    drawLabels(&context, labels: labels)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
                .simultaneousGesture(pinchGesture)
                .simultaneousGesture(rotateGesture)
                .onTapGesture(coordinateSpace: .local) { point in
                    model.map.stopCinematic()
                    if let hit = labels.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }) {
                        select(hit.peak)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { MapTopControls() }
        .overlay(alignment: .bottom) { MapBottomControls(showsSearch: $showsSearch) }
        .sheet(isPresented: $showsSearch) {
            PeakPickerView(title: "Find on map", allowsTypedName: false) { peak in
                guard let coordinate = peak.coordinate else { return }
                model.showOnMap(coordinate: coordinate, peakID: peak.id)
            }
        }
        // The start view the first time (waits for a position), afterwards just what changed meanwhile.
        .task {
            await model.showStartView()
            refresh()
        }
        .onChange(of: model.settings.mapStyle) { refresh() }
        .onChange(of: model.settings.mapExaggeration) { refresh() }
        .onChange(of: model.packs.version) { refresh() }
        .preferredColorScheme(model.settings.mapStyle == .dusk ? .dark : .light)
    }

    /// The style's sea colour, so whatever lies beyond the loaded area reads as open water.
    private var backgroundColor: UIColor {
        let w = model.settings.mapStyle.style.water
        return UIColor(red: CGFloat(w.r), green: CGFloat(w.g), blue: CGFloat(w.b), alpha: 1)
    }

    private static let space = UIColor(red: 0.01, green: 0.012, blue: 0.03, alpha: 1)

    private func refresh() {
        let map = model.map, packs = model.packs.snapshot()
        if map.mode == .globe {
            map.buildGlobe(style: model.settings.mapStyle, packs: packs, packVersion: model.packs.version)
        } else {
            map.update(settings: model.settings, packs: packs, packVersion: model.packs.version)
        }
    }

    private func select(_ peak: PeakInfo) {
        let from = model.currentViewpoint ?? peak.coordinate
        model.selectedPeak = VisiblePeak(peak: peak, azimuth: Geo.bearing(from: from, to: peak.coordinate), altitude: 0,
                               distance: Geo.distance(from, peak.coordinate))
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let map = model.map
                map.stopCinematic()
                let dx = Float(value.translation.width), dy = Float(value.translation.height)
                if map.mode == .globe {
                    let start = globeDragStart ?? map.globe
                    if globeDragStart == nil { globeDragStart = start }
                    var moved = start.panned(dx: dx, dy: dy, height: Float(size.height))
                    moved.altitude = map.globe.altitude  // keep a simultaneous pinch
                    moved.heading = map.globe.heading
                    map.globe = moved.clamped()
                } else {
                    let start = dragStart ?? map.camera
                    if dragStart == nil { dragStart = start }
                    var moved = start.panned(dx: dx, dy: dy, width: Float(size.width), height: Float(size.height))
                    // Keep pinch and rotation of a simultaneous gesture.
                    moved.distance = map.camera.distance
                    moved.heading = map.camera.heading
                    map.camera = moved.clamped()
                }
            }
            .onEnded { _ in
                dragStart = nil
                globeDragStart = nil
                refresh()
            }
    }

    /// Pinch zooms; past the flat map's farthest distance it turns into the globe, and back below
    /// `MapModel.globeExitAltitude`.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let map = model.map
                map.stopCinematic()
                let m = max(0.05, value.magnification)
                let current = map.mode == .globe ? map.globe.altitude : map.camera.distance
                let base = pinchBase ?? (current, m)
                if pinchBase == nil { pinchBase = base }
                let wanted = base.value * Float(base.magnification / m)
                let packs = model.packs.snapshot(), version = model.packs.version
                if map.mode == .flat {
                    if wanted > MapCamera.distanceRange.upperBound {
                        map.enterGlobe(settings: model.settings, packs: packs, packVersion: version)
                        pinchBase = (map.globe.altitude, m)
                        return
                    }
                    var camera = map.camera
                    camera.distance = wanted
                    map.camera = camera.clamped()
                    map.cameraDidChange()
                } else {
                    if wanted < MapModel.globeExitAltitude {
                        map.leaveGlobe(settings: model.settings, packs: packs, packVersion: version)
                        pinchBase = (map.camera.distance, m)
                        return
                    }
                    var globe = map.globe
                    globe.altitude = wanted
                    map.globe = globe.clamped()
                }
            }
            .onEnded { _ in
                pinchBase = nil
                refresh()
            }
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                let map = model.map
                map.stopCinematic()
                let start = rotateStart ?? (map.mode == .globe ? map.globe.heading : map.camera.heading)
                if rotateStart == nil { rotateStart = start }
                let heading = start - Float(value.rotation.degrees)
                if map.mode == .globe {
                    map.globe.heading = heading
                    map.globe = map.globe.clamped()
                } else {
                    var camera = map.camera
                    camera.heading = heading
                    map.camera = camera.clamped()
                }
            }
            .onEnded { _ in rotateStart = nil }
    }

    // MARK: - Labels

    struct MapLabel {
        var peak: PeakInfo
        var name: String
        var detail: String
        var summit: CGPoint
        var frame: CGRect
        var mark: PeakMark?
        var isHighlighted: Bool
    }

    private func layoutLabels(size: CGSize) -> [MapLabel] {
        let map = model.map
        let layers = map.layers
        guard map.mode == .flat, !layers.isEmpty else { return [] }
        let entries = labelMemory.entries(for: layers, settings: model.settings)
        let camera = map.camera
        let eye = camera.eye
        let w = Float(size.width), h = Float(size.height)
        let topInset: Float = 140, bottomInset: Float = 110
        let marks = model.peakBook.marks
        let highlighted = map.highlightedPeakID
        var candidates: [LabelLayout.Candidate] = []
        var byID: [String: (MapLabelMemory.Entry, PeakMark?)] = [:]
        var visibilityChecks = 0
        for e in entries {
            let mark = marks[e.peak.id]
            let isHighlighted = e.peak.id == highlighted
            if map.filter == .peakBook && mark == nil && !isHighlighted { continue }
            guard let s = camera.project(e.point, width: w, height: h),
                  s.x > -20, s.x < w + 20, s.y > topInset, s.y < h - bottomInset else { continue }
            // Visibility tests cost a few hundred samples each: plenty for the labels that can fit.
            if mark == nil && !isHighlighted {
                if visibilityChecks >= 220 { continue }
                visibilityChecks += 1
            }
            let layer = layers[e.layer]
            guard layer.grid.isVisible(e.point, from: eye, frame: layer.frame) else { continue }
            // Peaks from the peak book come first (after a search result), so they keep their names.
            let priority = e.peak.importance + (mark == nil ? 0 : 2) + (isHighlighted ? 100 : 0)
            candidates.append(.init(id: e.peak.id, x: Double(s.x), y: Double(s.y),
                                    width: e.width + (mark == nil ? 0 : PanoramaView.LabelMemory.markWidth),
                                    priority: priority))
            byID[e.peak.id] = (e, mark)
        }
        let placed = LabelLayout.place(candidates, rowHeight: 26, rows: 3, gap: 12, minY: Double(topInset),
                                       maxX: Double(size.width) - 4, maxLabels: 28, previous: labelMemory.rows)
        labelMemory.rows = Dictionary(placed.map { ($0.id, $0.row) }, uniquingKeysWith: { first, _ in first })
        return placed.compactMap { p in
            guard let found = byID[p.id] else { return nil }
            let e = found.0
            return MapLabel(peak: e.peak, name: e.name, detail: e.detail, summit: CGPoint(x: p.summitX, y: p.summitY),
                            frame: CGRect(x: p.x, y: p.y + 2, width: p.width, height: p.height - 4),
                            mark: found.1, isHighlighted: p.id == highlighted)
        }
    }

    private func drawLabels(_ context: inout GraphicsContext, labels: [MapLabel]) {
        for label in labels {
            let color: Color = label.isHighlighted ? .orange : .white
            var leader = Path()
            leader.move(to: label.summit)
            leader.addLine(to: CGPoint(x: label.summit.x, y: label.frame.maxY))
            context.stroke(leader, with: .color(color.opacity(0.9)), lineWidth: label.isHighlighted ? 2 : 1)
            context.fill(Path(ellipseIn: CGRect(x: label.summit.x - 3, y: label.summit.y - 3, width: 6, height: 6)),
                         with: .color(color))
            let background = Path(roundedRect: label.frame, cornerRadius: label.frame.height / 2)
            context.fill(background, with: .color(label.isHighlighted ? .orange : .black.opacity(0.55)))
            var title = Text(label.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            if let mark = label.mark {
                let symbol = Text(Image(systemName: mark == .climbed ? "checkmark.circle.fill" : "star.fill"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mark == .climbed ? Color.green : Color.yellow)
                title = Text("\(symbol) \(title)")
            }
            let detail = Text(" " + label.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            context.draw(Text("\(title)\(detail)"), at: CGPoint(x: label.frame.minX + 9, y: label.frame.midY),
                         anchor: .leading)
        }
    }

    /// Climbed peaks (green, with a tick) and wishlist peaks (yellow star) from the peak book, wherever they are in
    /// view, on the flat map and on the globe: from the entries' own coordinates, so they show even where no
    /// peak data is loaded and when there is no room for their label.
    private func drawBookMarkers(_ context: inout GraphicsContext, size: CGSize) {
        let map = model.map
        let w = Float(size.width), h = Float(size.height)
        var seen = Set<String>()
        // Climbed first: a peak both climbed and on an old wishlist entry shows as climbed.
        let entries = model.peakBook.entries.filter { $0.entry.status == .summited }
            + model.peakBook.entries.filter { $0.entry.status == .planned }
        for stored in entries {
            let climbed = stored.entry.status == .summited
            for (peak, resolved) in zip(stored.entry.peaks, stored.resolvedIDs) {
                guard let coordinate = peak.coordinate else { continue }
                let key = resolved ?? peak.id ?? "\(coordinate.latitude),\(coordinate.longitude)"
                guard seen.insert(key).inserted else { continue }
                let screen: (x: Float, y: Float)?
                if map.mode == .globe {
                    screen = map.globe.project(Globe.point(coordinate), width: w, height: h)
                } else if let frame = map.frame {
                    var p = frame.point(coordinate, height: peak.elevation ?? 0)
                    if peak.elevation == nil { p.y = map.groundHeight(x: p.x, z: p.z) ?? 0 }
                    screen = map.camera.project(p, width: w, height: h).map { ($0.x, $0.y) }
                } else {
                    screen = nil
                }
                guard let s = screen, s.x > -20, s.x < w + 20, s.y > -20, s.y < h + 20 else { continue }
                drawMarker(&context, at: CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)), climbed: climbed,
                           small: map.mode == .globe)
            }
        }
    }

    private func drawMarker(_ context: inout GraphicsContext, at p: CGPoint, climbed: Bool, small: Bool) {
        let r: CGFloat = small ? 6 : 9
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        context.fill(circle, with: .color(.white))
        let inner = Path(ellipseIn: CGRect(x: p.x - r + 2, y: p.y - r + 2, width: 2 * r - 4, height: 2 * r - 4))
        context.fill(inner, with: .color(climbed ? .green : .yellow))
        if climbed {
            var tick = Path()
            tick.move(to: CGPoint(x: p.x - r * 0.42, y: p.y + r * 0.02))
            tick.addLine(to: CGPoint(x: p.x - r * 0.1, y: p.y + r * 0.34))
            tick.addLine(to: CGPoint(x: p.x + r * 0.45, y: p.y - r * 0.3))
            context.stroke(tick, with: .color(.white), style: StrokeStyle(lineWidth: small ? 1.5 : 2, lineCap: .round,
                                                                          lineJoin: .round))
        } else {
            var star = Path()
            for i in 0..<10 {
                let angle = Double(i) * .pi / 5 - .pi / 2
                let radius = (i % 2 == 0 ? 0.62 : 0.27) * r
                let q = CGPoint(x: p.x + CGFloat(cos(angle)) * radius, y: p.y + CGFloat(sin(angle)) * radius)
                if i == 0 { star.move(to: q) } else { star.addLine(to: q) }
            }
            star.closeSubpath()
            context.fill(star, with: .color(.white))
        }
    }

    /// Your position (GPS or the fixed viewpoint): a blue dot.
    private func drawPosition(_ context: inout GraphicsContext, size: CGSize) {
        guard let here = model.currentViewpoint else { return }
        let map = model.map
        let screen: (x: Float, y: Float)?
        if map.mode == .globe {
            screen = map.globe.project(Globe.point(here), width: Float(size.width), height: Float(size.height))
        } else {
            guard let frame = map.frame else { return }
            var p = frame.point(here, height: 0)
            p.y = map.groundHeight(x: p.x, z: p.z) ?? 0
            screen = map.camera.project(p, width: Float(size.width), height: Float(size.height)).map { ($0.x, $0.y) }
        }
        guard let s = screen else { return }
        let center = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)),
                     with: .color(.white))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                     with: .color(.blue))
    }
}

/// Label data per set of layers (names, widths, summit points), built once per layer change, units or
/// language; and the rows of the last frame so labels stay put while the map moves.
@MainActor
final class MapLabelMemory {
    struct Entry {
        var peak: PeakInfo
        var point: SIMD3<Float>
        var name: String
        var detail: String
        var width: Double
        /// Index of the layer to test visibility against.
        var layer: Int
    }

    var rows: [String: Int] = [:]
    private var key: ([UUID], UnitSystem, String?)?
    private var cached: [Entry] = []

    func entries(for layers: [MapTerrain], settings: AppSettings) -> [Entry] {
        let language = settings.peakLanguage
        let ids = layers.map(\.id)
        if let key, key.0 == ids, key.1 == settings.units, key.2 == language { return cached }
        var seen = Set<String>()
        var entries: [Entry] = []
        for (index, layer) in layers.enumerated() {
            for peak in layer.peaks.prefix(3000) where seen.insert(peak.id).inserted {
                let name = peak.displayName(language: language)
                let detail = peak.elevation.map { settings.elevation($0) } ?? ""
                entries.append(Entry(peak: peak, point: layer.point(of: peak), name: name, detail: detail,
                                     width: PanoramaView.LabelMemory.textWidth(name: name, detail: detail) + 10,
                                     layer: index))
            }
        }
        cached = entries.sorted { $0.peak.importance > $1.peak.importance }
        key = (ids, settings.units, language)
        return cached
    }
}

/// RealityKit scene without the camera image: the terrain model and a camera that follows `MapCamera`.
struct MapSceneView: UIViewRepresentable {
    let camera: SceneCamera
    /// Terrain layers (or the globe) to show.
    let entities: [ModelEntity]
    let background: UIColor

    @MainActor
    final class Coordinator {
        let anchor = AnchorEntity(world: .zero)
        let cameraEntity = PerspectiveCamera()
        var shown: [ModelEntity] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows,
                              .disablePersonOcclusion, .disableFaceMesh, .disableAREnvironmentLighting]
        view.isUserInteractionEnabled = false
        let c = context.coordinator
        c.cameraEntity.camera.near = 0.05
        c.cameraEntity.camera.far = 8000
        c.anchor.addChild(c.cameraEntity)
        view.scene.addAnchor(c.anchor)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let c = context.coordinator
        view.environment.background = .color(background)
        let wanted = entities
        if wanted.map(ObjectIdentifier.init) != c.shown.map(ObjectIdentifier.init) {
            for entity in c.shown where !wanted.contains(where: { $0 === entity }) { entity.removeFromParent() }
            for entity in wanted where entity.parent == nil { c.anchor.addChild(entity) }
            c.shown = wanted
        }
        c.cameraEntity.camera.fieldOfViewInDegrees = camera.fieldOfView
        c.cameraEntity.camera.near = camera.near
        c.cameraEntity.camera.far = camera.far
        c.cameraEntity.look(at: camera.target, from: camera.eye, upVector: camera.up, relativeTo: nil)
    }
}

// MARK: - Controls

/// Close on the left; 2D/3D, north and "my position" on the right; a note while an area is being built.
private struct MapTopControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var map = model.map
        HStack(alignment: .top) {
            // Settings (leftmost) and which peaks to show, top left.
            HStack(spacing: 10) {
                GlassCircleButton(title: "Settings", action: { model.showSettings = true }) {
                    Image(systemName: "gearshape").font(.title3)
                }
                Menu {
                    Picker("Show", selection: $map.filter) {
                        ForEach(MapModel.MapFilter.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: map.filter == .all ? "mountain.2" : "book.fill")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                        .glassEffect(map.filter == .all ? .regular : .regular.tint(.green), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(map.filter.title)
            }
            Spacer()
            if map.isBuilding {
                ProgressView()
                    .padding(12)
                    .glassEffect(.regular, in: .circle)
            } else if map.mode == .flat && map.regional == nil {
                Text("Waiting for your position…")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            } else if map.mode == .flat && map.regional?.hasData == false {
                Text("No offline data here")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            }
            Spacer()
            VStack(spacing: 10) {
                if map.mode == .flat {
                    GlassCircleButton(title: map.camera.pitch > 80 ? "3D view" : "Flat map", action: toggleTilt) {
                        Text(map.camera.pitch > 80 ? "3D" : "2D").font(.headline)
                    }
                }
                GlassCircleButton(title: "North up", action: northUp) {
                    Image(systemName: "location.north.line.fill")
                        .font(.title3)
                        .rotationEffect(.degrees(Double(-(map.mode == .globe ? map.globe.heading : map.camera.heading))))
                }
                GlassCircleButton(title: "My position", action: locate) {
                    Image(systemName: "location.fill").font(.title3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .overlay(alignment: .bottom) {
            if let missing = model.missingCountry, map.mode == .flat {
                Button { model.showDownloads = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(missing.name) isn't downloaded yet").font(.footnote.weight(.semibold))
                            Text("Download it to see its mountains in 3D.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(.rect(cornerRadius: 20))
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
                .buttonStyle(PressScaleStyle())
                .alignmentGuide(.bottom) { $0[.top] - 12 }
            }
        }
    }

    private func toggleTilt() {
        var camera = model.map.camera
        camera.pitch = camera.pitch > 80 ? 55 : 90
        model.map.camera = camera.clamped()
    }

    private func northUp() {
        if model.map.mode == .globe {
            model.map.globe.heading = 0
        } else {
            model.map.camera.heading = 0
        }
    }

    private func locate() {
        if let here = model.currentViewpoint { model.showOnMap(coordinate: here, peakID: nil) }
    }
}

/// Bottom bar, laid out like the peak finder's: peak book, switch to the peak finder, search.
private struct MapBottomControls: View {
    @Environment(AppModel.self) private var model
    @Binding var showsSearch: Bool

    var body: some View {
        ModeBar(onPeakBook: { model.showPeakBook = true }, onSearch: { showsSearch = true }) {
            GlassCircleButton(title: "Peak finder", glass: .regular.tint(.orange), action: { model.screen = .finder }) {
                Image(systemName: "binoculars.fill").font(.title3).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
