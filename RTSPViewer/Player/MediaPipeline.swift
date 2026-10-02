import AVFoundation
import CoreMedia
import Foundation

enum PlaybackPhase: Equatable {
    case buffering
    case live
    case catchingUp(Double)
}

/// Decodes video and audio and drives one shared clock (`AVSampleBufferRenderSynchronizer`):
///
/// * keeps a jitter buffer (0.8 s video-only, 0.9 s with audio) so playback is smooth,
/// * freezes the clock when media stops arriving (stall),
/// * when delayed media arrives in a burst after a hiccup, plays it at 1.5–3× (faster the
///   bigger the delay) until the delay is gone ("catching up") – audio keeps its pitch,
/// * if the delay grows beyond `maximumLag`, jumps straight to the newest media.
///
/// When the camera sends audio, audio is the master stream (it must not have gaps);
/// otherwise video is.
///
/// Everything except `init` must be called on the player's queue.
final class MediaPipeline {
    private enum Tuning {
        static let videoBuffer = 0.8
        static let audioBuffer = 0.9
        /// Catching up starts when this much more than the buffer is queued…
        static let catchUpMargin = 0.7
        /// …and ends when the excess drops below this.
        static let catchUpExitMargin = 0.15
        static let maximumLag = 12.0
        static let stallIndicatorDelay = 0.6
        static let streamActiveWindow = 1.5
        /// How often catching up is checked for actually shrinking the delay.
        static let catchUpCheckInterval = 3.0
        /// Minimum delay reduction per second of catching up (at 1.5× it should be 0.5 s/s).
        static let catchUpMinimumProgress = 0.15
        /// Playback rate by excess delay (seconds above the buffer), checked top to bottom.
        static let catchUpRates: [(excess: Double, rate: Double)] = [
            (2.5, 3.0),
            (1.0, 2.0),
            (0.0, 1.5),
        ]
    }

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let video: VideoDecoder
    private var audio: AudioDecoder?
    private var isAudioRendererAttached = false
    private let timeline = MediaTimeline()

    // Clock
    private(set) var hasStarted = false
    private var rate: Double = 0
    private var pausedAt: CFAbsoluteTime?
    private var phase: PlaybackPhase = .buffering
    private var latestVideoTime: Double = 0
    private var latestAudioEnd: Double = 0
    private var lastVideoEnqueue: CFAbsoluteTime = 0
    private var lastAudioEnqueue: CFAbsoluteTime = 0
    private var lastVideoFrameTime: Double?
    private var frameDuration: Double = 0.04
    private var catchUpCheck: (wall: CFAbsoluteTime, lead: Double)?

    // Statistics
    private(set) var framesPerSecond: Double = 0
    private(set) var bufferedSeconds: Double = 0
    /// How fast the playback clock really moved during the last second (diagnostics).
    private(set) var measuredClockRate: Double = 0
    /// How many times playback skipped ahead to live instead of catching up.
    private(set) var liveJumps = 0
    private var clockSample: (wall: CFAbsoluteTime, clock: Double)?
    private var frameCounter = 0
    private var frameCounterStart: CFAbsoluteTime = 0

    var dimensions: CMVideoDimensions? { video.dimensions }
    var audioDescription: String? { audio?.track.displayName }

