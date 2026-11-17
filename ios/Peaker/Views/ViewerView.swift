import PeakerKit
import SwiftUI

/// The main screen: full-screen panorama (camera or rendered), with floating Liquid Glass controls.
struct ViewerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            background
            PanoramaView()
                .ignoresSafeArea()
            VStack(spacing: 12) {
                TopBar()
                StatusBanner()
                Spacer()
                if model.showsCamera {
                    CalibrationHint()
                }
                ControlBar()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(item: $model.selectedPeak) { peak in
            PeakDetailView(visible: peak)
                .presentationDetents([.height(340), .large])
        }
        .sheet(isPresented: $model.showDownloads) {
            DownloadsView()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
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
        .onChange(of: model.packs.version) { Task { await model.recompute() } }
        // Pause camera and sensors in the background (battery), resume as they were.
        .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
    }

    /// The camera preview stays in the view hierarchy once access is granted (so it isn't rebuilt on every
    /// toggle) and fades in when frames arrive; until then the drawn sky and terrain stay visible.
    private var background: some View {
        ZStack {
            SkyBackground()
            if model.camera.isAuthorized {
                CameraPreview(session: model.camera.session, rotationAngle: model.cameraRotationAngle)
                    .opacity(model.showsCamera && model.camera.isRunning ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: model.showsCamera && model.camera.isRunning)
            }
        }
        .ignoresSafeArea()
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
                CompassRibbon()
                    .frame(maxWidth: 520)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("compass", in: glass)
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
            Section("Viewpoints") {
                ForEach(Viewpoint.all) { viewpoint in
                    Button {
                        model.choose(viewpoint)
                    } label: {
                        Label("\(viewpoint.name) · \(viewpoint.region)", systemImage: "mountain.2.fill")
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isUsingDemoViewpoint ? "mountain.2.fill" : "location.fill")
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
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Banners

private struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.horizonStore.noDataHere {
                banner(icon: "arrow.down.circle", text: "No offline data here yet. Download this country with the ↓ button.")
            } else if let h = model.horizonStore.horizon, h.missingFraction > 0.25 {
                banner(icon: "square.dashed", text: "Part of the view is outside the offline data.")
            } else if model.isFollowingDevice && model.motion.isCompassUncertain {
                banner(icon: "exclamationmark.triangle", text: "Compass is inaccurate. Move the phone in a figure 8.")
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
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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

// MARK: - Bottom controls

/// Gyro (automatic direction) and camera toggles on the left; settings, downloads and compass on the right.
private struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
                ToggleButton(title: model.isFollowingDevice ? "Stop following the phone" : "Follow the phone",
                             icon: "gyroscope", isOn: model.isFollowingDevice) {
                    model.setFollowing(!model.isFollowingDevice)
                }
                .glassEffectID("follow", in: glass)
                .disabled(!model.motion.isAvailable)

                ToggleButton(title: model.showsCamera ? "Hide camera" : "Show camera",
                             icon: model.showsCamera ? "camera.fill" : "camera", isOn: model.showsCamera) {
                    model.setCamera(!model.showsCamera)
                }
                .glassEffectID("camera", in: glass)

                Spacer(minLength: 0)

                IconButton(title: "Settings", icon: "gearshape") { model.showSettings = true }
                    .glassEffectID("settings", in: glass)

                IconButton(title: "Offline maps", icon: "arrow.down.circle") { model.showDownloads = true }
                    .glassEffectID("downloads", in: glass)

                CompassButton()
                    .glassEffectID("compass-button", in: glass)
            }
            .animation(.smooth, value: model.isFollowingDevice)
            .animation(.smooth, value: model.showsCamera)
        }
    }
}

/// Round glass button with an icon (title for VoiceOver).
private struct IconButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

private struct ToggleButton: View {
    let title: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? Glass.regular.tint(.orange).interactive() : Glass.regular.interactive(), in: .circle)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Needle pointing north on screen. Tap: look north (and stop following the phone).
private struct CompassButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let heading = model.heading
        Button {
            withAnimation(.smooth) { model.faceNorth() }
        } label: {
            ZStack {
                Image(systemName: "location.north.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .rotationEffect(.degrees(-heading))
                Text("N")
                    .font(.system(size: 9, weight: .heavy))
                    .offset(y: -19)
                    .rotationEffect(.degrees(-heading))
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Compass, heading \(Int(heading.rounded())) degrees. Tap to face north.")
    }
}
