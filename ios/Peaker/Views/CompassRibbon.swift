import PeakerKit
import SwiftUI

/// Heading tape: degrees and cardinal directions around the current view direction.
struct CompassRibbon: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let heading = model.cameraPose(size: CGSize(width: 400, height: 800)).azimuth
            Canvas { context, size in
                let pointsPerDegree = size.width / 90  // 90° visible across the ribbon
                let mid = size.width / 2
                let first = Int((heading - 45).rounded(.down))
                for deg in first...(first + 91) {
                    let x = mid + (Double(deg) - heading) * pointsPerDegree
                    let d = ((deg % 360) + 360) % 360
                    if d % 5 != 0 { continue }
                    let major = d % 45 == 0
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - (major ? 12 : 7)))
                    tick.addLine(to: CGPoint(x: x, y: size.height - 3))
                    context.stroke(tick, with: .color(.white.opacity(major ? 0.9 : 0.4)), lineWidth: major ? 1.5 : 1)
                    if major {
                        let label = Self.cardinal(d)
                        context.draw(Text(label).font(.system(size: 12, weight: .bold))
                            .foregroundStyle(d == 0 ? Color.orange : .white),
                                     at: CGPoint(x: x, y: size.height / 2 - 4))
                    } else if d % 15 == 0 {
                        context.draw(Text("\(d)").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.6)),
                                     at: CGPoint(x: x, y: size.height / 2 - 4))
                    }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .center) {
                Text("\(Int(heading.rounded()) % 360)°")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.85), in: .capsule)
                    .offset(y: 13)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("Heading")
        .accessibilityValue("\(Int(model.cameraPose(size: CGSize(width: 400, height: 800)).azimuth.rounded())) degrees")
    }

    static func cardinal(_ degrees: Int) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][((degrees + 22) / 45) % 8]
    }
}
