import Foundation
import Network

enum RTSPError: LocalizedError {
    case invalidURL
    case connectionClosed
    case connectTimeout
    case noData
    case credentialsRequired
    case unauthorized
    case badStatus(method: String, code: Int, reason: String)
    case noSupportedVideo(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Nieprawidłowy adres RTSP."
        case .connectionClosed:
            return "Kamera zamknęła połączenie."
        case .connectTimeout:
            return "Przekroczono czas nawiązywania połączenia."
        case .noData:
            return "Strumień przestał przesyłać dane."
        case .credentialsRequired:
            return "Kamera wymaga loginu i hasła."
        case .unauthorized:
            return "Nieprawidłowy login lub hasło."
        case let .badStatus(method, code, reason):
            return "\(method): błąd \(code) \(reason)".trimmingCharacters(in: .whitespaces)
        case .noSupportedVideo(let codecs):
            if codecs.isEmpty {
                return "Strumień nie zawiera ścieżki wideo."
            }
            return "Nieobsługiwany kodek wideo (\(codecs)). Obsługiwane są H.264 i H.265."
        case .protocolError(let detail):
            return "Błąd protokołu RTSP: \(detail)."
        }
    }

    /// Human readable (Polish) description of any error coming from the RTSP stack or Network.framework.
    static func describe(_ error: Error) -> String {
        if let rtspError = error as? RTSPError, let description = rtspError.errorDescription {
            return description
        }
        if let networkError = error as? NWError {
            switch networkError {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED:
                    return "Kamera odrzuciła połączenie."
                case .ETIMEDOUT:
                    return "Przekroczono czas połączenia."
                case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
                    return "Kamera jest nieosiągalna."
                case .ECONNRESET, .EPIPE, .ECONNABORTED:
                    return "Połączenie zostało zerwane."
                default:
                    return "Błąd sieci (\(code.rawValue))."
                }
            case .dns(let code):
                if code == -65570 {
                    return "Brak zgody na dostęp do sieci lokalnej (Ustawienia › Prywatność › Sieć lokalna)."
                }
                return "Nie można odnaleźć hosta."
            case .tls:
                return "Błąd połączenia TLS."
            default:
                return "Błąd sieci."
            }
        }
        return error.localizedDescription
    }
}
