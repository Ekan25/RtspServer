import Foundation
import Network

final class CameraControlServer {
    private let queue = DispatchQueue(label: "camera.control.server", qos: .userInitiated)
    private let handler: CameraCommandHandler
    private let address: String
    private let port: UInt16
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private let maxLineBytes = 16_384
    private let maxPendingBytes = 65_536
    var onError: ((String) -> Void)?

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var input = Data()
        var pendingBytes = 0
        var closing = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(address: String, port: UInt16, handler: CameraCommandHandler) {
        self.address = address
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw StreamError.message("Invalid camera control port.") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.onError?("Camera control listener failed: \(error.localizedDescription)") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in Array(clients.values) { remove(client) }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 16 else { connection.cancel(); return }
        let client = Client(connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state { case .failed, .cancelled: self.remove(client); default: break }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        handler.disconnected(client.id)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, self.clients[client.id] != nil, !client.closing else { return }
            if let data { client.input.append(data) }
            self.parse(client)
            guard self.clients[client.id] != nil, !client.closing else { return }
            if complete || error != nil { self.remove(client) } else { self.receive(client) }
        }
    }

    private func parse(_ client: Client) {
        while let newline = client.input.firstIndex(of: 10) {
            guard newline <= maxLineBytes else { rejectOversized(client); return }
            var line = Data(client.input[..<newline])
            client.input = Data(client.input.dropFirst(newline + 1))
            if line.last == 13 { line.removeLast() }
            send(handler.handle(line, client: client.id), to: client)
            guard clients[client.id] != nil else { return }
        }
        if client.input.count > maxLineBytes { rejectOversized(client) }
    }

    private func rejectOversized(_ client: Client) {
        client.closing = true
        let error = CameraResponse.Failure(code: "line_too_long", message: "Request exceeds the line limit.")
        send(CameraResponse(id: nil, ok: false, status: nil, streamStatus: nil, commands: nil, error: error), to: client, close: true)
    }

    private func send(_ response: CameraResponse, to client: Client, close: Bool = false) {
        guard var data = try? JSONEncoder().encode(response) else { remove(client); return }
        data.append(10)
        guard client.pendingBytes + data.count <= maxPendingBytes else { remove(client); return }
        client.pendingBytes += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            client.pendingBytes -= data.count
            if close || error != nil { self.remove(client) }
        })
    }
}