import SwiftUI

/// Information shown under the video in the non-fullscreen layout.
struct StreamDetailsView: View {
    let stream: CameraStream
    @ObservedObject var player: StreamPlayer

    var body: some View {
        List {
            Section("Stan") {
                LabeledContent("Status", value: player.state.title)
                if let message = player.info.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Strumień") {
                LabeledContent("Kodek wideo", value: player.info.codec)
                LabeledContent("Dźwięk", value: player.info.audioCodec)
                LabeledContent("Rozdzielczość", value: player.info.resolutionText)
                LabeledContent("Klatki/s", value: player.info.framesPerSecondText)
                LabeledContent("Bufor", value: "\(player.info.bufferMilliseconds) ms")
                LabeledContent("Tempo zegara", value: String(format: "%.2f×", player.info.clockRate))
                LabeledContent("Przeskoki do „na żywo”", value: "\(player.info.liveJumps)")
                LabeledContent("Ponowne połączenia", value: "\(player.info.reconnects)")
            }

            Section("Adres") {
                Text(stream.displayURL)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }

            Section {
                Label("Rozsuń dwa palce, aby przybliżyć obraz. Dwukrotne stuknięcie przybliża lub przywraca widok.", systemImage: "hand.pinch")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }
}
