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

private final class StreamStateStore {
    private let lock = NSLock()
    private var value = CameraStreamStatus(state: .stopped, message: nil)

    func get() -> CameraStreamStatus {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: CameraStreamStatus) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class StreamControlBridge: CameraStreamControlling {
    weak var controller: StreamController?
    let stateStore: StreamStateStore

    init(stateStore: StreamStateStore) {
        self.stateStore = stateStore
    }

    func startStream(completion: @escaping (Result<CameraStreamStatus, CameraControlError>) -> Void) {
        Task { @MainActor [weak controller] in
            guard let controller else {
                completion(.failure(.init(code: "unavailable", message: "Stream control is unavailable.")))
                return
            }
            controller.startStream(completion: completion)
        }
    }

    func stopStream(completion: @escaping (Result<CameraStreamStatus, CameraControlError>) -> Void) {
        Task { @MainActor [weak controller] in
            guard let controller else {
                completion(.failure(.init(code: "unavailable", message: "Stream control is unavailable.")))
                return
            }
            controller.stopStream(completion: completion)
        }
    }

    func streamStatus() -> CameraStreamStatus {
        stateStore.get()
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
    @Published private(set) var latencyStatistics = LatencyStatistics.empty
    @Published private(set) var url = ""
    @Published private(set) var controlAddress = ""
    @Published private(set) var streamState: CameraStreamState = .stopped
    @Published var preset: VideoStreamConfiguration.Preset = .default
    @Published private(set) var configuration = VideoStreamConfiguration()
    @Published private(set) var cameraName: String

    private let worker = DispatchQueue(label: "stream.lifecycle", qos: .userInitiated)
    private let counters = StreamCounters()
    private let diagnostics = LatencyDiagnostics()
    private let streamStateStore = StreamStateStore()
    private let controlBridge: StreamControlBridge
    // Accessed only by worker.
    private var camera: CameraCapture?
    private var encoder: H264Encoder?
    private var server: RTSPServer?
    private var controlServer: CameraControlServer?
    private var remoteCamera: RemoteCameraController?
    private var generation = 0
    private var timer: Timer?
    private var lastStatistics = Date()
    private var thermalObserver: NSObjectProtocol?
    private var startCompletions: [(Result<CameraStreamStatus, CameraControlError>) -> Void] = []
    private var stopCompletions: [(Result<CameraStreamStatus, CameraControlError>) -> Void] = []
    private var startAfterStop = false

    init() {
        controlBridge = StreamControlBridge(stateStore: streamStateStore)
        cameraName = CameraDiscoverySettings.cameraName
        RemoteCameraController.applySavedKeepAwakePreference()
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalState = ProcessInfo.processInfo.thermalState }
        }
        controlBridge.controller = self
        Task { [weak self] in self?.startControlService() }
    }

    func setCameraName(_ name: String) {
        guard !isStreaming && !isBusy else { return }
        cameraName = CameraDiscoverySettings.saveCameraName(name)
    }

