import PeakerKit
import SwiftUI

/// Draws the ridge lines and peak labels for the current camera pose, and handles touch navigation.
struct PanoramaView: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: (yaw: Double, pitch: Double, heading: Double, pitchOffset: Double)?
    @State private var zoomStart: Double?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pose = model.cameraPose(size: size)
            let labels = layoutLabels(pose: pose, size: size)
            Canvas(rendersAsynchronously: false) { context, size in
                if let horizon = model.horizon {
                    if model.mode == .touch {
                        drawTerrain(&context, horizon: horizon, pose: pose, size: size)
                    }
                    drawRidges(&context, horizon: horizon, pose: pose, size: size)
                }
                drawLabels(&context, labels: labels)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .simultaneousGesture(zoomGesture)
            .onTapGesture(coordinateSpace: .local) { point in
                if let hit = labels.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }) {
                    model.selectedPeak = hit.peak
                }
            }
        }
    }

    // MARK: - Gestures

    // Gesture handlers are plain methods: big multi-statement closures inside gesture chains are slow
    // for the type checker.
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in handleDrag(translation: value.translation, size: size) }
            .onEnded { _ in dragStart = nil }
    }

    private func handleDrag(translation: CGSize, size: CGSize) {
        let pose = model.cameraPose(size: size)
        let halfPixelAngle: Double = atan(0.5 / pose.focalLength)
        let degreesPerPoint: Double = 2.0 * halfPixelAngle * 180.0 / Double.pi
        if dragStart == nil {
            dragStart = (model.touchYaw, model.touchPitch, model.headingOffset, model.pitchOffset)
        }
        guard let start = dragStart else { return }
        let dx: Double = Double(translation.width) * degreesPerPoint
        let dy: Double = Double(translation.height) * degreesPerPoint
        switch model.mode {
        case .touch:
            model.touchYaw = Geo.normalizedDegrees(start.yaw - dx)
            let pitch: Double = start.pitch + dy
            model.touchPitch = Swift.max(-45.0, Swift.min(45.0, pitch))
        case .camera:
            guard model.isCalibrating else { return }
            // Move the overlay with the finger: dragging right turns the overlay right.
            model.headingOffset = start.heading - dx
            model.pitchOffset = start.pitchOffset + dy
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in handleZoom(magnification: Double(value.magnification)) }
            .onEnded { _ in zoomStart = nil }
    }

    private func handleZoom(magnification: Double) {
        guard model.mode == .touch, magnification > 0 else { return }
        if zoomStart == nil { zoomStart = model.touchFieldOfView }
        let start: Double = zoomStart ?? 55
        model.touchFieldOfView = Swift.max(8.0, Swift.min(110.0, start / magnification))
    }

    // MARK: - Drawing

    /// Fill below the skyline so the rendered view reads as mountains against the sky.
    private func drawTerrain(_ context: inout GraphicsContext, horizon: HorizonResult, pose: CameraPose, size: CGSize) {
        var path = Path()
        var started = false
        let step: CGFloat = 3
        var x: CGFloat = 0
        while x <= size.width + step {
            let az = pose.direction(x: Double(x), y: pose.centerY).azimuthAltitude.azimuth
            let alt = horizon.skylineAltitude(azimuth: az)
            if let p = pose.project(azimuth: az, altitude: alt) {
                let pt = CGPoint(x: x, y: p.y)
                if started { path.addLine(to: pt) } else { path.move(to: CGPoint(x: x, y: size.height)); path.addLine(to: pt); started = true }
            }
            x += step
        }
        guard started else { return }
        path.addLine(to: CGPoint(x: size.width + step, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .linearGradient(
            Gradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.28), Color(red: 0.05, green: 0.06, blue: 0.09)]),
            startPoint: CGPoint(x: 0, y: size.height * 0.35), endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func drawRidges(_ context: inout GraphicsContext, horizon: HorizonResult, pose: CameraPose, size: CGSize) {
        let viewAz = pose.azimuth
        let maxOff = pose.maxVisibleAngle(width: size.width, height: size.height) + 2
        let camera = model.mode == .camera
        let gapLimit = horizon.settings.azimuthStep * 2.5

        // Far ridges first so near ones draw on top.
        for ridge in horizon.ridges.sorted(by: { $0.meanDistance > $1.meanDistance }) {
            var path = Path()
            var penDown = false
            var previousAz: Double?
            for p in ridge.points {
                guard abs(Geo.angleDifference(p.azimuth, viewAz)) <= maxOff,
                      let s = pose.project(azimuth: p.azimuth, altitude: p.altitude) else {
                    penDown = false
                    previousAz = nil
                    continue
                }
                let pt = CGPoint(x: s.x, y: s.y)
                if penDown, let previousAz, abs(Geo.angleDifference(p.azimuth, previousAz)) <= gapLimit {
                    path.addLine(to: pt)
                } else {
                    path.move(to: pt)
                }
                penDown = true
                previousAz = p.azimuth
            }
            guard !path.isEmpty else { continue }
            // Aerial perspective: distant ridges are thinner and fainter.
            let t: Double = min(1, ridge.meanDistance / 120_000)
            let baseWidth: Double = ridge.isSkyline ? 2.6 : 2.0
            let width = CGFloat(baseWidth - 1.3 * t)
            let baseOpacity: Double = ridge.isSkyline ? 1.0 : 0.9
            let opacity: Double = baseOpacity - 0.55 * t
            let red: Double = 0.75 + 0.2 * t
            let green: Double = 0.82 + 0.13 * t
            let color: Color = camera ? .white : Color(red: red, green: green, blue: 0.95)
            if camera {
                let shadow = StrokeStyle(lineWidth: width + 1.5, lineCap: .round, lineJoin: .round)
                context.stroke(path, with: .color(.black.opacity(0.35 * opacity)), style: shadow)
            }
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            context.stroke(path, with: .color(color.opacity(opacity)), style: style)
        }
    }

    private func drawLabels(_ context: inout GraphicsContext, labels: [PlacedLabel]) {
        for label in labels {
            let summit = label.summit
            var leader = Path()
            leader.move(to: summit)
            leader.addLine(to: CGPoint(x: summit.x, y: label.frame.maxY))
            context.stroke(leader, with: .color(.white.opacity(0.8)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: summit.x - 2.5, y: summit.y - 2.5, width: 5, height: 5)),
                         with: .color(.white))

            let background = Path(roundedRect: label.frame, cornerRadius: label.frame.height / 2)
            context.fill(background, with: .color(.black.opacity(0.38)))
            context.stroke(background, with: .color(.white.opacity(0.18)), lineWidth: 0.5)

            let title = Text(label.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            let detail = Text(" " + label.detail).font(.system(size: 11, weight: .regular)).foregroundStyle(.white.opacity(0.7))
            context.draw(Text("\(title)\(detail)"), at: CGPoint(x: label.frame.minX + 9, y: label.frame.midY),
                         anchor: .leading)
        }
    }

    // MARK: - Labels

    struct PlacedLabel {
        var peak: VisiblePeak
        var name: String
        var detail: String
        var summit: CGPoint
        var frame: CGRect
    }

    private func layoutLabels(pose: CameraPose, size: CGSize) -> [PlacedLabel] {
        let density = model.settings.labelDensity
        let language = Locale.current.language.languageCode?.identifier
        var byID: [String: (VisiblePeak, String, String)] = [:]
        var candidates: [LabelLayout.Candidate] = []
        let viewAz = pose.azimuth
        let maxOff = pose.maxVisibleAngle(width: size.width, height: size.height)
        for v in model.visiblePeaks where v.peak.importance >= density.minImportance {
            let screenWidth = Double(size.width), screenHeight = Double(size.height)
            guard abs(Geo.angleDifference(v.azimuth, viewAz)) <= maxOff,
                  let s = pose.project(azimuth: v.azimuth, altitude: v.altitude),
                  s.x > -20, s.x < screenWidth + 20, s.y > 80, s.y < screenHeight else { continue }
            let name = v.peak.displayName(language: language)
            var detailParts: [String] = []
            if let elevation = v.peak.elevation {
                detailParts.append(model.settings.elevation(elevation))
            }
            detailParts.append(model.settings.distance(v.distance))
            let detail: String = detailParts.joined(separator: " · ")
            // Rough text width (13 pt semibold + 11 pt detail) — good enough for collision checks.
            let nameWidth: Double = Double(name.count) * 7.4
            let detailWidth: Double = Double(detail.count) * 5.6
            let width: Double = nameWidth + detailWidth + 22
            byID[v.id] = (v, name, detail)
            // Prefer important and close peaks.
            let closeness: Double = 1 - min(1, v.distance / 100_000)
            let priority: Double = v.peak.importance + 0.15 * closeness
            candidates.append(.init(id: v.id, x: s.x, y: s.y, width: width, priority: priority))
        }
        let placed = LabelLayout.place(candidates, rowHeight: 26, rows: 5, gap: 18, minY: 150,
                                       maxLabels: density.maxLabels)
        return placed.compactMap { p in
            guard let entry = byID[p.id] else { return nil }
            return PlacedLabel(peak: entry.0, name: entry.1, detail: entry.2, summit: CGPoint(x: p.summitX, y: p.summitY),
                               frame: CGRect(x: p.x, y: p.y + 2, width: p.width, height: p.height - 4))
        }
    }
}
