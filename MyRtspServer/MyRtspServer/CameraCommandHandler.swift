import Foundation

enum CameraRequestID: Codable, Equatable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            throw DecodingError.typeMismatch(
                CameraRequestID.self,
                .init(codingPath: decoder.codingPath, debugDescription: "id must be a string or integer.")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        }
    }
}

struct CameraVideoMode: Codable, Equatable, Hashable {
    let width: Int
    let height: Int
    let minFrameRate: Double
    let maxFrameRate: Double
    let frameRate: Double?
}

struct CameraDescriptor: Codable, Equatable {
    let id: String
    let name: String
    let position: String
    let isVirtual: Bool
}

struct CameraZoomStatus: Codable, Equatable {
    let factor: Double
    let minFactor: Double
    let maxFactor: Double
    let isRamping: Bool
    let deviceName: String
    let switchOverFactors: [Double]
    let supportsContinuousZoom: Bool
}

struct CameraFocusStatus: Codable, Equatable {
    let mode: String
    let lensPosition: Float?
    let supportsAuto: Bool
    let supportsContinuous: Bool
    let supportsManual: Bool
}

struct CameraTorchStatus: Codable, Equatable {
    let available: Bool
    let enabled: Bool
    let level: Float?
}

struct CameraKeepAwakeStatus: Codable, Equatable {
    let enabled: Bool
}

enum CameraStreamState: String, Codable, Equatable {
    case stopped
    case starting
    case running
    case stopping
    case error
}

struct CameraStreamStatus: Codable, Equatable {
    let state: CameraStreamState
    let message: String?
}

struct CameraStatus: Codable, Equatable {
    let camera: CameraDescriptor
    let videoMode: CameraVideoMode
    let bitrate: Int
    let effectiveBitrate: Int?
    let zoom: CameraZoomStatus
    let focus: CameraFocusStatus
    let torch: CameraTorchStatus
    let keepAwake: CameraKeepAwakeStatus
    // Legacy zoom-only status fields retained for existing control clients.
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

struct CameraCapabilities: Codable, Equatable {
    let commands: [String]
    let status: CameraStatus
    let cameras: [CameraDescriptor]
    let videoModes: [CameraVideoMode]
    let focus: CameraFocusStatus
    let torch: CameraTorchStatus
    let zoom: CameraZoomStatus
}

struct CameraControlError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

protocol CameraRemoteControlling: AnyObject {
    func status() throws -> CameraStatus
    func capabilities() throws -> CameraCapabilities
    func videoModes() throws -> [CameraVideoMode]
    func setVideoMode(width: Int, height: Int, frameRate: Double) throws -> CameraStatus
    func quality() throws -> (requested: Int, effective: Int?)
    func setQuality(bitrate: Int) throws -> (requested: Int, effective: Int?)
    func cameras() throws -> [CameraDescriptor]
    func setCamera(position: String) throws -> CameraStatus
    func zoomStatus() throws -> CameraZoomStatus
    func setZoom(factor: Double, rate: Float?, owner: UUID) throws -> CameraZoomStatus
    func stopZoom(owner: UUID?) throws -> CameraZoomStatus
    func focusStatus() throws -> CameraFocusStatus
    func setFocusMode(_ mode: String) throws -> CameraFocusStatus
    func setFocus(position: Float) throws -> CameraFocusStatus
    func torchStatus() throws -> CameraTorchStatus
    func setTorch(enabled: Bool) throws -> CameraTorchStatus
    func setTorch(level: Float) throws -> CameraTorchStatus
    func keepAwakeStatus() throws -> CameraKeepAwakeStatus
    func setKeepAwake(enabled: Bool) throws -> CameraKeepAwakeStatus
}

private struct CameraCommand: Decodable {
    let command: String
    let factor: Double?
    let speed: Double?
    let width: Int?
    let height: Int?
    let fps: Double?
    let bitrate: Int?
    let enabled: Bool?
    let mode: String?
    let position: Double?
    let level: Double?
    let cameraPosition: String?

