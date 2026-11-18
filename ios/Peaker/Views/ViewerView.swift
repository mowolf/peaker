import PeakerKit
import SwiftUI

/// The app's root: the 3D map (start screen) or the peak finder, with the sheets both use and the lifecycle
/// (sensors run only in the peak finder).
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.screen {
            case .map: MapScreen()
            case .finder: ViewerView()
            }
        }
        .modifier(ViewerSheets())
        .modifier(ViewerLifecycle())
    }
}

/// The peak finder: full-screen panorama (camera or rendered), with floating Liquid Glass controls.
struct ViewerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            background
            PanoramaView()
                .ignoresSafeArea()
            VStack(spacing: 12) {
                TopBar()
                StatusBanner()
                SummitPrompt()
                Spacer()
                if model.searchTarget != nil {
                    SearchTargetChip()
                } else if model.showsCamera {
                    CalibrationHint()
                }
                ControlBar()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// The camera preview stays in the view hierarchy once access is granted (so it isn't rebuilt on every
    /// toggle) and fades in when frames arrive; until then the drawn sky and terrain stay visible.
    private var background: some View {
        ZStack {
            SkyBackground()
            if model.camera.isAuthorized {
                CameraPreview(session: model.camera.session, rotationAngle: model.cameraRotationAngle)
                    .allowsHitTesting(false)
                    .opacity(model.showsCamera && model.camera.isRunning ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: model.showsCamera && model.camera.isRunning)
            }
        }
        .ignoresSafeArea()
    }
}

/// Peak details, offline maps and settings sheets. (Separate from `ViewerView.body`, which otherwise took
/// Xcode > 300 ms to type-check.)
private struct ViewerSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.selectedPeak) { peak in
                PeakDetailView(visible: peak)
                    .presentationDetents([.height(420), .large])
            }
            .sheet(isPresented: $model.showDownloads) {
                DownloadsView()
            }
            .sheet(isPresented: $model.showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $model.showPeakBook) {
                PeakBookView()
            }
            .sheet(isPresented: $model.showSearch) {
                PeakSearchView()
                    .presentationDetents([.medium, .large])
            }
    }
}

/// Orientation, sun refresh, recomputing on setting and pack changes, pausing in the background.
private struct ViewerLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // Landscape = wide panorama: track the orientation for the sensors and the camera preview.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in model.updateInterfaceOrientation() }
            .onAppear { model.updateInterfaceOrientation() }
            // The sun moves: refresh its day after midnight (current position is computed every frame).
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    model.horizonStore.refreshSun()
                }
            }
            // The view-distance slider and eye-height stepper change in steps: wait until they rest before the
            // (expensive) recompute. Cancelled and restarted on every change.
            .task(id: [model.settings.maxDistanceKm, model.settings.eyeHeight]) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await model.recompute()
            }
            .onChange(of: model.settings.fixedViewpointID) { Task { await model.recompute() } }
            .onChange(of: model.packs.version) {
                Task { await model.recompute() }
                Task { await model.peakBook.setDatabases(model.packs.snapshot().peakDatabases) }
            }
            // A new result moves the search target (new viewpoint) or drops it (no longer visible).
            .onChange(of: model.horizonStore.resultID) { model.refreshSearchTarget() }
            // Camera and motion sensors only run in the peak finder, and not in the background (battery).
            .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active && model.screen == .finder) }
            .onChange(of: model.screen) { _, screen in model.setActive(screen == .finder) }
            .onAppear { model.setActive(model.screen == .finder) }
            // The missing country of the start view was downloaded: show it.
            .onChange(of: model.packs.version) { model.countryDataChanged() }
    }
}

/// Dusk-blue sky for touch mode.
struct SkyBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.22),
                                Color(red: 0.20, green: 0.33, blue: 0.55),
                                Color(red: 0.62, green: 0.70, blue: 0.82)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    // Settings top left, as on the map.
                    GlassCircleButton(title: "Settings", action: { model.showSettings = true }) {
                        Image(systemName: "gearshape").font(.title3)
                    }
                    CompassRibbon()
                        .frame(maxWidth: 520)
                        .frame(height: 44)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("compass", in: glass)
                }
                HStack(spacing: 8) {
                    ViewpointChip()
                        .glassEffectID("viewpoint", in: glass)
                    if model.horizonStore.isComputing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .glassEffect(.regular, in: .circle)
                            .glassEffectID("progress", in: glass)
                            .transition(.blurReplace)
                    }
                }
                .animation(.smooth, value: model.horizonStore.isComputing)
            }
        }
    }
}

