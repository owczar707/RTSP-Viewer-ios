import Foundation

/// RTCP parsing – only Sender Reports are needed, they link RTP timestamps to wall-clock
/// (NTP) time, which is what keeps audio and video in sync.
enum RTCP {
    struct SenderReport {
        /// NTP time in seconds.
        let ntpTime: Double
        let rtpTimestamp: UInt32
    }

    static func senderReports(in bytes: [UInt8]) -> [SenderReport] {
        var reports: [SenderReport] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            guard bytes[offset] >> 6 == 2 else { break }
            let packetType = bytes[offset + 1]
            let words = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            let length = (words + 1) * 4
            guard offset + length <= bytes.count else { break }
            if packetType == 200 && length >= 28 {
                let seconds = readUInt32(bytes, at: offset + 8)
                let fraction = readUInt32(bytes, at: offset + 12)
                let timestamp = readUInt32(bytes, at: offset + 16)
                reports.append(SenderReport(
                    ntpTime: Double(seconds) + Double(fraction) / 4_294_967_296.0,
                    rtpTimestamp: timestamp
                ))
            }
            offset += length
        }
        return reports
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 {
            value = (value << 8) | UInt32(bytes[index + offset])
        }
        return value
    }
}
