import Foundation

enum DebugLevel: Int, CaseIterable {
    case off = 0
    case normal = 1
    case verbose = 2

    var title: String {
        switch self {
        case .off:     return "Off"
        case .normal:  return "Normal"
        case .verbose: return "Verbose"
        }
    }

    static var current: DebugLevel {
        get {
            let raw = UserDefaults.standard.object(forKey: "debugLevel") as? Int ?? DebugLevel.normal.rawValue
            return DebugLevel(rawValue: raw) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "debugLevel") }
    }
}

enum DiagnosticLogger {
    static let fileURL = URL(fileURLWithPath: "/tmp/quotawarmer-diagnostics.log")

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func appendHistory(_ event: HistoryEvent) {
        let tool = event.tool?.rawValue ?? "app"
        append("history tool=\(tool) kind=\(event.kind.rawValue) title=\(event.title) detail=\(event.detail)")
    }

    static func append(_ message: String) {
        guard DebugLevel.current != .off else { return }
        let line = "[\(formatter.string(from: Date()))] \(redacted(message))\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func redacted(_ text: String) -> String {
        var output = text
        let patterns = [
            #"sk-[A-Za-z0-9._-]{12,}"#,
            #"Bearer\s+[A-Za-z0-9._-]{12,}"#,
            #"Authorization[:=]\s*[A-Za-z0-9._\-\s]{12,}"#
        ]

        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
        return output
    }
}
