import Foundation
import CoreMedia

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

final class H264RTPPacketizer {
    private(set) var sequence = UInt16.random(in: .min ... .max)
    private let initialTimestamp = UInt32.random(in: .min ... .max)
    private(set) var timestamp: UInt32
    let ssrc = UInt32.random(in: .min ... .max)
    private var firstTime: CMTime?
    private var firstNTPTime: TimeInterval?
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0
    private let maxPayload: Int

    init(maxPayload: Int = 1200) {
        self.maxPayload = max(3, min(maxPayload, 65_523))
        timestamp = initialTimestamp
    }

    func packetize(_ units: [Data], at time: CMTime) -> [Data] {
        guard time.isValid, time.isNumeric else { return [] }
        if firstTime == nil {
            firstTime = time
            firstNTPTime = Date().timeIntervalSince1970 + 2_208_988_800
        }
        let delta = CMTimeConvertScale(CMTimeSubtract(time, firstTime!), timescale: 90_000, method: .roundTowardZero).value
        timestamp = initialTimestamp &+ UInt32(truncatingIfNeeded: delta)
        let units = units.filter { !$0.isEmpty }
        var packets: [Data] = []
        for (index, unit) in units.enumerated() {
            let lastUnit = index == units.count - 1
            if unit.count <= maxPayload {
                packets.append(makePacket(payload: unit, marker: lastUnit))
            } else {
                let header = unit[unit.startIndex]
                let indicator = (header & 0xe0) | 28
                let type = header & 0x1f
                var offset = 1
                while offset < unit.count {
                    let end = min(offset + maxPayload - 2, unit.count)
                    let isLast = end == unit.count
                    var payload = Data([indicator, type | (offset == 1 ? 0x80 : 0) | (isLast ? 0x40 : 0)])
                    payload.append(unit.subdata(in: offset..<end))
                    packets.append(makePacket(payload: payload, marker: lastUnit && isLast))
                    offset = end
                }
            }
        }
        return packets
    }

    private func makePacket(payload: Data, marker: Bool) -> Data {
        var packet = Data([0x80, marker ? 0xe0 : 0x60])
        packet.appendBE(sequence)
        packet.appendBE(timestamp)
        packet.appendBE(ssrc)
        packet.append(payload)
        sequence &+= 1
        packetCount &+= 1
        octetCount &+= UInt32(truncatingIfNeeded: payload.count)
        return packet
    }

    func senderReport() -> Data {
        let ntp = (firstNTPTime ?? Date().timeIntervalSince1970 + 2_208_988_800) +
            Double(timestamp &- initialTimestamp) / 90_000
        let seconds = floor(ntp)
        let fraction = UInt32((ntp - seconds) * 4_294_967_296)
        var report = Data([0x80, 200, 0, 6])
        report.appendBE(ssrc)
        report.appendBE(UInt32(truncatingIfNeeded: UInt64(seconds)))
        report.appendBE(fraction)
        report.appendBE(timestamp)
        report.appendBE(packetCount)
        report.appendBE(octetCount)
        return report
    }
}