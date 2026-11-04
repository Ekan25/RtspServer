import Foundation

struct VideoStreamConfiguration: Equatable {
    var width = 1280
    var height = 720
    var frameRate = 30
    var bitrate = 2_000_000
    var keyframeInterval = 30
    var rtpPayloadSize = 1200
    var rtspPort: UInt16 = 8554
    var controlPort: UInt16 = 8555
    var controlInterface = "en0"

    enum Preset: String, CaseIterable, Identifiable {
        case low = "Low", `default` = "Default", high = "High", highFPS = "High FPS"
        var id: String { rawValue }
        var configuration: VideoStreamConfiguration {
            switch self {
            case .low: return .init(width: 640, height: 480, bitrate: 1_000_000)
            case .default: return .init()
            case .high: return .init(width: 1920, height: 1080, bitrate: 4_000_000)
            case .highFPS: return .init(width: 1280, height: 720, frameRate: 60, bitrate: 4_000_000)
            }
        }
    }

    var isValid: Bool {
        width > 0 && height > 0 && width <= Int(Int32.max) && height <= Int(Int32.max) &&
        frameRate > 0 && frameRate <= Int(Int32.max) && bitrate > 0 && keyframeInterval > 0 && rtspPort > 0 &&
        controlPort > 0 && controlPort != rtspPort && !controlInterface.isEmpty &&
        rtpPayloadSize >= 3 && rtpPayloadSize <= 65_523
    }
}
