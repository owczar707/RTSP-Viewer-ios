import Foundation

/// A parsed RTP packet (RFC 3550).
struct RTPPacket {
    let payloadType: UInt8
    let marker: Bool
    let sequence: UInt16
    let timestamp: UInt32
    let payload: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let hasPadding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0F)

        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
        }
        var end = bytes.count
        if hasPadding {
            end -= Int(bytes[bytes.count - 1])
        }
        guard offset < end else { return nil }

        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = RTPPacket.readUInt32(bytes, at: 4)
        payload = Array(bytes[offset..<end])
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 {
            value = value << 8 | UInt32(bytes[index + offset])
        }
        return value
    }
}
