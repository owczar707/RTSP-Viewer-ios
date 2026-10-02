import CoreGraphics
import Foundation

/// What the status badge in the top-right corner of the player shows.
enum PlayerState: Equatable {
    /// Player stopped (screen closed / app in background).
    case idle
    /// Establishing the RTSP session or waiting for the first picture.
    case connecting
    /// Session is up but no new frames are arriving – the picture is frozen.
    case buffering
    /// Playing in real time.
    case live
    /// Playing faster than real time to make up for a delay.
    case catchingUp(rate: Double)
    /// Connection lost – waiting before the next reconnect attempt.
    case disconnected

    var title: String {
        switch self {
        case .idle: return "Zatrzymany"
        case .connecting: return "Łączenie…"
        case .buffering: return "Oczekiwanie na obraz…"
        case .live: return "Na żywo"
        case .catchingUp(let rate): return String(format: "Nadrabianie opóźnienia (%.1f×)", rate)
        case .disconnected: return "Brak połączenia"
        }
    }
}

struct PlaybackInfo: Equatable {
    var codec = "—"
    var audioCodec = "—"
    var hasAudio = false
    var width = 0
    var height = 0
    var framesPerSecond: Double = 0
    var bufferMilliseconds = 0
    /// Measured speed of the playback clock (1.0 = real time).
    var clockRate: Double = 0
    var liveJumps = 0
    var reconnects = 0
    var message: String?

    var resolutionText: String { width > 0 ? "\(width)×\(height)" : "—" }

    var framesPerSecondText: String { framesPerSecond > 0 ? String(format: "%.0f", framesPerSecond) : "—" }

    var aspectRatio: CGFloat? {
        guard width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}
