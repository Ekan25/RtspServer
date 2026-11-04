import Combine
import Foundation
import SwiftUI

@MainActor
final class CameraViewModel: ObservableObject {
    enum ZoomDirection { case `in`, out }

    @Published var host: String
    @Published var portText: String
    @Published private(set) var connectionState: CameraControlConnectionState = .disconnected
    @Published private(set) var errorMessage: String?
    @Published private(set) var status: CameraStatus?
    @Published private(set) var capabilities: CameraCapabilities?
    @Published private(set) var supportedCommands = Set<String>()
    @Published private(set) var sliderValue = 1.0
    @Published var zoomSpeed = 2.0
    @Published private(set) var activeZoomDirection: ZoomDirection?
    @Published var selectedVideoModeID = ""
    @Published var selectedCameraPosition = "back"
    @Published var selectedFocusMode = "continuous"
    @Published var bitrateText = ""
    @Published var keepAwake = false
    @Published var manualFocusPosition = 0.5
    @Published var torchEnabled = false
    @Published var torchLevel = 1.0

    private let client = CameraControlClient()
    private var eventTask: Task<Void, Never>?
    private var sliderTask: Task<Void, Never>?
    private var isLoadingInitialState = false

    init(defaults: UserDefaults = .standard) {
        host = defaults.string(forKey: Keys.host) ?? ""
        let savedPort = defaults.integer(forKey: Keys.port)
        portText = String(savedPort == 0 ? 8555 : savedPort)
        observeClientEvents()
    }

    deinit { eventTask?.cancel(); sliderTask?.cancel() }

    var isConnected: Bool { connectionState == .connected }
    var zoomRange: ClosedRange<Double> {
        guard let zoom = status?.zoom, zoom.minFactor <= zoom.maxFactor else { return 1...1 }
        return zoom.minFactor...zoom.maxFactor
    }
    var canControlZoom: Bool { isConnected && status != nil && can(.setZoom) }
    var canRampZoom: Bool { canControlZoom && can(.rampZoom) && can(.stopZoom) }
    var videoModes: [CameraVideoMode] { capabilities?.videoModes ?? [] }
    var cameras: [CameraDescriptor] { capabilities?.cameras ?? [] }
    var canSelectVideoMode: Bool { isConnected && can(.setVideoMode) && !videoModes.isEmpty }
    var canSelectCamera: Bool { isConnected && can(.setCamera) && cameras.count > 1 }
    var canSetQuality: Bool { isConnected && can(.setQuality) }
    var canSetKeepAwake: Bool { isConnected && can(.setKeepAwake) }
    var canSetFocus: Bool { isConnected && can(.setFocusMode) }
    var canSetManualFocus: Bool { canSetFocus && (status?.focus.supportsManual ?? false) && selectedFocusMode == "manual" }
    var canSetTorch: Bool { isConnected && can(.setTorch) && (status?.torch.available ?? false) }

