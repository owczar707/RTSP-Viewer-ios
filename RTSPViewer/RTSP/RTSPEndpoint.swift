import Foundation

/// Parsed `rtsp://` / `rtsps://` address.
struct RTSPEndpoint {
    let host: String
    let port: UInt16
    let useTLS: Bool
    /// The URL used in RTSP requests – identical to the user's URL but without credentials.
    let requestURL: String
    let username: String?
    let password: String?

    init(urlString: String) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "rtsp" || scheme == "rtsps",
              var host = components.host,
              !host.isEmpty else {
            throw RTSPError.invalidURL
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        let portValue = components.port ?? (scheme == "rtsps" ? 322 : 554)
        guard portValue > 0, portValue <= Int(UInt16.max) else {
            throw RTSPError.invalidURL
        }

        self.host = host
        self.port = UInt16(portValue)
        self.useTLS = scheme == "rtsps"

        var url = "\(scheme)://" + (host.contains(":") ? "[\(host)]" : host)
        if let explicitPort = components.port {
            url += ":\(explicitPort)"
        }
        url += components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            url += "?\(query)"
        }
        self.requestURL = url

        if let user = components.user, !user.isEmpty {
            self.username = user
        } else {
            self.username = nil
        }
        self.password = components.password
    }

    static func isValid(_ urlString: String) -> Bool {
        (try? RTSPEndpoint(urlString: urlString)) != nil
    }

    /// The URL with the password removed, safe to show on screen.
    static func redacted(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.password = nil
        return components.string ?? trimmed
    }
}
