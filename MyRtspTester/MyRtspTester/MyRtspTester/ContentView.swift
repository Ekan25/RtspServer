import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionSection

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                statusSection
                zoomSection
                additionalControlsSection
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 440)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                viewModel.windowDidLoseFocus()
            }
        }
    }

    private var connectionSection: some View {
        GroupBox("Connection") {
            Grid(alignment: .leading, verticalSpacing: 10) {
                GridRow {
                    Text("Address")
                    TextField("192.168.68.51", text: $viewModel.host)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.connectionState == .connecting || viewModel.isConnected)
                }
                GridRow {
                    Text("Port")
                    TextField("8555", text: $viewModel.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                        .disabled(viewModel.connectionState == .connecting || viewModel.isConnected)
                }
            }

            HStack {
                Label(connectionStatusText, systemImage: connectionStatusSymbol)
                    .foregroundStyle(connectionStatusColor)
                Spacer()
                if viewModel.isConnected {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnect()
                    }
                } else {
                    Button("Connect") {
                        viewModel.connect()
                    }
                    .disabled(viewModel.connectionState == .connecting)
                }
            }
            .padding(.top, 8)
        }
    }

    private var statusSection: some View {
        GroupBox("Camera Status") {
            VStack(alignment: .leading, spacing: 6) {
                if let status = viewModel.status {
                    LabeledContent("Device", value: status.deviceName)
                    LabeledContent("Zoom range", value: String(format: "%.1f×–%.1f×", status.minFactor, status.maxFactor))
                    if !status.switchOverFactors.isEmpty {
                        LabeledContent(
                            "Lens switch-over",
                            value: status.switchOverFactors.map { String(format: "%.1f×", $0) }.joined(separator: ", ")
                        )
                    }
                    LabeledContent("Ramping", value: status.isRamping ? "Yes" : "No")
                } else {
                    Text("Connect to load camera status.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Refresh") {
                        viewModel.refresh()
                    }
                    .disabled(!viewModel.isConnected)
                }
            }
        }
    }

    private var zoomSection: some View {
        GroupBox("Zoom") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Current zoom")
                    Spacer()
                    Text(String(format: "%.2f×", viewModel.status?.factor ?? viewModel.sliderValue))
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { viewModel.sliderValue },
                        set: { viewModel.userChangedZoom(to: $0) }
                    ),
                    in: viewModel.zoomRange
                )
                .disabled(!viewModel.canControlZoom)

                HStack {
                    Text("Speed")
                    Slider(value: $viewModel.zoomSpeed, in: 0.1...10, step: 0.1)
                    Text(String(format: "%.1f", viewModel.zoomSpeed))
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!viewModel.canRampZoom)

                HStack(spacing: 12) {
                    HoldZoomButton(title: "Zoom Out", isEnabled: viewModel.canRampZoom) {
                        viewModel.startZoom(.out)
                    } onRelease: {
                        viewModel.stopZoom()
                    }
                    HoldZoomButton(title: "Zoom In", isEnabled: viewModel.canRampZoom) {
                        viewModel.startZoom(.in)
                    } onRelease: {
                        viewModel.stopZoom()
                    }
                }
            }
        }
    }

    private var additionalControlsSection: some View {
        GroupBox("Additional Camera Controls") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Camera", selection: .constant("rear")) {
                    Text("Rear camera").tag("rear")
                    Text("Front camera").tag("front")
                }
                Toggle("Torch", isOn: .constant(false))
                Toggle("Autofocus", isOn: .constant(true))
                Text(viewModel.unavailableControlsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(true)
        }
    }

    private var connectionStatusText: String {
        switch viewModel.connectionState {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting…"
        case .connected:
            "Connected"
        case .failed:
            "Connection failed"
        }
    }

    private var connectionStatusSymbol: String {
        switch viewModel.connectionState {
        case .connected:
            "checkmark.circle.fill"
        case .connecting:
            "clock"
        case .disconnected, .failed:
            "xmark.circle.fill"
        }
    }

    private var connectionStatusColor: Color {
        switch viewModel.connectionState {
        case .connected:
            .green
        case .connecting:
            .orange
        case .disconnected, .failed:
            .secondary
        }
    }
}

private struct HoldZoomButton: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress, onRelease: onRelease)
    }

    func makeNSView(context: Context) -> PressAndHoldButton {
        let button = PressAndHoldButton(title: title)
        button.onPress = context.coordinator.onPress
        button.onRelease = context.coordinator.onRelease
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: PressAndHoldButton, context: Context) {
        context.coordinator.onPress = onPress
        context.coordinator.onRelease = onRelease
        button.title = title
        button.isEnabled = isEnabled
        button.onPress = context.coordinator.onPress
        button.onRelease = context.coordinator.onRelease
    }

    final class Coordinator {
        var onPress: () -> Void
        var onRelease: () -> Void

        init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onPress = onPress
            self.onRelease = onRelease
        }
    }
}

private final class PressAndHoldButton: NSButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var isPressing = false
    private var trackingArea: NSTrackingArea?
    private var windowResignObserver: NSObjectProtocol?

    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressing = true
        onPress?()
        observeWindowResigningKey()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
    }

    override func mouseExited(with event: NSEvent) {
        endPress()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            endPress()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    deinit {
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
    }

    private func observeWindowResigningKey() {
        guard windowResignObserver == nil, let window else { return }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.endPress()
        }
    }

    private func endPress() {
        guard isPressing else { return }
        isPressing = false
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        onRelease?()
    }
}

#Preview {
    ContentView()
}
