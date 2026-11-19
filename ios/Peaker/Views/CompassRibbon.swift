import PeakerKit
import SwiftUI

/// Heading tape: degrees and cardinal directions around the current view direction.
struct CompassRibbon: View {
    @Environment(AppModel.self) private var model
    /// The direction to show; nil: the peak finder's view direction.
    var heading: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let heading = self.heading ?? model.heading
            Canvas { context, size in
                let width = Double(size.width), height = Double(size.height)
                let pointsPerDegree: Double = width / 90  // 90° visible across the ribbon
                let mid: Double = width / 2
                let first = Int((heading - 45).rounded(.down))
                for deg in first...(first + 91) {
                    let offset: Double = Double(deg) - heading
                    let x: Double = mid + offset * pointsPerDegree
                    let d = ((deg % 360) + 360) % 360
                    if d % 5 != 0 { continue }
                    let major = d % 45 == 0
                    // The current heading is written in the middle: no other labels next to it.
                    let nearCentre = abs(offset) < 11
                    let tickLength: Double = major ? 12 : 7
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: height - tickLength))
                    tick.addLine(to: CGPoint(x: x, y: height - 3))
                    context.stroke(tick, with: .color(.white.opacity(major ? 0.9 : 0.4)), lineWidth: major ? 1.5 : 1)
                    if nearCentre {
                        continue
                    } else if major {
                        let label = Self.cardinal(d)
                        context.draw(Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(.white),
                                     at: CGPoint(x: x, y: height / 2 - 4))
                    } else if d % 15 == 0 {
                        context.draw(Text("\(d)").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.6)),
                                     at: CGPoint(x: x, y: height / 2 - 4))
                    }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay {
                // The current heading, in line with the other labels, with a tick below it.
                let value = ((Int(heading.rounded()) % 360) + 360) % 360
                Canvas { context, size in
                    let mid = Double(size.width) / 2, height = Double(size.height)
                    context.draw(Text("\(value)° \(Self.cardinal(value))")
                        .font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white), at: CGPoint(x: mid, y: height / 2 - 4))
                    var tick = Path()
                    tick.move(to: CGPoint(x: mid, y: height - 14))
                    tick.addLine(to: CGPoint(x: mid, y: height - 2))
                    context.stroke(tick, with: .color(.white), lineWidth: 2.5)
                }
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("Heading")
        .accessibilityValue("\(Int((heading ?? model.heading).rounded())) degrees")
    }

    static func cardinal(_ degrees: Int) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][((degrees + 22) / 45) % 8]
    }
}

/// The bar at the top of both modes: where you are (tap to update the position) above the compass ribbon.
struct HeadingBar: View {
    @Environment(AppModel.self) private var model
    /// The direction to show; nil: the peak finder's view direction.
    var heading: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            Button { if model.fixedViewpoint == nil { model.updatePositionNow() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.isOnSummit ? "mountain.2.fill" : "location.fill")
                        .font(.caption2)
                    Text(model.viewpointName).font(.caption.weight(.semibold))
                    if let detail = model.viewpointDetail {
                        Text("· " + detail + (model.isPositionRough ? " · improving…" : ""))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.top, 7)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Position: \(model.viewpointName). Update position")
            CompassRibbon(heading: heading)
                .frame(height: 36)
        }
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
