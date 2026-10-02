import Foundation
import SwiftData

/// A saved RTSP stream. The password (if any) lives in the Keychain, see `KeychainStore`.
@Model
final class CameraStream {
    var id: UUID = UUID()
    var name: String = ""
    var url: String = ""
    var username: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(name: String, url: String, username: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.username = username
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    /// Address without the password, safe to display.
    var displayURL: String {
        RTSPEndpoint.redacted(url)
    }
}

extension StreamSource {
    init(stream: CameraStream) {
        let trimmedUser = stream.username.trimmingCharacters(in: .whitespaces)
        let storedPassword = KeychainStore.password(for: stream.id)
        self.init(
            urlString: stream.url,
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            password: (storedPassword?.isEmpty ?? true) ? nil : storedPassword
        )
    }
}
