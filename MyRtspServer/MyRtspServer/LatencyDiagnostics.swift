import Darwin
import Foundation

final class FrameTrace {
    let identifier: UInt64
    let captureTime: UInt64
    private let lock = NSLock()
    private(set) var submittedTime: UInt64?
    private(set) var encodedTime: UInt64?
    private(set) var packetizedTime: UInt64?
    private(set) var networkSubmittedTime: UInt64?

    init(identifier: UInt64, captureTime: UInt64 = MonotonicClock.now()) {
        self.identifier = identifier
        self.captureTime = captureTime
    }

    func markSubmitted() { lock.lock(); submittedTime = MonotonicClock.now(); lock.unlock() }
    func markEncoded() { lock.lock(); encodedTime = MonotonicClock.now(); lock.unlock() }
    func markPacketizedIfNeeded() {
        lock.lock()
        if packetizedTime == nil { packetizedTime = MonotonicClock.now() }
        lock.unlock()
    }

    func markNetworkSubmittedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard networkSubmittedTime == nil else { return false }
        networkSubmittedTime = MonotonicClock.now()
        return true
    }

    func snapshot() -> (UInt64, UInt64?, UInt64?, UInt64?, UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        return (captureTime, submittedTime, encodedTime, packetizedTime, networkSubmittedTime)
    }
}

enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func now() -> UInt64 { mach_continuous_time() }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end &- start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }
}

struct LatencyStatistics {
    let captureToSubmit: LatencySummary
    let submitToEncode: LatencySummary
    let encodeToPacketize: LatencySummary
    let packetizeToNetwork: LatencySummary
    let total: LatencySummary

    static let empty = LatencyStatistics(captureToSubmit: .empty, submitToEncode: .empty,
                                         encodeToPacketize: .empty, packetizeToNetwork: .empty, total: .empty)
}

struct LatencySummary {
    let average: Double
    let maximum: Double
    let p95: Double
    let count: Int

    static let empty = LatencySummary(average: 0, maximum: 0, p95: 0, count: 0)
}

final class LatencyDiagnostics {
    private let lock = NSLock()
    private var nextIdentifier: UInt64 = 0
    private let limit: Int
    private var captureToSubmit: [Double] = []
    private var submitToEncode: [Double] = []
    private var encodeToPacketize: [Double] = []
    private var packetizeToNetwork: [Double] = []
    private var total: [Double] = []

    init(windowSize: Int = 300) {
        limit = max(1, windowSize)
    }

    func makeTrace() -> FrameTrace {
        lock.lock()
        defer { lock.unlock() }
        nextIdentifier &+= 1
        return FrameTrace(identifier: nextIdentifier)
    }

    func record(_ trace: FrameTrace) {
        let (capture, submitted, encoded, packetized, networkSubmitted) = trace.snapshot()
        guard let submitted, let encoded, let packetized, let networkSubmitted else { return }
        lock.lock()
        defer { lock.unlock() }
        append(MonotonicClock.milliseconds(from: capture, to: submitted), to: &captureToSubmit)
        append(MonotonicClock.milliseconds(from: submitted, to: encoded), to: &submitToEncode)
        append(MonotonicClock.milliseconds(from: encoded, to: packetized), to: &encodeToPacketize)
        append(MonotonicClock.milliseconds(from: packetized, to: networkSubmitted), to: &packetizeToNetwork)
        append(MonotonicClock.milliseconds(from: capture, to: networkSubmitted), to: &total)
    }

    func snapshot() -> LatencyStatistics {
        lock.lock()
        defer { lock.unlock() }
        return LatencyStatistics(captureToSubmit: summary(captureToSubmit), submitToEncode: summary(submitToEncode),
                                 encodeToPacketize: summary(encodeToPacketize), packetizeToNetwork: summary(packetizeToNetwork),
                                 total: summary(total))
    }

    private func append(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > limit { values.removeFirst(values.count - limit) }
    }

    private func summary(_ values: [Double]) -> LatencySummary {
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return LatencySummary(average: values.reduce(0, +) / Double(values.count), maximum: sorted.last ?? 0,
                              p95: sorted[p95Index], count: values.count)
    }
}