    deinit {
        timer?.invalidate()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func start() {
        startStream { _ in }
    }

    func startStream(completion: @escaping (Result<CameraStreamStatus, CameraControlError>) -> Void) {
        switch streamState {
        case .running:
            completion(.success(currentStreamStatus()))
            return
        case .starting:
            startCompletions.append(completion)
            return
        case .stopping:
            startCompletions.append(completion)
            startAfterStop = true
            return
        case .stopped, .error:
            startCompletions.append(completion)
        }
        configuration = preset.configuration
        errorMessage = nil; droppedFrames = 0; actualBitrate = 0; actualFrameRate = 0
        _ = counters.take()
        isBusy = true
        transition(to: .starting)
        generation += 1
        let token = generation
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard granted else {
                    self.isBusy = false
                    self.errorMessage = "Camera access denied. Enable it in Settings."
                    self.transition(to: .error, message: self.errorMessage)
                    self.finishStart(.failure(.init(code: "camera_access_denied", message: self.errorMessage!)))
                    return
                }
                self.startPipeline(token: token, configuration: self.configuration)
            }
        }
    }

    private func startPipeline(token: Int, configuration: VideoStreamConfiguration) {
        let counters = self.counters
        worker.async { [weak self] in
            guard let self else { return }
            let camera = CameraCapture()
            let encoder = H264Encoder()
            let server = RTSPServer(port: configuration.rtspPort, rtpPayloadSize: configuration.rtpPayloadSize)
            do {
                guard let address = Self.localAddress(interface: configuration.controlInterface) else {
                    throw StreamError.message("No IPv4 address on \(configuration.controlInterface). Connect to Wi-Fi before starting.")
                }
                try encoder.start(configuration: configuration)
                try camera.start(configuration: configuration)
                camera.makeTrace = { [weak diagnostics = self.diagnostics] in
                    diagnostics?.makeTrace() ?? FrameTrace(identifier: 0)
                }
                camera.onFrame = { [weak encoder] buffer, time, trace in encoder?.encode(buffer, at: time, trace: trace) }
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
                server.onTraceComplete = { [weak diagnostics = self.diagnostics] trace in diagnostics?.record(trace) }
                server.onKeyframeNeeded = { [weak encoder] in encoder?.requestKeyframe() }
                server.onClientCount = { [weak self] count in
                    DispatchQueue.main.async { if self?.generation == token { self?.clientCount = count } }
                }
                server.onError = { [weak self] message in
                    DispatchQueue.main.async { self?.fail(message, token: token) }
                }
                let remoteCamera = RemoteCameraController(camera: camera, encoder: encoder, server: server, configuration: configuration)
                remoteCamera.configurationDidChange = { [weak self] updated in
                    DispatchQueue.main.async {
                        guard self?.generation == token else { return }
                        self?.configuration = updated
                    }
                }
                try server.start()
                self.camera = camera; self.encoder = encoder; self.server = server; self.remoteCamera = remoteCamera
                camera.run()
                DispatchQueue.main.async {
                    guard self.generation == token else {
                        server.stop(); camera.stop(); encoder.stop()
                        return
                    }
                    self.isBusy = false; self.isStreaming = true
                    self.url = Self.localURL(port: configuration.rtspPort)
                    self.lastStatistics = Date()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.refreshStatistics() }
                    }
                    self.transition(to: .running)
                    self.finishStart(.success(self.currentStreamStatus()))
                }
            } catch {
                server.stop(); camera.stop(); encoder.stop()
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.isBusy = false; self.errorMessage = error.localizedDescription
                    self.transition(to: .error, message: error.localizedDescription)
                    self.finishStart(.failure(.init(code: "stream_start_failed", message: error.localizedDescription)))
                }
            }
        }
    }

    func stop() {
        stopStream { _ in }
    }

    func stopStream(completion: @escaping (Result<CameraStreamStatus, CameraControlError>) -> Void) {
        let wasStarting = streamState == .starting
        switch streamState {
        case .stopped:
            completion(.success(currentStreamStatus()))
            return
        case .stopping:
            stopCompletions.append(completion)
            return
        case .starting, .running, .error:
            stopCompletions.append(completion)
        }
        if wasStarting {
            finishStart(.failure(.init(code: "stream_start_cancelled", message: "Stream start was cancelled by stopStream.")))
        }
        generation += 1
        let token = generation
        isStreaming = false; isBusy = true
        transition(to: .stopping)
        timer?.invalidate(); timer = nil
        clientCount = 0; url = ""
        worker.async { [weak self] in
            guard let self else { return }
            self.remoteCamera = nil
            self.server?.stop(); self.server = nil
            self.camera?.stop(); self.camera = nil
            self.encoder?.stop(); self.encoder = nil
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.isBusy = false
                self.transition(to: .stopped)
                self.finishStop(.success(self.currentStreamStatus()))
                if self.startAfterStop {
                    self.startAfterStop = false
                    self.startStream { _ in }
                }
            }
        }
    }

    func updateBitrate(_ bitrate: Int) {
        guard isStreaming, bitrate > 0 else { return }
        let token = generation
        worker.async { [weak self] in
            do {
                _ = try self?.remoteCamera?.setQuality(bitrate: bitrate)
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func fail(_ message: String, token: Int) {
        guard generation == token else { return }
        isStreaming = false
        isBusy = true
        timer?.invalidate(); timer = nil
        clientCount = 0; url = ""
        transition(to: .error, message: message)
        errorMessage = message
        worker.async { [weak self] in
            guard let self else { return }
            self.remoteCamera = nil
            self.server?.stop(); self.server = nil
            self.camera?.stop(); self.camera = nil
            self.encoder?.stop(); self.encoder = nil
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.isBusy = false
                self.finishStart(.failure(.init(code: "stream_error", message: message)))
            }
        }
    }

    private func refreshStatistics() {
        let now = Date(), elapsed = max(now.timeIntervalSince(lastStatistics), 0.001)
        lastStatistics = now
        let (frames, bytes, drops) = counters.take()
        actualFrameRate = Double(frames) / elapsed
        actualBitrate = Double(bytes * 8) / elapsed
        droppedFrames += drops
        latencyStatistics = diagnostics.snapshot()
    }

    private static func localURL(port: UInt16) -> String {
        guard let address = localAddress(interface: "en0") else { return "rtsp://<device-ip>:\(port)/camera" }
        return "rtsp://\(address):\(port)/camera"
    }

    private func startControlService() {
        let configuration = self.configuration
        worker.async { [weak self] in
            guard let self, self.controlServer == nil else { return }
            guard let address = Self.localAddress(interface: configuration.controlInterface) else {
                DispatchQueue.main.async {
                    self.errorMessage = "No IPv4 address on \(configuration.controlInterface). Connect to Wi-Fi before starting camera control."
                }
                return
            }
            let handler = CameraCommandHandler(
                cameraProvider: { [weak self] in
                    guard let self else { return nil }
                    return self.worker.sync { self.remoteCamera }
                },
                stream: self.controlBridge
            )
            let control = CameraControlServer(
                address: address,
                port: configuration.controlPort,
                handler: handler,
                cameraName: self.cameraName,
                cameraIdentifier: CameraDiscoverySettings.cameraIdentifier,
                rtspPort: configuration.rtspPort
            )
            control.onError = { [weak self] message in
                DispatchQueue.main.async { self?.errorMessage = message }
            }
            do {
                try control.start()
                self.controlServer = control
                DispatchQueue.main.async {
                    self.controlAddress = "\(address):\(configuration.controlPort)"
                }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func transition(to state: CameraStreamState, message: String? = nil) {
        streamState = state
        let status = CameraStreamStatus(state: state, message: message)
        streamStateStore.set(status)
        worker.async { [weak self] in
            guard let self else { return }
            self.controlServer.map { control in
                control.broadcastStreamState(status)
            }
        }
    }

    private func currentStreamStatus() -> CameraStreamStatus {
        streamStateStore.get()
    }

    private func finishStart(_ result: Result<CameraStreamStatus, CameraControlError>) {
        let completions = startCompletions
        startCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    private func finishStop(_ result: Result<CameraStreamStatus, CameraControlError>) {
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0(result) }
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
