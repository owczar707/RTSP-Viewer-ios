import Foundation
import Network

/// Minimal RTSP client: OPTIONS → DESCRIBE → SETUP video (+ audio) over interleaved TCP → PLAY,
/// then forwards RTP packets and RTCP sender reports of the selected tracks.
///
/// RTP over TCP is used on purpose: when the network hiccups, TCP retransmits instead of
/// dropping packets, so the delayed media arrives later in a burst and the player can
/// fast-forward through it instead of losing it.
///
/// Every method must be called on `queue`; callbacks are delivered on `queue`.
final class RTSPClient {
    /// Video track, audio track (nil when absent or not playable) and, when the camera offers
    /// audio we can't play, a description of it.
    var onTracks: ((VideoTrack, AudioTrack?, String?) -> Void)?
    var onRTPPacket: ((MediaKind, RTPPacket) -> Void)?
    var onSenderReport: ((MediaKind, RTCP.SenderReport) -> Void)?
    var onPlaying: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private struct Request {
        let method: String
        let url: String
        let headers: [String]
        var authAttempts = 0
        let completion: (RTSPMessage) -> Void
    }

    private static let userAgent = "RTSPViewer/1.0 (iOS)"
    private static let headerTerminator: [UInt8] = Array("\r\n\r\n".utf8)
    private static let maxHeaderSize = 64 * 1024
    private static let messagePrefixes: [[UInt8]] = [
        "RTSP/", "ANNOUNCE ", "GET_PARAMETER ", "SET_PARAMETER ", "OPTIONS ", "REDIRECT ", "TEARDOWN ",
    ].map { Array($0.utf8) }

    private let endpoint: RTSPEndpoint
    private let queue: DispatchQueue
    private let authenticator: RTSPAuthenticator?

    private var connection: NWConnection?
    private var isReady = false
    private var isStopped = false
    private var isPlaying = false
    private var buffer = ByteBuffer()
    private var cseq = 0
    private var pending: [Int: Request] = [:]
    private var session: String?
    private var sessionTimeout: TimeInterval = 60
    private var supportsGetParameter = false
    private var aggregateURL: String
    private var rtpChannels: [UInt8: MediaKind] = [:]
    private var rtcpChannels: [UInt8: MediaKind] = [:]
    private var keepAliveTimer: DispatchSourceTimer?

    init(endpoint: RTSPEndpoint, username: String?, password: String?, queue: DispatchQueue) {
        self.endpoint = endpoint
        self.queue = queue
        self.aggregateURL = endpoint.requestURL
        if let username, !username.isEmpty {
            authenticator = RTSPAuthenticator(username: username, password: password ?? "")
        } else {
            authenticator = nil
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard connection == nil, !isStopped else { return }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            fail(RTSPError.invalidURL)
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: endpoint.useTLS ? NWProtocolTLS.Options() : nil, tcp: tcp)

        let newConnection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        newConnection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        connection = newConnection
        newConnection.start(queue: queue)
    }

    /// Stops the session (sends TEARDOWN when possible). No callbacks are delivered afterwards.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        onTracks = nil
        onRTPPacket = nil
        onSenderReport = nil
        onPlaying = nil
        onFailure = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        pending.removeAll()

