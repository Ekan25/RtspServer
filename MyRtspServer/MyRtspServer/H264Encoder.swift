import AVFoundation
import VideoToolbox

struct H264Frame {
    let nalUnits: [Data]
    let presentationTime: CMTime
    let isKeyframe: Bool
    let sps: Data?
    let pps: Data?
}

final class H264Encoder {
    private let queue = DispatchQueue(label: "encoder.control", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var forceKeyframe = false
    private var session: VTCompressionSession?
    var onFrame: ((H264Frame) -> Void)?
    var onDrop: (() -> Void)?
    var onError: ((String) -> Void)?

    func start(configuration: VideoStreamConfiguration) throws {
        guard configuration.isValid else { throw StreamError.message("Invalid encoder configuration.") }
        var created: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(configuration.width), height: Int32(configuration.height), codecType: kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { refcon, _, status, flags, sample in
            guard let refcon else { return }
            let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
            defer { encoder.slots.signal() }
            guard status == noErr, !flags.contains(.frameDropped), let sample, CMSampleBufferDataIsReady(sample) else {
                encoder.onDrop?()
                if status != noErr { encoder.onError?("H.264 encoding failed (\(status)).") }
                return
            }
            if let frame = encoder.extract(sample) { encoder.onFrame?(frame) } else { encoder.onDrop?() }
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created)
        guard status == noErr, let created else { throw StreamError.message("Hardware H.264 encoder unavailable (\(status)).") }
        session = created
        do {
            try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, configuration.frameRate as CFNumber)
            try set(kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate as CFNumber)
            try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.keyframeInterval as CFNumber)
            let prepare = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepare == noErr else { throw StreamError.message("Encoder preparation failed (\(prepare)).") }
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            throw error
        }
    }

    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session else { throw StreamError.message("Encoder is not running.") }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw StreamError.message("Encoder property \(key) failed (\(status)).") }
    }

    func updateBitrate(_ bitrate: Int, completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                guard bitrate > 0 else { throw StreamError.message("Bitrate must be positive.") }
                try self.set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
                completion(nil)
            } catch { completion(error) }
        }
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard slots.wait(timeout: .now()) == .success else { onDrop?(); return }
        queue.async {
            guard let session = self.session else { self.slots.signal(); return }
            self.lock.lock()
            let force = self.forceKeyframe
            self.forceKeyframe = false
            self.lock.unlock()
            let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid, frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
            if status != noErr {
                self.slots.signal()
                self.onDrop?()
                self.onError?("Could not submit video frame (\(status)).")
            }
        }
    }

    func stop() {
        queue.sync {
            if let session = self.session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
                self.session = nil
            }
        }
    }

    private func extract(_ sample: CMSampleBuffer) -> H264Frame? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var spsPointer: UnsafePointer<UInt8>?
        var ppsPointer: UnsafePointer<UInt8>?
        var spsSize = 0, ppsSize = 0, lengthSize: Int32 = 0
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &lengthSize)
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard spsStatus == noErr, ppsStatus == noErr, let spsPointer, let ppsPointer, (1...4).contains(lengthSize) else { return nil }
        let count = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: count)
        let copyStatus = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: raw.baseAddress!)
        }
        guard count > 0, copyStatus == kCMBlockBufferNoErr else { return nil }
        var offset = 0
        var units: [Data] = []
        while offset + Int(lengthSize) <= count {
            var size = 0
            for byte in bytes[offset..<(offset + Int(lengthSize))] { size = (size << 8) | Int(byte) }
            offset += Int(lengthSize)
            guard size > 0, size <= count - offset else { return nil }
            units.append(bytes.subdata(in: offset..<(offset + size)))
            offset += size
        }
        guard offset == count, !units.isEmpty else { return nil }
        return H264Frame(nalUnits: units, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample), isKeyframe: units.contains { ($0.first ?? 0) & 0x1f == 5 }, sps: Data(bytes: spsPointer, count: spsSize), pps: Data(bytes: ppsPointer, count: ppsSize))
    }
}