import PeakerKit
import SwiftUI
import UIKit

/// Draws the ridge lines and peak labels for the current camera pose, and handles touch navigation.
struct PanoramaView: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: (yaw: Double, pitch: Double, heading: Double, pitchOffset: Double)?
    @State private var zoomStart: Double?
    /// Label rows of the last frame and per-result label data (not observed: no redraws).
    @State private var labelMemory = LabelMemory()

    /// A visible peak's label, prepared once per horizon result (or units/language change), not every frame.
    struct LabelEntry {
        var visible: VisiblePeak
        var name: String
        var detail: String
        /// Label width for `LabelLayout` (text plus padding).
        var width: Double
        /// Priority before the per-frame stickiness bonus: important and close peaks first.
        var priority: Double
        /// Climbed or on the wishlist (peak book): a symbol before the name.
        var mark: PeakMark?
    }

    @MainActor
    final class LabelMemory {
        /// Rows used in the last frame, so labels stay put while the view moves.
        var rows: [String: Int] = [:]

        struct EntriesKey: Equatable {
            var result: Int
            var units: UnitSystem
            var language: String?
            var marks: Int
        }
        private var entriesKey: EntriesKey?
        private var cachedEntries: [LabelEntry] = []
        /// Peak ID → index in `cachedEntries` (to find the search target without a scan every frame).
        private(set) var entryIndex: [String: Int] = [:]

        /// Label data for the current result, most important peak first.
        func entries(for key: EntriesKey, make: () -> [LabelEntry]) -> [LabelEntry] {
            if key != entriesKey {
                cachedEntries = make().sorted { $0.visible.peak.importance > $1.visible.peak.importance }
                entryIndex = Dictionary(cachedEntries.enumerated().map { ($1.visible.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
                entriesKey = key
            }
            return cachedEntries
        }

        private static let nameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        private static let detailFont = UIFont.systemFont(ofSize: 11, weight: .regular)

        /// Width of the climbed/wishlist symbol and its space, as drawn in `drawLabels`.
        static let markWidth = 17.0

        /// Width of a label's text as drawn in `drawLabels` (name + " " + detail).
        /// Character counts are far off for non-Latin scripts and wide letters.
        static func textWidth(name: String, detail: String) -> Double {
            let nameWidth = (name as NSString).size(withAttributes: [.font: nameFont]).width
            let detailWidth = ((" " + detail) as NSString).size(withAttributes: [.font: detailFont]).width
            return Double((nameWidth + detailWidth).rounded(.up))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pose = model.cameraPose(size: size)
            let labels = layoutLabels(pose: pose, size: size)
            Canvas(rendersAsynchronously: false) { context, size in
                if let horizon = model.horizonStore.horizon {
                    if let sunDay = model.horizonStore.sunDay {
                        drawSun(&context, day: sunDay, horizon: horizon, pose: pose, size: size)
                    }
                    if !cameraVisible {
                        drawTerrain(&context, horizon: horizon, pose: pose, size: size)
                    }
                    drawRidges(&context, horizon: horizon, pose: pose, size: size)
                }
                drawLabels(&context, labels: labels)
                if let target = model.searchTarget {
                    drawSearchTarget(&context, target: target, pose: pose, size: size)
                }
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

    /// Camera frames are actually on screen (not just requested and still starting).
    private var cameraVisible: Bool { model.showsCamera && model.camera.isRunning }

    // MARK: - Gestures

    // Gesture handlers are plain methods: big multi-statement closures inside gesture chains are slow
    // for the type checker.
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in handleDrag(translation: value.translation, size: size) }
            .onEnded { _ in dragStart = nil }
    }

    /// Drag always works: it turns the view by hand. While following the device it hands control
    /// back to the finger (like Apple Maps); with the camera shown it aligns the lines with the image instead.
    private func handleDrag(translation: CGSize, size: CGSize) {
        if dragStart == nil, model.isFollowingDevice, !model.showsCamera {
            model.setFollowing(false)  // keeps the current direction
        }
        let pose = model.cameraPose(size: size)
        let halfPixelAngle: Double = atan(0.5 / pose.focalLength)
        let degreesPerPoint: Double = 2.0 * halfPixelAngle * 180.0 / Double.pi
        if dragStart == nil {
            dragStart = (model.touchYaw, model.touchPitch, model.headingOffset, model.pitchOffset)
        }
        guard let start = dragStart else { return }
        let dx: Double = Double(translation.width) * degreesPerPoint
        let dy: Double = Double(translation.height) * degreesPerPoint
        if model.showsCamera {
            // Move the overlay with the finger: dragging right moves the lines right.
            model.headingOffset = start.heading - dx
            model.pitchOffset = start.pitchOffset + dy
        } else {
            model.touchYaw = Geo.normalizedDegrees(start.yaw - dx)
            let pitch: Double = start.pitch + dy
            model.touchPitch = Swift.max(-45.0, Swift.min(45.0, pitch))
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in handleZoom(magnification: Double(value.magnification)) }
            .onEnded { _ in zoomStart = nil }
    }

    /// Pinch always zooms the one shared zoom level (camera zoom follows it while the camera is shown).
    private func handleZoom(magnification: Double) {
        guard magnification > 0 else { return }
        if zoomStart == nil { zoomStart = model.fieldOfView }
        let start: Double = zoomStart ?? 65
        model.hasZoomed = true
        model.setFieldOfView(start / magnification)
    }

    // MARK: - Drawing

    /// Fill below the skyline so the rendered view reads as mountains against the sky.
    private func drawTerrain(_ context: inout GraphicsContext, horizon: HorizonResult, pose: CameraPose, size: CGSize) {
        var path = Path()
        var started = false
        let step: CGFloat = 3
        // Columns well beyond both screen edges: while the phone is rolled (e.g. swung quickly sideways) the
        // skyline points of the edge columns land inside the screen, and a fill ending there left a light
        // wedge of sky at the side.
        let overscan: CGFloat = Swift.max(size.width, size.height) / 2
        var x: CGFloat = -overscan
        // Far below the screen, so the fill also covers the corners while the phone is rolled.
        let bottom: CGFloat = 2 * Swift.max(size.width, size.height)
        var lastX: CGFloat = 0
        while x <= size.width + overscan {
            let az = pose.direction(x: Double(x), y: pose.centerY).azimuthAltitude.azimuth
            let alt = horizon.skylineAltitude(azimuth: az)
            if let p = pose.project(azimuth: az, altitude: alt) {
                // Use the projected point (not the column's x): with roll they differ.
                let pt = CGPoint(x: p.x, y: p.y)
                if started {
                    path.addLine(to: pt)
                } else {
                    path.move(to: CGPoint(x: pt.x, y: bottom))
                    path.addLine(to: pt)
                    started = true
                }
                lastX = pt.x
            }
            x += step
        }
        guard started else { return }
        path.addLine(to: CGPoint(x: lastX, y: bottom))
        path.closeSubpath()
        context.fill(path, with: .linearGradient(
            Gradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.28), Color(red: 0.05, green: 0.06, blue: 0.09)]),
            startPoint: CGPoint(x: 0, y: size.height * 0.35), endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func drawRidges(_ context: inout GraphicsContext, horizon: HorizonResult, pose: CameraPose, size: CGSize) {
        let viewAz = pose.azimuth
        let maxOff = pose.maxVisibleAngle(width: size.width, height: size.height) + 2
        let camera = cameraVisible
        let gapLimit = horizon.settings.azimuthStep * 2.5

        // Ridges come far-first, so near ones draw on top.
        for ridge in horizon.ridges {
            // Skip lines entirely outside the view without touching their points.
            let range = ridge.azimuthRange
            if abs(Geo.angleDifference(range.center, viewAz)) > range.halfWidth + maxOff { continue }
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

    /// Search result: white label with dark text, white ring and edge marker.
    private static let targetColor = Color.white
    private static let targetText = Color(red: 0.08, green: 0.10, blue: 0.16)

    private func drawLabels(_ context: inout GraphicsContext, labels: [PlacedLabel]) {
        for label in labels {
            let summit = label.summit
            var leader = Path()
            leader.move(to: summit)
            leader.addLine(to: CGPoint(x: summit.x, y: label.frame.maxY))
            context.stroke(leader, with: .color(label.isTarget ? Self.targetColor : .white.opacity(0.8)),
                           lineWidth: label.isTarget ? 2 : 1)
            context.fill(Path(ellipseIn: CGRect(x: summit.x - 2.5, y: summit.y - 2.5, width: 5, height: 5)),
                         with: .color(.white))

            let background = Path(roundedRect: label.frame, cornerRadius: label.frame.height / 2)
            if label.isTarget {
                context.fill(background, with: .color(Self.targetColor))
            } else {
                context.fill(background, with: .color(.black.opacity(0.38)))
                context.stroke(background, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            }

            let textColor = label.isTarget ? Self.targetText : .white
            var title = Text(label.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(textColor)
            if let mark = label.mark {
                let symbol = Text(Image(systemName: mark == .climbed ? "checkmark.circle.fill" : "star.fill"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mark == .climbed ? Color.green : Color.yellow)
                title = Text("\(symbol) \(title)")
            }
            let detail = Text(" " + label.detail).font(.system(size: 11, weight: .regular))
                .foregroundStyle(textColor.opacity(label.isTarget ? 0.75 : 0.7))
            context.draw(Text("\(title)\(detail)"), at: CGPoint(x: label.frame.minX + 9, y: label.frame.midY),
                         anchor: .leading)
        }
    }

    /// The search target: a ring around its summit when on screen, else a marker at the screen edge pointing
    /// the way to turn.
    private func drawSearchTarget(_ context: inout GraphicsContext, target: VisiblePeak, pose: CameraPose, size: CGSize) {
        let width = Double(size.width), height = Double(size.height)
        // Clear of the top bar (compass, location) and the bottom bar (chip, buttons).
        let landscape = width > height
        if let marker = PeakSearch.edgeMarker(azimuth: target.azimuth, altitude: target.altitude, pose: pose,
                                              width: width, height: height, inset: 34,
                                              topInset: landscape ? 110 : 160, bottomInset: landscape ? 120 : 160) {
            let center = CGPoint(x: marker.x, y: marker.y)
            let radius: CGFloat = 20
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(Self.targetColor))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(.black.opacity(0.25)), lineWidth: 1)
            // Arrow pointing towards the peak.
            var arrow = context
            arrow.translateBy(x: center.x, y: center.y)
            arrow.rotate(by: .radians(marker.angle))
            var head = Path()
            head.move(to: CGPoint(x: 9, y: 0))
            head.addLine(to: CGPoint(x: -5, y: -8))
            head.addLine(to: CGPoint(x: -1, y: 0))
            head.addLine(to: CGPoint(x: -5, y: 8))
            head.closeSubpath()
            arrow.fill(head, with: .color(Self.targetText))
            return
        }
        guard let s = pose.project(azimuth: target.azimuth, altitude: target.altitude) else { return }
        let center = CGPoint(x: s.x, y: s.y)
        for (radius, opacity) in [(CGFloat(11), 1.0), (CGFloat(17), 0.45)] {
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(Self.targetColor.opacity(opacity)), lineWidth: 2.5)
        }
    }

    // MARK: - Sun

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")  // 24 h or 12 h as the user prefers
        return f
    }()

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()

    /// Sun path (only where it's above the terrain), hour marks, the sun now, and where it rises and
    /// sets behind the mountains with times.
    private func drawSun(_ context: inout GraphicsContext, day: Sun.Day, horizon: HorizonResult, pose: CameraPose,
                         size: CGSize) {
        let sunColor = Color(red: 1.0, green: 0.78, blue: 0.25)
        var path = Path()
        var penDown = false
        var calendar = Calendar.current
        calendar.timeZone = .current
        for sample in day.samples {
            let p = sample.position
            let aboveTerrain: Bool = p.altitude + Sun.semiDiameter > horizon.skylineAltitude(azimuth: p.azimuth)
            guard aboveTerrain, let s = pose.project(azimuth: p.azimuth, altitude: p.altitude) else {
                penDown = false
                continue
            }
            let pt = CGPoint(x: s.x, y: s.y)
            if penDown { path.addLine(to: pt) } else { path.move(to: pt) }
            penDown = true
            // Hour marks
            let minute = calendar.component(.minute, from: sample.date)
            if minute == 0 {
                context.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)),
                             with: .color(sunColor.opacity(0.9)))
                let hour = Text(Self.hourFormatter.string(from: sample.date))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(sunColor)
                context.draw(hour, at: CGPoint(x: pt.x, y: pt.y - 10))
            }
        }
        // Solid: a dash pattern starts wherever the visible part of the path starts, so the dashes seemed to
        // crawl along the line whenever the view moved.
        context.stroke(path, with: .color(sunColor.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        // Sun now: a glowing disc, faded when it is behind the mountains or below the horizon.
        let now = Sun.position(at: Date(), coordinate: horizon.observer)
        if let s = pose.project(azimuth: now.azimuth, altitude: now.altitude) {
            let visible: Bool = now.altitude + Sun.semiDiameter > horizon.skylineAltitude(azimuth: now.azimuth)
            let discRadius = CGFloat(Swift.max(9, pose.focalLength * tan(Sun.semiDiameter * Double.pi / 180)))
            let center = CGPoint(x: s.x, y: s.y)
            let glow = Path(ellipseIn: CGRect(x: center.x - discRadius * 3, y: center.y - discRadius * 3,
                                              width: discRadius * 6, height: discRadius * 6))
            context.fill(glow, with: .radialGradient(Gradient(colors: [sunColor.opacity(visible ? 0.55 : 0.15), .clear]),
                                                     center: center, startRadius: discRadius * 0.5,
                                                     endRadius: discRadius * 3))
            let disc = Path(ellipseIn: CGRect(x: center.x - discRadius, y: center.y - discRadius,
                                              width: discRadius * 2, height: discRadius * 2))
            if visible {
                context.fill(disc, with: .color(Color(red: 1.0, green: 0.92, blue: 0.6)))
            } else {
                context.stroke(disc, with: .color(sunColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }

        // Where the sun really rises / sets over the terrain, with the time.
        for event in day.terrainEvents {
            guard let s = pose.project(azimuth: event.position.azimuth, altitude: event.position.altitude) else {
                continue
            }
            let pt = CGPoint(x: s.x, y: s.y)
            context.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(sunColor))
            let icon = event.kind == .rise ? "sunrise.fill" : "sunset.fill"
            let label = Text("\(Image(systemName: icon)) \(Self.timeFormatter.string(from: event.date))")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
            let resolved = context.resolve(label)
            let textSize = resolved.measure(in: CGSize(width: 200, height: 40))
            let box = CGRect(x: pt.x - textSize.width / 2 - 7, y: pt.y - textSize.height - 16,
                             width: textSize.width + 14, height: textSize.height + 6)
            context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(sunColor))
            context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
        }
    }

    // MARK: - Labels

    struct PlacedLabel {
        var peak: VisiblePeak
        var name: String
        var detail: String
        var summit: CGPoint
        var frame: CGRect
        var isTarget = false
        var mark: PeakMark?
    }

    private func layoutLabels(pose: CameraPose, size: CGSize) -> [PlacedLabel] {
        let density = model.settings.labelDensity
        // Zoom relative to the default framing (camera's native angle). Zoomed in, peaks spread out,
        // so show more and smaller peaks; zoomed out, only the most important ones.
        let longSide: Double = Double(Swift.max(size.width, size.height))
        let fieldOfView: Double = 2 * atan(longSide / 2 / pose.focalLength) * 180 / Double.pi
        let zoom: Double = Swift.max(0.4, Swift.min(4.0, model.camera.fieldOfView / fieldOfView))
        let maxLabels: Int = Int((Double(density.maxLabels) * Swift.min(2.5, zoom)).rounded())
        let minImportance: Double = density.minImportance / zoom
        // Keep labels below the top bar (shorter in landscape); summits under it couldn't get a label anyway.
        let topInset: Double = size.width > size.height ? 100 : 150
        let entries = labelEntries()
        var candidates: [LabelLayout.Candidate] = []
        var entryIndex: [String: Int] = [:]
        let viewAz = pose.azimuth
        let maxOff = pose.maxVisibleAngle(width: size.width, height: size.height)
        let screenWidth = Double(size.width), screenHeight = Double(size.height)
        // The search target always gets a label, placed first, whatever its importance.
        let targetID = model.searchTarget?.id
        if let targetID, let i = labelMemory.entryIndex[targetID] {
            let e = entries[i]
            if let s = pose.project(azimuth: e.visible.azimuth, altitude: e.visible.altitude),
               s.x > -20, s.x < screenWidth + 20, s.y > topInset, s.y < screenHeight {
                entryIndex[targetID] = i
                candidates.append(.init(id: targetID, x: s.x, y: s.y, width: e.width, priority: 1_000))
            }
        }
        for (i, e) in entries.enumerated() {
            let v = e.visible
            if v.peak.importance < minImportance { break }  // sorted by importance: the rest are smaller
            guard v.id != targetID, abs(Geo.angleDifference(v.azimuth, viewAz)) <= maxOff,
                  let s = pose.project(azimuth: v.azimuth, altitude: v.altitude),
                  s.x > -20, s.x < screenWidth + 20, s.y > topInset, s.y < screenHeight else { continue }
            entryIndex[v.id] = i
            candidates.append(.init(id: v.id, x: s.x, y: s.y, width: e.width, priority: e.priority))
        }
        let placed = LabelLayout.place(candidates, rowHeight: 26, rows: 5, gap: 18, minY: topInset,
                                       maxX: Double(size.width) - 4, maxLabels: maxLabels,
                                       previous: labelMemory.rows)
        labelMemory.rows = Dictionary(placed.map { ($0.id, $0.row) }, uniquingKeysWith: { first, _ in first })
        return placed.compactMap { p in
            guard let i = entryIndex[p.id] else { return nil }
            let e = entries[i]
            return PlacedLabel(peak: e.visible, name: e.name, detail: e.detail, summit: CGPoint(x: p.summitX, y: p.summitY),
                               frame: CGRect(x: p.x, y: p.y + 2, width: p.width, height: p.height - 4),
                               isTarget: p.id == targetID, mark: e.mark)
        }
    }

    /// Names, detail texts, measured widths and priorities of the visible peaks: built once per result.
    private func labelEntries() -> [LabelEntry] {
        let settings = model.settings
        let store = model.horizonStore
        let book = model.peakBook
        let key = LabelMemory.EntriesKey(result: store.resultID, units: settings.units, language: settings.peakLanguage,
                                         marks: book.marksVersion)
        return labelMemory.entries(for: key) {
            let marks = book.marks
            return store.visiblePeaks.map { v in
                let name = v.peak.displayName(language: key.language)
                var detailParts: [String] = []
                if let elevation = v.peak.elevation { detailParts.append(settings.elevation(elevation)) }
                detailParts.append(settings.distance(v.distance))
                let detail = detailParts.joined(separator: " · ")
                // The text starts 9 pt into the frame, which is `width + 8` wide (LabelLayout).
                let mark = marks[v.id]
                let width = LabelMemory.textWidth(name: name, detail: detail) + 10
                    + (mark == nil ? 0 : LabelMemory.markWidth)
                let closeness = 1 - min(1, v.distance / 100_000)
                return LabelEntry(visible: v, name: name, detail: detail, width: width,
                                  priority: v.peak.importance + 0.15 * closeness, mark: mark)
            }
        }
    }
}
