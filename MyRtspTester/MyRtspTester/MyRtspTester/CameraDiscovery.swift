import Combine
import Foundation
import Network

struct CameraDiscoveryRecord: Equatable {
    let id: UUID
    let name: String
    let rtspPort: UInt16
    let rtspPath: String

    static func parse(txtRecord: NWTXTRecord, serviceName: String) -> CameraDiscoveryRecord? {
        let values = txtRecord.dictionary
        func value(for key: String) -> String? {
            guard let value = values[key] else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard value(for: "version") == "1",
              let identifier = value(for: "id").flatMap(UUID.init(uuidString:)),
              let portText = value(for: "rtsp_port"),
              let rtspPort = UInt16(portText),
              rtspPort > 0,
              let rtspPath = value(for: "rtsp_path"),
              rtspPath.hasPrefix("/"),
              !rtspPath.contains("\n"),
              !rtspPath.contains("\r") else {
            return nil
        }

        let name = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(id: identifier, name: name.isEmpty ? "Camera" : name, rtspPort: rtspPort, rtspPath: rtspPath)
    }
}

enum DiscoveredCameraConnectionState: Equatable {
    case available
    case resolving
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .available: "Available"
        case .resolving: "Resolving…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }
}

struct DiscoveredCamera: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rtspPort: UInt16
    let rtspPath: String
    let connectionState: DiscoveredCameraConnectionState
}

struct ResolvedCameraEndpoint: Equatable {
    let id: UUID
    let controlHost: String
    let controlPort: UInt16
    let rtspURL: String
}

@MainActor
final class CameraDiscovery: ObservableObject {
    enum State: Equatable {
        case stopped
        case browsing
        case failed(String)
    }

    @Published private(set) var cameras: [DiscoveredCamera] = []
    @Published private(set) var state: State = .stopped
    @Published private(set) var selectedCameraID: UUID?
    @Published private(set) var resolvedEndpoint: ResolvedCameraEndpoint?

    private struct Service {
        let record: CameraDiscoveryRecord
        let result: NWBrowser.Result
    }

    private enum ResolutionResult {
        case success(ResolvedCameraEndpoint)
        case failure(String)
    }

    private let queue = DispatchQueue(label: "camera.discovery", qos: .userInitiated)
    private var browser: NWBrowser?
    private var services: [UUID: Service] = [:]
    private var connectionStates: [UUID: DiscoveredCameraConnectionState] = [:]
    private var resolutionConnection: NWConnection?
    private var resolutionGeneration = 0

    deinit {
        browser?.cancel()
        resolutionConnection?.cancel()
    }

    func start() {
        guard browser == nil else { return }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_lvi-camera._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                self?.handle(browserState)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results)
            }
        }
        self.browser = browser
        state = .browsing
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        cancelResolution()
        services.removeAll()
        connectionStates.removeAll()
        cameras.removeAll()
        selectedCameraID = nil
        resolvedEndpoint = nil
        state = .stopped
    }

    func select(_ camera: DiscoveredCamera) {
        guard let service = services[camera.id] else { return }
        selectedCameraID = camera.id
        resolvedEndpoint = nil
        resolve(service)
    }

    func clearSelection() {
        if let selectedCameraID {
            connectionStates[selectedCameraID] = .available
        }
        selectedCameraID = nil
        resolvedEndpoint = nil
        cancelResolution()
        publishCameras()
    }

    func updateControlConnectionState(_ state: CameraControlConnectionState) {
        guard let selectedCameraID else { return }
        switch state {
        case .disconnected:
            connectionStates[selectedCameraID] = .available
        case .connecting:
            connectionStates[selectedCameraID] = .connecting
        case .connected:
            connectionStates[selectedCameraID] = .connected
        case let .failed(message):
            connectionStates[selectedCameraID] = .failed(message)
        }
        publishCameras()
    }

    private func handle(_ browserState: NWBrowser.State) {
        switch browserState {
        case .ready:
            state = .browsing
        case let .failed(error):
            state = .failed(error.localizedDescription)
            browser = nil
        case .cancelled:
            if browser == nil { state = .stopped }
        default:
            break
        }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var updatedServices: [UUID: Service] = [:]
        for result in results {
            guard case let .bonjour(txtRecord) = result.metadata,
                  case let .service(name, _, _, _) = result.endpoint,
                  let record = CameraDiscoveryRecord.parse(txtRecord: txtRecord, serviceName: name) else {
                continue
            }
            updatedServices[record.id] = .init(record: record, result: result)
            if connectionStates[record.id] == nil {
                connectionStates[record.id] = .available
            }
        }

        let removedIDs = Set(services.keys).subtracting(updatedServices.keys)
        for identifier in removedIDs {
            connectionStates.removeValue(forKey: identifier)
        }
        services = updatedServices

        if let selectedCameraID, let service = services[selectedCameraID] {
            resolvedEndpoint = nil
            resolve(service)
        } else if selectedCameraID != nil {
            cancelResolution()
            resolvedEndpoint = nil
        }
        publishCameras()
    }

    private func resolve(_ service: Service) {
        cancelResolution()
        resolutionGeneration += 1
        let generation = resolutionGeneration
        connectionStates[service.record.id] = .resolving
        publishCameras()

        let connection = NWConnection(to: service.result.endpoint, using: .tcp)
        resolutionConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let connection else { return }
            switch connectionState {
            case .ready:
                let endpoint = Self.resolvedEndpoint(for: service.record, connection: connection)
                connection.cancel()
                Task { @MainActor in
                    self?.finishResolution(endpoint, for: service.record.id, generation: generation)
                }
            case let .failed(error):
                Task { @MainActor in
                    self?.finishResolution(.failure(error.localizedDescription), for: service.record.id, generation: generation)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func cancelResolution() {
        resolutionGeneration += 1
        resolutionConnection?.cancel()
        resolutionConnection = nil
    }

    private func finishResolution(
        _ result: ResolutionResult,
        for identifier: UUID,
        generation: Int
    ) {
        guard generation == resolutionGeneration, selectedCameraID == identifier else { return }
        resolutionConnection = nil
        switch result {
        case let .success(endpoint):
            resolvedEndpoint = endpoint
            connectionStates[identifier] = .connecting
        case let .failure(message):
            resolvedEndpoint = nil
            connectionStates[identifier] = .failed(message)
        }
        publishCameras()
    }

    private func publishCameras() {
        cameras = services.values
            .map {
                .init(
                    id: $0.record.id,
                    name: $0.record.name,
                    rtspPort: $0.record.rtspPort,
                    rtspPath: $0.record.rtspPath,
                    connectionState: connectionStates[$0.record.id] ?? .available
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func resolvedEndpoint(
        for record: CameraDiscoveryRecord,
        connection: NWConnection
    ) -> ResolutionResult {
        guard let path = connection.currentPath,
              case let .hostPort(host, controlPort) = path.remoteEndpoint else {
            return .failure("Could not resolve the camera address.")
        }

        let hostText = host.debugDescription
        let rtspHost = hostText.contains(":") ? "[\(hostText)]" : hostText
        return .success(
            .init(
                id: record.id,
                controlHost: hostText,
                controlPort: controlPort.rawValue,
                rtspURL: "rtsp://\(rtspHost):\(record.rtspPort)\(record.rtspPath)"
            )
        )
    }
}