    enum CodingKeys: String, CodingKey {
        case command, factor, speed, width, height, fps, bitrate, enabled, mode, position, level
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        factor = try container.decodeIfPresent(Double.self, forKey: .factor)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        fps = try container.decodeIfPresent(Double.self, forKey: .fps)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        position = try? container.decode(Double.self, forKey: .position)
        cameraPosition = try? container.decode(String.self, forKey: .position)
        level = try container.decodeIfPresent(Double.self, forKey: .level)
    }
}

struct CameraResponse: Encodable {
    struct Failure: Encodable { let code: String; let message: String }
    let id: CameraRequestID?
    let ok: Bool
    let status: CameraStatus?
    let capabilities: CameraCapabilities?
    let videoModes: [CameraVideoMode]?
    let quality: Quality?
    let cameras: [CameraDescriptor]?
    let zoom: CameraZoomStatus?
    let focus: CameraFocusStatus?
    let torch: CameraTorchStatus?
    let keepAwake: CameraKeepAwakeStatus?
    let stream: CameraStreamStatus?
    let event: String?
    let commands: [String]?
    let error: Failure?

    struct Quality: Encodable {
        let requestedBitrate: Int
        let effectiveBitrate: Int?
    }

    static func success(
        id: CameraRequestID?,
        status: CameraStatus? = nil,
        capabilities: CameraCapabilities? = nil,
        videoModes: [CameraVideoMode]? = nil,
        quality: Quality? = nil,
        cameras: [CameraDescriptor]? = nil,
        zoom: CameraZoomStatus? = nil,
        focus: CameraFocusStatus? = nil,
        torch: CameraTorchStatus? = nil,
        keepAwake: CameraKeepAwakeStatus? = nil,
        commands: [String]? = nil,
        stream: CameraStreamStatus? = nil,
        event: String? = nil
    ) -> Self {
        .init(id: id, ok: true, status: status, capabilities: capabilities, videoModes: videoModes, quality: quality,
              cameras: cameras, zoom: zoom, focus: focus, torch: torch, keepAwake: keepAwake, stream: stream, event: event,
              commands: commands, error: nil)
    }

    static func failure(id: CameraRequestID?, _ error: CameraControlError) -> Self {
        .init(id: id, ok: false, status: nil, capabilities: nil, videoModes: nil, quality: nil, cameras: nil, zoom: nil,
              focus: nil, torch: nil, keepAwake: nil, stream: nil, event: nil, commands: nil,
              error: .init(code: error.code, message: error.message))
    }
}

protocol CameraStreamControlling: AnyObject {
    func startStream(completion: @escaping (Result<CameraStreamStatus, CameraControlError>) -> Void)
    func stopStream(completion: @escaping (Result<CameraStreamStatus, CameraControlError>) -> Void)
    func streamStatus() -> CameraStreamStatus
}

final class CameraCommandHandler {
    private let cameraProvider: () -> CameraRemoteControlling?
    private weak var stream: CameraStreamControlling?
    private let queue = DispatchQueue(label: "camera.control.commands", qos: .userInitiated)

    init(cameraProvider: @escaping () -> CameraRemoteControlling?, stream: CameraStreamControlling) {
        self.cameraProvider = cameraProvider
        self.stream = stream
    }

    func handle(_ data: Data, client: UUID, completion: @escaping (CameraResponse) -> Void) {
        if let streamCommand = Self.streamCommand(data) {
            handle(streamCommand, completion: completion)
            return
        }
        queue.async { [cameraProvider] in
            guard let camera = cameraProvider() else {
                completion(.failure(id: Self.requestID(from: data), CameraControlError(
                    code: "stream_not_running",
                    message: "Camera controls are unavailable while the stream is stopped."
                )))
                return
            }
            completion(Self.handle(data, client: client, camera: camera))
        }
    }

