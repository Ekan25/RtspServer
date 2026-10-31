import Foundation
import Network

final class RTSPServer {
    private let queue = DispatchQueue(label: "rtsp.server", qos: .userInitiated)
    private let offerLock = NSLock()
    private var frameQueued = false
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var sps: Data?
    private var pps: Data?
    private let port: UInt16
    var onClientCount: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    var onDrop: (() -> Void)?

    private final class Client {
        enum State { case initial, ready, playing }
        let id = UUID()
        let connection: NWConnection
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let rtp = H264RTPPacketizer()
        var state: State = .initial
        var input = Data()
        var rtpChannel: UInt8 = 0
        var rtcpChannel: UInt8 = 1
        var needsKeyframe = true
        var videoPending = false
        var controlBytes = 0
        var lastReport = Date.distantPast
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(port: UInt16) { self.port = port }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw StreamError.message("Invalid RTSP port.") }
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.onError?("RTSP listener failed: \(error.localizedDescription)") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            self.listener?.cancel()
            self.listener = nil
            for client in self.clients.values { client.connection.cancel() }
            self.clients.removeAll()
            self.sps = nil; self.pps = nil
            self.onClientCount?(0)
        }
    }

    // At most one access unit can wait for the network queue.
    func offer(_ frame: H264Frame) {
        offerLock.lock()
        if frameQueued { offerLock.unlock(); onDrop?(); return }
        frameQueued = true
        offerLock.unlock()
        queue.async {
            defer { self.offerLock.lock(); self.frameQueued = false; self.offerLock.unlock() }
            if let sps = frame.sps, let pps = frame.pps { self.sps = sps; self.pps = pps }
            guard frame.nalUnits.reduce(0, { $0 + $1.count }) <= 2_000_000 else { self.onDrop?(); return }
            for client in self.clients.values where client.state == .playing {
                if client.videoPending {
                    client.needsKeyframe = true
                    continue
                }
                if client.needsKeyframe && !frame.isKeyframe { continue }
                var units = frame.nalUnits
                if client.needsKeyframe {
                    guard let sps = self.sps, let pps = self.pps else { continue }
                    units.insert(contentsOf: [sps, pps], at: 0)
                    client.needsKeyframe = false
                }
                let packets = client.rtp.packetize(units, at: frame.presentationTime)
                guard !packets.isEmpty else { continue }
                var data = Data()
                for packet in packets { self.appendInterleaved(packet, channel: client.rtpChannel, to: &data) }
                if Date().timeIntervalSince(client.lastReport) >= 5 {
                    self.appendInterleaved(client.rtp.senderReport(), channel: client.rtcpChannel, to: &data)
                    client.lastReport = Date()
                }
                client.videoPending = true
                client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
                    guard let self, let client else { return }
                    client.videoPending = false
                    if error != nil { self.remove(client) }
                })
            }
        }
    }

    private func appendInterleaved(_ packet: Data, channel: UInt8, to data: inout Data) {
        guard packet.count <= Int(UInt16.max) else { return }
        data.append(contentsOf: [0x24, channel])
        data.appendBE(UInt16(packet.count))
        data.append(packet)
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 16 else { connection.cancel(); return }
        let client = Client(connection)
        clients[client.id] = client
        onClientCount?(clients.count)
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state { case .failed, .cancelled: self.remove(client); default: break }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        onClientCount?(clients.count)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            if let data { client.input.append(data) }
            if client.input.count > 262_144 || error != nil || complete { self.remove(client); return }
            self.parse(client)
            if self.clients[client.id] != nil { self.receive(client) }
        }
    }

    private func parse(_ client: Client) {
        while !client.input.isEmpty {
            if client.input[0] == 0x24 {
                guard client.input.count >= 4 else { return }
                let length = Int(client.input[2]) * 256 + Int(client.input[3])
                guard client.input.count >= length + 4 else { return }
                let channel = client.input[1]
                let payload = Data(client.input[4..<(4 + length)])
                client.input = Data(client.input.dropFirst(4 + length))
                if channel == client.rtcpChannel { handleRTCP(payload, client: client) }
                continue
            }
            guard let end = client.input.range(of: Data("\r\n\r\n".utf8)) else {
                if client.input.count > 65_536 { remove(client) }
                return
            }
            guard end.lowerBound <= 65_536, let header = String(data: client.input[..<end.lowerBound], encoding: .utf8) else { remove(client); return }
            let lines = header.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ", omittingEmptySubsequences: true)
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { remove(client); return }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard headers[key] == nil else { remove(client); return }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length: Int
            if let value = headers["content-length"] {
                guard let parsed = Int(value), parsed >= 0, parsed <= 65_536 else { remove(client); return }
                length = parsed
            } else { length = 0 }
            let total = end.upperBound + length
            guard client.input.count >= total else { return }
            client.input = Data(client.input.dropFirst(total))
            guard request.count == 3, request[2] == "RTSP/1.0", let cseq = headers["cseq"], UInt32(cseq) != nil else {
                respond(client, cseq: headers["cseq"], code: 400, reason: "Bad Request"); continue
            }
            handle(client, method: String(request[0]), uri: String(request[1]), headers: headers, cseq: cseq)
        }
    }

    private func handle(_ client: Client, method: String, uri: String, headers: [String: String], cseq: String) {
        let path = URLComponents(string: uri)?.path ?? uri
        if uri != "*" && path != "/camera" && path != "/camera/" && path != "/camera/trackID=0" {
            respond(client, cseq: cseq, code: 404, reason: "Not Found"); return
        }
        let suppliedSession = headers["session"]?.split(separator: ";").first.map(String.init)
        if suppliedSession != nil && suppliedSession != client.session {
            respond(client, cseq: cseq, code: 454, reason: "Session Not Found"); return
        }
        switch method {
        case "OPTIONS":
            respond(client, cseq: cseq, extra: ["Public": "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER"])
        case "DESCRIBE":
            guard let sps, let pps, sps.count >= 4 else {
                respond(client, cseq: cseq, code: 503, reason: "Service Unavailable", extra: ["Retry-After": "1"]); return
            }
            let profile = sps.dropFirst().prefix(3).map { String(format: "%02X", $0) }.joined()
            let sdp = "v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=Camera\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1;profile-level-id=\(profile);sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())\r\na=control:trackID=0\r\n"
            let base = uri.hasSuffix("/") ? uri : uri + "/"
            respond(client, cseq: cseq, extra: ["Content-Type": "application/sdp", "Content-Base": base], body: Data(sdp.utf8))
        case "SETUP":
            guard client.state == .initial else { respond(client, cseq: cseq, code: 455, reason: "Method Not Valid in This State"); return }
            guard let transport = headers["transport"], let channels = parseTransport(transport) else {
                respond(client, cseq: cseq, code: 461, reason: "Unsupported Transport"); return
            }
            client.rtpChannel = channels.0; client.rtcpChannel = channels.1
            client.state = .ready
            respond(client, cseq: cseq, extra: ["Session": client.session, "Transport": "RTP/AVP/TCP;unicast;interleaved=\(channels.0)-\(channels.1);ssrc=\(String(format: "%08X", client.rtp.ssrc))"])
        case "PLAY", "PAUSE", "TEARDOWN", "GET_PARAMETER":
            guard suppliedSession == client.session, client.state != .initial else {
                respond(client, cseq: cseq, code: 454, reason: "Session Not Found"); return
            }
            switch method {
            case "PLAY":
                client.state = .playing; client.needsKeyframe = true
                respond(client, cseq: cseq, extra: ["Session": client.session])
                onKeyframeNeeded?()
            case "PAUSE":
                guard client.state == .playing else { respond(client, cseq: cseq, code: 455, reason: "Method Not Valid in This State"); return }
                client.state = .ready
                respond(client, cseq: cseq, extra: ["Session": client.session])
            case "TEARDOWN":
                client.state = .initial
                respond(client, cseq: cseq, extra: ["Session": client.session], close: true)
            default: respond(client, cseq: cseq, extra: ["Session": client.session])
            }
        default: respond(client, cseq: cseq, code: 405, reason: "Method Not Allowed", extra: ["Public": "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER"])
        }
    }

    private func parseTransport(_ transport: String) -> (UInt8, UInt8)? {
        for alternative in transport.split(separator: ",") {
            let parts = alternative.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first?.uppercased() == "RTP/AVP/TCP", !parts.contains(where: { $0.lowercased() == "multicast" }) else { continue }
            if let channels = parts.first(where: { $0.lowercased().hasPrefix("interleaved=") }) {
                let values = channels.dropFirst("interleaved=".count).split(separator: "-")
                guard values.count == 2, let first = UInt8(values[0]), let second = UInt8(values[1]), first != second else { continue }
                return (first, second)
            }
            return (0, 1)
        }
        return nil
    }

    private func handleRTCP(_ data: Data, client: Client) {
        var offset = 0
        while offset + 4 <= data.count {
            let length = (Int(data[offset + 2]) * 256 + Int(data[offset + 3]) + 1) * 4
            guard data[offset] >> 6 == 2, length >= 4, offset + length <= data.count else { return }
            // Picture loss indication and full intra request.
            if data[offset + 1] == 206 && (data[offset] & 0x1f == 1 || data[offset] & 0x1f == 4) {
                client.needsKeyframe = true
                onKeyframeNeeded?()
            }
            offset += length
        }
    }

    private func respond(_ client: Client, cseq: String?, code: Int = 200, reason: String = "OK", extra: [String: String] = [:], body: Data = Data(), close: Bool = false) {
        var text = "RTSP/1.0 \(code) \(reason)\r\n"
        if let cseq { text += "CSeq: \(cseq)\r\n" }
        for (key, value) in extra { text += "\(key): \(value)\r\n" }
        text += "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(text.utf8); data.append(body)
        guard client.controlBytes + data.count <= 262_144 else { remove(client); return }
        client.controlBytes += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { return }
            client.controlBytes -= data.count
            if close || error != nil { self.remove(client) }
        })
    }
}
