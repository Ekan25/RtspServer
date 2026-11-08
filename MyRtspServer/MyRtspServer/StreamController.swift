import AVFoundation
import Combine
import Darwin
import Foundation

private final class StreamCounters {
    private let lock = NSLock()
    private var frames = 0, bytes = 0, drops = 0
    func frame(bytes: Int) { lock.lock(); frames += 1; self.bytes += bytes; lock.unlock() }
    func drop() { lock.lock(); drops += 1; lock.unlock() }
    func take() -> (Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (frames, bytes, drops); frames = 0; bytes = 0; drops = 0; return result
    }
}

@MainActor
final class StreamController: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var isBusy = false
    @Published private(set) var clientCount = 0
    @Published private(set) var actualFrameRate = 0.0
    @Published private(set) var actualBitrate = 0.0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var url = ""
    @Published private(set) var controlAddress = ""
    @Published var preset: VideoStreamConfiguration.Preset = .default
    @Published private(set) var configuration = VideoStreamConfiguration()

    private let worker = DispatchQueue(label: "stream.lifecycle", qos: .userInitiated)
    private let counters = StreamCounters()
    private let streamCommands = CameraStreamCommandBridge()
    // Accessed only by worker.
    private var camera: CameraCapture?
    private var encoder: H264Encoder?
    private var server: RTSPServer?
    private var controlServer: CameraControlServer?
    private var generation = 0
    private var timer: Timer?
    private var lastStatistics = Date()
    private var thermalObserver: NSObjectProtocol?

    init() {
        streamCommands.setHandlers(
            start: { [weak self] in Task { @MainActor in self?.start() } },
            stop: { [weak self] in Task { @MainActor in self?.stop(keepControlServer: true) } })
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalState = ProcessInfo.processInfo.thermalState }
        }
    }

    deinit {
        timer?.invalidate()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func start() {
        guard !isStreaming && !isBusy else { return }
        streamCommands.update(state: "starting")
        configuration = preset.configuration
        errorMessage = nil; droppedFrames = 0; actualBitrate = 0; actualFrameRate = 0
        _ = counters.take()
        isBusy = true
        generation += 1
        let token = generation
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard granted else {
                    self.isBusy = false
                    self.errorMessage = "Camera access denied. Enable it in Settings."
                    self.streamCommands.update(state: "error")
                    return
                }
                self.startPipeline(token: token, configuration: self.configuration)
            }
        }
    }

    private func startPipeline(token: Int, configuration: VideoStreamConfiguration) {
        let counters = self.counters
        let streamCommands = self.streamCommands
        worker.async { [weak self] in
            guard let self else { return }
            let existingControlServer = self.controlServer
            let camera = self.camera ?? CameraCapture()
            let encoder = H264Encoder()
            let server = RTSPServer(port: configuration.rtspPort)
            var controlServer = existingControlServer
            let preserveControlServer = existingControlServer != nil
            do {
                guard let address = Self.localAddress(interface: configuration.controlInterface) else {
                    throw StreamError.message("No IPv4 address on \(configuration.controlInterface). Connect to Wi-Fi before starting.")
                }
                try encoder.start(configuration: configuration)
                try camera.start(configuration: configuration)
                camera.onFrame = { [weak encoder] buffer, time in encoder?.encode(buffer, at: time) }
                camera.onDrop = { counters.drop() }
                encoder.onDrop = { counters.drop() }
                encoder.onFrame = { [weak server] frame in
                    counters.frame(bytes: frame.nalUnits.reduce(0) { $0 + $1.count })
                    server?.offer(frame)
                }
                encoder.onError = { [weak self] message in
                    DispatchQueue.main.async { self?.fail(message, token: token) }
                }
                server.onDrop = { counters.drop() }
                server.onKeyframeNeeded = { [weak encoder] in encoder?.requestKeyframe() }
                server.onClientCount = { [weak self] count in
                    DispatchQueue.main.async { if self?.generation == token { self?.clientCount = count } }
                }
                server.onError = { [weak self] message in
                    DispatchQueue.main.async { self?.fail(message, token: token) }
                }
                if controlServer == nil {
                    let control = CameraControlServer(address: address, port: configuration.controlPort,
                        handler: CameraCommandHandler(camera: camera, stream: streamCommands))
                    control.onError = { [weak self] message in
                        DispatchQueue.main.async { self?.fail(message, token: token) }
                    }
                    controlServer = control
                }
                try server.start()
                if !preserveControlServer { try controlServer?.start() }
                self.camera = camera; self.encoder = encoder; self.server = server; self.controlServer = control
                camera.run()
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.isBusy = false; self.isStreaming = true
                    self.streamCommands.update(state: "ready")
                    self.url = Self.localURL(port: configuration.rtspPort)
                    self.controlAddress = "\(address):\(configuration.controlPort)"
                    self.lastStatistics = Date()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.refreshStatistics() }
                    }
                }
            } catch {
                if !preserveControlServer { controlServer?.stop() }
                server.stop(); camera.stop(retainDevice: preserveControlServer); encoder.stop()
                if !preserveControlServer { self.camera = nil; self.controlServer = nil }
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.isBusy = false; self.errorMessage = error.localizedDescription
                    self.streamCommands.update(state: "error")
                }
            }
        }
    }

    func stop(keepControlServer: Bool = false) {
        guard isStreaming || isBusy else {
            if !keepControlServer {
                worker.async { [weak self] in
                    self?.controlServer?.stop(); self?.controlServer = nil
                    self?.camera?.stop(); self?.camera = nil
                }
            }
            return
        }
        streamCommands.update(state: "stopping")
        generation += 1
        let token = generation
        isStreaming = false; isBusy = true
        timer?.invalidate(); timer = nil
        clientCount = 0; url = ""; controlAddress = ""
        worker.async { [weak self] in
            guard let self else { return }
            if !keepControlServer {
                self.controlServer?.stop(); self.controlServer = nil
            }
            self.server?.stop(); self.server = nil
            self.camera?.stop(retainDevice: keepControlServer)
            if !keepControlServer { self.camera = nil }
            self.encoder?.stop(); self.encoder = nil
            DispatchQueue.main.async {
                if self.generation == token {
                    self.isBusy = false
                    self.streamCommands.update(state: "stopped")
                }
            }
        }
    }

    func updateBitrate(_ bitrate: Int) {
        guard isStreaming, bitrate > 0 else { return }
        let token = generation
        worker.async { [weak self] in
            self?.encoder?.updateBitrate(bitrate) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if let error { self.errorMessage = error.localizedDescription }
                    else { self.configuration.bitrate = bitrate }
                }
            }
        }
    }

    private func fail(_ message: String, token: Int) {
        guard generation == token else { return }
        stop()
        errorMessage = message
    }

    private func refreshStatistics() {
        let now = Date(), elapsed = max(now.timeIntervalSince(lastStatistics), 0.001)
        lastStatistics = now
        let (frames, bytes, drops) = counters.take()
        actualFrameRate = Double(frames) / elapsed
        actualBitrate = Double(bytes * 8) / elapsed
        droppedFrames += drops
    }

    private static func localURL(port: UInt16) -> String {
        guard let address = localAddress(interface: "en0") else { return "rtsp://<device-ip>:\(port)/camera" }
        return "rtsp://\(address):\(port)/camera"
    }

    nonisolated private static func localAddress(interface: String) -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0, String(cString: item.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
