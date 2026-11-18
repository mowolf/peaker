import PeakerKit
import RealityKit
import SwiftUI
import UIKit

/// The 3D map: our own terrain from the elevation tiles, peaks labelled where they can be seen.
/// Drag to move, pinch to zoom, twist to turn; 2D/3D tilts between a flat map and a bird's-eye view.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var dragStart: MapCamera?
    @State private var pinchStart: MapCamera?
    @State private var rotateStart: MapCamera?
    @State private var selected: VisiblePeak?
    @State private var showsSearch = false
    @State private var labelMemory = MapLabelMemory()

    var body: some View {
        let map = model.map
        GeometryReader { geo in
            let size = geo.size
            let labels = layoutLabels(size: size)
            ZStack {
                MapSceneView(camera: map.camera, entities: [map.overviewEntity, map.showsDetail ? map.detailEntity : nil],
                             background: backgroundColor)
                    .allowsHitTesting(false)
                Canvas(rendersAsynchronously: false) { context, _ in
                    drawPosition(&context, size: size)
                    drawLabels(&context, labels: labels)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
                .simultaneousGesture(pinchGesture)
                .simultaneousGesture(rotateGesture)
                .onTapGesture(coordinateSpace: .local) { point in
                    if let hit = labels.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }) {
                        select(hit.peak)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { MapTopControls(onClose: { dismiss() }) }
        .overlay(alignment: .bottom) { MapBottomControls(showsSearch: $showsSearch) }
        .sheet(item: $selected) { peak in
            PeakDetailView(visible: peak)
                .presentationDetents([.height(420), .large])
        }
        .sheet(isPresented: $showsSearch) {
            PeakPickerView(title: "Find on map", allowsTypedName: false) { peak in
                guard let coordinate = peak.coordinate else { return }
                model.showOnMap(coordinate: coordinate, peakID: peak.id)
            }
        }
        .task { model.openMapIfNeeded() }
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

    private func refresh() {
        model.map.update(settings: model.settings, packs: model.packs.snapshot(), packVersion: model.packs.version)
    }

    private func select(_ peak: PeakInfo) {
        let from = model.currentViewpoint ?? peak.coordinate
        selected = VisiblePeak(peak: peak, azimuth: Geo.bearing(from: from, to: peak.coordinate), altitude: 0,
                               distance: Geo.distance(from, peak.coordinate))
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? model.map.camera
                if dragStart == nil { dragStart = start }
                var moved = start.panned(dx: Float(value.translation.width), dy: Float(value.translation.height),
                                         width: Float(size.width), height: Float(size.height))
                // Keep pinch and rotation of a simultaneous gesture.
                moved.distance = model.map.camera.distance
                moved.heading = model.map.camera.heading
                model.map.camera = moved
            }
            .onEnded { _ in
                dragStart = nil
                refresh()
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? model.map.camera
                if pinchStart == nil { pinchStart = start }
                var camera = model.map.camera
                camera.distance = start.distance / Float(max(0.1, value.magnification))
                model.map.camera = camera.clamped()
                model.map.cameraDidChange()
            }
            .onEnded { _ in
                pinchStart = nil
                refresh()
            }
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                let start = rotateStart ?? model.map.camera
                if rotateStart == nil { rotateStart = start }
                var camera = model.map.camera
                camera.heading = start.heading - Float(value.rotation.degrees)
                model.map.camera = camera.clamped()
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
        guard !layers.isEmpty else { return [] }
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
            let priority = e.peak.importance + (mark == nil ? 0 : 0.5) + (isHighlighted ? 100 : 0)
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

    /// Your position (GPS or the fixed viewpoint): a blue dot.
    private func drawPosition(_ context: inout GraphicsContext, size: CGSize) {
        guard let frame = model.map.frame, let here = model.currentViewpoint else { return }
        var p = frame.point(here, height: 0)
        p.y = model.map.groundHeight(x: p.x, z: p.z) ?? 0
        guard let s = model.map.camera.project(p, width: Float(size.width), height: Float(size.height)) else { return }
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
    let camera: MapCamera
    /// Terrain layers to show (nil entries are skipped).
    let entities: [ModelEntity?]
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
        let wanted = entities.compactMap { $0 }
        if wanted.map(ObjectIdentifier.init) != c.shown.map(ObjectIdentifier.init) {
            for entity in c.shown where !wanted.contains(where: { $0 === entity }) { entity.removeFromParent() }
            for entity in wanted where entity.parent == nil { c.anchor.addChild(entity) }
            c.shown = wanted
        }
        c.cameraEntity.camera.fieldOfViewInDegrees = camera.fieldOfView
        c.cameraEntity.look(at: camera.target, from: camera.eye, upVector: camera.up, relativeTo: nil)
    }
}

// MARK: - Controls

/// Close on the left; 2D/3D, north and "my position" on the right; a note while an area is being built.
private struct MapTopControls: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    var body: some View {
        let map = model.map
        HStack(alignment: .top) {
            GlassCircleButton(title: "Close map", action: onClose) {
                Image(systemName: "xmark").font(.title3.weight(.semibold))
            }
            Spacer()
            if map.isBuilding {
                ProgressView()
                    .padding(12)
                    .glassEffect(.regular, in: .circle)
            } else if map.overview == nil {
                Text("Waiting for your position…")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            } else if map.overview?.hasData == false {
                Text("No offline data here")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            }
            Spacer()
            VStack(spacing: 10) {
                GlassCircleButton(title: map.camera.pitch > 80 ? "3D view" : "Flat map", action: toggleTilt) {
                    Text(map.camera.pitch > 80 ? "3D" : "2D").font(.headline)
                }
                GlassCircleButton(title: "North up", action: northUp) {
                    Image(systemName: "location.north.line.fill")
                        .font(.title3)
                        .rotationEffect(.degrees(Double(-map.camera.heading)))
                }
                GlassCircleButton(title: "My position", action: locate) {
                    Image(systemName: "location.fill").font(.title3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func toggleTilt() {
        withAnimation(.smooth) { model.map.camera.pitch = model.map.camera.pitch > 80 ? 55 : 90 }
    }

    private func northUp() {
        withAnimation(.smooth) { model.map.camera.heading = 0 }
    }

    private func locate() {
        if let here = model.currentViewpoint { model.showOnMap(coordinate: here, peakID: nil) }
    }
}

/// Search and the peak book filter.
private struct MapBottomControls: View {
    @Environment(AppModel.self) private var model
    @Binding var showsSearch: Bool

    var body: some View {
        @Bindable var map = model.map
        HStack(spacing: 12) {
            Menu {
                Picker("Show", selection: $map.filter) {
                    ForEach(MapModel.MapFilter.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(map.filter.title, systemImage: map.filter == .all ? "mountain.2" : "book")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .contentShape(Capsule())
                    .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
            Spacer()
            GlassCircleButton(title: "Find a peak", action: { showsSearch = true }) {
                Image(systemName: "magnifyingglass").font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
