import Foundation

enum CameraCommand: String, Codable, Sendable {
    case status, capabilities, getStatus, getCapabilities
    case setZoom, rampZoom, stopZoom
    case getVideoModes, setVideoMode, getQuality, setQuality
    case getKeepAwake, setKeepAwake
    case setFocusMode, setFocus
    case getCameras, setCamera, getZoomCapabilities
    case setTorch, setTorchLevel
    case startStream, stopStream, getStreamStatus
    case capturePhoto
}

struct CameraControlRequest: Encodable, Sendable {
    let id: String
    let command: CameraCommand
    let factor: Double?
    let speed: Double?
    let width: Int?
    let height: Int?
    let fps: Int?
    let bitrate: Int?
    let enabled: Bool?
    let mode: String?
    let focusPosition: Double?
    let cameraPosition: String?
    let level: Double?
    let format: PhotoFormat?

    static func status(id: String) -> Self { .init(id: id, command: .status) }
    static func capabilities(id: String) -> Self { .init(id: id, command: .capabilities) }
    static func setZoom(id: String, factor: Double) -> Self { .init(id: id, command: .setZoom, factor: factor) }
    static func rampZoom(id: String, factor: Double, speed: Double) -> Self { .init(id: id, command: .rampZoom, factor: factor, speed: speed) }
    static func stopZoom(id: String) -> Self { .init(id: id, command: .stopZoom) }
    static func setVideoMode(id: String, mode: CameraVideoMode) -> Self {
        .init(id: id, command: .setVideoMode, width: mode.width, height: mode.height, fps: Int(mode.maxFrameRate.rounded()))
    }
    static func setQuality(id: String, bitrate: Int) -> Self { .init(id: id, command: .setQuality, bitrate: bitrate) }
    static func setKeepAwake(id: String, enabled: Bool) -> Self { .init(id: id, command: .setKeepAwake, enabled: enabled) }
    static func setFocusMode(id: String, mode: String) -> Self { .init(id: id, command: .setFocusMode, mode: mode) }
    static func setFocus(id: String, position: Double) -> Self { .init(id: id, command: .setFocus, focusPosition: position) }
    static func setCamera(id: String, position: String) -> Self { .init(id: id, command: .setCamera, cameraPosition: position) }
    static func setTorch(id: String, enabled: Bool) -> Self { .init(id: id, command: .setTorch, enabled: enabled) }
    static func setTorchLevel(id: String, level: Double) -> Self { .init(id: id, command: .setTorchLevel, level: level) }

    init(id: String, command: CameraCommand, factor: Double? = nil, speed: Double? = nil, width: Int? = nil,
         height: Int? = nil, fps: Int? = nil, bitrate: Int? = nil, enabled: Bool? = nil, mode: String? = nil,
         focusPosition: Double? = nil, cameraPosition: String? = nil, level: Double? = nil, format: PhotoFormat? = nil) {
        self.id = id; self.command = command; self.factor = factor; self.speed = speed; self.width = width; self.height = height
        self.fps = fps; self.bitrate = bitrate; self.enabled = enabled; self.mode = mode; self.focusPosition = focusPosition
        self.cameraPosition = cameraPosition; self.level = level
        self.format = format
    }

    enum CodingKeys: String, CodingKey {
        case id, command, factor, speed, width, height, fps, bitrate, enabled, mode, position, level, format
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(factor, forKey: .factor)
        try container.encodeIfPresent(speed, forKey: .speed)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(fps, forKey: .fps)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(focusPosition, forKey: .position)
        try container.encodeIfPresent(cameraPosition, forKey: .position)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(format, forKey: .format)
    }
}

enum PhotoFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case jpeg, bgra
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

struct PhotoTransferInfo: Codable, Sendable {
    let transferId: String
    let transferHost: String
    let transferPort: UInt16
    let transferToken: String
    let format: PhotoFormat
}

