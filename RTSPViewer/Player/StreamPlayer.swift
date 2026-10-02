import AVFoundation
import Combine
import Foundation

struct StreamSource {
    let urlString: String
    let username: String?
    let password: String?
}

/// Owns the RTSP session and the media pipeline, reconnects automatically and publishes
/// the state shown in the UI.
final class StreamPlayer: ObservableObject {
    @Published private(set) var state: PlayerState = .idle
    @Published private(set) var info = PlaybackInfo()

    /// The view that displays the video. It is owned by the player (not by SwiftUI), so it
    /// survives switching between the normal and the fullscreen layout without reconnecting.
    let videoView: VideoDisplayView

    private static let connectTimeout: CFAbsoluteTime = 10
    private static let dataTimeout: CFAbsoluteTime = 8
    private static let stableSessionAge: CFAbsoluteTime = 15
    private static let reconnectDelays: [Double] = [0.5, 1, 2, 3, 5]

    private let source: StreamSource
    private let queue = DispatchQueue(label: "rtspviewer.player", qos: .userInitiated)
    private let pipeline: MediaPipeline
    private var interruptionObserver: NSObjectProtocol?

    // Everything below is confined to `queue`.
    private var client: RTSPClient?
    private var isActive = false
    private var isPlaying = false
    private var hasFatalError = false
    private var isAudioSessionActive = false
    private var connectStartedAt: CFAbsoluteTime = 0
    private var lastDataAt: CFAbsoluteTime = 0
    private var reconnectAttempt = 0
    private var reconnectCount = 0
    private var reconnectWork: DispatchWorkItem?
    private var nextReconnectAt: CFAbsoluteTime?
    private var lastError: String?
    private var codecName = "—"
    private var audioCodecName = "—"
    private var timer: DispatchSourceTimer?
    private var publishedState: PlayerState = .idle
    private var publishedInfo = PlaybackInfo()
    private var lastInfoPublish: CFAbsoluteTime = 0

