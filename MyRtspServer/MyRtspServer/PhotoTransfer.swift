import Foundation
import Network

enum PhotoFormat: String, Codable {
    case jpeg
    case bgra

    var wireValue: UInt16 { self == .jpeg ? 1 : 2 }
}

struct CapturedPhotoData {
    let format: PhotoFormat
    let width: Int
    let height: Int
    let rowStride: Int
    let bytes: Data
}

struct PhotoTransferInfo: Encodable {
    let transferId: String
    let transferHost: String
    let transferPort: UInt16
    let transferToken: String
    let format: PhotoFormat
}

final class ImageTransferServer {
    private struct Pending {
        let token: String
        let photo: CapturedPhotoData
        let expiry: DispatchWorkItem
    }

    private let queue = DispatchQueue(label: "camera.image.transfer", qos: .userInitiated)
    private let address: String
    private let port: UInt16
    private var listener: NWListener?
    private var pending: [String: Pending] = [:]
    var onError: ((String) -> Void)?

    init(address: String, port: UInt16 = 8556) {
        self.address = address
        self.port = port
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw StreamError.message("Invalid image transfer port.") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.onError?("Image transfer listener failed: \(error.localizedDescription)") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            pending.values.forEach { $0.expiry.cancel() }
            pending.removeAll()
        }
    }

    func register(_ photo: CapturedPhotoData) -> PhotoTransferInfo {
        let transferID = UUID().uuidString.lowercased()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        queue.sync {
            let expiry = DispatchWorkItem { [weak self] in self?.pending.removeValue(forKey: transferID) }
            self.pending[transferID] = .init(token: token, photo: photo, expiry: expiry)
            self.queue.asyncAfter(deadline: .now() + 30, execute: expiry)
        }
        return .init(transferId: transferID, transferHost: address, transferPort: port, transferToken: token, format: photo.format)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveExact(connection, count: 12) { [weak self] header in
            guard let self, let header, header.count == 12,
                  header.prefix(4) == Data("LVP1".utf8),
                  header.u16(at: 4) == 1,
                  let idLength = header.u16(at: 6), let tokenLength = header.u16(at: 8),
                  idLength > 0, tokenLength > 0, idLength <= 64, tokenLength <= 128 else {
                self?.sendErrorAndClose(connection)
                return
            }
            self.receiveExact(connection, count: Int(idLength + tokenLength)) { body in
                guard let body,
                      let transferID = String(data: body.prefix(Int(idLength)), encoding: .utf8),
                      let token = String(data: body.dropFirst(Int(idLength)), encoding: .utf8),
                      let item = self.pending.removeValue(forKey: transferID),
                      item.token == token else {
                    self.sendErrorAndClose(connection)
                    return
                }
                item.expiry.cancel()
                self.send(photo: item.photo, on: connection)
            }
        }
    }

    private func send(photo: CapturedPhotoData, on connection: NWConnection) {
        var header = Data("LVP1".utf8)
        header.appendU16(1); header.appendU16(0); header.appendU16(photo.format.wireValue); header.appendU16(0)
        header.appendU32(UInt32(photo.width)); header.appendU32(UInt32(photo.height)); header.appendU32(UInt32(photo.rowStride))
        header.appendU64(UInt64(photo.bytes.count))
        connection.send(content: header + photo.bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendErrorAndClose(_ connection: NWConnection) {
        var header = Data("LVP1".utf8)
        header.appendU16(1); header.appendU16(1); header.appendU16(0); header.appendU16(0)
        header.appendU32(0); header.appendU32(0); header.appendU32(0); header.appendU64(0)
        connection.send(content: header, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func receiveExact(_ connection: NWConnection, count: Int, completion: @escaping (Data?) -> Void) {
        var data = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { chunk, _, complete, error in
                if let chunk { data.append(chunk) }
                if data.count == count { completion(data) }
                else if complete || error != nil { completion(nil) }
                else { receive() }
            }
        }
        receive()
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) { var value = value.bigEndian; append(Data(bytes: &value, count: 2)) }
    mutating func appendU32(_ value: UInt32) { var value = value.bigEndian; append(Data(bytes: &value, count: 4)) }
    mutating func appendU64(_ value: UInt64) { var value = value.bigEndian; append(Data(bytes: &value, count: 8)) }
    func u16(at offset: Int) -> UInt16? {
        guard count >= offset + 2 else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian }
    }
}
