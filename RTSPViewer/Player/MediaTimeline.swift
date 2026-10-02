import Foundation

/// Places the RTP timestamps of the video and audio tracks on one shared, monotonic
/// playback timeline (in seconds).
///
/// * Each RTSP session continues where the previous one ended, so reconnects never move
///   the timeline backwards.
/// * Within a session both tracks are first anchored to the arrival time of their first
///   packet, which keeps them roughly aligned from the very first frame.
/// * As soon as the camera has sent an RTCP Sender Report for both tracks, the tracks are
///   aligned exactly (lip sync) using the NTP ↔ RTP mapping from those reports.
final class MediaTimeline {
    private var clocks: [MediaKind: TrackClock] = [:]
    private var sessionOrigin: Double = 0
    private var wallOrigin: CFAbsoluteTime?
    private var isSynchronized = false

    /// Latest time handed out so far.
    private(set) var end: Double = 0

    func beginSession(videoClockRate: Double, audioClockRate: Double?) {
        sessionOrigin = end + 0.1
        wallOrigin = nil
        isSynchronized = false
        var newClocks: [MediaKind: TrackClock] = [.video: TrackClock(clockRate: videoClockRate)]
        if let audioClockRate {
            newClocks[.audio] = TrackClock(clockRate: audioClockRate)
        }
        clocks = newClocks
    }

    func time(for kind: MediaKind, timestamp: UInt32, arrival: CFAbsoluteTime) -> Double? {
        guard let clock = clocks[kind] else { return nil }
        let origin = wallOrigin ?? arrival
        wallOrigin = origin
        let time = clock.time(for: timestamp, arrivalTime: sessionOrigin + (arrival - origin))
        end = max(end, time)
        return time
    }

    func senderReport(for kind: MediaKind, report: RTCP.SenderReport) {
        guard let clock = clocks[kind] else { return }
        clock.senderReport(report)

        guard !isSynchronized,
              let video = clocks[.video],
              let audio = clocks[.audio],
              let videoTime = video.timelineTime(atNTP: report.ntpTime),
              let audioTime = audio.timelineTime(atNTP: report.ntpTime) else { return }
        isSynchronized = true

        // Both values describe the same moment of capture – make them equal. Only ever shift
        // a track forward so timestamps handed to the renderers stay monotonic.
        let offset = videoTime - audioTime
        guard abs(offset) > 0.02, abs(offset) < 3 else { return }
        if offset > 0 {
            audio.shift(by: offset)
        } else {
            video.shift(by: -offset)
        }
    }
}

/// RTP timestamp → timeline mapping of a single track.
private final class TrackClock {
    private let clockRate: Double
    private var lastTimestamp: UInt32?
    private var extended: Int64 = 0
    private var anchorExtended: Int64 = 0
    private var anchorTime: Double = 0
    private var latestTime: Double = 0
    private var reportNTP: Double?
    private var reportExtended: Int64 = 0

    init(clockRate: Double) {
        self.clockRate = clockRate > 0 ? clockRate : 90_000
    }

    func time(for timestamp: UInt32, arrivalTime: Double) -> Double {
        if let last = lastTimestamp {
            let difference = Int64(Int32(bitPattern: timestamp &- last))
            extended += difference
            let delta = Double(difference) / clockRate
            if delta > 5 || delta < -1 {
                // Discontinuity (camera restarted its clock etc.) – re-anchor.
                anchorExtended = extended
                anchorTime = max(arrivalTime, latestTime)
            }
        } else {
            anchorTime = arrivalTime
        }
        lastTimestamp = timestamp
        let time = anchorTime + Double(extended - anchorExtended) / clockRate
        latestTime = max(latestTime, time)
        return time
    }

    func senderReport(_ report: RTCP.SenderReport) {
        guard let last = lastTimestamp else { return }
        reportNTP = report.ntpTime
        reportExtended = extended + Int64(Int32(bitPattern: report.rtpTimestamp &- last))
    }

    /// Timeline position of the media captured at wall-clock `ntp`.
    func timelineTime(atNTP ntp: Double) -> Double? {
        guard let reportNTP else { return nil }
        let extendedAtNTP = Double(reportExtended) + (ntp - reportNTP) * clockRate
        return anchorTime + (extendedAtNTP - Double(anchorExtended)) / clockRate
    }

    func shift(by seconds: Double) {
        anchorTime += seconds
    }
}
