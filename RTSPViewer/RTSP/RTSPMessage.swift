import Foundation

/// An RTSP response (or a request sent by the server, which we ignore).
struct RTSPMessage {
    let isResponse: Bool
    let statusCode: Int
    let reason: String
    let headers: [(name: String, value: String)]
    var body = Data()

    init?(headerText: String) {
        let lines = headerText.split(whereSeparator: { $0.isNewline })
        guard let startLine = lines.first else { return nil }

        let parts = startLine.split(separator: " ", maxSplits: 2)
        if let proto = parts.first, proto.hasPrefix("RTSP/"), parts.count >= 2, let code = Int(parts[1]) {
            isResponse = true
            statusCode = code
            reason = parts.count > 2 ? String(parts[2]) : ""
        } else {
            isResponse = false
            statusCode = 0
            reason = ""
        }

        var parsed: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed.append((name: name, value: value))
        }
        headers = parsed
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    var cseq: Int? { header("CSeq").flatMap { Int($0) } }

    var contentLength: Int { max(0, header("Content-Length").flatMap { Int($0) } ?? 0) }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func headerValues(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { $0.value }
    }
}

/// Growable byte buffer with cheap consumption from the front.
struct ByteBuffer {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    subscript(offset: Int) -> UInt8 { storage[head + offset] }

    mutating func append(_ data: Data) {
        storage.append(contentsOf: data)
    }

    mutating func consume(_ length: Int) {
        head += length
        if head >= storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 1 << 20 {
            storage.removeFirst(head)
            head = 0
        }
    }

    func bytes(at offset: Int, count length: Int) -> [UInt8] {
        let start = head + offset
        return Array(storage[start..<(start + length)])
    }

    /// True when the buffered bytes agree with `pattern` on their common length.
    func matchesStart(of pattern: [UInt8]) -> Bool {
        let length = min(count, pattern.count)
        for index in 0..<length where storage[head + index] != pattern[index] {
            return false
        }
        return true
    }

    func firstIndex(of pattern: [UInt8], searchLimit: Int) -> Int? {
        let last = min(count, searchLimit) - pattern.count
        guard last >= 0 else { return nil }
        var index = 0
        outer: while index <= last {
            for offset in 0..<pattern.count where storage[head + index + offset] != pattern[offset] {
                index += 1
                continue outer
            }
            return index
        }
        return nil
    }
}
