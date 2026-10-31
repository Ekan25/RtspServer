import Foundation
import SwiftUI
import Combine

@MainActor
final class CameraViewModel: ObservableObject {
    enum ZoomDirection {
        case `in`
        case out
    }

    @Published var host: String
    @Published var portText: String
    @Published private(set) var connectionState: CameraControlConnectionState = .disconnected
    @Published private(set) var errorMessage: String?
    @Published private(set) var status: CameraStatus?
    @Published private(set) var supportedCommands = Set<String>()
    @Published private(set) var sliderValue = 1.0
    @Published var zoomSpeed = 2.0
    @Published private(set) var activeZoomDirection: ZoomDirection?

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

    deinit {
        eventTask?.cancel()
        sliderTask?.cancel()
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    var zoomRange: ClosedRange<Double> {
        guard let status, status.minFactor <= status.maxFactor else { return 1...1 }
        return status.minFactor...status.maxFactor
    }

    var canControlZoom: Bool {
        isConnected && status != nil && supportedCommands.contains(CameraCommand.setZoom.rawValue)
    }

    var canRampZoom: Bool {
        canControlZoom && supportedCommands.contains(CameraCommand.rampZoom.rawValue) && supportedCommands.contains(CameraCommand.stopZoom.rawValue)
    }

    var unavailableControlsMessage: String {
        "Front/rear camera, torch, and autofocus are unavailable because this server does not advertise those controls."
    }

    func connect() {
        guard let port = UInt16(portText), port > 0 else {
            errorMessage = "Enter a TCP port from 1 to 65535."
            return
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            errorMessage = "Enter an IP address or hostname."
            return
        }

        UserDefaults.standard.set(trimmedHost, forKey: Keys.host)
        UserDefaults.standard.set(Int(port), forKey: Keys.port)
        host = trimmedHost
        errorMessage = nil
        status = nil
        supportedCommands.removeAll()
        Task { await client.connect(host: trimmedHost, port: port) }
    }

    func disconnect() {
        sliderTask?.cancel()
        activeZoomDirection = nil
        Task {
            if isConnected, supportedCommands.contains(CameraCommand.stopZoom.rawValue) {
                _ = try? await client.request(.stopZoom(id: requestID()))
            }
            await client.disconnect()
        }
    }

    func refresh() {
        guard isConnected else { return }
        errorMessage = nil
        Task { await loadStatus() }
    }

    func userChangedZoom(to factor: Double) {
        guard canControlZoom else { return }
        sliderValue = factor
        sliderTask?.cancel()
        sliderTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self, self.isConnected else { return }
                let response = try await self.client.request(.setZoom(id: self.requestID(), factor: factor))
                self.apply(response)
            } catch is CancellationError {
                // A newer slider position superseded this request.
            } catch {
                self?.show(error)
            }
        }
    }

    func startZoom(_ direction: ZoomDirection) {
        guard canRampZoom, activeZoomDirection != direction, let status else { return }
        let previousDirection = activeZoomDirection
        activeZoomDirection = direction
        let target = direction == .in ? status.maxFactor : status.minFactor

        Task {
            do {
                if previousDirection != nil {
                    _ = try await client.request(.stopZoom(id: requestID()))
                }
                let response = try await client.request(
                    .rampZoom(id: requestID(), factor: target, speed: zoomSpeed)
                )
                apply(response)
            } catch {
                activeZoomDirection = nil
                show(error)
            }
        }
    }

    func stopZoom() {
        guard activeZoomDirection != nil else { return }
        activeZoomDirection = nil
        guard isConnected, supportedCommands.contains(CameraCommand.stopZoom.rawValue) else { return }

        Task {
            do {
                let response = try await client.request(.stopZoom(id: requestID()))
                apply(response)
            } catch {
                show(error)
            }
        }
    }

    func windowDidLoseFocus() {
        stopZoom()
    }

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
            switch state {
            case .connected:
                Task { await loadInitialState() }
            case .disconnected:
                activeZoomDirection = nil
            case let .failed(message):
                activeZoomDirection = nil
                errorMessage = message
            case .connecting:
                break
            }
        case let .error(message):
            errorMessage = message
        }
    }

    private func loadInitialState() async {
        guard !isLoadingInitialState else { return }
        isLoadingInitialState = true
        defer { isLoadingInitialState = false }

        do {
            let capabilities = try await client.request(.capabilities(id: requestID()))
            apply(capabilities)
            await loadStatus()
        } catch {
            show(error)
        }
    }

    private func loadStatus() async {
        do {
            let response = try await client.request(.status(id: requestID()))
            apply(response)
        } catch {
            show(error)
        }
    }

    private func apply(_ response: CameraControlResponse) {
        if let commands = response.commands {
            supportedCommands = Set(commands)
        }
        if let responseStatus = response.status {
            status = responseStatus
            sliderValue = responseStatus.factor
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func requestID() -> String {
        UUID().uuidString
    }

    private enum Keys {
        static let host = "cameraControl.host"
        static let port = "cameraControl.port"
    }
}
