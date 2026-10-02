import Foundation

/// All NAL units belonging to one picture (same RTP timestamp).
struct AccessUnit {
    let nalUnits: [[UInt8]]
    let timestamp: UInt32
    /// Set when packets were lost while assembling – the picture must not be decoded.
    let isCorrupted: Bool
}

/// Reassembles H.264 (RFC 6184) and H.265 (RFC 7798) NAL units from RTP packets.
final class RTPDepacketizer {
    private let codec: VideoCodec
    private var nalUnits: [[UInt8]] = []
    private var timestamp: UInt32 = 0
    private var isCollecting = false
    private var isCorrupted = false
    private var fragment: [UInt8] = []
    private var isFragmenting = false
    private var lastSequence: UInt16?

    init(codec: VideoCodec) {
        self.codec = codec
    }

    func push(_ packet: RTPPacket) -> [AccessUnit] {
        var output: [AccessUnit] = []
        let lost = lastSequence.map { packet.sequence != $0 &+ 1 } ?? false
        lastSequence = packet.sequence

        // A new timestamp starts a new picture even if the marker bit was missing.
        if isCollecting && packet.timestamp != timestamp, let unit = finish(forceCorrupted: lost) {
            output.append(unit)
        }
        if !isCollecting {
            isCollecting = true
            timestamp = packet.timestamp
        }
        if lost {
            isCorrupted = true
            fragment.removeAll(keepingCapacity: true)
            isFragmenting = false
        }

        switch codec {
        case .h264:
            depacketizeH264(packet.payload)
        case .h265:
            depacketizeH265(packet.payload)
        }

        if packet.marker, let unit = finish(forceCorrupted: false) {
            output.append(unit)
        }
        return output
    }

    private func finish(forceCorrupted: Bool) -> AccessUnit? {
        let corrupted = isCorrupted || forceCorrupted || isFragmenting
        let units = nalUnits
        let unitTimestamp = timestamp
        nalUnits = []
        fragment.removeAll(keepingCapacity: true)
        isFragmenting = false
        isCorrupted = false
        isCollecting = false
        guard !units.isEmpty || corrupted else { return nil }
        return AccessUnit(nalUnits: units, timestamp: unitTimestamp, isCorrupted: corrupted)
    }

    // MARK: - H.264

    private func depacketizeH264(_ payload: [UInt8]) {
        guard let header = payload.first else { return }
        switch header & 0x1F {
        case 1...23:
            nalUnits.append(payload)
        case 24: // STAP-A
            appendAggregated(payload, from: 1)
        case 28: // FU-A
            guard payload.count > 2 else { return }
            let fuHeader = payload[1]
            let nalHeader = (header & 0xE0) | (fuHeader & 0x1F)
            appendFragment(
                payload,
                dataOffset: 2,
                isStart: fuHeader & 0x80 != 0,
                isEnd: fuHeader & 0x40 != 0,
                header: [nalHeader]
            )
        default:
            break // STAP-B, MTAP, FU-B are not used by IP cameras
        }
    }

    // MARK: - H.265

    private func depacketizeH265(_ payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        switch (payload[0] >> 1) & 0x3F {
        case 48: // Aggregation packet
            appendAggregated(payload, from: 2)
        case 49: // Fragmentation unit
            guard payload.count > 3 else { return }
            let fuHeader = payload[2]
            let nalType = fuHeader & 0x3F
            let firstByte = (payload[0] & 0x81) | (nalType << 1)
            appendFragment(
                payload,
                dataOffset: 3,
                isStart: fuHeader & 0x80 != 0,
                isEnd: fuHeader & 0x40 != 0,
                header: [firstByte, payload[1]]
            )
        case 50: // PACI
            break
        default:
            nalUnits.append(payload)
        }
    }

    // MARK: - Helpers

    private func appendAggregated(_ payload: [UInt8], from start: Int) {
        var index = start
        while index + 2 <= payload.count {
            let size = Int(payload[index]) << 8 | Int(payload[index + 1])
            index += 2
            guard size > 0 else { return }
            guard index + size <= payload.count else {
                isCorrupted = true
                return
            }
            nalUnits.append(Array(payload[index..<(index + size)]))
            index += size
        }
    }

    private func appendFragment(_ payload: [UInt8], dataOffset: Int, isStart: Bool, isEnd: Bool, header: [UInt8]) {
        if isStart {
            if isFragmenting {
                isCorrupted = true
            }
            fragment = header
            isFragmenting = true
        } else if !isFragmenting {
            isCorrupted = true
            return
        }
        fragment.append(contentsOf: payload[dataOffset...])
        if isEnd {
            nalUnits.append(fragment)
            fragment.removeAll(keepingCapacity: true)
            isFragmenting = false
        }
    }
}
