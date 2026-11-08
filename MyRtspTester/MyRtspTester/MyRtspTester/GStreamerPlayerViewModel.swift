import AppKit
import Combine
import Foundation

@MainActor
final class GStreamerPlayerViewModel: NSObject, ObservableObject {
    enum PlaybackState: Equatable {
        case idle
        case connecting
        case playing
        case reconnecting
        case stopped
        case failed

        var label: String {
            switch self {
            case .idle: "Idle"
            case .connecting: "Connecting"
            case .playing: "Playing"
            case .reconnecting: "Reconnecting"
            case .stopped: "Stopped"
            case .failed: "Failed"
            }
        }

        var symbol: String {
            switch self {
            case .playing: "checkmark.circle.fill"
            case .connecting, .reconnecting: "arrow.triangle.2.circlepath.circle"
            case .idle, .stopped: "video.slash"
            case .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    @Published private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var negotiatedWidth = 0
    @Published private(set) var negotiatedHeight = 0
    @Published private(set) var negotiatedFrameRate = 0.0
    @Published private(set) var measuredFrameRate = 0.0
    @Published private(set) var lastFrameTime: Date?
    @Published private(set) var reconnectionCount = 0
    @Published private(set) var lastError: String?
    @Published var transport = "TCP"
    @Published var latencyText: String
    @Published var urlOverride: String
    @Published var stallTimeoutText: String

    private let player = GStreamerVideoPlayer()
    private var host = ""
    private var discoveredURL: String?
    private weak var renderView: NSView?

    init(defaults: UserDefaults = .standard) {
        latencyText = String(defaults.integer(forKey: Keys.latency) == 0 ? 20 : defaults.integer(forKey: Keys.latency))
        urlOverride = defaults.string(forKey: Keys.urlOverride) ?? ""
        stallTimeoutText = String(defaults.double(forKey: Keys.stallTimeout) == 0 ? 3 : defaults.double(forKey: Keys.stallTimeout))
        transport = defaults.string(forKey: Keys.transport) ?? "TCP"
        super.init()
        player.delegate = self
    }

    deinit {
        player.stop()
    }

    var actualResolution: String {
        negotiatedWidth > 0 && negotiatedHeight > 0 ? "\(negotiatedWidth) × \(negotiatedHeight)" : "Unknown"
    }

    var currentURL: String {
        let override = urlOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return override
        }
        if let discoveredURL {
            return discoveredURL
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHost.isEmpty ? "" : "rtsp://\(trimmedHost):8554/camera"
    }

    func updateHost(_ host: String) {
        let newHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.host != newHost else { return }
        self.host = newHost
        if playbackState == .playing || playbackState == .connecting || playbackState == .reconnecting {
            start()
        }
    }

    func updateDiscoveredURL(_ url: String?) {
        let trimmedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newURL = trimmedURL?.isEmpty == false ? trimmedURL : nil
        guard discoveredURL != newURL else { return }
        discoveredURL = newURL
        if playbackState == .playing || playbackState == .connecting || playbackState == .reconnecting {
            start()
        }
    }

    func attachRenderView(_ view: NSView) {
        renderView = view
        player.setRenderView(view)
    }

    func detachRenderView() {
        renderView = nil
        player.setRenderView(nil)
    }

    func start() {
        let url = currentURL
        guard !url.isEmpty else {
            lastError = "Enter a camera address or an RTSP URL."
            playbackState = .failed
            return
        }
        guard let latency = Int(latencyText), latency >= 0 else {
            lastError = "RTSP latency must be zero or greater."
            playbackState = .failed
            return
        }
        guard let stallTimeout = Double(stallTimeoutText), stallTimeout >= 1 else {
            lastError = "Frame stall timeout must be at least one second."
            playbackState = .failed
            return
        }
        guard let renderView else {
            lastError = "The embedded video view is not available."
            playbackState = .failed
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(latency, forKey: Keys.latency)
        defaults.set(urlOverride, forKey: Keys.urlOverride)
        defaults.set(stallTimeout, forKey: Keys.stallTimeout)
        defaults.set(transport, forKey: Keys.transport)
        lastError = nil
        player.start(withURLString: url, transport: transport, latencyMilliseconds: latency,
                     stallTimeoutSeconds: stallTimeout, renderView: renderView)
    }

    func stop() {
        player.stop()
    }

    func reconnect() {
        lastError = nil
        if playbackState == .idle || playbackState == .stopped || playbackState == .failed {
            start()
        } else {
            player.reconnect()
        }
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private enum Keys {
        static let latency = "gstreamerVideo.latencyMilliseconds"
        static let urlOverride = "gstreamerVideo.urlOverride"
        static let stallTimeout = "gstreamerVideo.stallTimeoutSeconds"
        static let transport = "gstreamerVideo.transport"
    }
}

extension GStreamerPlayerViewModel: GStreamerVideoPlayerDelegate {
    func videoPlayer(_ player: GStreamerVideoPlayer, didChange state: GStreamerVideoPlayerState) {
        switch state {
        case .idle:
            playbackState = .idle
        case .connecting:
            playbackState = .connecting
        case .playing:
            playbackState = .playing
        case .reconnecting:
            playbackState = .reconnecting
            reconnectionCount += 1
        case .stopped:
            playbackState = .stopped
        case .failed:
            playbackState = .failed
        @unknown default:
            playbackState = .failed
        }
    }

    func videoPlayer(_ player: GStreamerVideoPlayer, didUpdateVideoWidth width: Int, height: Int, frameRate: Double) {
        negotiatedWidth = width
        negotiatedHeight = height
        negotiatedFrameRate = frameRate
    }

    func videoPlayer(_ player: GStreamerVideoPlayer, didUpdateMeasuredFrameRate frameRate: Double, lastFrameTime: Date) {
        measuredFrameRate = frameRate
        self.lastFrameTime = lastFrameTime
    }

    func videoPlayer(_ player: GStreamerVideoPlayer, didReceiveError message: String) {
        lastError = message
    }
}
