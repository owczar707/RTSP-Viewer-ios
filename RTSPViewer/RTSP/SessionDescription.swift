import Foundation

enum MediaKind: Hashable {
    case video
    case audio
}

enum VideoCodec: Equatable {
    case h264
    case h265

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265 (HEVC)"
        }
    }
}

struct VideoTrack {
    let codec: VideoCodec
    let payloadType: Int
    let clockRate: Int
    let controlURL: String
    /// SPS/PPS (and VPS for H.265) from the SDP `sprop-*` attributes.
    let parameterSets: [[UInt8]]
}

/// Minimal SDP (RFC 4566) parser – just enough to find the video and audio tracks.
struct SessionDescription {
    struct RTPMap {
        let encoding: String
        let clockRate: Int
        let channels: Int
    }

    struct Media {
        var kind: String
        var formats: [Int] = []
        var control: String?
        var direction: String?
        var rtpmap: [Int: RTPMap] = [:]
        var fmtp: [Int: [String: String]] = [:]

        /// ONVIF "backchannel" tracks are marked sendonly – they are for talking *to* the camera.
        var isReceivable: Bool { direction != "sendonly" && direction != "inactive" }

        func map(for payloadType: Int) -> RTPMap? {
            rtpmap[payloadType] ?? SessionDescription.staticMap(for: payloadType)
        }
    }

    private(set) var sessionControl: String?
    private(set) var media: [Media] = []

    init(_ text: String) {
        var current: Media?
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if let finished = current {
                    media.append(finished)
                }
                let parts = line.dropFirst(2).split(separator: " ")
                var next = Media(kind: parts.first.map { String($0).lowercased() } ?? "")
                if parts.count > 3 {
                    next.formats = parts[3...].compactMap { Int($0) }
                }
                current = next
            } else if line.hasPrefix("a=") {
                let attribute = String(line.dropFirst(2))
                if attribute.hasPrefix("control:") {
                    let value = String(attribute.dropFirst("control:".count)).trimmingCharacters(in: .whitespaces)
                    if current != nil {
                        current?.control = value
                    } else {
                        sessionControl = value
                    }
                } else if ["sendonly", "recvonly", "sendrecv", "inactive"].contains(attribute) {
                    current?.direction = attribute
                } else if attribute.hasPrefix("rtpmap:") {
                    let pieces = attribute.dropFirst("rtpmap:".count).split(separator: " ", maxSplits: 1)
                    guard pieces.count == 2, let payloadType = Int(pieces[0]) else { continue }
                    let encodingParts = pieces[1].trimmingCharacters(in: .whitespaces).split(separator: "/")
                    let encoding = encodingParts.first.map { String($0).uppercased() } ?? ""
                    let clockRate = encodingParts.count > 1 ? (Int(encodingParts[1]) ?? 90_000) : 90_000
                    let channels = encodingParts.count > 2 ? (Int(encodingParts[2]) ?? 1) : 1
                    current?.rtpmap[payloadType] = RTPMap(encoding: encoding, clockRate: clockRate, channels: channels)
                } else if attribute.hasPrefix("fmtp:") {
                    let pieces = attribute.dropFirst("fmtp:".count).split(separator: " ", maxSplits: 1)
                    guard pieces.count == 2, let payloadType = Int(pieces[0]) else { continue }
                    var parameters: [String: String] = [:]
                    for item in pieces[1].split(separator: ";") {
                        let pair = item.split(separator: "=", maxSplits: 1)
                        guard let key = pair.first else { continue }
                        let name = key.trimmingCharacters(in: .whitespaces).lowercased()
                        parameters[name] = pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespaces) : ""
                    }
                    current?.fmtp[payloadType] = parameters
                }
            }
        }
        if let finished = current {
            media.append(finished)
        }
    }

    /// Payload types with a fixed meaning (RFC 3551) – cameras often omit `a=rtpmap` for them.
    static func staticMap(for payloadType: Int) -> RTPMap? {
        switch payloadType {
        case 0: return RTPMap(encoding: "PCMU", clockRate: 8_000, channels: 1)
        case 8: return RTPMap(encoding: "PCMA", clockRate: 8_000, channels: 1)
        case 10: return RTPMap(encoding: "L16", clockRate: 44_100, channels: 2)
        case 11: return RTPMap(encoding: "L16", clockRate: 44_100, channels: 1)
        default: return nil
        }
    }

    /// Comma separated list of encodings of the given kind (for messages).
    func encodings(of kind: String) -> String {
        media
            .filter { $0.kind == kind && $0.isReceivable }
            .flatMap { item in item.formats.compactMap { item.map(for: $0)?.encoding } }
            .joined(separator: ", ")
    }

    /// First H.264/H.265 video track.
    func videoTrack(baseURL: String) -> VideoTrack? {
        for item in media where item.kind == "video" {
            for payloadType in item.formats {
                guard let map = item.map(for: payloadType) else { continue }
                let codec: VideoCodec
                switch map.encoding {
                case "H264":
                    codec = .h264
                case "H265", "HEVC":
                    codec = .h265
                default:
                    continue
                }

                let fmtp = item.fmtp[payloadType] ?? [:]
                let encodedSets: [String]
                switch codec {
                case .h264:
                    encodedSets = (fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").map { String($0) }
                case .h265:
                    encodedSets = ["sprop-vps", "sprop-sps", "sprop-pps"].flatMap { key in
                        (fmtp[key] ?? "").split(separator: ",").map { String($0) }
                    }
                }
                let parameterSets = encodedSets.compactMap { Self.decodeBase64($0) }.filter { !$0.isEmpty }

                return VideoTrack(
                    codec: codec,
                    payloadType: payloadType,
                    clockRate: map.clockRate > 0 ? map.clockRate : 90_000,
                    controlURL: Self.resolve(control: item.control, base: baseURL),
                    parameterSets: parameterSets
                )
            }
        }
        return nil
    }

    /// First audio track in a format we can decode (AAC, G.711, L16).
    func audioTrack(baseURL: String) -> AudioTrack? {
        for item in media where item.kind == "audio" && item.isReceivable {
            for payloadType in item.formats {
                guard let map = item.map(for: payloadType) else { continue }
                let track = AudioTrack.make(
                    map: map,
                    fmtp: item.fmtp[payloadType] ?? [:],
                    payloadType: payloadType,
                    controlURL: Self.resolve(control: item.control, base: baseURL)
                )
                if let track {
                    return track
                }
            }
        }
        return nil
    }

    static func isAbsolute(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.hasPrefix("rtsp://") || lowercased.hasPrefix("rtsps://")
    }

    static func resolve(control: String?, base: String) -> String {
        guard let control, !control.isEmpty, control != "*" else { return base }
        if isAbsolute(control) {
            return control
        }
        if control.hasPrefix("/") {
            if let schemeRange = base.range(of: "://"),
               let pathStart = base[schemeRange.upperBound...].firstIndex(of: "/") {
                return String(base[..<pathStart]) + control
            }
            return base + control
        }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    static func decodeBase64(_ text: String) -> [UInt8]? {
        var value = text.trimmingCharacters(in: .whitespaces)
        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: value).map { [UInt8]($0) }
    }
}
