import Foundation

enum CameraCommand: String, Codable, Sendable {
    case status
    case capabilities
    case setZoom
    case rampZoom
    case stopZoom
}

struct CameraControlRequest: Codable, Sendable {
    let id: String
    let command: CameraCommand
    let factor: Double?
    let speed: Double?

    static func status(id: String) -> Self {
        Self(id: id, command: .status, factor: nil, speed: nil)
    }

    static func capabilities(id: String) -> Self {
        Self(id: id, command: .capabilities, factor: nil, speed: nil)
    }

    static func setZoom(id: String, factor: Double) -> Self {
        Self(id: id, command: .setZoom, factor: factor, speed: nil)
    }

    static func rampZoom(id: String, factor: Double, speed: Double) -> Self {
        Self(id: id, command: .rampZoom, factor: factor, speed: speed)
    }

    static func stopZoom(id: String) -> Self {
        Self(id: id, command: .stopZoom, factor: nil, speed: nil)
    }
}

struct CameraControlErrorResponse: Codable, Sendable, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

struct CameraStatus: Codable, Sendable, Equatable {
    let factor: Double
    let minFactor: Double
    let maxFactor: Double
    let isRamping: Bool
    let deviceName: String
    let switchOverFactors: [Double]
}

struct CameraControlResponse: Codable, Sendable {
    let id: String?
    let ok: Bool
    let status: CameraStatus?
    let commands: [String]?
    let error: CameraControlErrorResponse?
}
