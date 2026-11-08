import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @StateObject private var videoPlayer = GStreamerPlayerViewModel()
    @StateObject private var discovery = CameraDiscovery()
    @Environment(\.scenePhase) private var scenePhase
    @State private var photoZoom: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            videoPreviewSection
                .frame(minWidth: 500, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    discoveredCamerasSection
                    playbackControlsSection
                    photoControlsSection
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
        .onChange(of: viewModel.connectionState) { _, state in discovery.updateControlConnectionState(state) }
        .onChange(of: viewModel.autoConnect) { _, enabled in
            if enabled { selectSavedCameraIfAvailable() }
        }
        .onChange(of: viewModel.autoStream) { _, enabled in
            if enabled, viewModel.isConnected { viewModel.refresh() }
        }
        .onChange(of: discovery.cameras) { _, _ in selectSavedCameraIfAvailable() }
        .onChange(of: discovery.resolvedEndpoint) { _, endpoint in
            guard let endpoint else { return }
            videoPlayer.updateDiscoveredURL(endpoint.rtspURL)
            viewModel.connectDiscoveredCamera(endpoint)
        }
        .onChange(of: viewModel.streamStatus) { _, status in
            guard viewModel.autoStream else { return }
            switch status?.state {
            case .running:
                videoPlayer.start()
            case .stopped, .stopping:
                videoPlayer.stop()
            case .starting, .error, nil:
                break
            }
        }
        .onAppear {
            videoPlayer.updateHost(viewModel.host)
            discovery.start()
            selectSavedCameraIfAvailable()
        }
        .onDisappear { discovery.stop() }
    }

    private var videoPreviewSection: some View {
        GroupBox(viewModel.isShowingPhoto ? "Captured Photo" : "RTSP Video") {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isShowingPhoto, let image = viewModel.capturedImage {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: image.size.width * photoZoom, height: image.size.height * photoZoom)
                    }
                    .background(.black)
                    .gesture(MagnificationGesture().onChanged { photoZoom = min(max($0, 0.1), 8) })
                    HStack {
                        Text("\(viewModel.capturedPhoto?.width ?? 0) × \(viewModel.capturedPhoto?.height ?? 0)")
                        Spacer()
                        Button("Return to Live Video") { viewModel.showLiveVideo() }
                    }
                } else {
                    ZStack {
                        GStreamerVideoView(player: videoPlayer)
                        if videoPlayer.playbackState != .playing {
                            Label(videoPlayer.playbackState.label, systemImage: videoPlayer.playbackState.symbol)
                                .foregroundStyle(.white.opacity(0.85)).padding(8).background(.black.opacity(0.45), in: Capsule())
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var photoControlsSection: some View {
            GroupBox("Photo Capture") {
                HStack {
                    Picker("Format", selection: $viewModel.photoFormat) {
                        ForEach(PhotoFormat.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    Button(viewModel.isCapturingPhoto ? "Capturing…" : "Capture Photo") { viewModel.capturePhoto() }
                        .disabled(!viewModel.canCapturePhoto)
                    Button("Save Image") { viewModel.saveCapturedPhoto() }
                        .disabled(viewModel.capturedPhoto == nil)
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
        GroupBox("Manual Connection") {
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
                    Button("Disconnect", role: .destructive) {
                        discovery.clearSelection()
                        viewModel.disconnect()
                    }
                } else {
                    Button("Connect") { connectManually() }.disabled(viewModel.connectionState == .connecting)
                }
            }.padding(.top, 8)
        }
    }

    private var discoveredCamerasSection: some View {
        GroupBox("Discovered Cameras") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(discoveryStatusText, systemImage: discoveryStatusSymbol)
                        .foregroundStyle(discoveryStatusColor)
                    Spacer()
                    Button(discovery.state == .stopped ? "Start" : "Stop") {
                        if discovery.state == .stopped { discovery.start() }
                        else { discovery.stop() }
                    }
                }

                if discovery.cameras.isEmpty {
                    Text("No cameras found on the local network.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discovery.cameras) { camera in
                        Button { select(camera) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(camera.name)
                                    Text(camera.id.uuidString.lowercased())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(camera.connectionState.label)
                                    .font(.caption)
                                    .foregroundStyle(cameraStatusColor(camera.connectionState))
                                if discovery.selectedCameraID == camera.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.connectionState == .resolving)
                    }
                    Toggle("Auto Connect", isOn: $viewModel.autoConnect)
                    Toggle("Auto Stream", isOn: $viewModel.autoStream)
                }
            }
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
                if let streamStatus = viewModel.streamStatus {
                    LabeledContent("Stream", value: streamStatus.state.rawValue.capitalized)
                    if let message = streamStatus.message, !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Start Stream") { viewModel.startStream() }.disabled(!viewModel.canStartStream)
                    Button("Stop Stream", role: .destructive) { viewModel.stopStream() }.disabled(!viewModel.canStopStream)
                }
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

    private func connectManually() {
        discovery.clearSelection()
        videoPlayer.updateDiscoveredURL(nil)
        viewModel.connect()
    }

    private func select(_ camera: DiscoveredCamera) {
        viewModel.selectDiscoveredCamera(camera.id)
        discovery.select(camera)
    }

    private func selectSavedCameraIfAvailable() {
        guard viewModel.shouldAutoConnect,
              let identifier = viewModel.selectedCameraID,
              let camera = discovery.cameras.first(where: { $0.id == identifier }),
              discovery.selectedCameraID != identifier else { return }
        discovery.select(camera)
    }

    private var discoveryStatusText: String {
        switch discovery.state {
        case .stopped: "Discovery stopped"
        case .browsing: "Searching local network"
        case let .failed(message): message
        }
    }

    private var discoveryStatusSymbol: String {
        switch discovery.state {
        case .stopped: "pause.circle"
        case .browsing: "dot.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var discoveryStatusColor: Color {
        switch discovery.state {
        case .stopped: .secondary
        case .browsing: .orange
        case .failed: .red
        }
    }

    private func cameraStatusColor(_ state: DiscoveredCameraConnectionState) -> Color {
        switch state {
        case .available: .secondary
        case .resolving, .connecting: .orange
        case .connected: .green
        case .failed: .red
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