    @MainActor
    init(source: StreamSource) {
        self.source = source
        let view = VideoDisplayView()
        videoView = view
        pipeline = MediaPipeline(layer: view.displayLayer)

        // After a phone call / Siri etc. the audio session has to be activated again.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended else { return }
            self?.queue.async { [weak self] in
                guard let self, self.isActive, self.isAudioSessionActive else { return }
                AudioSession.activate()
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        timer?.cancel()
        let client = self.client
        let deactivateAudio = isAudioSessionActive
        queue.async {
            client?.stop()
            if deactivateAudio {
                AudioSession.deactivate()
            }
        }
    }

    // MARK: - Public API

    func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            hasFatalError = false
            reconnectAttempt = 0
            lastError = nil
            pipeline.reset()
            startTimer()
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            guard isActive else { return }
            isActive = false
            reconnectWork?.cancel()
            reconnectWork = nil
            nextReconnectAt = nil
            client?.stop()
            client = nil
            isPlaying = false
            timer?.cancel()
            timer = nil
            pipeline.reset()
            if isAudioSessionActive {
                AudioSession.deactivate()
                isAudioSessionActive = false
            }
            publish(state: .idle)
        }
    }

    /// Drops the current session and buffered media and connects again from scratch.
    func reconnect() {
        queue.async { [self] in
            guard isActive else { return }
            reconnectWork?.cancel()
            reconnectWork = nil
            reconnectAttempt = 0
            hasFatalError = false
            lastError = nil
            client?.stop()
            client = nil
            pipeline.reset()
            connect()
        }
    }

    // MARK: - Connection management

    private func connect() {
        guard isActive else { return }
        reconnectWork = nil
        nextReconnectAt = nil
        client?.stop()
        client = nil
        isPlaying = false

        let endpoint: RTSPEndpoint
        do {
            endpoint = try RTSPEndpoint(urlString: source.urlString)
        } catch {
            hasFatalError = true
            lastError = RTSPError.describe(error)
            return
        }

        let newClient = RTSPClient(
            endpoint: endpoint,
            username: source.username ?? endpoint.username,
            password: source.password ?? endpoint.password,
            queue: queue
        )
        newClient.onTracks = { [weak self] video, audio, unsupportedAudio in
            self?.configure(video: video, audio: audio, unsupportedAudio: unsupportedAudio)
        }
        newClient.onRTPPacket = { [weak self] kind, packet in
            guard let self else { return }
            self.lastDataAt = CFAbsoluteTimeGetCurrent()
            self.pipeline.handle(packet, kind: kind)
        }
        newClient.onSenderReport = { [weak self] kind, report in
            self?.pipeline.handle(report, kind: kind)
        }
        newClient.onPlaying = { [weak self] in
            guard let self else { return }
            self.isPlaying = true
            self.lastDataAt = CFAbsoluteTimeGetCurrent()
        }
        newClient.onFailure = { [weak self] error in
            self?.handleFailure(error)
        }
        client = newClient
        connectStartedAt = CFAbsoluteTimeGetCurrent()
        newClient.start()
    }

    private func configure(video: VideoTrack, audio: AudioTrack?, unsupportedAudio: String?) {
        codecName = video.codec.displayName
        if audio != nil && !isAudioSessionActive {
            AudioSession.activate()
            isAudioSessionActive = true
        }
        pipeline.configure(video: video, audio: audio)

        if let description = pipeline.audioDescription {
            audioCodecName = description
        } else if let audio {
            audioCodecName = "Nieobsługiwany (\(audio.displayName))"
        } else if let unsupportedAudio {
            audioCodecName = "Nieobsługiwany (\(unsupportedAudio))"
        } else {
            audioCodecName = "Brak"
        }
    }

    private func handleFailure(_ error: Error) {
        guard isActive else { return }
        client?.stop()
        client = nil
        isPlaying = false
        lastError = RTSPError.describe(error)

        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        reconnectCount += 1
        nextReconnectAt = CFAbsoluteTimeGetCurrent() + delay

        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnectWork?.cancel()
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Periodic work

    private func startTimer() {
        timer?.cancel()
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        newTimer.setEventHandler { [weak self] in
            self?.tick()
        }
        newTimer.resume()
        timer = newTimer
    }

    private func tick() {
        guard isActive else { return }
        let now = CFAbsoluteTimeGetCurrent()

        // Watchdog: a hung handshake or a stream that silently stopped → reconnect.
        if client != nil {
            if !isPlaying {
                if now - connectStartedAt > Self.connectTimeout {
                    handleFailure(RTSPError.connectTimeout)
                }
            } else if now - lastDataAt > Self.dataTimeout {
                handleFailure(RTSPError.noData)
            } else if now - connectStartedAt > Self.stableSessionAge {
                reconnectAttempt = 0
            }
        }

        let phase = pipeline.tick(now: now)
        let newState: PlayerState
        if client == nil {
            newState = .disconnected
        } else if !isPlaying || !pipeline.hasStarted {
            newState = .connecting
        } else {
            switch phase {
            case .buffering:
                newState = .buffering
            case .live:
                newState = .live
            case .catchingUp(let rate):
                newState = .catchingUp(rate: rate)
            }
        }
        if newState == .live {
            lastError = nil
        }
        publish(state: newState)

        if now - lastInfoPublish >= 0.5 {
            lastInfoPublish = now
            publishInfo(for: newState, now: now)
        }
    }

    private func publish(state newState: PlayerState) {
        guard newState != publishedState else { return }
        publishedState = newState
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }

    private func publishInfo(for currentState: PlayerState, now: CFAbsoluteTime) {
        var newInfo = PlaybackInfo()
        newInfo.codec = codecName
        newInfo.audioCodec = audioCodecName
        newInfo.hasAudio = pipeline.audioDescription != nil
        if let dimensions = pipeline.dimensions {
            newInfo.width = Int(dimensions.width)
            newInfo.height = Int(dimensions.height)
        }
        newInfo.framesPerSecond = pipeline.framesPerSecond
        newInfo.bufferMilliseconds = Int((pipeline.bufferedSeconds * 1000).rounded())
        newInfo.clockRate = pipeline.measuredClockRate
        newInfo.liveJumps = pipeline.liveJumps
        newInfo.reconnects = reconnectCount

        if let lastError, currentState != .live {
            if hasFatalError {
                newInfo.message = lastError
            } else if currentState == .disconnected, let nextReconnectAt {
                let seconds = max(0, Int((nextReconnectAt - now).rounded(.up)))
                newInfo.message = "\(lastError) Ponowna próba za \(seconds) s."
            } else {
                newInfo.message = lastError
            }
        }

        guard newInfo != publishedInfo else { return }
        publishedInfo = newInfo
        DispatchQueue.main.async { [weak self] in
            self?.info = newInfo
        }
    }
}

/// Audio session for camera sound: plays even with the ring/silent switch set to silent.
enum AudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
