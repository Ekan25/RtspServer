import Foundation
import UIKit

final class RemoteCameraController: CameraRemoteControlling {
    private let camera: CameraCapture
    private let encoder: H264Encoder
    private let server: RTSPServer
    private let imageTransfer: ImageTransferServer
    private let stateLock = NSLock()
    private var configuration: VideoStreamConfiguration
    private var effectiveBitrate: Int?
    var configurationDidChange: ((VideoStreamConfiguration) -> Void)?

    init(camera: CameraCapture, encoder: H264Encoder, server: RTSPServer, imageTransfer: ImageTransferServer, configuration: VideoStreamConfiguration) {
        self.camera = camera
        self.encoder = encoder
        self.server = server
        self.imageTransfer = imageTransfer
        self.configuration = configuration
        effectiveBitrate = encoder.effectiveBitrate()
    }

    func status() throws -> CameraStatus {
        let configuration = currentConfiguration()
        return .init(camera: try camera.cameraDescriptor(), videoMode: try camera.activeVideoMode(), bitrate: configuration.bitrate,
                     effectiveBitrate: currentEffectiveBitrate(), zoom: try camera.zoomStatus(), focus: try camera.focusStatus(),
                     torch: try camera.torchStatus(), keepAwake: try keepAwakeStatus())
    }

    func capabilities() throws -> CameraCapabilities {
        let commands = [
            "status", "capabilities", "getStatus", "getCapabilities", "setZoom", "rampZoom", "stopZoom",
            "getVideoModes", "setVideoMode", "getQuality", "setQuality", "getKeepAwake", "setKeepAwake",
            "setFocusMode", "setFocus", "getCameras", "setCamera", "getZoomCapabilities", "setTorch", "setTorchLevel",
            "capturePhoto"
        ]
        return .init(commands: commands, status: try status(), cameras: camera.availableCameras(), videoModes: try camera.supportedVideoModes(),
                     focus: try camera.focusStatus(), torch: try camera.torchStatus(), zoom: try camera.zoomStatus())
    }

    func videoModes() throws -> [CameraVideoMode] { try camera.supportedVideoModes() }

    func setVideoMode(width: Int, height: Int, frameRate: Double) throws -> CameraStatus {
        guard frameRate.rounded() == frameRate else {
            throw CameraControlError(code: "invalid_parameters", message: "Frame rate must be a whole number.")
        }
        guard try camera.supportedVideoModes().contains(where: {
            $0.width == width && $0.height == height && $0.minFrameRate <= frameRate && frameRate <= $0.maxFrameRate
        }) else {
            throw CameraControlError(code: "unsupported_video_mode", message: "Requested video mode is not supported by the active camera.")
        }
        server.disconnectClientsForReconfiguration()
        encoder.stop()
        do {
            let configuration = try camera.setVideoMode(width: width, height: height, frameRate: frameRate)
            try encoder.start(configuration: configuration)
            encoder.requestKeyframe()
            updateConfiguration(configuration)
            effectiveBitrate = encoder.effectiveBitrate()
            return try status()
        } catch {
            // The old encoder session cannot safely resume after a failed format transition.
            throw error
        }
    }

    func quality() throws -> (requested: Int, effective: Int?) {
        let configuration = currentConfiguration()
        return (configuration.bitrate, currentEffectiveBitrate())
    }

    func setQuality(bitrate: Int) throws -> (requested: Int, effective: Int?) {
        guard bitrate > 0 else { throw CameraControlError(code: "invalid_parameters", message: "Bitrate must be positive.") }
        let effective = try encoder.updateBitrate(bitrate)
        var configuration = currentConfiguration()
        configuration.bitrate = bitrate
        updateConfiguration(configuration)
        stateLock.lock()
        effectiveBitrate = effective
        stateLock.unlock()
        return (bitrate, effective)
    }

    func cameras() throws -> [CameraDescriptor] { camera.availableCameras() }

    func setCamera(position: String) throws -> CameraStatus {
        let old = currentConfiguration()
        server.disconnectClientsForReconfiguration()
        let updated = try camera.switchCamera(position: position)
        if old.width != updated.width || old.height != updated.height || old.frameRate != updated.frameRate {
            encoder.stop()
            do {
                try encoder.start(configuration: updated)
                effectiveBitrate = encoder.effectiveBitrate()
            } catch {
                throw error
            }
        }
        encoder.requestKeyframe()
        updateConfiguration(updated)
        return try status()
    }

    func zoomStatus() throws -> CameraZoomStatus { try camera.zoomStatus() }
    func setZoom(factor: Double, rate: Float?, owner: UUID) throws -> CameraZoomStatus {
        try camera.setZoom(factor: factor, rate: rate, owner: owner)
    }
    func stopZoom(owner: UUID?) throws -> CameraZoomStatus { try camera.stopZoom(owner: owner) }
    func focusStatus() throws -> CameraFocusStatus { try camera.focusStatus() }
    func setFocusMode(_ mode: String) throws -> CameraFocusStatus { try camera.setFocusMode(mode) }
    func setFocus(position: Float) throws -> CameraFocusStatus { try camera.setFocus(position: position) }
    func torchStatus() throws -> CameraTorchStatus { try camera.torchStatus() }
    func setTorch(enabled: Bool) throws -> CameraTorchStatus { try camera.setTorch(enabled: enabled) }
    func setTorch(level: Float) throws -> CameraTorchStatus { try camera.setTorch(level: level) }

    func keepAwakeStatus() throws -> CameraKeepAwakeStatus {
        let enabled = DispatchQueue.main.sync { UIApplication.shared.isIdleTimerDisabled }
        return .init(enabled: enabled)
    }

    func setKeepAwake(enabled: Bool) throws -> CameraKeepAwakeStatus {
        DispatchQueue.main.sync {
            UserDefaults.standard.set(enabled, forKey: Self.keepAwakeDefaultsKey)
            UIApplication.shared.isIdleTimerDisabled = enabled
        }
        return .init(enabled: enabled)
    }

    func capturePhoto(format: PhotoFormat, completion: @escaping (Result<PhotoTransferInfo, CameraControlError>) -> Void) {
        camera.capturePhoto(format: format) { [imageTransfer] result in
            completion(result.map { imageTransfer.register($0) })
        }
    }

    static func applySavedKeepAwakePreference() {
        let enabled = UserDefaults.standard.bool(forKey: keepAwakeDefaultsKey)
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = enabled
        } else {
            DispatchQueue.main.sync { UIApplication.shared.isIdleTimerDisabled = enabled }
        }
    }

    private func currentConfiguration() -> VideoStreamConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return configuration
    }

    private func currentEffectiveBitrate() -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return effectiveBitrate
    }

    private func updateConfiguration(_ configuration: VideoStreamConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        stateLock.unlock()
        configurationDidChange?(configuration)
    }

    private static let keepAwakeDefaultsKey = "cameraControl.keepAwake"
}
