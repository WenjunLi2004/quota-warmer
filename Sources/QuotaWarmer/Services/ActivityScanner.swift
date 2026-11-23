import Foundation

struct DayActivity {
    let date: Date
    let sessionCount: Int
}

class ActivityScanner {

    private let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Public

    /// Most-recent message timestamp across all log files (display only).
    func lastActivity(for tool: ToolID, directories: [URL]? = nil) -> Date? {
        let roots = (directories ?? tool.activityDirectoryURLs).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !roots.isEmpty else { return nil }
        var latest: Date?
        for base in roots {
            enumerateActivityFiles(in: base, tool: tool) { url in
                let ts: Date? = (url.pathExtension == "jsonl")
                    ? self.lastTimestamp(in: url)
                    : self.mtime(of: url)
                if let t = ts, latest == nil || t > latest! {
                    latest = t
                }
            }
        }
        return latest
    }

    /// Earliest message timestamp within the current rolling window.
    /// This is the correct scheduling anchor: window expires at windowStart + windowDuration.
    ///
    /// Approach: scan all JSONL/conversation files touched in the last windowDuration seconds,
    /// find the earliest timestamp inside them that is also within the window.
    /// The Anthropic API would give an exact `resets_at` but is ToS-restricted for
    /// third-party use (Feb 2026). Log-based scanning is ≈ ±1 minute accurate.
    func windowStartTime(for tool: ToolID, directories: [URL]? = nil) -> Date? {
        let roots = (directories ?? tool.activityDirectoryURLs).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !roots.isEmpty else { return nil }

        let windowDuration = tool.windowDuration
        let cutoff = Date().addingTimeInterval(-windowDuration)

        var candidates: [(mtime: Date, url: URL)] = []
        for base in roots {
            enumerateActivityFiles(in: base, tool: tool) { url in
                if let mtime = self.mtime(of: url), mtime >= cutoff {
                    candidates.append((mtime, url))
                }
            }
        }

        guard !candidates.isEmpty else { return nil }
        // Oldest files first — the window start is in the earliest active file
        candidates.sort { $0.mtime < $1.mtime }

        var windowStart: Date?
        for candidate in candidates {
            let ts: Date?
            if candidate.url.pathExtension == "jsonl" {
                ts = firstTimestampInWindow(candidate.url, cutoff: cutoff)
            } else {
                let created = creationDate(of: candidate.url)
                if let created, created >= cutoff {
                    ts = created
                } else {
                    ts = candidate.mtime
                }
            }
            if let ts, windowStart == nil || ts < windowStart! {
                windowStart = ts
            }
        }
        return windowStart
    }

    func weeklyActivity(for tool: ToolID, directories: [URL]? = nil) -> [DayActivity] {
        let roots = (directories ?? tool.activityDirectoryURLs).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !roots.isEmpty else { return emptyWeek() }

        let calendar = Calendar.current
        let now      = Date()
        let cutoff   = calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast

        var countsByDay: [Date: Int] = [:]
        for offset in 0..<7 {
            if let d = calendar.date(byAdding: .day, value: -offset, to: now) {
                countsByDay[calendar.startOfDay(for: d)] = 0
            }
        }

        for base in roots {
            enumerateActivityFiles(in: base, tool: tool) { url in
                let rawTS = (url.pathExtension == "jsonl")
                    ? self.lastTimestamp(in: url)
                    : self.mtime(of: url)
                guard let ts = rawTS, ts >= cutoff else { return }
                let day = calendar.startOfDay(for: ts)
                if countsByDay[day] != nil { countsByDay[day]! += 1 }
            }
        }

        return countsByDay
            .sorted { $0.key < $1.key }
            .map { DayActivity(date: $0.key, sessionCount: $0.value) }
    }

    // MARK: - Private

    /// Reads from the beginning of the file and returns the earliest complete-line
    /// timestamp that is >= cutoff. Reads up to 16 KB to cover long first lines.
    /// Discards any partial line at the buffer boundary to avoid parse errors.
    private func firstTimestampInWindow(_ url: URL, cutoff: Date) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // 16 KB is enough to cover the timestamp field even in very long JSONL lines,
        // since the timestamp field appears in the first ~200 bytes of each record.
        let data = handle.readData(ofLength: 16_384)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // Split on newlines; drop the last element which may be a truncated line.
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1 { lines.removeLast() }

        for line in lines {
            if let ts = parseTimestamp(from: line), ts >= cutoff { return ts }
        }
        return nil
    }

    /// Reads last 8 KB and returns the most-recent timestamp (any line).
    private func lastTimestamp(in url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return nil }
        let readSize = UInt64(min(fileSize, 8_192))
        try? handle.seek(toOffset: fileSize - readSize)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Reversed: first complete line from the end that has a timestamp wins
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1 { lines.removeFirst() } // may be partial at start of buffer
        for line in lines.reversed() {
            if let ts = parseTimestamp(from: line) { return ts }
        }
        return nil
    }

    private func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private func parseTimestamp(from jsonLine: String) -> Date? {
        let t = jsonLine.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.hasPrefix("{"),
              let data = t.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ts = obj["timestamp"] as? String {
            return iso8601Frac.date(from: ts) ?? iso8601.date(from: ts)
        }
        if let num = obj["timestamp"] as? NSNumber {
            let val = num.doubleValue
            if val > 0 {
                return Date(timeIntervalSince1970: val > 10_000_000_000 ? val / 1000 : val)
            }
        }
        return nil
    }

    private func enumerateActivityFiles(in directory: URL, tool: ToolID, handler: (URL) -> Void) {
        guard let en = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var count = 0
        for case let url as URL in en {
            count += 1; if count > 50_000 { break }
            let ext = url.pathExtension.lowercased()
            if ext == "jsonl" {
                handler(url)
            } else if tool == .antigravity, ext == "db" {
                // Antigravity 1.2.3+ writes an index `conversation_summaries.db`
                // alongside conversation databases; skip non-session index files.
                if url.lastPathComponent.lowercased() == "conversation_summaries.db" { continue }
                handler(url)
            }
        }
    }

    private func emptyWeek() -> [DayActivity] {
        let calendar = Calendar.current
        let now      = Date()
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map {
                DayActivity(date: calendar.startOfDay(for: $0), sessionCount: 0)
            }
        }
    }
}