    func disconnected(_ client: UUID) {
        queue.async { [cameraProvider] in _ = try? cameraProvider()?.stopZoom(owner: client) }
    }

    private enum StreamCommand {
        case start(id: CameraRequestID?)
        case stop(id: CameraRequestID?)
        case status(id: CameraRequestID?)
        case invalid(id: CameraRequestID?)

        var id: CameraRequestID? {
            switch self {
            case let .start(id), let .stop(id), let .status(id), let .invalid(id): return id
            }
        }
    }

    private func handle(_ command: StreamCommand, completion: @escaping (CameraResponse) -> Void) {
        guard let stream else {
            completion(.failure(id: command.id, CameraControlError(code: "unavailable", message: "Stream control is unavailable.")))
            return
        }
        switch command {
        case let .start(id):
            stream.startStream { result in
                switch result {
                case let .success(status):
                    completion(.success(id: id, stream: status))
                case let .failure(error):
                    completion(.failure(id: id, error))
                }
            }
        case let .stop(id):
            stream.stopStream { result in
                switch result {
                case let .success(status):
                    completion(.success(id: id, stream: status))
                case let .failure(error):
                    completion(.failure(id: id, error))
                }
            }
        case let .status(id):
            completion(.success(id: id, stream: stream.streamStatus()))
        case let .invalid(id):
            completion(.failure(id: id, Self.invalidParameters()))
        }
    }

    private static func streamCommand(_ data: Data) -> StreamCommand? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else { return nil }
        let id = requestID(from: data)
        let allowed = Set(["id", "command"])
        guard Set(object.keys).isSubset(of: allowed) else {
            switch command {
            case "startStream", "stopStream", "getStreamStatus": return .invalid(id: id)
            default: return nil
            }
        }
        switch command {
        case "startStream": return .start(id: id)
        case "stopStream": return .stop(id: id)
        case "getStreamStatus": return .status(id: id)
        default: return nil
        }
    }