struct CameraControlErrorResponse: Codable, Sendable, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct CameraVideoMode: Codable, Sendable, Equatable, Hashable, Identifiable {
    let width: Int
    let height: Int
    let minFrameRate: Double
    let maxFrameRate: Double
    let frameRate: Double?
    var id: String { "\(width)x\(height)-\(minFrameRate)-\(maxFrameRate)" }
    var label: String { "\(width) × \(height) (\(Int(maxFrameRate.rounded())) fps)" }
}

struct CameraDescriptor: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let position: String
    let isVirtual: Bool
}

struct CameraZoomStatus: Codable, Sendable, Equatable {
    let factor: Double
    let minFactor: Double
    let maxFactor: Double
    let isRamping: Bool
    let deviceName: String
    let switchOverFactors: [Double]
    let supportsContinuousZoom: Bool
}

struct CameraFocusStatus: Codable, Sendable, Equatable {
    let mode: String
    let lensPosition: Float?
    let supportsAuto: Bool
    let supportsContinuous: Bool
    let supportsManual: Bool
}

struct CameraTorchStatus: Codable, Sendable, Equatable {
    let available: Bool
    let enabled: Bool
    let level: Float?
}

struct CameraKeepAwakeStatus: Codable, Sendable, Equatable {
    let enabled: Bool
}

enum CameraStreamState: String, Codable, Sendable, Equatable {
    case stopped, starting, running, stopping, error
}

struct CameraStreamStatus: Codable, Sendable, Equatable {
    let state: CameraStreamState
    let message: String?
}

struct CameraStatus: Codable, Sendable, Equatable {
    let camera: CameraDescriptor
    let videoMode: CameraVideoMode
    let bitrate: Int
    let effectiveBitrate: Int?
    let zoom: CameraZoomStatus
    let focus: CameraFocusStatus
    let torch: CameraTorchStatus
    let keepAwake: CameraKeepAwakeStatus
    let factor: Double
    let minFactor: Double
    let maxFactor: Double
    let isRamping: Bool
    let deviceName: String
    let switchOverFactors: [Double]

    init(camera: CameraDescriptor, videoMode: CameraVideoMode, bitrate: Int, effectiveBitrate: Int?, zoom: CameraZoomStatus,
         focus: CameraFocusStatus, torch: CameraTorchStatus, keepAwake: CameraKeepAwakeStatus) {
        self.camera = camera; self.videoMode = videoMode; self.bitrate = bitrate; self.effectiveBitrate = effectiveBitrate
        self.zoom = zoom; self.focus = focus; self.torch = torch; self.keepAwake = keepAwake
        factor = zoom.factor; minFactor = zoom.minFactor; maxFactor = zoom.maxFactor; isRamping = zoom.isRamping
        deviceName = zoom.deviceName; switchOverFactors = zoom.switchOverFactors
    }
}

struct CameraCapabilities: Codable, Sendable, Equatable {
    let commands: [String]
    let status: CameraStatus
    let cameras: [CameraDescriptor]
    let videoModes: [CameraVideoMode]
    let focus: CameraFocusStatus
    let torch: CameraTorchStatus
    let zoom: CameraZoomStatus
}

struct CameraQuality: Codable, Sendable, Equatable {
    let requestedBitrate: Int
    let effectiveBitrate: Int?
}

struct CameraControlResponse: Codable, Sendable {
    let id: String?
    let ok: Bool
    let status: CameraStatus?
    let capabilities: CameraCapabilities?
    let videoModes: [CameraVideoMode]?
    let quality: CameraQuality?
    let cameras: [CameraDescriptor]?
    let zoom: CameraZoomStatus?
    let focus: CameraFocusStatus?
    let torch: CameraTorchStatus?
    let keepAwake: CameraKeepAwakeStatus?
    let stream: CameraStreamStatus?
    let event: String?
    let commands: [String]?
    let error: CameraControlErrorResponse?
    let photo: PhotoTransferInfo?
}
