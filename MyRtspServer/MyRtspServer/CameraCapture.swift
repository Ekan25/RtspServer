import AVFoundation

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private let configurationQueue = DispatchQueue(label: "camera.configuration", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var rampOwner: UUID?
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onDrop: (() -> Void)?

    func start(configuration: VideoStreamConfiguration) throws {
        try configurationQueue.sync { try configure(configuration: configuration) }
    }

    private func configure(configuration: VideoStreamConfiguration) throws {
        guard configuration.isValid else { throw StreamError.message("Invalid video configuration.") }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        var selection: (AVCaptureDevice, AVCaptureDevice.Format)?
        for type in types {
            for candidate in discovery.devices where candidate.deviceType == type {
                if let format = candidate.formats.first(where: { format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return dimensions.width == configuration.width && dimensions.height == configuration.height &&
                        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(configuration.frameRate) && $0.maxFrameRate >= Double(configuration.frameRate) }
                }) {
                    selection = (candidate, format)
                    break
                }
            }
            if selection != nil { break }
        }
        guard let (device, format) = selection else {
            throw StreamError.message("Camera does not support \(configuration.width)×\(configuration.height) at \(configuration.frameRate) fps.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw StreamError.message("Unable to configure the camera capture session.")
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        try device.lockForConfiguration()
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        self.device = device
    }

    func run() { configurationQueue.sync { session.startRunning() } }

    func stop(retainDevice: Bool = false) {
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
            if !retainDevice { device = nil }
        }
    }

    private func snapshot(_ device: AVCaptureDevice) -> CameraZoomStatus {
        CameraZoomStatus(factor: Double(device.videoZoomFactor), minFactor: Double(device.minAvailableVideoZoomFactor),
                         maxFactor: Double(min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)),
                         isRamping: device.isRampingVideoZoom, deviceName: device.localizedName,
                         switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue })
    }

    private func withDevice<T>(_ body: (AVCaptureDevice) throws -> T) throws -> T {
        try configurationQueue.sync {
            guard let device else { throw CameraControlError(code: "unavailable", message: "Camera is not available.") }
            return try body(device)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onDrop?()
    }
}

extension CameraCapture: CameraZoomControlling {
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
}

enum StreamError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
