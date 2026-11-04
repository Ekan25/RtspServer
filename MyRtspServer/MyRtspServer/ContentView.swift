import SwiftUI

struct ContentView: View {
    @StateObject private var stream = StreamController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var bitrateMbps = 2.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Stream") {
                    Picker("Preset", selection: $stream.preset) {
                        ForEach(VideoStreamConfiguration.Preset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .disabled(stream.isStreaming || stream.isBusy)
                    Button(stream.isStreaming ? "Stop streaming" : "Start streaming") {
                        if stream.isStreaming { stream.stop() }
                        else { bitrateMbps = Double(stream.preset.configuration.bitrate) / 1_000_000; stream.start() }
                    }
                    .disabled(stream.isBusy)
                    if stream.isBusy { ProgressView() }
                    if stream.isStreaming {
                        LabeledContent("RTSP URL") {
                            Text(stream.url).textSelection(.enabled).font(.footnote)
                        }
                        LabeledContent("Camera control") {
                            Text(stream.controlAddress).textSelection(.enabled).font(.footnote)
                        }
                        Text("Use trusted networks only. Streaming and camera control are not authenticated or encrypted; interface binding does not prevent routed access.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Status") {
                    LabeledContent("Clients", value: "\(stream.clientCount)")
                    LabeledContent("Resolution", value: "\(stream.configuration.width) × \(stream.configuration.height)")
                    LabeledContent("Frame rate", value: String(format: "%.1f / %d fps", stream.actualFrameRate, stream.configuration.frameRate))
                    LabeledContent("Encoding bitrate", value: String(format: "%.2f Mbps", stream.actualBitrate / 1_000_000))
                    LabeledContent("Dropped frames", value: "\(stream.droppedFrames)")
                    LabeledContent("Thermal state", value: thermalDescription)
                }
                if stream.isStreaming {
                    Section("Latency diagnostics") {
                        LabeledContent("Server processing avg / p95", value: latency(stream.latencyStatistics.total))
                        LabeledContent("Capture to encode p95", value: latencySum(stream.latencyStatistics.captureToSubmit, stream.latencyStatistics.submitToEncode))
                        LabeledContent("Packetize to network p95", value: latencySum(stream.latencyStatistics.encodeToPacketize, stream.latencyStatistics.packetizeToNetwork))
                    }
                }
                if stream.isStreaming {
                    Section("Bitrate") {
                        Stepper(String(format: "Target: %.1f Mbps", bitrateMbps), value: $bitrateMbps, in: 0.5...20, step: 0.5)
                        Button("Apply bitrate") { stream.updateBitrate(Int(bitrateMbps * 1_000_000)) }
                    }
                }
                if let error = stream.errorMessage {
                    Section("Error") { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Camera RTSP")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stream.stop() }
        }
    }

    private var thermalDescription: String {
        switch stream.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func latency(_ summary: LatencySummary) -> String {
        guard summary.count > 0 else { return "Waiting for client" }
        return String(format: "%.1f / %.1f ms", summary.average, summary.p95)
    }

    private func latencySum(_ first: LatencySummary, _ second: LatencySummary) -> String {
        guard first.count > 0, second.count > 0 else { return "—" }
        return String(format: "%.1f ms", first.p95 + second.p95)
    }
}

#Preview {
    ContentView()
}
