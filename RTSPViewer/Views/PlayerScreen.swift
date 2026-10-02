import SwiftUI
import UIKit

struct PlayerScreen: View {
    let stream: CameraStream

    @StateObject private var player: StreamPlayer
    @State private var isFullscreen = false
    @State private var deviceIsLandscape = false
    @Environment(\.scenePhase) private var scenePhase

    init(stream: CameraStream) {
        self.stream = stream
        _player = StateObject(wrappedValue: StreamPlayer(source: StreamSource(stream: stream)))
    }

    var body: some View {
        // A stable container: switching between the normal and fullscreen layout must not
        // trigger onAppear/onDisappear (that would stop and restart the stream).
        ZStack {
            content
        }
        .navigationTitle(stream.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .onAppear {
            player.start()
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            deviceIsLandscape = UIDevice.current.orientation.isLandscape
        }
        .onDisappear {
            player.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            if isFullscreen {
                isFullscreen = false
                OrientationController.shared.exitFullscreen()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                player.start()
            case .background:
                player.stop()
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            handleDeviceRotation()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isFullscreen {
            ZStack {
                Color.black
                    .ignoresSafeArea()
                ZoomableVideoView(player: player)
                    .ignoresSafeArea()
                overlay
            }
        } else {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    ZoomableVideoView(player: player)
                    overlay
                }
                .aspectRatio(videoAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .layoutPriority(1)

                StreamDetailsView(stream: stream, player: player)
            }
        }
    }

    private var overlay: some View {
        PlayerOverlay(
            state: player.state,
            isFullscreen: isFullscreen,
            hasAudio: player.info.hasAudio,
            isMuted: player.isMuted,
            onToggleMute: { player.setMuted(!player.isMuted) },
            onToggleFullscreen: { setFullscreen(!isFullscreen) }
        )
    }

    /// Video box follows the camera's aspect ratio (clamped so portrait cameras don't take the whole screen).
    private var videoAspectRatio: CGFloat {
        guard let ratio = player.info.aspectRatio else { return 16.0 / 9.0 }
        return min(max(ratio, 1.0), 2.4)
    }

    /// Rotating the phone to landscape enters fullscreen, rotating back to portrait leaves it.
    private func handleDeviceRotation() {
        let orientation = UIDevice.current.orientation
        guard orientation.isLandscape || orientation == .portrait else { return }
        let landscape = orientation.isLandscape
        guard landscape != deviceIsLandscape else { return }
        deviceIsLandscape = landscape
        guard OrientationController.shared.isPhone else { return }
        setFullscreen(landscape)
    }

    private func setFullscreen(_ value: Bool) {
        guard value != isFullscreen else { return }
        isFullscreen = value
        if value {
            OrientationController.shared.enterFullscreen()
        } else {
            OrientationController.shared.exitFullscreen()
        }
    }
}
