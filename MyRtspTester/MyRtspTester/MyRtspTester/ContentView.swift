import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @StateObject private var videoPlayer = GStreamerPlayerViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            videoPreviewSection
                .frame(minWidth: 500, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    playbackControlsSection
                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    statusSection
                    videoSection
                    zoomSection
                    focusSection
                    torchSection
                    keepAwakeSection
                }
                .padding(.vertical, 2)
            }
            .frame(width: 380)
        }
        .padding()
        .frame(minWidth: 1_000, minHeight: 640)
        .onChange(of: scenePhase) { _, phase in if phase != .active { viewModel.windowDidLoseFocus() } }
        .onChange(of: viewModel.host) { _, host in videoPlayer.updateHost(host) }
        .onAppear { videoPlayer.updateHost(viewModel.host) }
    }

    private var videoPreviewSection: some View {
        GroupBox("RTSP Video") {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    GStreamerVideoView(player: videoPlayer)
                    if videoPlayer.playbackState != .playing {
                        Label(videoPlayer.playbackState.label, systemImage: videoPlayer.playbackState.symbol)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(8)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack {
                    Label(videoPlayer.playbackState.label, systemImage: videoPlayer.playbackState.symbol)
                        .foregroundStyle(videoStatusColor)
                    Spacer()
                    Text("\(videoPlayer.actualResolution) @ \(videoPlayer.negotiatedFrameRate, specifier: "%.1f") fps")
                        .monospacedDigit()
                }

                if let error = videoPlayer.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Text("Incoming \(videoPlayer.measuredFrameRate, specifier: "%.1f") fps")
                    Text("Reconnects \(videoPlayer.reconnectionCount)")
                    if let lastFrameTime = videoPlayer.lastFrameTime {
                        Text("Last frame \(lastFrameTime.formatted(date: .omitted, time: .standard))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var playbackControlsSection: some View {
        GroupBox("Playback Controls") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, verticalSpacing: 8) {
                    GridRow {
                        Text("Transport")
                        Picker("Transport", selection: $videoPlayer.transport) {
                            Text("TCP").tag("TCP")
                            Text("UDP").tag("UDP")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Latency")
                        TextField("20", text: $videoPlayer.latencyText)
                            .textFieldStyle(.roundedBorder)
                        Text("ms").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Stall timeout")
                        TextField("3", text: $videoPlayer.stallTimeoutText)
                            .textFieldStyle(.roundedBorder)
                        Text("s").foregroundStyle(.secondary)
                    }
                }

                TextField("Optional RTSP URL override", text: $videoPlayer.urlOverride)
                    .textFieldStyle(.roundedBorder)
                Text(videoPlayer.currentURL.isEmpty ? "Enter a camera address or RTSP URL." : videoPlayer.currentURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack {
                    Button("Start Video") { videoPlayer.start() }
                    Button("Stop Video", role: .destructive) { videoPlayer.stop() }
                    Button("Reconnect") { videoPlayer.reconnect() }
                    Spacer()
                    Button("Full Screen") { videoPlayer.toggleFullScreen() }
                }
            }
        }
    }

    private var videoStatusColor: Color {
        switch videoPlayer.playbackState {
        case .playing: .green
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .idle, .stopped: .secondary
        }
    }

    private var connectionSection: some View {
        GroupBox("Connection") {
            Grid(alignment: .leading, verticalSpacing: 10) {
                GridRow {
                    Text("Address")
                    TextField("192.168.68.51", text: $viewModel.host).textFieldStyle(.roundedBorder)
                        .disabled(viewModel.connectionState == .connecting || viewModel.isConnected)
                }
                GridRow {
                    Text("Port")
                    TextField("8555", text: $viewModel.portText).textFieldStyle(.roundedBorder).frame(maxWidth: 100)
                        .disabled(viewModel.connectionState == .connecting || viewModel.isConnected)
                }
            }
            HStack {
                Label(connectionStatusText, systemImage: connectionStatusSymbol).foregroundStyle(connectionStatusColor)
                Spacer()
                if viewModel.isConnected {
                    Button("Disconnect", role: .destructive) { viewModel.disconnect() }
                } else {
                    Button("Connect") { viewModel.connect() }.disabled(viewModel.connectionState == .connecting)
                }
            }.padding(.top, 8)
        }
    }

    private var statusSection: some View {
        GroupBox("Camera Status") {
            VStack(alignment: .leading, spacing: 6) {
                if let status = viewModel.status {
                    LabeledContent("Device", value: status.camera.name)
                    LabeledContent("Video", value: "\(status.videoMode.width) × \(status.videoMode.height) @ \(Int((status.videoMode.frameRate ?? 0).rounded())) fps")
                    LabeledContent("Bitrate", value: "\(status.bitrate) bps")
                    LabeledContent("Zoom range", value: String(format: "%.1f×–%.1f×", status.zoom.minFactor, status.zoom.maxFactor))
                    if !status.zoom.switchOverFactors.isEmpty {
                        LabeledContent("Lens switch-over", value: status.zoom.switchOverFactors.map { String(format: "%.1f×", $0) }.joined(separator: ", "))
                    }
                } else {
                    Text("Connect to load camera status.").foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Refresh") { viewModel.refresh() }.disabled(!viewModel.isConnected) }
            }
        }
    }

    private var videoSection: some View {
        GroupBox("Video and Camera") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Camera", selection: $viewModel.selectedCameraPosition) {
                    Text("Rear camera").tag("back")
                    Text("Front camera").tag("front")
                }
                .disabled(!viewModel.canSelectCamera)
                .onChange(of: viewModel.selectedCameraPosition) { _, _ in viewModel.setCamera() }

                Picker("Video mode", selection: $viewModel.selectedVideoModeID) {
                    ForEach(viewModel.videoModes) { mode in Text(mode.label).tag(mode.id) }
                }
                .disabled(!viewModel.canSelectVideoMode)
                HStack { Spacer(); Button("Apply video mode") { viewModel.setVideoMode() }.disabled(!viewModel.canSelectVideoMode) }

                HStack {
                    TextField("Bitrate (bps)", text: $viewModel.bitrateText).textFieldStyle(.roundedBorder)
                    Button("Apply bitrate") { viewModel.setQuality() }.disabled(!viewModel.canSetQuality)
                }
            }
        }
    }

    private var zoomSection: some View {
        GroupBox("Zoom") {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Current zoom"); Spacer(); Text(String(format: "%.2f×", viewModel.status?.zoom.factor ?? viewModel.sliderValue)).monospacedDigit() }
                Slider(value: Binding(get: { viewModel.sliderValue }, set: { viewModel.userChangedZoom(to: $0) }), in: viewModel.zoomRange)
                    .disabled(!viewModel.canControlZoom)
                HStack {
                    Text("Speed")
                    Slider(value: $viewModel.zoomSpeed, in: 0.1...10, step: 0.1)
                    Text(String(format: "%.1f", viewModel.zoomSpeed)).monospacedDigit().frame(width: 32, alignment: .trailing)
                }.disabled(!viewModel.canRampZoom)
                HStack(spacing: 12) {
                    HoldZoomButton(title: "Zoom Out", isEnabled: viewModel.canRampZoom) { viewModel.startZoom(.out) } onRelease: { viewModel.stopZoom() }
                    HoldZoomButton(title: "Zoom In", isEnabled: viewModel.canRampZoom) { viewModel.startZoom(.in) } onRelease: { viewModel.stopZoom() }
                }
            }
        }
    }

    private var focusSection: some View {
        GroupBox("Focus") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Mode", selection: $viewModel.selectedFocusMode) {
                    Text("Auto").tag("auto")
                    Text("Continuous").tag("continuous")
                    Text("Manual").tag("manual")
                }
                .disabled(!viewModel.canSetFocus)
                .onChange(of: viewModel.selectedFocusMode) { _, _ in viewModel.setFocusMode() }
                HStack {
                    Slider(value: $viewModel.manualFocusPosition, in: 0...1)
                    Text(String(format: "%.2f", viewModel.manualFocusPosition)).monospacedDigit().frame(width: 36)
                    Button("Set focus") { viewModel.setManualFocus() }.disabled(!viewModel.canSetManualFocus)
                }.disabled(!viewModel.canSetManualFocus)
            }
        }
    }

    private var torchSection: some View {
        GroupBox("Torch") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable torch", isOn: Binding(get: { viewModel.torchEnabled }, set: { viewModel.torchEnabled = $0; viewModel.setTorch() }))
                    .disabled(!viewModel.canSetTorch)
                HStack {
                    Slider(value: $viewModel.torchLevel, in: 0...1)
                    Text(String(format: "%.2f", viewModel.torchLevel)).monospacedDigit().frame(width: 36)
                    Button("Set level") { viewModel.setTorchLevel() }.disabled(!viewModel.canSetTorch || !viewModel.torchEnabled)
                }.disabled(!viewModel.canSetTorch || !viewModel.torchEnabled)
            }
        }
    }

    private var keepAwakeSection: some View {
        GroupBox("Keep Awake") {
            Toggle("Prevent idle sleep", isOn: Binding(get: { viewModel.keepAwake }, set: { viewModel.keepAwake = $0; viewModel.setKeepAwake() }))
                .disabled(!viewModel.canSetKeepAwake)
        }
    }

    private var connectionStatusText: String {
        switch viewModel.connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }
    private var connectionStatusSymbol: String {
        switch viewModel.connectionState {
        case .connected: "checkmark.circle.fill"
        case .connecting: "clock"
        case .disconnected, .failed: "xmark.circle.fill"
        }
    }
    private var connectionStatusColor: Color {
        switch viewModel.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .failed: .secondary
        }
    }
}

private struct HoldZoomButton: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress, onRelease: onRelease) }
    func makeNSView(context: Context) -> PressAndHoldButton {
        let button = PressAndHoldButton(title: title)
        button.onPress = context.coordinator.onPress; button.onRelease = context.coordinator.onRelease
        return button
    }
    func updateNSView(_ button: PressAndHoldButton, context: Context) {
        context.coordinator.onPress = onPress; context.coordinator.onRelease = onRelease
        button.title = title; button.isEnabled = isEnabled; button.onPress = onPress; button.onRelease = onRelease
    }
    final class Coordinator {
        var onPress: () -> Void
        var onRelease: () -> Void
        init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) { self.onPress = onPress; self.onRelease = onRelease }
    }
}

private final class PressAndHoldButton: NSButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var isPressing = false
    convenience init(title: String) { self.init(title: title, target: nil, action: nil) }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; isPressing = true; onPress?() }
    override func mouseUp(with event: NSEvent) { endPress() }
    override func mouseExited(with event: NSEvent) { endPress() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { endPress() }; super.viewWillMove(toWindow: newWindow) }
    private func endPress() { guard isPressing else { return }; isPressing = false; onRelease?() }
}
