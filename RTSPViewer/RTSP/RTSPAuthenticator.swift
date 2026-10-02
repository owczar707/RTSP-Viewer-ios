import CryptoKit
import Foundation

/// Basic and Digest (RFC 2617) authentication for RTSP requests.
final class RTSPAuthenticator {
    private enum Scheme {
        case basic
        case digest
    }

    private let username: String
    private let password: String
    private var scheme: Scheme?
    private var realm = ""
    private var nonce = ""
    private var opaque: String?
    private var qop: String?
    private var algorithm: String?
    private var nonceCount = 0

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Reads the `WWW-Authenticate` challenge(s) of a 401 response. Prefers Digest over Basic.
    func update(with response: RTSPMessage) -> Bool {
        var offersBasic = false
        for challenge in response.headerValues("WWW-Authenticate") {
            let trimmed = challenge.trimmingCharacters(in: .whitespaces)
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("digest") {
                let parameters = Self.parseParameters(String(trimmed.dropFirst("digest".count)))
                guard let newNonce = parameters["nonce"] else { continue }
                scheme = .digest
                realm = parameters["realm"] ?? ""
                nonce = newNonce
                opaque = parameters["opaque"]
                qop = parameters["qop"]
                algorithm = parameters["algorithm"]
                nonceCount = 0
                return true
            } else if lowercased.hasPrefix("basic") {
                offersBasic = true
            }
        }
        if offersBasic {
            scheme = .basic
            return true
        }
        return false
    }

    func authorization(method: String, uri: String) -> String? {
        guard let scheme else { return nil }
        switch scheme {
        case .basic:
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case .digest:
            let ha1 = md5("\(username):\(realm):\(password)")
            let ha2 = md5("\(method):\(uri)")
            var fields = [
                "username=\"\(username)\"",
                "realm=\"\(realm)\"",
                "nonce=\"\(nonce)\"",
                "uri=\"\(uri)\"",
            ]
            let response: String
            if supportsQopAuth {
                nonceCount += 1
                let nc = String(format: "%08x", nonceCount)
                let cnonce = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                response = md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
                fields.append("qop=auth")
                fields.append("nc=\(nc)")
                fields.append("cnonce=\"\(cnonce)\"")
            } else {
                response = md5("\(ha1):\(nonce):\(ha2)")
            }
            fields.append("response=\"\(response)\"")
            if let opaque {
                fields.append("opaque=\"\(opaque)\"")
            }
            if let algorithm {
                fields.append("algorithm=\(algorithm)")
            }
            return "Digest " + fields.joined(separator: ", ")
        }
    }

    private var supportsQopAuth: Bool {
        guard let qop else { return false }
        return qop.lowercased()
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "auth" }
    }

    private func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Parses `key=value, key="quoted, value"` lists.
    static func parseParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false

        func commit() {
            let name = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !name.isEmpty && !readingKey {
                result[name] = value.trimmingCharacters(in: .whitespaces)
            }
            key = ""
            value = ""
            readingKey = true
        }

        for character in text {
            if readingKey {
                if character == "=" {
                    readingKey = false
                } else if character == "," {
                    key = ""
                } else {
                    key.append(character)
                }
            } else if inQuotes {
                if character == "\"" {
                    inQuotes = false
                } else {
                    value.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }
}
