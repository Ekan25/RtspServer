import Foundation

struct CameraZoomStatus: Codable {
    let factor: Double
    let minFactor: Double
    let maxFactor: Double
    let isRamping: Bool
    let deviceName: String
    let switchOverFactors: [Double]
}

struct CameraStreamStatus: Codable {
    let state: String
    let isReady: Bool
    let isStreaming: Bool
}

final class CameraStreamCommandBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var state = "stopped"
    private var startHandler: (() -> Void)?
    private var stopHandler: (() -> Void)?

    func setHandlers(start: @escaping () -> Void, stop: @escaping () -> Void) {
        lock.lock()
        startHandler = start
        stopHandler = stop
        lock.unlock()
    }

    func update(state: String) {
        lock.lock()
        self.state = state
        lock.unlock()
    }

    func status() -> CameraStreamStatus {
        lock.lock()
        let current = state
        lock.unlock()
        return CameraStreamStatus(state: current, isReady: current == "ready", isStreaming: current == "ready" || current == "starting" || current == "stopping")
    }

    func start() {
        lock.lock()
        guard state != "ready" && state != "starting" && state != "stopping" else {
            lock.unlock()
            return
        }
        state = "starting"
        let handler = startHandler
        lock.unlock()
        handler?()
    }

    func stop() {
        lock.lock()
        guard state != "stopped" && state != "stopping" else {
            lock.unlock()
            return
        }
        if state == "error" {
            state = "stopped"
            lock.unlock()
            return
        }
        state = "stopping"
        let handler = stopHandler
        lock.unlock()
        handler?()
    }
}

struct CameraControlError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

protocol CameraZoomControlling: AnyObject {
    func zoomStatus() throws -> CameraZoomStatus
    func setZoom(factor: Double, rate: Float?, owner: UUID) throws -> CameraZoomStatus
    // A nil owner is an explicit stop; otherwise only the matching ramp is stopped.
    func stopZoom(owner: UUID?) throws -> CameraZoomStatus
}

struct CameraCommand: Decodable {
    let id: String?
    let command: String
    let factor: Double?
    let speed: Double?
}

struct CameraResponse: Encodable {
    struct Failure: Encodable { let code: String; let message: String }
    let id: String?
    let ok: Bool
    let status: CameraZoomStatus?
    let streamStatus: CameraStreamStatus?
    let commands: [String]?
    let error: Failure?
}

final class CameraCommandHandler {
    private let camera: CameraZoomControlling
    private let stream: CameraStreamCommandBridge
    init(camera: CameraZoomControlling, stream: CameraStreamCommandBridge) {
        self.camera = camera
        self.stream = stream
    }

    func handle(_ data: Data, client: UUID) -> CameraResponse {
        var id: String?
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CameraControlError(code: "invalid_request", message: "Expected a JSON object.")
            }
            id = object["id"] as? String
            guard Set(object.keys).isSubset(of: ["id", "command", "factor", "speed"]) else {
                throw CameraControlError(code: "invalid_request", message: "Unknown request field.")
            }
            let request = try JSONDecoder().decode(CameraCommand.self, from: data)
            id = request.id
            let status: CameraZoomStatus
            var streamStatus: CameraStreamStatus?
            var commands: [String]?
            switch request.command {
            case "status", "capabilities":
                guard request.factor == nil, request.speed == nil else { throw invalidParameters() }
                status = try camera.zoomStatus()
                streamStatus = stream.status()
                if request.command == "capabilities" { commands = ["status", "capabilities", "setZoom", "rampZoom", "stopZoom", "startStream", "stopStream"] }
            case "startStream":
                guard request.factor == nil, request.speed == nil else { throw invalidParameters() }
                status = try camera.zoomStatus()
                stream.start()
                streamStatus = stream.status()
            case "stopStream":
                guard request.factor == nil, request.speed == nil else { throw invalidParameters() }
                status = try camera.zoomStatus()
                stream.stop()
                streamStatus = stream.status()
            case "setZoom", "rampZoom":
                guard let factor = request.factor, factor.isFinite, factor > 0 else { throw invalidParameters() }
                let rate: Float?
                if request.command == "rampZoom" {
                    guard let speed = request.speed, speed.isFinite, speed > 0, speed <= Double(Float.greatestFiniteMagnitude), Float(speed) > 0 else { throw invalidParameters() }
                    rate = Float(speed)
                } else {
                    guard request.speed == nil else { throw invalidParameters() }
                    rate = nil
                }
                status = try camera.setZoom(factor: factor, rate: rate, owner: client)
            case "stopZoom":
                guard request.factor == nil, request.speed == nil else { throw invalidParameters() }
                status = try camera.stopZoom(owner: nil)
            default:
                throw CameraControlError(code: "unknown_command", message: "Unknown command.")
            }
            return CameraResponse(id: id, ok: true, status: status, streamStatus: streamStatus, commands: commands, error: nil)
        } catch {
            let failure = error as? CameraControlError
            let code = failure?.code ?? (error is DecodingError || error is CocoaError ? "invalid_request" : "camera_error")
            let message = failure?.message ?? (code == "invalid_request" ? "Malformed JSON or invalid field types." : error.localizedDescription)
            return CameraResponse(id: id, ok: false, status: nil, streamStatus: nil, commands: nil, error: .init(code: code, message: message))
        }
    }

    func disconnected(_ client: UUID) { _ = try? camera.stopZoom(owner: client) }

    private func invalidParameters() -> CameraControlError {
        CameraControlError(code: "invalid_parameters", message: "Invalid parameters for command.")
    }
}