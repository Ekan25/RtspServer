import AppKit
import Foundation
import Network

struct CapturedPhoto: @unchecked Sendable {
    let format: PhotoFormat
    let width: Int
    let height: Int
    let rowStride: Int
    let data: Data

    func image() throws -> NSImage {
        switch format {
        case .jpeg:
            guard let image = NSImage(data: data) else { throw PhotoTransferError.invalidImage }
            return image
        case .bgra:
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: rowStride, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw PhotoTransferError.invalidImage
            }
            return NSImage(cgImage: image, size: .init(width: width, height: height))
        }
    }
}

enum PhotoTransferError: LocalizedError {
    case invalidHeader, rejected, invalidImage, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidHeader: "The camera sent an invalid photo transfer."
        case .rejected: "The camera rejected the photo transfer."
        case .invalidImage: "The received photo could not be decoded."
        case .tooLarge: "The received photo exceeds the size limit."
        }
    }
}

actor PhotoTransferReceiver {
    private let maxBytes = 100 * 1024 * 1024

    func receive(_ info: PhotoTransferInfo) async throws -> CapturedPhoto {
        let connection = NWConnection(host: .init(info.transferHost), port: .init(rawValue: info.transferPort)!, using: .tcp)
        try await ready(connection)
        defer { connection.cancel() }
        let id = Data(info.transferId.utf8), token = Data(info.transferToken.utf8)
        guard id.count <= 64, token.count <= 128 else { throw PhotoTransferError.invalidHeader }
        var hello = Data("LVP1".utf8)
        hello.appendU16(1); hello.appendU16(UInt16(id.count)); hello.appendU16(UInt16(token.count)); hello.appendU16(0)
        hello.append(id); hello.append(token)
        try await send(hello, connection)
        let header = try await receiveExactly(32, connection)
        guard header.prefix(4) == Data("LVP1".utf8), header.u16(at: 4) == 1, header.u16(at: 6) == 0,
              let rawFormat = header.u16(at: 8), let format = rawFormat == 1 ? PhotoFormat.jpeg : rawFormat == 2 ? PhotoFormat.bgra : nil,
              let width = header.u32(at: 12), let height = header.u32(at: 16), let stride = header.u32(at: 20), let length = header.u64(at: 24),
              width > 0, height > 0, length <= UInt64(maxBytes) else { throw PhotoTransferError.rejected }
        if format == .bgra && (stride < width * 4 || UInt64(stride) * UInt64(height) != length) { throw PhotoTransferError.invalidHeader }
        let data = try await receiveExactly(Int(length), connection)
        return .init(format: format, width: Int(width), height: Int(height), rowStride: Int(stride), data: data)
    }

    private func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state { case .ready: continuation.resume(); case let .failed(error): continuation.resume(throwing: error); default: break }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
    private func send(_ data: Data, _ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    private func receiveExactly(_ count: Int, _ connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: CameraControlClientError.disconnected) }
                    else { continuation.resume(throwing: PhotoTransferError.invalidHeader) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) { var value = value.bigEndian; append(Data(bytes: &value, count: 2)) }
    func u16(at offset: Int) -> UInt16? { guard count >= offset + 2 else { return nil }; return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian } }
    func u32(at offset: Int) -> UInt32? { guard count >= offset + 4 else { return nil }; return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian } }
    func u64(at offset: Int) -> UInt64? { guard count >= offset + 8 else { return nil }; return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian } }
}
