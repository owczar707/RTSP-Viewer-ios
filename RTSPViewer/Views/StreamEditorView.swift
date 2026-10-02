import SwiftData
import SwiftUI

struct StreamEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let stream: CameraStream?
    let nextSortOrder: Int

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nazwa, np. Brama wjazdowa", text: $name)
                        .textInputAutocapitalization(.sentences)
                    TextField("rtsp://192.168.1.10:554/stream1", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Strumień")
                } footer: {
                    if showsURLError {
                        Text("Adres musi zaczynać się od rtsp:// lub rtsps:// i zawierać nazwę hosta.")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("Użytkownik", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Hasło", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Logowanie (opcjonalnie)")
                } footer: {
                    Text("Dane logowania można też wpisać w adresie: rtsp://użytkownik:hasło@host/… Hasło jest przechowywane w pęku kluczy iOS.")
                }
            }
            .navigationTitle(stream == nil ? "Nowy strumień" : "Edytuj strumień")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        save()
                    }
                    .disabled(!isURLValid)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isURLValid: Bool {
        RTSPEndpoint.isValid(trimmedURL)
    }

    private var showsURLError: Bool {
        !trimmedURL.isEmpty && !isURLValid
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let stream else { return }
        name = stream.name
        url = stream.url
        username = stream.username
        password = KeychainStore.password(for: stream.id) ?? ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName: String
        if trimmedName.isEmpty {
            finalName = (try? RTSPEndpoint(urlString: trimmedURL))?.host ?? "Kamera"
        } else {
            finalName = trimmedName
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)

        let target: CameraStream
        if let stream {
            target = stream
            target.name = finalName
            target.url = trimmedURL
            target.username = trimmedUser
        } else {
            target = CameraStream(name: finalName, url: trimmedURL, username: trimmedUser, sortOrder: nextSortOrder)
            modelContext.insert(target)
        }
        KeychainStore.setPassword(password, for: target.id)
        dismiss()
    }
}
