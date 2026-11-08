import Foundation
import Network

enum CameraControlConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum CameraControlClientEvent: Sendable {
    case state(CameraControlConnectionState)
    case error(String)
    case streamState(CameraStreamStatus)
}

enum CameraControlClientError: LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case connectionTimeout
    case requestTimeout
    case disconnected
    case invalidResponse(String)
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to the camera control server."
        case let .connectionFailed(message), let .invalidResponse(message):
            message
        case .connectionTimeout:
            "Timed out while connecting to the camera control server."
        case .requestTimeout:
            "The camera control server did not respond in time."
        case .disconnected:
            "The camera control connection was closed."
        case .messageTooLarge:
            "The camera control server sent a message larger than 16 KB."
        }
    }
}

actor CameraControlClient {
    private let maxMessageBytes = 16_384
    private let receiveChunkBytes = 4_096
    private let connectionTimeout: Duration = .seconds(10)
    private let defaultRequestTimeout: Duration = .seconds(5)

    private var connection: NWConnection?
    private var state: CameraControlConnectionState = .disconnected
    private var inputBuffer = Data()
    private var pendingRequests: [String: CheckedContinuation<CameraControlResponse, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var connectionTimeoutTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<CameraControlClientEvent>.Continuation?

    func events() -> AsyncStream<CameraControlClientEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
            continuation.yield(.state(state))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearEventContinuation() }
            }
        }
    }

    func connect(host: String, port: UInt16) {
        disconnect()
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            transition(to: .failed("Enter an IP address or hostname."))
            return
        }

        transition(to: .connecting)
        inputBuffer.removeAll(keepingCapacity: true)
        let connection = NWConnection(
            host: NWEndpoint.Host(host.trimmingCharacters(in: .whitespacesAndNewlines)),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            Task { await self?.handleConnectionState(newState, for: connection) }
        }
        connection.start(queue: .global(qos: .userInitiated))

        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: self?.connectionTimeout ?? .seconds(10))
            await self?.connectionTimedOut(for: connection)
        }
    }

    func disconnect() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connection?.cancel()
        connection = nil
        inputBuffer.removeAll(keepingCapacity: true)
        failPendingRequests(with: CameraControlClientError.disconnected)
        transition(to: .disconnected)
    }

    func request(
        _ request: CameraControlRequest,
        timeout: Duration? = nil
    ) async throws -> CameraControlResponse {
        guard state == .connected, let connection else {
            throw CameraControlClientError.notConnected
        }
        guard pendingRequests[request.id] == nil else {
            throw CameraControlClientError.invalidResponse("Duplicate request ID: \(request.id)")
        }

        var data = try JSONEncoder().encode(request)
        data.append(10)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[request.id] = continuation
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout ?? self?.defaultRequestTimeout ?? .seconds(5))
                await self?.timeoutRequest(id: request.id)
            }
            timeoutTasks[request.id] = timeoutTask

            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task {
                    await self?.failRequest(
                        id: request.id,
                        with: CameraControlClientError.connectionFailed(error.localizedDescription)
                    )
                }
            })
        }
    }

    private func clearEventContinuation() {
        eventContinuation = nil
    }

    private func handleConnectionState(_ newState: NWConnection.State, for connection: NWConnection) {
        guard self.connection === connection else { return }

        switch newState {
        case .ready:
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            transition(to: .connected)
            receive(on: connection)
        case let .failed(error):
            closeConnection(
                error: CameraControlClientError.connectionFailed(error.localizedDescription),
                state: .failed(error.localizedDescription)
            )
        case .cancelled:
            closeConnection(error: CameraControlClientError.disconnected, state: .disconnected)
        case .waiting(let error):
            eventContinuation?.yield(.error("Waiting for camera control connection: \(error.localizedDescription)"))
        default:
            break
        }
    }

    private func connectionTimedOut(for connection: NWConnection) {
        guard self.connection === connection, state == .connecting else { return }
        connection.cancel()
        closeConnection(error: CameraControlClientError.connectionTimeout, state: .failed(CameraControlClientError.connectionTimeout.localizedDescription))
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkBytes) { [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceive(data: data, isComplete: isComplete, error: error, for: connection)
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        for connection: NWConnection
    ) {
        guard self.connection === connection else { return }
        if let data {
            inputBuffer.append(data)
            parseIncomingMessages()
        }

        guard self.connection === connection else { return }
        if let error {
            closeConnection(
                error: CameraControlClientError.connectionFailed(error.localizedDescription),
                state: .failed(error.localizedDescription)
            )
        } else if isComplete {
            closeConnection(error: CameraControlClientError.disconnected, state: .disconnected)
        } else {
            receive(on: connection)
        }
    }

    private func parseIncomingMessages() {
        while let newlineIndex = inputBuffer.firstIndex(of: 10) {
            guard newlineIndex <= maxMessageBytes else {
                closeConnection(error: CameraControlClientError.messageTooLarge, state: .failed(CameraControlClientError.messageTooLarge.localizedDescription))
                return
            }

            var line = Data(inputBuffer[..<newlineIndex])
            inputBuffer = Data(inputBuffer.dropFirst(newlineIndex + 1))
            if line.last == 13 {
                line.removeLast()
            }

            do {
                let response = try JSONDecoder().decode(CameraControlResponse.self, from: line)
                guard let id = response.id else {
                    if response.event == "streamStateChanged", let stream = response.stream {
                        eventContinuation?.yield(.streamState(stream))
                    } else {
                        eventContinuation?.yield(.error("Received an unsupported control event."))
                    }
                    continue
                }
                if response.ok {
                    completeRequest(id: id, with: .success(response))
                } else {
                    let error = response.error?.message ?? "The camera control server rejected the request."
                    completeRequest(id: id, with: .failure(CameraControlClientError.connectionFailed(error)))
                }
            } catch {
                eventContinuation?.yield(.error("Received invalid camera control JSON: \(error.localizedDescription)"))
            }
        }

        if inputBuffer.count > maxMessageBytes {
            closeConnection(error: CameraControlClientError.messageTooLarge, state: .failed(CameraControlClientError.messageTooLarge.localizedDescription))
        }
    }

    private func timeoutRequest(id: String) {
        failRequest(id: id, with: CameraControlClientError.requestTimeout)
    }

    private func failRequest(id: String, with error: Error) {
        completeRequest(id: id, with: .failure(error))
    }

    private func completeRequest(id: String, with result: Result<CameraControlResponse, Error>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failPendingRequests(with error: Error) {
        let continuations = pendingRequests
        pendingRequests.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    private func closeConnection(error: Error, state: CameraControlConnectionState) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connection?.cancel()
        connection = nil
        inputBuffer.removeAll(keepingCapacity: true)
        failPendingRequests(with: error)
        transition(to: state)
    }

    private func transition(to newState: CameraControlConnectionState) {
        guard state != newState else { return }
        state = newState
        eventContinuation?.yield(.state(newState))
    }
}