    private static func requestID(from data: Data) -> CameraRequestID? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["id"] else { return nil }
        if let string = rawID as? String { return .string(string) }
        guard let number = rawID as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return nil }
        return .number(number.intValue)
    }

    private static func handle(_ data: Data, client: UUID, camera: CameraRemoteControlling) -> CameraResponse {
        var id: CameraRequestID?
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CameraControlError(code: "invalid_request", message: "Expected a JSON object.")
            }
            let allowed = Set(["id", "command", "factor", "speed", "width", "height", "fps", "bitrate", "enabled", "mode", "position", "level"])
            guard Set(object.keys).isSubset(of: allowed) else {
                throw CameraControlError(code: "invalid_request", message: "Unknown request field.")
            }
            if let rawID = object["id"] {
                if let string = rawID as? String {
                    id = .string(string)
                } else if let number = rawID as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite,
                          number.doubleValue.rounded() == number.doubleValue,
                          number.doubleValue >= Double(Int.min),
                          number.doubleValue <= Double(Int.max) {
                    id = .number(number.intValue)
                } else {
                    throw CameraControlError(code: "invalid_request", message: "id must be a string or integer.")
                }
            }
            let request = try JSONDecoder().decode(CameraCommand.self, from: data)
            switch request.command {
            case "status", "getStatus":
                try noParameters(request)
                return .success(id: id, status: try camera.status())
            case "capabilities", "getCapabilities":
                try noParameters(request)
                let capabilities = try camera.capabilities()
                return .success(id: id, capabilities: capabilities, commands: capabilities.commands)
            case "getVideoModes":
                try noParameters(request)
                return .success(id: id, videoModes: try camera.videoModes())
            case "setVideoMode":
                guard let width = request.width, let height = request.height, let fps = request.fps,
                      width > 0, height > 0, fps.isFinite, fps > 0 else { throw invalidParameters() }
                return .success(id: id, status: try camera.setVideoMode(width: width, height: height, frameRate: fps))
            case "getQuality":
                try noParameters(request)
                let quality = try camera.quality()
                return .success(id: id, quality: .init(requestedBitrate: quality.requested, effectiveBitrate: quality.effective))
            case "setQuality":
                guard let bitrate = request.bitrate, bitrate > 0 else { throw invalidParameters() }
                let quality = try camera.setQuality(bitrate: bitrate)
                return .success(id: id, status: try camera.status(), quality: .init(requestedBitrate: quality.requested, effectiveBitrate: quality.effective))
            case "getKeepAwake":
                try noParameters(request)
                return .success(id: id, keepAwake: try camera.keepAwakeStatus())
            case "setKeepAwake":
                guard let enabled = request.enabled else { throw invalidParameters() }
                let keepAwake = try camera.setKeepAwake(enabled: enabled)
                return .success(id: id, status: try camera.status(), keepAwake: keepAwake)
            case "setFocusMode":
                guard let mode = request.mode else { throw invalidParameters() }
                let focus = try camera.setFocusMode(mode)
                return .success(id: id, status: try camera.status(), focus: focus)
            case "setFocus":
                guard let position = request.position, position.isFinite, position >= 0, position <= 1 else { throw invalidParameters() }
                let focus = try camera.setFocus(position: Float(position))
                return .success(id: id, status: try camera.status(), focus: focus)
            case "getCameras":
                try noParameters(request)
                return .success(id: id, cameras: try camera.cameras())
            case "setCamera":
                guard let position = request.cameraPosition, ["front", "back"].contains(position) else { throw invalidParameters() }
                return .success(id: id, status: try camera.setCamera(position: position))
            case "getZoomCapabilities":
                try noParameters(request)
                return .success(id: id, zoom: try camera.zoomStatus())
            case "setTorch":
                guard let enabled = request.enabled else { throw invalidParameters() }
                let torch = try camera.setTorch(enabled: enabled)
                return .success(id: id, status: try camera.status(), torch: torch)
            case "setTorchLevel":
                guard let level = request.level, level.isFinite, level >= 0, level <= 1 else { throw invalidParameters() }
                let torch = try camera.setTorch(level: Float(level))
                return .success(id: id, status: try camera.status(), torch: torch)
            case "setZoom", "rampZoom":
                guard let factor = request.factor, factor.isFinite, factor > 0 else { throw invalidParameters() }
                let rate: Float?
                if request.command == "rampZoom" {
                    guard let speed = request.speed, speed.isFinite, speed > 0, speed <= Double(Float.greatestFiniteMagnitude) else { throw invalidParameters() }
                    rate = Float(speed)
                } else {
                    guard request.speed == nil else { throw invalidParameters() }
                    rate = nil
                }
                let zoom = try camera.setZoom(factor: factor, rate: rate, owner: client)
                return .success(id: id, status: try camera.status(), zoom: zoom)
            case "stopZoom":
                try noParameters(request)
                let zoom = try camera.stopZoom(owner: nil)
                return .success(id: id, status: try camera.status(), zoom: zoom)
            default:
                throw CameraControlError(code: "unknown_command", message: "Unknown command.")
            }
        } catch {
            let failure = error as? CameraControlError
            let code = failure?.code ?? (error is DecodingError || error is CocoaError ? "invalid_request" : "camera_error")
            return .failure(id: id, CameraControlError(
                code: code,
                message: failure?.message ?? (code == "invalid_request" ? "Malformed JSON or invalid field types." : error.localizedDescription)
            ))
        }
    }

    private static func noParameters(_ request: CameraCommand) throws {
        guard request.factor == nil, request.speed == nil, request.width == nil, request.height == nil, request.fps == nil,
              request.bitrate == nil, request.enabled == nil, request.mode == nil, request.position == nil, request.level == nil,
              request.cameraPosition == nil else { throw invalidParameters() }
    }

    private static func invalidParameters() -> CameraControlError {
        CameraControlError(code: "invalid_parameters", message: "Invalid parameters for command.")
    }
}