    func connect() {
        guard let port = UInt16(portText), port > 0 else { errorMessage = "Enter a TCP port from 1 to 65535."; return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { errorMessage = "Enter an IP address or hostname."; return }
        UserDefaults.standard.set(trimmedHost, forKey: Keys.host)
        UserDefaults.standard.set(Int(port), forKey: Keys.port)
        host = trimmedHost; errorMessage = nil; status = nil; capabilities = nil; supportedCommands.removeAll()
        Task { await client.connect(host: trimmedHost, port: port) }
    }

    func disconnect() {
        sliderTask?.cancel(); activeZoomDirection = nil
        Task {
            if isConnected, can(.stopZoom) { _ = try? await client.request(.stopZoom(id: requestID())) }
            await client.disconnect()
        }
    }

    func refresh() { guard isConnected else { return }; errorMessage = nil; Task { await loadInitialState() } }

    func userChangedZoom(to factor: Double) {
        guard canControlZoom else { return }
        sliderValue = factor; sliderTask?.cancel()
        sliderTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self, self.isConnected else { return }
                self.apply(try await self.client.request(.setZoom(id: self.requestID(), factor: factor)))
            } catch is CancellationError {
            } catch { self?.show(error) }
        }
    }

    func startZoom(_ direction: ZoomDirection) {
        guard canRampZoom, activeZoomDirection != direction, let zoom = status?.zoom else { return }
        let previousDirection = activeZoomDirection; activeZoomDirection = direction
        let target = direction == .in ? zoom.maxFactor : zoom.minFactor
        Task {
            do {
                if previousDirection != nil { _ = try await client.request(.stopZoom(id: requestID())) }
                apply(try await client.request(.rampZoom(id: requestID(), factor: target, speed: zoomSpeed)))
            } catch { activeZoomDirection = nil; show(error) }
        }
    }

    func stopZoom() {
        guard activeZoomDirection != nil else { return }
        activeZoomDirection = nil
        guard isConnected, can(.stopZoom) else { return }
        Task { do { apply(try await client.request(.stopZoom(id: requestID()))) } catch { show(error) } }
    }

    func setVideoMode() {
        guard let mode = videoModes.first(where: { $0.id == selectedVideoModeID }), canSelectVideoMode else { return }
        Task {
            do {
                apply(try await client.request(.setVideoMode(id: requestID(), mode: mode), timeout: .seconds(15)))
                await loadInitialState()
            } catch { show(error) }
        }
    }

    func setQuality() {
        guard let bitrate = Int(bitrateText), bitrate > 0, canSetQuality else { errorMessage = "Enter a positive bitrate in bits per second."; return }
        Task { do { apply(try await client.request(.setQuality(id: requestID(), bitrate: bitrate))) } catch { show(error) } }
    }

    func setKeepAwake() {
        guard canSetKeepAwake else { return }
        Task { do { apply(try await client.request(.setKeepAwake(id: requestID(), enabled: keepAwake))) } catch { show(error) } }
    }

    func setFocusMode() {
        guard canSetFocus else { return }
        Task { do { apply(try await client.request(.setFocusMode(id: requestID(), mode: selectedFocusMode))) } catch { show(error) } }
    }

    func setManualFocus() {
        guard canSetManualFocus else { return }
        Task { do { apply(try await client.request(.setFocus(id: requestID(), position: manualFocusPosition))) } catch { show(error) } }
    }

    func setCamera() {
        guard canSelectCamera else { return }
        Task {
            do {
                apply(try await client.request(.setCamera(id: requestID(), position: selectedCameraPosition), timeout: .seconds(15)))
                await loadInitialState()
            } catch { show(error) }
        }
    }

    func setTorch() {
        guard canSetTorch else { return }
        Task { do { apply(try await client.request(.setTorch(id: requestID(), enabled: torchEnabled))) } catch { show(error) } }
    }

    func setTorchLevel() {
        guard canSetTorch else { return }
        Task { do { apply(try await client.request(.setTorchLevel(id: requestID(), level: torchLevel))) } catch { show(error) } }
    }

    func windowDidLoseFocus() { stopZoom() }

    private func can(_ command: CameraCommand) -> Bool { supportedCommands.contains(command.rawValue) }

    private func observeClientEvents() {
        eventTask = Task { [weak self, client] in
            let events = await client.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: CameraControlClientEvent) {
        switch event {
        case let .state(state):
            connectionState = state
            if case .connected = state { Task { await loadInitialState() } }
            if case .disconnected = state { activeZoomDirection = nil }
            if case let .failed(message) = state { activeZoomDirection = nil; errorMessage = message }
        case let .error(message): errorMessage = message
        }
    }

    private func loadInitialState() async {
        guard !isLoadingInitialState else { return }
        isLoadingInitialState = true
        defer { isLoadingInitialState = false }
        do {
            apply(try await client.request(.capabilities(id: requestID())))
            apply(try await client.request(.status(id: requestID())))
        } catch { show(error) }
    }

    private func apply(_ response: CameraControlResponse) {
        if let capabilities = response.capabilities {
            self.capabilities = capabilities
            supportedCommands = Set(capabilities.commands)
            applyStatus(capabilities.status)
            if selectedVideoModeID.isEmpty, let first = capabilities.videoModes.first { selectedVideoModeID = first.id }
        }
        if let commands = response.commands { supportedCommands.formUnion(commands) }
        if let status = response.status {
            applyStatus(status)
        }

        if let zoom = response.zoom, var status {
            status = CameraStatus(camera: status.camera, videoMode: status.videoMode, bitrate: status.bitrate, effectiveBitrate: status.effectiveBitrate,
                                  zoom: zoom, focus: status.focus, torch: status.torch, keepAwake: status.keepAwake)
            self.status = status; sliderValue = zoom.factor
        }
        if let focus = response.focus, var status {
            status = CameraStatus(camera: status.camera, videoMode: status.videoMode, bitrate: status.bitrate, effectiveBitrate: status.effectiveBitrate,
                                  zoom: status.zoom, focus: focus, torch: status.torch, keepAwake: status.keepAwake)
            self.status = status; selectedFocusMode = focus.mode; manualFocusPosition = Double(focus.lensPosition ?? 0.5)
        }
        if let torch = response.torch, var status {
            status = CameraStatus(camera: status.camera, videoMode: status.videoMode, bitrate: status.bitrate, effectiveBitrate: status.effectiveBitrate,
                                  zoom: status.zoom, focus: status.focus, torch: torch, keepAwake: status.keepAwake)
            self.status = status; torchEnabled = torch.enabled; torchLevel = Double(torch.level ?? 1)
        }
        if let keepAwake = response.keepAwake { self.keepAwake = keepAwake.enabled }
        if let quality = response.quality { bitrateText = String(quality.requestedBitrate) }
    }

    private func applyStatus(_ status: CameraStatus) {
        self.status = status
        sliderValue = status.zoom.factor
        selectedCameraPosition = status.camera.position
        selectedFocusMode = status.focus.mode
        bitrateText = String(status.bitrate)
        keepAwake = status.keepAwake.enabled
        manualFocusPosition = Double(status.focus.lensPosition ?? 0.5)
        torchEnabled = status.torch.enabled
        torchLevel = Double(status.torch.level ?? 1)
        if let mode = videoModes.first(where: {
            $0.width == status.videoMode.width && $0.height == status.videoMode.height &&
                $0.minFrameRate <= (status.videoMode.frameRate ?? 0) && (status.videoMode.frameRate ?? 0) <= $0.maxFrameRate
        }) {
            selectedVideoModeID = mode.id
        }
    }

    private func show(_ error: Error) { errorMessage = error.localizedDescription }
    private func requestID() -> String { UUID().uuidString }

    private enum Keys {
        static let host = "cameraControl.host"
        static let port = "cameraControl.port"
    }
}
