import SwiftUI

/// Controls drawn over the video: status badge (top-right), mute button (bottom-left,
/// only when the stream has sound) and fullscreen button (bottom-right).
struct PlayerOverlay: View {
    let state: PlayerState
    let isFullscreen: Bool
    let hasAudio: Bool
    let isMuted: Bool
    let onToggleMute: () -> Void
    let onToggleFullscreen: () -> Void

    var body: some View {
        VStack {
            HStack {
                Spacer()
                StatusBadge(state: state)
            }
            Spacer()
            HStack {
                if hasAudio {
                    OverlayButton(
                        systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        accessibilityLabel: isMuted ? "Włącz dźwięk" : "Wycisz",
                        action: onToggleMute
                    )
                }
                Spacer()
                OverlayButton(
                    systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    accessibilityLabel: isFullscreen ? "Zamknij pełny ekran" : "Pełny ekran",
                    action: onToggleFullscreen
                )
            }
        }
        .padding(10)
    }
}

private struct OverlayButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Spinner while connecting / stalled, stop icon when disconnected,
/// LIVE arrow when real-time, forward icon while catching up.
struct StatusBadge: View {
    let state: PlayerState

    var body: some View {
        content
            .animation(.easeInOut(duration: 0.2), value: state)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.title)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .connecting, .buffering:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(0.5)))
        case .live:
            badge(icon: "play.fill", text: "LIVE", color: .red)
        case .catchingUp(let rate):
            badge(icon: "forward.fill", text: String(format: "%.1f×", rate), color: .orange)
        case .idle, .disconnected:
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(0.5)))
        }
    }

    private func badge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(color.opacity(0.9)))
    }
}
