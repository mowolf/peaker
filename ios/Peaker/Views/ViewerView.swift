import PeakerKit
import SwiftUI

/// The main screen: full-screen panorama (camera or rendered), with floating Liquid Glass controls.
struct ViewerView: View {
    @Environment(AppModel.self) private var model

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
                if model.isCalibrating {
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
        .onChange(of: model.settings.maxDistanceKm) { Task { await model.recompute() } }
        .onChange(of: model.settings.useDemoViewpoint) { Task { await model.recompute() } }
        .onChange(of: model.packs.version) { Task { await model.recompute() } }
    }

    @ViewBuilder private var background: some View {
        if model.mode == .camera && model.camera.isAuthorized {
            CameraPreview(session: model.camera.session)
                .ignoresSafeArea()
        } else {
            SkyBackground()
                .ignoresSafeArea()
        }
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
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("compass", in: glass)
                HStack(spacing: 8) {
                    ViewpointChip()
                        .glassEffectID("viewpoint", in: glass)
                    if model.isComputing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .glassEffect(.regular, in: .circle)
                            .glassEffectID("progress", in: glass)
                            .transition(.blurReplace)
                    }
                }
                .animation(.smooth, value: model.isComputing)
            }
        }
    }
}

private struct ViewpointChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.settings.useDemoViewpoint = false
                model.location.requestAndStart()
            } label: {
                Label("Use my location", systemImage: "location.fill")
            }
            .disabled(model.location.isDenied)
            Button {
                model.settings.useDemoViewpoint = true
            } label: {
                Label("Demo: \(DemoViewpoint.name)", systemImage: "mountain.2.fill")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isUsingDemoViewpoint ? "mountain.2.fill" : "location.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.viewpointName)
                        .font(.subheadline.weight(.semibold))
                    if let ground = model.observerGround {
                        Text(model.settings.elevation(ground))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            if model.noDataHere {
                banner(icon: "arrow.down.circle", text: "No elevation data here yet.", action: "Download") {
                    model.showDownloads = true
                }
            } else if let h = model.horizon, h.missingFraction > 0.25, !model.isUsingDemoViewpoint {
                banner(icon: "square.dashed", text: "Parts of the view need more downloads.", action: "Download") {
                    model.showDownloads = true
                }
            } else if model.mode == .camera && model.motion.isCompassUncertain {
                banner(icon: "exclamationmark.triangle", text: "Compass is inaccurate. Move the phone in a figure 8.",
                       action: nil, perform: nil)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.smooth, value: model.noDataHere)
    }

    private func banner(icon: String, text: String, action: String?, perform: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            if let action, let perform {
                Button(action, action: perform)
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private struct CalibrationHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.draw")
                .font(.title3)
            Text("Drag to line up the ridges with the real mountains.")
                .font(.footnote.weight(.medium))
            Button("Reset") {
                model.headingOffset = 0
                model.pitchOffset = 0
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .rect(cornerRadius: 20))
        .transition(.blurReplace)
    }
}

// MARK: - Bottom controls

private struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.smooth) {
                        model.setMode(model.mode == .camera ? .touch : .camera)
                    }
                } label: {
                    Label(model.mode == .camera ? "Touch mode" : "Camera mode",
                          systemImage: model.mode == .camera ? "hand.point.up.left.fill" : "camera.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 52, height: 52)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("mode", in: glass)

                if model.mode == .camera {
                    Button {
                        withAnimation(.smooth) { model.isCalibrating.toggle() }
                    } label: {
                        Label("Calibrate", systemImage: "scope")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 52, height: 52)
                    }
                    .glassEffect(model.isCalibrating ? Glass.regular.tint(.orange).interactive() : Glass.regular.interactive(),
                                 in: .circle)
                    .glassEffectID("calibrate", in: glass)
                }

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    Button { model.showDownloads = true } label: {
                        Label("Offline maps", systemImage: "arrow.down.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 52, height: 52)
                    }
                    Button { model.showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 52, height: 52)
                    }
                }
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("menu", in: glass)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }
}
