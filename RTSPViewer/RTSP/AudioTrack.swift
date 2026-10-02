import Foundation

/// An audio track the player can decode.
struct AudioTrack: Equatable {
    enum Format: Equatable {
        /// G.711 µ-law
        case pcmu
        /// G.711 A-law
        case pcma
        /// 16-bit big-endian PCM
        case l16
        /// AAC packed per RFC 3640 (`MPEG4-GENERIC`)
        case aacGeneric(sizeLength: Int, indexLength: Int, indexDeltaLength: Int)
        /// AAC packed per RFC 3016 (`MP4A-LATM`)
        case aacLATM
    }

    let format: Format
    let payloadType: Int
    let clockRate: Int
    let sampleRate: Double
    let channels: Int
    let controlURL: String

    var isAAC: Bool {
        switch format {
        case .aacGeneric, .aacLATM:
            return true
        case .pcmu, .pcma, .l16:
            return false
        }
    }

    /// RTP clock ticks covered by one AAC frame (1024 samples).
    var ticksPerAACFrame: UInt32 {
        UInt32(max(1, (1024 * Double(clockRate) / sampleRate).rounded()))
    }

    var displayName: String {
        let name: String
        switch format {
        case .pcmu: name = "G.711 µ-law"
        case .pcma: name = "G.711 A-law"
        case .l16: name = "PCM 16-bit"
        case .aacGeneric, .aacLATM: name = "AAC"
        }
        let kilohertz = sampleRate / 1000
        let rate = kilohertz == kilohertz.rounded() ? "\(Int(kilohertz)) kHz" : String(format: "%.1f kHz", kilohertz)
        let layout: String
        switch channels {
        case 1: layout = "mono"
        case 2: layout = "stereo"
        default: layout = "\(channels) kan."
        }
        return "\(name), \(rate), \(layout)"
    }

    static func make(
        map: SessionDescription.RTPMap,
        fmtp: [String: String],
        payloadType: Int,
        controlURL: String
    ) -> AudioTrack? {
        let clockRate = map.clockRate > 0 ? map.clockRate : 8_000
        let channels = max(1, min(map.channels, 8))

        func track(_ format: Format, sampleRate: Double, channels: Int) -> AudioTrack {
            AudioTrack(
                format: format,
                payloadType: payloadType,
                clockRate: clockRate,
                sampleRate: sampleRate,
                channels: max(1, min(channels, 8)),
                controlURL: controlURL
            )
        }

        switch map.encoding {
        case "PCMU":
            return track(.pcmu, sampleRate: Double(clockRate), channels: channels)
        case "PCMA":
            return track(.pcma, sampleRate: Double(clockRate), channels: channels)
        case "L16":
            return track(.l16, sampleRate: Double(clockRate), channels: channels)
        case "MPEG4-GENERIC":
            let mode = (fmtp["mode"] ?? "").lowercased()
            guard mode.hasPrefix("aac") || fmtp["sizelength"] != nil else { return nil }
            let config = fmtp["config"].flatMap { AACConfig(hex: $0) }
            let isLowBitrate = mode == "aac-lbr"
            let format = Format.aacGeneric(
                sizeLength: Int(fmtp["sizelength"] ?? "") ?? (isLowBitrate ? 6 : 13),
                indexLength: Int(fmtp["indexlength"] ?? "") ?? (isLowBitrate ? 2 : 3),
                indexDeltaLength: Int(fmtp["indexdeltalength"] ?? "") ?? (isLowBitrate ? 2 : 3)
            )
            return track(
                format,
                sampleRate: config?.sampleRate ?? Double(clockRate),
                channels: config?.channels ?? channels
            )
        case "MP4A-LATM":
            // Only the common out-of-band configuration (cpresent=0) is supported.
            guard fmtp["cpresent"] != "1",
                  let config = fmtp["config"].flatMap({ AACConfig(streamMuxConfigHex: $0) }) else { return nil }
            return track(.aacLATM, sampleRate: config.sampleRate, channels: config.channels)
        default:
            return nil
        }
    }
}

/// The parts of an MPEG-4 AudioSpecificConfig we need.
struct AACConfig {
    let objectType: Int
    let sampleRate: Double
    let channels: Int

    private static let sampleRates: [Double] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// AudioSpecificConfig given as hex (the `config=` of MPEG4-GENERIC).
    init?(hex: String) {
        guard let bytes = AACConfig.bytes(fromHex: hex) else { return nil }
        var reader = BitReader(bytes)
        self.init(reader: &reader)
    }

    /// StreamMuxConfig given as hex (the `config=` of MP4A-LATM).
    init?(streamMuxConfigHex hex: String) {
        guard let bytes = AACConfig.bytes(fromHex: hex) else { return nil }
        var reader = BitReader(bytes)
        guard reader.read(1) == 0 else { return nil } // audioMuxVersion 1 is not supported
        _ = reader.read(1) // allStreamsSameTimeFraming
        _ = reader.read(6) // numSubFrames
        _ = reader.read(4) // numProgram
        _ = reader.read(3) // numLayer
        self.init(reader: &reader)
    }

    private init?(reader: inout BitReader) {
        var objectType = reader.read(5)
        if objectType == 31 {
            objectType = 32 + reader.read(6)
        }
        let frequencyIndex = reader.read(4)
        let rate: Double
        if frequencyIndex == 15 {
            rate = Double(reader.read(24))
        } else if frequencyIndex < AACConfig.sampleRates.count {
            rate = AACConfig.sampleRates[frequencyIndex]
        } else {
            return nil
        }
        let channelConfiguration = reader.read(4)
        guard rate > 0 else { return nil }

        self.objectType = objectType
        self.sampleRate = rate
        switch channelConfiguration {
        case 0: channels = 1
        case 7: channels = 8
        default: channels = channelConfiguration
        }
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let characters = Array(hex.trimmingCharacters(in: .whitespaces))
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            result.append(byte)
            index += 2
        }
        return result
    }
}

/// Reads big-endian bit fields.
struct BitReader {
    private let bytes: [UInt8]
    private(set) var position: Int

    init(_ bytes: [UInt8], byteOffset: Int = 0) {
        self.bytes = bytes
        self.position = byteOffset * 8
    }

    var bitsRemaining: Int { max(0, bytes.count * 8 - position) }

    /// Reads up to 32 bits; reading past the end yields zero bits.
    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<max(0, count) {
            let byteIndex = position / 8
            let bit: Int
            if byteIndex < bytes.count {
                bit = Int((bytes[byteIndex] >> UInt8(7 - position % 8)) & 1)
            } else {
                bit = 0
            }
            value = (value << 1) | bit
            position += 1
        }
        return value
    }
}