    init(layer: AVSampleBufferDisplayLayer) {
        video = VideoDecoder(renderer: layer.sampleBufferRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(layer)
        synchronizer.setRate(0, time: .zero)
        audioRenderer.audioTimePitchAlgorithm = .spectral
    }

    // MARK: - Session lifecycle

    /// Called for every new RTSP session (first connect and each reconnect).
    func configure(video videoTrack: VideoTrack, audio audioTrack: AudioTrack?) {
        video.configure(track: videoTrack)

        if let audioTrack {
            if let audio, audio.track == audioTrack {
                audio.resetDepacketizer()
            } else {
                if audio != nil {
                    audioRenderer.flush()
                }
                audio = AudioDecoder(track: audioTrack, renderer: audioRenderer)
            }
            if audio != nil && !isAudioRendererAttached {
                // Attached lazily: a synchronizer with an audio renderer runs on the audio
                // hardware clock, which video-only cameras don't need.
                synchronizer.addRenderer(audioRenderer)
                isAudioRendererAttached = true
            }
        } else {
            audio = nil
        }

        timeline.beginSession(
            videoClockRate: Double(videoTrack.clockRate),
            audioClockRate: audio.map { Double($0.track.clockRate) }
        )
        lastVideoFrameTime = nil
    }

    /// Stops playback and drops queued media (player stopped / app went to background).
    func reset() {
        setRate(0)
        video.reset()
        audioRenderer.flush()
        audio?.resetDepacketizer()
        hasStarted = false
        pausedAt = nil
        phase = .buffering
        framesPerSecond = 0
        frameCounter = 0
        bufferedSeconds = 0
        measuredClockRate = 0
    }

    func handle(_ packet: RTPPacket, kind: MediaKind) {
        let now = CFAbsoluteTimeGetCurrent()
        switch kind {
        case .video:
            for unit in video.accessUnits(from: packet) {
                guard let time = timeline.time(for: .video, timestamp: unit.timestamp, arrival: now) else { continue }
                trackFrameDuration(time)
                if video.decode(unit, at: time) {
                    didEnqueue(at: time, gapThreshold: max(0.6, frameDuration * 4), now: now)
                    latestVideoTime = max(latestVideoTime, time)
                    lastVideoEnqueue = now
                    countFrame(now: now)
                }
            }
        case .audio:
            guard let audio else { return }
            for frame in audio.frames(from: packet) {
                guard let time = timeline.time(for: .audio, timestamp: frame.timestamp, arrival: now) else { continue }
                if let duration = audio.decode(frame, at: time) {
                    didEnqueue(at: time, gapThreshold: 0.6, now: now)
                    latestAudioEnd = max(latestAudioEnd, time + duration)
                    lastAudioEnqueue = now
                }
            }
        }
    }

    func handle(_ report: RTCP.SenderReport, kind: MediaKind) {
        timeline.senderReport(for: kind, report: report)
    }

    // MARK: - Clock control

    /// Called periodically (every 50 ms). Adjusts the playback rate and reports the phase.
    func tick(now: CFAbsoluteTime) -> PlaybackPhase {
        video.checkHealth()
        if audioRenderer.status == .failed {
            audioRenderer.flush()
        }
        guard hasStarted else {
            phase = .buffering
            bufferedSeconds = 0
            return phase
        }
        if synchronizer.rate != Float(rate) {
            synchronizer.rate = Float(rate) // e.g. after an audio interruption
        }

        let audioIsMaster = audio != nil && now - lastAudioEnqueue < Tuning.streamActiveWindow
        let latest = audioIsMaster ? latestAudioEnd : latestVideoTime
        let time = currentTime
        let lead = latest - time
        bufferedSeconds = max(0, lead)
        measureClockRate(time: time, now: now)

        let target = audioIsMaster ? Tuning.audioBuffer : max(Tuning.videoBuffer, frameDuration * 1.5)
        let catchUpStart = target + max(Tuning.catchUpMargin, audioIsMaster ? 0 : frameDuration * 2)
        let catchUpStop = target + Tuning.catchUpExitMargin

        if rate == 0 {
            // Frozen: resume once enough media is buffered.
            if lead >= target {
                setRate(lead > catchUpStart ? catchUpRate(forExcess: lead - target) : 1.0)
                pausedAt = nil
            }
        } else if lead <= 0 {
            // Ran out of media – freeze on the last picture.
            setRate(0)
            setTime(latest)
            pausedAt = now
        } else if lead > Tuning.maximumLag {
            // Too far behind to catch up in reasonable time.
            jumpToLive(latest: latest, target: target)
        } else if rate > 1.0 {
            if lead <= catchUpStop {
                setRate(1.0)
            } else if catchUpIsIneffective(lead: lead, now: now) {
                // Faster playback isn't shrinking the delay – skip to live instead.
                jumpToLive(latest: latest, target: target)
            } else {
                // Catching up: slow down step by step as the delay shrinks.
                setRate(catchUpRate(forExcess: lead - target))
            }
        } else if lead > catchUpStart {
            setRate(catchUpRate(forExcess: lead - target))
        }

        if rate > 1.0 {
            phase = .catchingUp(rate)
        } else if rate > 0 {
            phase = .live
        } else if let pausedAt, now - pausedAt >= Tuning.stallIndicatorDelay {
            phase = .buffering
        }
        return phase
    }

    private func catchUpRate(forExcess excess: Double) -> Double {
        Tuning.catchUpRates.first { excess >= $0.excess }?.rate ?? 1.5
    }

    /// True when, over the last few seconds of fast playback, the delay did not shrink as it should.
    private func catchUpIsIneffective(lead: Double, now: CFAbsoluteTime) -> Bool {
        guard let check = catchUpCheck else {
            catchUpCheck = (wall: now, lead: lead)
            return false
        }
        let elapsed = now - check.wall
        guard elapsed >= Tuning.catchUpCheckInterval else { return false }
        catchUpCheck = (wall: now, lead: lead)
        return check.lead - lead < elapsed * Tuning.catchUpMinimumProgress
    }

    /// Skips straight to the newest media. Queued audio would otherwise be played late, so drop it.
    private func jumpToLive(latest: Double, target: Double) {
        audioRenderer.flush()
        setTime(latest - target)
        setRate(1.0)
        liveJumps += 1
    }

    private func measureClockRate(time: Double, now: CFAbsoluteTime) {
        guard let sample = clockSample else {
            clockSample = (wall: now, clock: time)
            return
        }
        let elapsed = now - sample.wall
        guard elapsed >= 1 else { return }
        measuredClockRate = max(0, (time - sample.clock) / elapsed)
        clockSample = (wall: now, clock: time)
    }

    private var currentTime: Double {
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    private func setTime(_ seconds: Double) {
        synchronizer.setRate(Float(rate), time: CMTime(seconds: seconds, preferredTimescale: 90_000))
        clockSample = nil // a jump would distort the measured clock rate
    }

    private func setRate(_ newRate: Double) {
        guard newRate != rate else { return }
        rate = newRate
        synchronizer.rate = Float(newRate)
        if newRate <= 1.0 {
            catchUpCheck = nil
        }
    }

    private func didEnqueue(at time: Double, gapThreshold: Double, now: CFAbsoluteTime) {
        let clock = currentTime
        if !hasStarted {
            // First media: show it immediately, then wait for the jitter buffer to fill.
            hasStarted = true
            setRate(0)
            setTime(time)
            pausedAt = now
        } else if rate == 0
                    && clock >= max(latestVideoTime, latestAudioEnd) - 0.001
                    && time - clock > gapThreshold {
            // Frozen with nothing queued and the next media is far ahead (e.g. after waiting
            // for a keyframe) – skip the empty interval instead of showing a frozen frame.
            setTime(time)
        }
    }

    private func trackFrameDuration(_ time: Double) {
        if let last = lastVideoFrameTime {
            let delta = time - last
            if delta > 0.004 && delta < 0.5 {
                frameDuration = frameDuration * 0.9 + delta * 0.1
            }
        }
        lastVideoFrameTime = time
    }

    private func countFrame(now: CFAbsoluteTime) {
        frameCounter += 1
        if frameCounterStart == 0 {
            frameCounterStart = now
        } else if now - frameCounterStart >= 1 {
            framesPerSecond = Double(frameCounter) / (now - frameCounterStart)
            frameCounter = 0
            frameCounterStart = now
        }
    }
}
