import AVFoundation

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private let configurationQueue = DispatchQueue(label: "camera.configuration", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var configuration: VideoStreamConfiguration?
    private var rampOwner: UUID?
    var onFrame: ((CVPixelBuffer, CMTime, FrameTrace) -> Void)?
    var onDrop: (() -> Void)?
    var makeTrace: (() -> FrameTrace)?

    func start(configuration: VideoStreamConfiguration) throws {
        try configurationQueue.sync {
            guard self.configuration == nil else { throw StreamError.message("Camera capture is already configured.") }
            let device = try selectDevice(position: .back)
            let format = try findFormat(on: device, width: configuration.width, height: configuration.height, frameRate: Double(configuration.frameRate))
            try install(device: device, format: format, configuration: configuration, replacingInput: true)
        }
    }

    func run() { configurationQueue.sync { session.startRunning() } }

    func stop() {
        configurationQueue.sync {
            if let device, device.isRampingVideoZoom, (try? device.lockForConfiguration()) != nil {
                device.cancelVideoZoomRamp()
                device.unlockForConfiguration()
            }
            rampOwner = nil
            session.stopRunning()
            output.setSampleBufferDelegate(nil, queue: nil)
            captureQueue.sync { }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            device = nil
            input = nil
            configuration = nil
        }
    }

    func supportedVideoModes() throws -> [CameraVideoMode] {
        try withDevice { Self.modes(for: $0) }
    }

    func activeVideoMode() throws -> CameraVideoMode {
        try withDevice { device in
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let frameRate = 1 / max(device.activeVideoMinFrameDuration.seconds, 0.000_001)
            return .init(width: Int(dimensions.width), height: Int(dimensions.height), minFrameRate: frameRate, maxFrameRate: frameRate, frameRate: frameRate)
        }
    }

    func setVideoMode(width: Int, height: Int, frameRate: Double) throws -> VideoStreamConfiguration {
        try configurationQueue.sync {
            guard let device, var configuration else { throw unavailable() }
            let format = try findFormat(on: device, width: width, height: height, frameRate: frameRate)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1_000_000, timescale: CMTimeScale((frameRate * 1_000_000).rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.frameRate = Int(frameRate.rounded())
            self.configuration = configuration
            return configuration
        }
    }

    func availableCameras() -> [CameraDescriptor] {
        Self.cameraDescriptors()
    }

    func switchCamera(position: String) throws -> VideoStreamConfiguration {
        try configurationQueue.sync {
            guard let current = configuration else { throw unavailable() }
            let requestedPosition: AVCaptureDevice.Position = position == "front" ? .front : .back
            let replacement = try selectDevice(position: requestedPosition)
            var updated = current
            let format: AVCaptureDevice.Format
            if let supported = try? findFormat(on: replacement, width: current.width, height: current.height, frameRate: Double(current.frameRate)) {
                format = supported
            } else if let fallback = Self.modes(for: replacement).first,
                      let selected = try? findFormat(on: replacement, width: fallback.width, height: fallback.height, frameRate: fallback.maxFrameRate) {
                format = selected
                updated.width = fallback.width
                updated.height = fallback.height
                updated.frameRate = Int(fallback.maxFrameRate.rounded())
            } else {
                throw CameraControlError(code: "unavailable", message: "Selected camera has no supported video modes.")
            }
            try install(device: replacement, format: format, configuration: updated, replacingInput: true)
            return updated
        }
    }

    func cameraDescriptor() throws -> CameraDescriptor {
        try withDevice { Self.descriptor(for: $0) }
    }

    func zoomStatus() throws -> CameraZoomStatus { try withDevice { snapshot($0) } }

    func setZoom(factor: Double, rate: Float?, owner: UUID) throws -> CameraZoomStatus {
        try withDevice { device in
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let status = snapshot(device)
            guard factor.isFinite, factor >= status.minFactor, factor <= status.maxFactor else {
                throw CameraControlError(code: "out_of_range", message: "Zoom factor is outside the current device limits.")
            }
            if let rate {
                device.ramp(toVideoZoomFactor: CGFloat(factor), withRate: rate)
                rampOwner = owner
            } else {
                device.videoZoomFactor = CGFloat(factor)
                rampOwner = nil
            }
            return snapshot(device)
        }
    }

    func stopZoom(owner: UUID?) throws -> CameraZoomStatus {
        try withDevice { device in
            if owner == nil || owner == rampOwner {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.unlockForConfiguration()
                rampOwner = nil
            }
            return snapshot(device)
        }
    }

    func focusStatus() throws -> CameraFocusStatus {
        try withDevice { Self.focusSnapshot($0) }
    }

    func setFocusMode(_ mode: String) throws -> CameraFocusStatus {
        try withDevice { device in
            let target: AVCaptureDevice.FocusMode
            switch mode {
            case "auto": target = .autoFocus
            case "continuous": target = .continuousAutoFocus
            case "manual":
                guard device.isLockingFocusWithCustomLensPositionSupported else {
                    throw CameraControlError(code: "unavailable", message: "Manual focus is not supported by the active camera.")
                }
                target = .locked
            default: throw CameraControlError(code: "invalid_parameters", message: "Unsupported focus mode.")
            }
            guard device.isFocusModeSupported(target) else {
                throw CameraControlError(code: "unavailable", message: "Focus mode is not supported by the active camera.")
            }
            try device.lockForConfiguration()
            if target == .locked {
                device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
            } else {
                device.focusMode = target
            }
            device.unlockForConfiguration()
            return Self.focusSnapshot(device)
        }
    }

    func setFocus(position: Float) throws -> CameraFocusStatus {
        try withDevice { device in
            guard position.isFinite, (0...1).contains(position), device.isLockingFocusWithCustomLensPositionSupported else {
                throw CameraControlError(code: "unavailable", message: "Manual focus is not supported by the active camera.")
            }
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
            device.unlockForConfiguration()
            return Self.focusSnapshot(device)
        }
    }

    func torchStatus() throws -> CameraTorchStatus {
        try withDevice { Self.torchSnapshot($0) }
    }

    func setTorch(enabled: Bool) throws -> CameraTorchStatus {
        try withDevice { device in
            guard device.hasTorch, device.isTorchModeSupported(enabled ? .on : .off) else {
                throw CameraControlError(code: "unavailable", message: "Torch is not supported by the active camera.")
            }
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            return Self.torchSnapshot(device)
        }
    }

    func setTorch(level: Float) throws -> CameraTorchStatus {
        try withDevice { device in
            guard device.hasTorch, device.isTorchModeSupported(.on), level.isFinite, level >= 0, level <= 1 else {
                throw CameraControlError(code: "out_of_range", message: "Torch level is not supported by the active camera.")
            }
            try device.lockForConfiguration()
            if level == 0 {
                device.torchMode = .off
            } else {
                try device.setTorchModeOn(level: level)
            }
            device.unlockForConfiguration()
            return Self.torchSnapshot(device)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let trace = makeTrace?() else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), trace)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onDrop?()
    }

    private func install(device: AVCaptureDevice, format: AVCaptureDevice.Format, configuration: VideoStreamConfiguration, replacingInput: Bool) throws {
        let replacementInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if replacingInput {
            if let input { session.removeInput(input) }
            guard session.canAddInput(replacementInput) else {
                throw StreamError.message("Unable to configure the camera capture session.")
            }
            session.addInput(replacementInput)
            input = replacementInput
        }
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw StreamError.message("Unable to configure the camera capture session.") }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            session.addOutput(output)
            if let connection = output.connection(with: .video), connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        self.device = device
        self.configuration = configuration
    }

    private func findFormat(on device: AVCaptureDevice, width: Int, height: Int, frameRate: Double) throws -> AVCaptureDevice.Format {
        guard let format = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == width && dimensions.height == height &&
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= frameRate && frameRate <= $0.maxFrameRate }
        }) else {
            throw CameraControlError(code: "unsupported_video_mode", message: "Camera does not support \(width)×\(height) at \(frameRate) fps.")
        }
        return format
    }

    private func selectDevice(position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) { return device }
        }
        throw CameraControlError(code: "unavailable", message: "Requested camera is not available.")
    }

    private func withDevice<T>(_ body: (AVCaptureDevice) throws -> T) throws -> T {
        try configurationQueue.sync {
            guard let device else { throw unavailable() }
            return try body(device)
        }
    }

    private func snapshot(_ device: AVCaptureDevice) -> CameraZoomStatus {
        let maximum = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)
        return .init(factor: Double(device.videoZoomFactor), minFactor: Double(device.minAvailableVideoZoomFactor),
                     maxFactor: Double(maximum), isRamping: device.isRampingVideoZoom, deviceName: device.localizedName,
                     switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue },
                     supportsContinuousZoom: maximum > device.minAvailableVideoZoomFactor)
    }

    private static func modes(for device: AVCaptureDevice) -> [CameraVideoMode] {
        var modes = Set<CameraVideoMode>()
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate > 0 {
                modes.insert(.init(width: Int(dimensions.width), height: Int(dimensions.height), minFrameRate: range.minFrameRate, maxFrameRate: range.maxFrameRate, frameRate: nil))
            }
        }
        return modes.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.maxFrameRate < $1.maxFrameRate
        }
    }

    private static func cameraDescriptors() -> [CameraDescriptor] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            .map(descriptor(for:))
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.name < $1.name
            }
    }

    private static func descriptor(for device: AVCaptureDevice) -> CameraDescriptor {
        .init(id: device.uniqueID, name: device.localizedName,
              position: device.position == .front ? "front" : "back",
              isVirtual: device.isVirtualDevice)
    }

    private static func focusModeName(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .autoFocus: return "auto"
        case .continuousAutoFocus: return "continuous"
        case .locked: return "manual"
        @unknown default: return "unknown"
        }
    }

    private static func focusSnapshot(_ device: AVCaptureDevice) -> CameraFocusStatus {
        .init(
            mode: focusModeName(device.focusMode),
            lensPosition: device.isLockingFocusWithCustomLensPositionSupported ? device.lensPosition : nil,
            supportsAuto: device.isFocusModeSupported(.autoFocus),
            supportsContinuous: device.isFocusModeSupported(.continuousAutoFocus),
            supportsManual: device.isLockingFocusWithCustomLensPositionSupported
        )
    }

    private static func torchSnapshot(_ device: AVCaptureDevice) -> CameraTorchStatus {
        let enabled = device.torchMode == .on
        return .init(available: device.hasTorch && device.isTorchModeSupported(.on), enabled: enabled, level: enabled ? device.torchLevel : nil)
    }

    private func unavailable() -> CameraControlError {
        CameraControlError(code: "unavailable", message: "Camera is not available.")
    }
}

enum StreamError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