        guard let connection else { return }
        self.connection = nil
        if isReady && session != nil {
            let teardown = Data(requestText(method: "TEARDOWN", url: aggregateURL, headers: []).utf8)
            connection.send(content: teardown, completion: .contentProcessed { _ in
                connection.cancel()
            })
            queue.asyncAfter(deadline: .now() + 1) {
                connection.cancel()
            }
        } else {
            connection.cancel()
        }
    }

    private func fail(_ error: Error) {
        guard !isStopped else { return }
        let callback = onFailure
        isReady = false // the connection is broken, don't bother with TEARDOWN
        stop()
        queue.async {
            callback?(error)
        }
    }

    private func handle(state: NWConnection.State) {
        guard !isStopped else { return }
        switch state {
        case .ready:
            isReady = true
            receive()
            sendOptions()
        case .waiting(let error):
            // Network.framework would keep waiting on its own; the player owns the retry policy.
            fail(error)
        case .failed(let error):
            fail(error)
        default:
            break
        }
    }

    // MARK: - Receiving

    private func receive() {
        guard let connection, !isStopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isStopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseBuffer()
            }
            if self.isStopped {
                return
            }
            if let error {
                self.fail(error)
                return
            }
            if isComplete {
                self.fail(RTSPError.connectionClosed)
                return
            }
            self.receive()
        }
    }

    private func parseBuffer() {
        while !isStopped && !buffer.isEmpty {
            if buffer[0] == 0x24 { // '$' – interleaved binary frame
                guard buffer.count >= 4 else { return }
                let channel = buffer[1]
                let length = Int(buffer[2]) << 8 | Int(buffer[3])
                guard buffer.count >= 4 + length else { return }
                if let kind = rtpChannels[channel] {
                    if let packet = RTPPacket(buffer.bytes(at: 4, count: length)) {
                        onRTPPacket?(kind, packet)
                    }
                } else if let kind = rtcpChannels[channel] {
                    for report in RTCP.senderReports(in: buffer.bytes(at: 4, count: length)) {
                        onSenderReport?(kind, report)
                    }
                }
                buffer.consume(4 + length)
                continue
            }

            guard let isMessage = messageStartsHere() else { return } // need more bytes to decide
            if isMessage {
                guard let headerEnd = buffer.firstIndex(of: Self.headerTerminator, searchLimit: Self.maxHeaderSize) else {
                    if buffer.count >= Self.maxHeaderSize {
                        buffer.consume(1) // not a real message – resynchronise
                        continue
                    }
                    return
                }
                let headerText = String(decoding: buffer.bytes(at: 0, count: headerEnd), as: UTF8.self)
                guard var message = RTSPMessage(headerText: headerText) else {
                    buffer.consume(headerEnd + 4)
                    continue
                }
                let total = headerEnd + 4 + message.contentLength
                guard buffer.count >= total else { return }
                message.body = Data(buffer.bytes(at: headerEnd + 4, count: message.contentLength))
                buffer.consume(total)
                if message.isResponse {
                    handle(response: message)
                }
            } else {
                // Garbage: skip to the next '$' or uppercase letter.
                var skip = 1
                while skip < buffer.count {
                    let byte = buffer[skip]
                    if byte == 0x24 || (byte >= 0x41 && byte <= 0x5A) {
                        break
                    }
                    skip += 1
                }
                buffer.consume(skip)
            }
        }
    }

    /// true – an RTSP message starts here, false – garbage, nil – not enough bytes to tell.
    private func messageStartsHere() -> Bool? {
        var undecided = false
        for prefix in Self.messagePrefixes where buffer.matchesStart(of: prefix) {
            if buffer.count >= prefix.count {
                return true
            }
            undecided = true
        }
        return undecided ? nil : false
    }

    private func handle(response: RTSPMessage) {
        let key: Int
        if let cseq = response.cseq, pending[cseq] != nil {
            key = cseq
        } else if pending.count == 1, let only = pending.keys.first {
            key = only // some cameras forget the CSeq header
        } else {
            return
        }
        guard let request = pending.removeValue(forKey: key) else { return }

        if response.statusCode == 401 {
            guard let authenticator else {
                fail(RTSPError.credentialsRequired)
                return
            }
            guard request.authAttempts < 2, authenticator.update(with: response) else {
                fail(RTSPError.unauthorized)
                return
            }
            var retry = request
            retry.authAttempts += 1
            transmit(retry)
            return
        }
        request.completion(response)
    }

    // MARK: - Sending

    private func send(_ method: String, url: String, headers: [String] = [], completion: @escaping (RTSPMessage) -> Void) {
        transmit(Request(method: method, url: url, headers: headers, completion: completion))
    }

    private func transmit(_ request: Request) {
        guard let connection, isReady, !isStopped else { return }
        let text = requestText(method: request.method, url: request.url, headers: request.headers)
        pending[cseq] = request
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.fail(error)
        })
    }

    private func requestText(method: String, url: String, headers: [String]) -> String {
        cseq += 1
        var lines = [
            "\(method) \(url) RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: \(Self.userAgent)",
        ]
        if let authorization = authenticator?.authorization(method: method, uri: url) {
            lines.append("Authorization: \(authorization)")
        }
        if let session {
            lines.append("Session: \(session)")
        }
        lines.append(contentsOf: headers)
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    // MARK: - Handshake

    private func sendOptions() {
        send("OPTIONS", url: endpoint.requestURL) { [weak self] response in
            guard let self else { return }
            if let methods = response.header("Public") {
                self.supportsGetParameter = methods.uppercased().contains("GET_PARAMETER")
            }
            self.sendDescribe() // some cameras answer OPTIONS with an error – carry on anyway
        }
    }

    private func sendDescribe() {
        send("DESCRIBE", url: endpoint.requestURL, headers: ["Accept: application/sdp"]) { [weak self] response in
            guard let self else { return }
            guard response.isSuccess else {
                self.fail(RTSPError.badStatus(method: "DESCRIBE", code: response.statusCode, reason: response.reason))
                return
            }
            let sdp = SessionDescription(String(decoding: response.body, as: UTF8.self))
            let base = (response.header("Content-Base")
                ?? response.header("Content-Location")
                ?? self.endpoint.requestURL).trimmingCharacters(in: .whitespaces)
            if let control = sdp.sessionControl, SessionDescription.isAbsolute(control) {
                self.aggregateURL = control
            } else {
                self.aggregateURL = base
            }
            guard let video = sdp.videoTrack(baseURL: base) else {
                self.fail(RTSPError.noSupportedVideo(sdp.encodings(of: "video")))
                return
            }
            let audio = sdp.audioTrack(baseURL: base)
            let audioEncodings = sdp.encodings(of: "audio")
            let unsupportedAudio = (audio == nil && !audioEncodings.isEmpty) ? audioEncodings : nil
            self.sendSetup(video: video, audio: audio, unsupportedAudio: unsupportedAudio)
        }
    }

    private func sendSetup(video: VideoTrack, audio: AudioTrack?, unsupportedAudio: String?) {
        setUp(.video, url: video.controlURL, channel: 0) { [weak self] response in
            guard let self else { return }
            guard response.isSuccess else {
                if response.statusCode == 461 {
                    self.fail(RTSPError.protocolError("kamera nie obsługuje przesyłania RTP przez TCP"))
                } else {
                    self.fail(RTSPError.badStatus(method: "SETUP", code: response.statusCode, reason: response.reason))
                }
                return
            }
            guard let audio else {
                self.onTracks?(video, nil, unsupportedAudio)
                self.sendPlay()
                return
            }
            self.setUp(.audio, url: audio.controlURL, channel: 2) { [weak self] audioResponse in
                guard let self else { return }
                // A failed audio SETUP is not fatal – play the video alone.
                if audioResponse.isSuccess {
                    self.onTracks?(video, audio, nil)
                } else {
                    self.onTracks?(video, nil, "\(audio.displayName) – SETUP \(audioResponse.statusCode)")
                }
                self.sendPlay()
            }
        }
    }

    private func setUp(_ kind: MediaKind, url: String, channel: UInt8, completion: @escaping (RTSPMessage) -> Void) {
        let transport = "Transport: RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)"
        send("SETUP", url: url, headers: [transport]) { [weak self] response in
            guard let self else { return }
            if response.isSuccess {
                if let header = response.header("Session") {
                    self.parseSession(header)
                }
                var channels = (rtp: channel, rtcp: channel + 1)
                if let transportHeader = response.header("Transport"),
                   let granted = Self.interleavedChannels(in: transportHeader) {
                    channels = granted
                }
                self.rtpChannels[channels.rtp] = kind
                self.rtcpChannels[channels.rtcp] = kind
            }
            completion(response)
        }
    }

    private func sendPlay() {
        send("PLAY", url: aggregateURL, headers: ["Range: npt=0.000-"]) { [weak self] response in
            guard let self else { return }
            guard response.isSuccess else {
                self.fail(RTSPError.badStatus(method: "PLAY", code: response.statusCode, reason: response.reason))
                return
            }
            self.isPlaying = true
            self.startKeepAlive()
            self.onPlaying?()
        }
    }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let interval = max(5, min(sessionTimeout * 0.5, 30))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            let method = self.supportsGetParameter ? "GET_PARAMETER" : "OPTIONS"
            self.send(method, url: self.aggregateURL) { _ in }
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func parseSession(_ header: String) {
        let parts = header.split(separator: ";")
        guard let identifier = parts.first?.trimmingCharacters(in: .whitespaces), !identifier.isEmpty else { return }
        session = identifier
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "timeout",
                  let value = Double(pair[1].trimmingCharacters(in: .whitespaces)),
                  value > 0 else { continue }
            sessionTimeout = value
        }
    }

    /// Parses `interleaved=a-b` from a Transport header.
    private static func interleavedChannels(in transport: String) -> (rtp: UInt8, rtcp: UInt8)? {
        for part in transport.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "interleaved" else { continue }
            let numbers = pair[1].split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let rtp = numbers.first.flatMap({ UInt8($0) }) else { return nil }
            let rtcp = numbers.count > 1 ? (UInt8(numbers[1]) ?? rtp &+ 1) : rtp &+ 1
            return (rtp: rtp, rtcp: rtcp)
        }
        return nil
    }
}