private struct ViewpointChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if model.fixedViewpoint == nil {
                Button {
                    model.updatePositionNow()
                } label: {
                    Label("Update position now", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    model.choose(nil)
                } label: {
                    Label("Use my location", systemImage: "location.fill")
                }
                .disabled(model.location.isDenied)
            }
            // Fixed viewpoints are chosen in Settings.
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isOnSummit ? "mountain.2.fill" : "location.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.viewpointName)
                        .font(.subheadline.weight(.semibold))
                    if let detail = model.viewpointDetail {
                        HStack(spacing: 4) {
                            Text(detail)
                            if model.isPositionRough {
                                Text("· improving…")
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.isPositionRough ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule())  // the whole capsule opens the menu, not just the text
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Banners

private struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.horizonStore.noDataHere {
                Button { model.showDownloads = true } label: {
                    banner(icon: "arrow.down.circle", text: "No offline data here yet. Tap to download this country.")
                }
                .buttonStyle(PressScaleStyle())
            } else if let h = model.horizonStore.horizon, h.missingFraction > 0.25 {
                banner(icon: "square.dashed", text: "Part of the view is outside the offline data.")
            } else if model.isFollowingDevice && model.motion.isCompassUncertain {
                banner(icon: "exclamationmark.triangle", text: "Compass is inaccurate. Move the phone in a figure 8.")
            } else if model.fixedViewpoint == nil && model.location.isDenied {
                banner(icon: "location.slash", text: "Location access is off. Allow it in Settings › Peaker, or pick a viewpoint in Peaker's settings.")
            } else if model.camera.isDenied && model.showsCamera {
                banner(icon: "camera", text: "Camera access is off. Allow it in Settings › Peaker.")
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.smooth, value: model.horizonStore.noDataHere)
    }

    private func banner(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Standing on a summit (GPS): offer to record the climb, once per peak and day.
private struct SummitPrompt: View {
    @Environment(AppModel.self) private var model
    @State private var failed = false
    @State private var recorded = 0

    var body: some View {
        Group {
            if let summit = model.summitToRecord {
                HStack(spacing: 12) {
                    Image(systemName: "flag.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("On \(summit.displayName(language: model.settings.peakLanguage))")
                            .font(.subheadline.weight(.semibold))
                        Text(failed ? "Couldn't save. Try again from the peak's details." : "Mark it as climbed today?")
                            .font(.caption)
                            .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: 4)
                    Button("Climbed") { record(summit) }
                        .buttonStyle(.glassProminent)
                        .tint(.green)
                    Button { withAnimation(.smooth) { model.dismissSummitPrompt() } } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not now")
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: model.summitToRecord?.id)
        .sensoryFeedback(.success, trigger: recorded)
    }

    private func record(_ summit: PeakInfo) {
        do {
            _ = try withAnimation(.smooth) {
                try model.peakBook.markClimbed(summit, on: DayDate(Date()), language: model.settings.peakLanguage)
            }
            failed = false
            recorded += 1
        } catch {
            failed = true
        }
    }
}

/// While the camera is shown, dragging aligns the lines with the image (compass error).
private struct CalibrationHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.draw")
                .font(.title3)
            Text(model.isAlignedByHand ? "Aligned by hand." : "Lines off? Drag to line them up with the mountains.")
                .font(.footnote.weight(.medium))
            if model.isAlignedByHand {
                Button("Reset") { model.resetAlignment() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .transition(.blurReplace)
    }
}

/// The peak picked in search: which way to turn, tap for details, ✕ to stop highlighting it.
private struct SearchTargetChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let target = model.searchTarget {
            HStack(spacing: 10) {
                Button { model.selectedPeak = target } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(target.peak.displayName(language: model.settings.peakLanguage))
                                .font(.subheadline.weight(.semibold))
                            Text(hint)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { withAnimation(.smooth) { model.clearSearchTarget() } } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop highlighting")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .transition(.blurReplace)
        }
    }

    /// Within this many degrees the peak counts as straight ahead.
    private static let aheadTolerance = 10.0

    private var turn: Double { model.turnToSearchTarget ?? 0 }

    private var icon: String {
        if abs(turn) <= Self.aheadTolerance { return "scope" }
        return turn > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left"
    }

    private var hint: String {
        if abs(turn) <= Self.aheadTolerance { return "Ahead" }
        let degrees = Int(abs(turn).rounded())
        return turn > 0 ? "Turn \(degrees)° right" : "Turn \(degrees)° left"
    }
}

// MARK: - Bottom controls

/// The peak finder's bottom bar, laid out like the map's (`ModeBar`): peak book on the left, search on the right,
/// and in the middle the phone-following (immersive) toggle, the switch back to the map, and the camera.
private struct ControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ModeBar(onPeakBook: { model.showPeakBook = true }, onSearch: { model.showSearch = true }) {
            ToggleButton(title: model.isFollowingDevice ? "Stop following the phone" : "Follow the phone",
                         icon: "gyroscope", isOn: model.isFollowingDevice) {
                model.setFollowing(!model.isFollowingDevice)
            }
            .disabled(!model.motion.isAvailable)

            GlassCircleButton(title: "Map", glass: .regular.tint(.blue), action: { model.openMap() }) {
                Image(systemName: "map.fill").font(.title3).foregroundStyle(.white)
            }

            ToggleButton(title: model.showsCamera ? "Hide camera" : "Show camera",
                         icon: model.showsCamera ? "camera.fill" : "camera", isOn: model.showsCamera) {
                model.setCamera(!model.showsCamera)
            }
        }
        .animation(.smooth, value: model.isFollowingDevice)
        .animation(.smooth, value: model.showsCamera)
    }
}

/// The bottom bar of both modes: peak book left, `center` in the middle, search right.
struct ModeBar<Center: View>: View {
    let onPeakBook: () -> Void
    let onSearch: () -> Void
    @ViewBuilder let center: () -> Center

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
                GlassCircleButton(title: "Peak book", action: onPeakBook) {
                    Image(systemName: "book").font(.title3)
                }
                Spacer(minLength: 0)
                HStack(spacing: 12) { center() }
                Spacer(minLength: 0)
                GlassCircleButton(title: "Find a peak", action: onSearch) {
                    Image(systemName: "magnifyingglass").font(.title3)
                }
            }
        }
    }
}

/// Round 52 pt glass button.
///
/// The glass and the hit area are part of the button's label: with the glass applied outside the button,
/// only the small icon itself reacted to taps and taps on the rest of the circle went to the glass.
/// Press feedback comes from the button style instead of interactive glass, which handles touches itself.
struct GlassCircleButton<Icon: View>: View {
    let title: String
    var glass: Glass = .regular
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .glassEffect(glass, in: .circle)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
    }
}

/// Shrinks the label slightly while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct ToggleButton: View {
    let title: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        GlassCircleButton(title: title, glass: isOn ? Glass.regular.tint(.orange) : Glass.regular, action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
