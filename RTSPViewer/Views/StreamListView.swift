import SwiftData
import SwiftUI
import UIKit

private enum EditorRoute: Identifiable {
    case new
    case edit(CameraStream)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let stream): return stream.id.uuidString
        }
    }
}

struct StreamListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\CameraStream.sortOrder), SortDescriptor(\CameraStream.createdAt)])
    private var streams: [CameraStream]
    @State private var editor: EditorRoute?

    var body: some View {
        NavigationStack {
            Group {
                if streams.isEmpty {
                    emptyState
                } else {
                    streamList
                }
            }
            .navigationTitle("Kamery")
            .navigationDestination(for: CameraStream.self) { stream in
                PlayerScreen(stream: stream)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .disabled(streams.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = .new
                    } label: {
                        Label("Dodaj strumień", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editor) { route in
                switch route {
                case .new:
                    StreamEditorView(stream: nil, nextSortOrder: nextSortOrder)
                case .edit(let stream):
                    StreamEditorView(stream: stream, nextSortOrder: nextSortOrder)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Brak strumieni", systemImage: "video.slash")
        } description: {
            Text("Dodaj adres RTSP swojej kamery i nadaj mu przyjazną nazwę.")
        } actions: {
            Button("Dodaj strumień") {
                editor = .new
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var streamList: some View {
        List {
            ForEach(streams) { stream in
                NavigationLink(value: stream) {
                    StreamRow(stream: stream)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        delete(stream)
                    } label: {
                        Label("Usuń", systemImage: "trash")
                    }
                    Button {
                        editor = .edit(stream)
                    } label: {
                        Label("Edytuj", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button {
                        editor = .edit(stream)
                    } label: {
                        Label("Edytuj", systemImage: "pencil")
                    }
                    Button {
                        UIPasteboard.general.string = stream.url
                    } label: {
                        Label("Kopiuj adres", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        delete(stream)
                    } label: {
                        Label("Usuń", systemImage: "trash")
                    }
                }
            }
            .onMove(perform: move)
            .onDelete { offsets in
                let doomed = offsets.map { streams[$0] }
                doomed.forEach { delete($0) }
            }
        }
    }

    private var nextSortOrder: Int {
        (streams.map(\.sortOrder).max() ?? -1) + 1
    }

    private func delete(_ stream: CameraStream) {
        KeychainStore.setPassword(nil, for: stream.id)
        modelContext.delete(stream)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = streams
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, stream) in reordered.enumerated() {
            stream.sortOrder = index
        }
    }
}

private struct StreamRow: View {
    let stream: CameraStream

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(stream.name)
                    .font(.headline)
                Text(stream.displayURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}
