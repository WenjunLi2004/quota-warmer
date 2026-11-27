import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LocalUsageProvider {
    private struct UsageRecord {
        let date: Date
        let model: String?
        let inputTokens: Int
        let uncachedInput: Int
        let cachedInput: Int
        let cacheCreationFiveMinuteTokens: Int
        let cacheCreationOneHourTokens: Int
        let cacheReadTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let explicitCostUSD: Double?
    }

    private struct UsageBucket {
        var tokens = 0
        var uncachedInput = 0
        var cachedInput = 0
        var output = 0
        var costUSD: Double?
        var byModel: [String: Int] = [:]

        mutating func add(
            tokens: Int,
            uncachedInput: Int = 0,
            cachedInput: Int = 0,
            output: Int = 0,
            cost: Double?,
            model: String? = nil
        ) {
            self.tokens += tokens
            self.uncachedInput += uncachedInput
            self.cachedInput += cachedInput
            self.output += output
            if let model, !model.isEmpty, tokens > 0 {
                self.byModel[model, default: 0] += tokens
            }
            guard let cost else { return }
            self.costUSD = (self.costUSD ?? 0) + cost
        }

        mutating func merge(_ other: UsageBucket) {
            self.tokens += other.tokens
            self.uncachedInput += other.uncachedInput
            self.cachedInput += other.cachedInput
            self.output += other.output
            for (model, count) in other.byModel {
                self.byModel[model, default: 0] += count
            }
            if let otherCost = other.costUSD {
                self.costUSD = (self.costUSD ?? 0) + otherCost
            }
        }
    }

    private struct ModelRates {
        let input: Double
        let cacheWrite: Double
        let cacheRead: Double
        let output: Double
        let cacheReadExplicit: Bool
    }

    private struct CodexPricingTier {
        let input: Double
        let cacheRead: Double
        let output: Double
        let longContextThreshold: Int?
        let inputAboveThreshold: Double?
        let cacheReadAboveThreshold: Double?
        let outputAboveThreshold: Double?

        init(
            input: Double,
            cacheRead: Double,
            output: Double,
            longContextOutput: Double? = nil
        ) {
            self.input = input
            self.cacheRead = cacheRead
            self.output = output
            if let longContextOutput {
                self.longContextThreshold = 272_000
                self.inputAboveThreshold = input * 2.0
                self.cacheReadAboveThreshold = cacheRead * 2.0
                self.outputAboveThreshold = longContextOutput
            } else {
                self.longContextThreshold = nil
                self.inputAboveThreshold = nil
                self.cacheReadAboveThreshold = nil
                self.outputAboveThreshold = nil
            }
        }
    }

    private struct CodexTotals: Hashable {
        let input: Int
        let cached: Int
        let output: Int
        let total: Int
    }

    private struct CodexSnapshotKey: Hashable {
        let total: CodexTotals
        let lastInput: Int
        let lastCached: Int
        let lastOutput: Int
    }

    private struct CodexCandidateEvent {
        let record: UsageRecord
        let responseID: String?
        let snapshotKey: CodexSnapshotKey?
        let beforeFirstTurnContext: Bool
        let totalExceedsLast: Bool
    }

    private struct ParsedCodexFile {
        let sessionId: String?
        let isForkOrSubagent: Bool
        let events: [CodexCandidateEvent]
    }

    private static let codexRemoteCache = CodexRemoteUsageCache()

    private let fileManager: FileManager
    private let calendar: Calendar

    private let iso8601Frac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    /// Asynchronous token usage lookup. For Codex, queries OpenAI's official
    /// `wham/analytics/daily-workspace-usage-counts` endpoint (matching OpenUsage)
    /// and reconciles/falls back to local rollout logs when offline or mid-turn.
    func usageAsync(
        for tool: ToolID,
        credentialStore: CredentialStore = CredentialStore(),
        session: URLSession = .shared,
        now: Date = Date()
    ) async -> TokenUsageSummary {
        if tool == .codex {
            if let remote = await fetchCodexRemoteSummary(
                credentialStore: credentialStore,
                session: session,
                now: now
            ) {
                let localUTC = LocalUsageProvider(fileManager: fileManager, calendar: Self.utcCalendar)
                    .usage(for: .codex, now: now)
                if localUTC.today.totalTokens > remote.today.totalTokens {
                    let deltaTokens = localUTC.today.totalTokens - remote.today.totalTokens
                    let deltaCost: Double?
                    if let lCost = localUTC.today.costUSD {
                        deltaCost = max(0, lCost - (remote.today.costUSD ?? 0))
                    } else {
                        deltaCost = nil
                    }
                    let mergedLast30Cost: Double?
                    if let r30 = remote.last30Days.costUSD, let dCost = deltaCost {
                        mergedLast30Cost = r30 + dCost
                    } else {
                        mergedLast30Cost = remote.last30Days.costUSD ?? deltaCost
                    }
                    let mergedLast30 = TokenUsageDay(
                        date: remote.last30Days.date,
                        totalTokens: remote.last30Days.totalTokens + deltaTokens,
                        costUSD: mergedLast30Cost,
                        uncachedInputTokens: remote.last30Days.uncachedInputTokens + max(0, localUTC.today.uncachedInputTokens - remote.today.uncachedInputTokens),
                        cachedInputTokens: remote.last30Days.cachedInputTokens + max(0, localUTC.today.cachedInputTokens - remote.today.cachedInputTokens),
                        outputTokens: remote.last30Days.outputTokens + max(0, localUTC.today.outputTokens - remote.today.outputTokens),
                        topModels: remote.last30Days.topModels.isEmpty ? localUTC.today.topModels : remote.last30Days.topModels
                    )
                    return TokenUsageSummary(
                        fetchedAt: now,
                        source: remote.source,
                        today: localUTC.today,
                        yesterday: remote.yesterday,
                        last30Days: mergedLast30
                    )
                }
                return remote
            }
        }
        return usage(for: tool, now: now)
    }

    private func fetchCodexRemoteSummary(
        credentialStore: CredentialStore,
        session: URLSession,
        now: Date
    ) async -> TokenUsageSummary? {
        guard let credential = try? await credentialStore.credential(for: .codex),
              !credential.accessToken.isEmpty else {
            return nil
        }
        let cacheKey = credential.accountID ?? String(credential.accessToken.prefix(16))
        if let cached = await Self.codexRemoteCache.cachedSummary(for: cacheKey, now: now) {
            return cached
        }
        if await Self.codexRemoteCache.isBackedOff(for: cacheKey, now: now) {
            return nil
        }

        let utc = Self.utcCalendar
        let today = utc.startOfDay(for: now)
        let since = utc.date(byAdding: .day, value: -30, to: today) ?? today
        let startStr = Self.utcDateString(since)
        let endStr = Self.utcDateString(today)

        var comps = URLComponents(string: "https://chatgpt.com/backend-api/wham/analytics/daily-workspace-usage-counts")!
        comps.queryItems = [
            URLQueryItem(name: "start_date", value: startStr),
            URLQueryItem(name: "end_date", value: endStr),
            URLQueryItem(name: "group_by", value: "day"),
            URLQueryItem(name: "workspace_user", value: "true")
        ]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credential.accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        if http.statusCode == 429 {
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1800
            await Self.codexRemoteCache.recordBackoff(for: cacheKey, seconds: retry, now: now)
            return nil
        }
        guard (200..<300).contains(http.statusCode),
              let parsed = codexRemoteSummary(data: data, now: now) else {
            return nil
        }
        await Self.codexRemoteCache.store(summary: parsed, for: cacheKey, now: now)
        return parsed
    }

    /// Parses ChatGPT's `wham/analytics/daily-workspace-usage-counts` JSON report
    /// (UTC `yyyy-MM-dd` records with `totals` and `models[]`, matching OpenUsage 0.8+).
    func codexRemoteSummary(data: Data, now: Date = Date()) -> TokenUsageSummary? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = root["data"] as? [[String: Any]] else {
            return nil
        }

        let utc = Self.utcCalendar
        let today = utc.startOfDay(for: now)
        let yesterday = utc.date(byAdding: .day, value: -1, to: today) ?? today
        let since = utc.date(byAdding: .day, value: -30, to: today) ?? today

        let todayKey = Self.utcDateString(today)
        let yesterdayKey = Self.utcDateString(yesterday)
        let sinceKey = Self.utcDateString(since)

        var bucketsByDayKey: [String: UsageBucket] = [:]
        for record in records {
            guard let rawDate = stringValue(record["date"]), rawDate.count >= 10,
                  let totals = record["totals"] as? [String: Any] else {
                continue
            }
            let dayKey = String(rawDate.prefix(10))
            let uncached = max(0, intValue(totals["uncached_text_input_tokens"]))
            let cached = max(0, intValue(totals["cached_text_input_tokens"]))
            let output = max(0, intValue(totals["text_output_tokens"]))
            let explicitTotal = max(0, intValue(totals["text_total_tokens"]))
            let resolvedTotal = explicitTotal > 0 ? explicitTotal : (uncached + cached + output)

            var modelTokens: [String: Int] = [:]
            if let models = record["models"] as? [[String: Any]] {
                for m in models {
                    let rawName = stringValue(m["model"]) ?? "unknown"
                    let mTok = max(0, intValue(m["text_total_tokens"]))
                    let mTurns = max(0, intValue(m["turns"]))
                    if mTok > 0 {
                        modelTokens[rawName, default: 0] += mTok
                    } else if mTurns > 0, resolvedTotal > 0 {
                        modelTokens[rawName, default: 0] += mTurns
                    }
                }
            }

            let estimatedCost = estimateCodexDayCost(
                uncachedInput: uncached,
                cachedInput: cached,
                output: output,
                totalTokens: resolvedTotal,
                modelWeights: modelTokens
            )

            var dayBucket = bucketsByDayKey[dayKey] ?? UsageBucket()
            dayBucket.tokens += resolvedTotal
            dayBucket.uncachedInput += uncached
            dayBucket.cachedInput += cached
            dayBucket.output += output
            if let estimatedCost {
                dayBucket.costUSD = (dayBucket.costUSD ?? 0) + estimatedCost
            }
            let weightSum = modelTokens.values.reduce(0, +)
            if weightSum > 0, resolvedTotal > 0 {
                for (mName, w) in modelTokens {
                    let attributed = Int((Double(resolvedTotal) * (Double(w) / Double(weightSum))).rounded())
                    if attributed > 0 {
                        dayBucket.byModel[mName, default: 0] += attributed
                    }
                }
            }
            bucketsByDayKey[dayKey] = dayBucket
        }

        let todayBucket = bucketsByDayKey[todayKey] ?? UsageBucket()
        let yesterdayBucket = bucketsByDayKey[yesterdayKey] ?? UsageBucket()
        let last30Bucket = bucketsByDayKey
            .filter { $0.key >= sinceKey && $0.key <= todayKey }
            .reduce(into: UsageBucket()) { agg, item in agg.merge(item.value) }

        return TokenUsageSummary(
            fetchedAt: now,
            source: "Codex analytics",
            today: makeDay(date: today, bucket: todayBucket),
            yesterday: makeDay(date: yesterday, bucket: yesterdayBucket),
            last30Days: makeDay(date: since, bucket: last30Bucket)
        )
    }

    private func estimateCodexDayCost(
        uncachedInput: Int,
        cachedInput: Int,
        output: Int,
        totalTokens: Int,
        modelWeights: [String: Int]
    ) -> Double? {
        guard totalTokens > 0 else { return 0 }
        let weightSum = modelWeights.values.reduce(0, +)
        guard weightSum > 0 else { return nil }

        var totalCost: Double = 0
        var pricedAny = false
        for (modelName, weight) in modelWeights where weight > 0 {
            guard let tier = codexPricingTier(for: modelName) else { continue }
            pricedAny = true
            let fraction = Double(weight) / Double(weightSum)
            let partUncached = Double(uncachedInput) * fraction
            let partCached = Double(cachedInput) * fraction
            let partOutput = Double(output) * fraction
            totalCost += ((partUncached * tier.input)
                + (partCached * tier.cacheRead)
                + (partOutput * tier.output)) / 1_000_000
        }
        return pricedAny ? totalCost : nil
    }

    private static func utcDateString(_ date: Date) -> String {
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    func usage(for tool: ToolID, baseURL: URL? = nil, now: Date = Date()) -> TokenUsageSummary {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let since = calendar.date(byAdding: .day, value: -30, to: today) ?? today

        let buckets: [Date: UsageBucket]
        switch tool {
        case .claude:
            if let root = baseURL ?? tool.logDirectoryURL, fileManager.fileExists(atPath: root.path) {
                buckets = claudeBuckets(in: root, since: since)
            } else {
                buckets = [:]
            }
        case .codex:
            let roots = codexRoots(baseURL: baseURL)
            buckets = roots.isEmpty ? [:] : codexBuckets(in: roots, since: since)
        case .antigravity:
            let roots = (baseURL.map { [$0] } ?? tool.activityDirectoryURLs)
                .filter { fileManager.fileExists(atPath: $0.path) }
            let brainRoots = antigravityBrainRoots(baseURL: baseURL)
            buckets = (roots.isEmpty && brainRoots.isEmpty)
                ? [:]
                : antigravityBuckets(in: roots, brainRoots: brainRoots, since: since)
        }

        let todayBucket = buckets[today] ?? UsageBucket()
        let yesterdayBucket = buckets[yesterday] ?? UsageBucket()
        let last30Bucket = buckets
            .filter { $0.key >= since && $0.key <= today }
            .reduce(into: UsageBucket()) { aggregate, entry in
                aggregate.merge(entry.value)
            }

        let sourceLabel: String
        switch tool {
        case .claude:      sourceLabel = "Claude local usage"
        case .codex:       sourceLabel = "Codex local usage"
        case .antigravity: sourceLabel = "Antigravity local usage"
        }

        return TokenUsageSummary(
            fetchedAt: now,
            source: sourceLabel,
            today: makeDay(date: today, bucket: todayBucket),
            yesterday: makeDay(date: yesterday, bucket: yesterdayBucket),
            last30Days: makeDay(date: since, bucket: last30Bucket)
        )
    }

    private func makeDay(date: Date, bucket: UsageBucket) -> TokenUsageDay {
        let resolvedCost: Double? = bucket.costUSD ?? (bucket.tokens == 0 ? 0 : nil)
        let modelSum = max(1, bucket.byModel.values.reduce(0, +))
        let topModels: [ModelTokenShare] = bucket.byModel
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(5)
            .map { entry in
                ModelTokenShare(
                    model: entry.key,
                    tokens: entry.value,
                    share: min(1, max(0, Double(entry.value) / Double(modelSum)))
                )
            }
        return TokenUsageDay(
            date: date,
            totalTokens: bucket.tokens,
            costUSD: resolvedCost,
            uncachedInputTokens: bucket.uncachedInput,
            cachedInputTokens: bucket.cachedInput,
            outputTokens: bucket.output,
            topModels: topModels
        )
    }

    private func codexRoots(baseURL: URL?) -> [URL] {
        if let baseURL {
            var list = [baseURL]
            if baseURL.lastPathComponent == "sessions" {
                let archived = baseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("archived_sessions", isDirectory: true)
                list.append(archived)
            }
            return list.filter { fileManager.fileExists(atPath: $0.path) }
        }
        return ToolID.codex.activityDirectoryURLs.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func claudeBuckets(in root: URL, since: Date) -> [Date: UsageBucket] {
        var recordsByID: [String: UsageRecord] = [:]
        enumerateJSONL(in: root, since: since) { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                guard let object = jsonObject(String(line)),
                      let date = date(from: object),
                      date >= since,
                      let record = claudeRecord(from: object, date: date) else { continue }
                let id = claudeIdentity(from: object) ?? "\(url.path)#\(index)"
                if let existing = recordsByID[id], existing.totalTokens >= record.totalTokens { continue }
                recordsByID[id] = record
            }
        }
        return buckets(from: Array(recordsByID.values), pricing: claudeCost)
    }

    private func codexBuckets(in roots: [URL], since: Date) -> [Date: UsageBucket] {
        var parsedFiles: [ParsedCodexFile] = []
        var seenCanonicalPaths = Set<String>()
        var seenRolloutNames = Set<String>()

        for root in roots {
            enumerateJSONL(in: root, since: since) { url in
                let canonical = url.resolvingSymlinksInPath().path
                guard seenCanonicalPaths.insert(canonical).inserted else { return }
                let filename = url.lastPathComponent
                if filename.hasPrefix("rollout-") {
                    // Active `sessions/` roots are scanned before `archived_sessions/`,
                    // so an active copy wins over an archived copy of the same rollout.
                    guard seenRolloutNames.insert(filename).inserted else { return }
                }
                if let parsed = parseCodexFile(url, since: since), !parsed.events.isEmpty {
                    parsedFiles.append(parsed)
                }
            }
        }

        // Two-pass deduplication:
        // Pass 1 processes root sessions and records their (total_token_usage, last_token_usage)
        // snapshots. Pass 2 processes forked / subagent rollouts, skipping replayed parent
        // history snapshots so spawned subagents or resumed forks never inflate token counts.
        var acceptedRecords: [UsageRecord] = []
        var seenResponseIDs = Set<String>()
        var seenSnapshots = Set<CodexSnapshotKey>()

        for file in parsedFiles where !file.isForkOrSubagent {
            for event in file.events {
                if let rid = event.responseID, !seenResponseIDs.insert(rid).inserted {
                    continue
                }
                if let snap = event.snapshotKey {
                    seenSnapshots.insert(snap)
                }
                acceptedRecords.append(event.record)
            }
        }

        for file in parsedFiles where file.isForkOrSubagent {
            for event in file.events {
                if let rid = event.responseID, !seenResponseIDs.insert(rid).inserted {
                    continue
                }
                if let snap = event.snapshotKey {
                    if seenSnapshots.contains(snap) {
                        continue
                    }
                    // When the parent file is older than the 30-day lookback window,
                    // a forked/subagent rollout still replays parent history at spawn
                    // before the child's first turn_context, with cumulative totals > last.
                    if event.beforeFirstTurnContext && event.totalExceedsLast {
                        continue
                    }
                    seenSnapshots.insert(snap)
                }
                acceptedRecords.append(event.record)
            }
        }

        return buckets(from: acceptedRecords, pricing: codexCost)
    }

    private func parseCodexFile(_ url: URL, since: Date) -> ParsedCodexFile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var currentModel: String?
        var sessionId: String?
        var sawPrimarySessionMeta = false
        var isForkOrSubagent = false
        var childCreatedEpoch: TimeInterval?
        var inReplayedParentTask = false
        var sawTurnContext = false
        var prevTotal: CodexTotals?
        var ledgerThreadTotals = Set<CodexTotals>()
        var events: [CodexCandidateEvent] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let object = jsonObject(String(line)) else { continue }
            currentModel = model(from: object) ?? currentModel

            let topType = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if topType == "session_meta" || payloadType == "session_meta" {
                let meta = payload ?? object
                if !sawPrimarySessionMeta {
                    sawPrimarySessionMeta = true
                    sessionId = stringValue(meta["id"] ?? meta["session_id"] ?? meta["thread_id"])
                    if stringValue(meta["forked_from_id"]) != nil
                        || stringValue(meta["parent_thread_id"]) != nil
                        || isSubagentSource(meta["source"]) {
                        isForkOrSubagent = true
                        childCreatedEpoch = (stringValue(meta["timestamp"]) ?? stringValue(object["timestamp"]))
                            .flatMap(parseDate)?.timeIntervalSince1970
                    }
                }
                continue
            }

            if payloadType == "task_started" {
                if isForkOrSubagent,
                   let createdEpoch = childCreatedEpoch,
                   let rawStarted = payload?["started_at"],
                   let startedEpoch = epochSeconds(from: rawStarted) {
                    if startedEpoch < createdEpoch - 1.0 {
                        inReplayedParentTask = true
                        continue
                    }
                }
                inReplayedParentTask = false
                sawTurnContext = true
                continue
            }

            if topType == "turn_context" || payloadType == "turn_context" || payloadType == "user_message" {
                if !inReplayedParentTask {
                    sawTurnContext = true
                }
                continue
            }

            // 1. Modern Codex per-request ledger record (`type == "token_usage_record"`).
            if topType == "token_usage_record",
               let payload,
               let usageDict = payload["usage"] as? [String: Any] {
                let threadTotal = (payload["thread_token_usage"] as? [String: Any]).flatMap(parseCodexTotals)
                if let threadTotal {
                    ledgerThreadTotals.insert(threadTotal)
                    prevTotal = threadTotal
                }
                if inReplayedParentTask { continue }
                guard let recordDate = date(from: object), recordDate >= since else { continue }
                let rowModel = stringValue(payload["model"]) ?? currentModel
                let input = intValue(usageDict["input_tokens"])
                let cached = min(
                    max(intValue(usageDict["cached_input_tokens"]), intValue(usageDict["cache_read_input_tokens"])),
                    input
                )
                let output = intValue(usageDict["output_tokens"])
                let explicitTotal = intValue(usageDict["total_tokens"])
                let resolvedTotal = explicitTotal > 0 ? explicitTotal : (input + output)
                guard resolvedTotal > 0 else { continue }

                let record = UsageRecord(
                    date: recordDate,
                    model: rowModel,
                    inputTokens: input,
                    uncachedInput: max(0, input - cached),
                    cachedInput: cached,
                    cacheCreationFiveMinuteTokens: 0,
                    cacheCreationOneHourTokens: 0,
                    cacheReadTokens: 0,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    totalTokens: resolvedTotal,
                    explicitCostUSD: explicitCost(from: object)
                )
                let snap = threadTotal.map {
                    CodexSnapshotKey(total: $0, lastInput: input, lastCached: cached, lastOutput: output)
                }
                events.append(CodexCandidateEvent(
                    record: record,
                    responseID: stringValue(payload["response_id"]),
                    snapshotKey: snap,
                    beforeFirstTurnContext: !sawTurnContext,
                    totalExceedsLast: (threadTotal?.total ?? 0) > resolvedTotal
                ))
                continue
            }

            // 2. Standard Codex `token_count` event (`payload.type == "token_count"`).
            if payloadType == "token_count",
               let info = payload?["info"] as? [String: Any] {
                let total = (info["total_token_usage"] as? [String: Any]).flatMap(parseCodexTotals)

                // Skip duplicate `token_count` snapshots where `total_token_usage` has not
                // changed (emitted on rate-limit / UI refreshes, 40%+ of real Codex rows),
                // and skip rows already accounted for by a `token_usage_record` mirror.
                if let total {
                    if total == prevTotal || ledgerThreadTotals.contains(total) {
                        prevTotal = total
                        continue
                    }
                }

                let priorTotal = prevTotal
                if let total { prevTotal = total }
                if inReplayedParentTask { continue }

                let input: Int
                let cached: Int
                let output: Int
                let resolvedTotal: Int

                if let lastDict = info["last_token_usage"] as? [String: Any] {
                    input = intValue(lastDict["input_tokens"])
                    cached = min(
                        max(intValue(lastDict["cached_input_tokens"]), intValue(lastDict["cache_read_input_tokens"])),
                        input
                    )
                    output = intValue(lastDict["output_tokens"])
                    let explicitTotal = intValue(lastDict["total_tokens"])
                    resolvedTotal = explicitTotal > 0 ? explicitTotal : (input + output)
                } else if let total, let priorTotal, total.total > priorTotal.total {
                    input = max(0, total.input - priorTotal.input)
                    cached = min(max(0, total.cached - priorTotal.cached), input)
                    output = max(0, total.output - priorTotal.output)
                    resolvedTotal = max(0, total.total - priorTotal.total)
                } else {
                    continue
                }

                // Zero-usage checkpoint markers carry inherited context, not billed usage.
                guard resolvedTotal > 0, let recordDate = date(from: object), recordDate >= since else {
                    continue
                }

                let record = UsageRecord(
                    date: recordDate,
                    model: currentModel,
                    inputTokens: input,
                    uncachedInput: max(0, input - cached),
                    cachedInput: cached,
                    cacheCreationFiveMinuteTokens: 0,
                    cacheCreationOneHourTokens: 0,
                    cacheReadTokens: 0,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    totalTokens: resolvedTotal,
                    explicitCostUSD: explicitCost(from: object)
                )
                let snap = total.map {
                    CodexSnapshotKey(total: $0, lastInput: input, lastCached: cached, lastOutput: output)
                }
                events.append(CodexCandidateEvent(
                    record: record,
                    responseID: nil,
                    snapshotKey: snap,
                    beforeFirstTurnContext: !sawTurnContext,
                    totalExceedsLast: (total?.total ?? 0) > resolvedTotal
                ))
                continue
            }

            // 3. One-shot `codex exec --json` completion envelopes (`turn.completed` / `response.completed`).
            if topType == "turn.completed" || topType == "response.completed",
               let recordDate = date(from: object),
               recordDate >= since,
               let usageDict = (object["usage"] as? [String: Any])
                   ?? ((object["response"] as? [String: Any])?["usage"] as? [String: Any]) {
                let input = intValue(usageDict["input_tokens"] ?? usageDict["prompt_tokens"])
                let cached = min(
                    max(intValue(usageDict["cached_input_tokens"]), intValue(usageDict["cached_tokens"])),
                    input
                )
                let output = intValue(usageDict["output_tokens"] ?? usageDict["completion_tokens"])
                let explicitTotal = intValue(usageDict["total_tokens"])
                let resolvedTotal = explicitTotal > 0 ? explicitTotal : (input + output)
                guard resolvedTotal > 0 else { continue }
                let record = UsageRecord(
                    date: recordDate,
                    model: currentModel,
                    inputTokens: input,
                    uncachedInput: max(0, input - cached),
                    cachedInput: cached,
                    cacheCreationFiveMinuteTokens: 0,
                    cacheCreationOneHourTokens: 0,
                    cacheReadTokens: 0,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    totalTokens: resolvedTotal,
                    explicitCostUSD: explicitCost(from: object)
                )
                events.append(CodexCandidateEvent(
                    record: record,
                    responseID: stringValue((object["response"] as? [String: Any])?["id"] ?? object["response_id"]),
                    snapshotKey: nil,
                    beforeFirstTurnContext: false,
                    totalExceedsLast: false
                ))
            }
        }

        return ParsedCodexFile(
            sessionId: sessionId,
            isForkOrSubagent: isForkOrSubagent,
            events: events
        )
    }

    private func epochSeconds(from raw: Any) -> TimeInterval? {
        if raw is NSNull { return nil }
        if let str = raw as? String, let parsed = parseDate(str) {
            return parsed.timeIntervalSince1970
        }
        if let val = doubleValue(raw), val > 0 {
            return val > 10_000_000_000 ? val / 1000 : val
        }
        return nil
    }

    private func parseCodexTotals(_ usage: [String: Any]) -> CodexTotals {
        let input = intValue(usage["input_tokens"])
        let cached = max(intValue(usage["cached_input_tokens"]), intValue(usage["cache_read_input_tokens"]))
        let output = intValue(usage["output_tokens"])
        let explicitTotal = intValue(usage["total_tokens"])
        let total = explicitTotal > 0 ? explicitTotal : (input + output)
        return CodexTotals(input: input, cached: cached, output: output, total: total)
    }

    private func isSubagentSource(_ source: Any?) -> Bool {
        guard let source, !(source is NSNull) else { return false }
        if let str = source as? String {
            let lower = str.lowercased()
            return lower.contains("subagent") || lower.contains("thread_spawn") || lower.contains("fork")
        }
        if let dict = source as? [String: Any] {
            if let sub = dict["subagent"], !(sub is NSNull) { return true }
            if let spawn = dict["thread_spawn"], !(spawn is NSNull) { return true }
        }
        return false
    }

    private func antigravityBrainRoots(baseURL: URL?) -> [URL] {
        if let baseURL {
            return [
                baseURL,
                baseURL.appendingPathComponent("brain", isDirectory: true)
            ].filter { fileManager.fileExists(atPath: $0.path) }
        }
        return ToolID.antigravity.antigravityBrainDirectoryURLs
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func antigravityBuckets(in roots: [URL], brainRoots: [URL], since: Date) -> [Date: UsageBucket] {
        var recordsByID: [String: UsageRecord] = [:]
        var seenFiles = Set<String>()

        let parseFile: (URL) -> Void = { url in
            let canonical = url.resolvingSymlinksInPath().path
            guard seenFiles.insert(canonical).inserted else { return }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            var currentModel: String?
            let fallbackDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                guard let object = self.jsonObject(String(line)) else { continue }
                if let initObj = object["init"] as? [String: Any],
                   let initModel = self.stringValue(initObj["model"]) {
                    currentModel = initModel
                }
                currentModel = self.model(from: object) ?? currentModel
                // Skip terminal `result` envelopes when `step_update` lines already
                // supplied per-step usage, or dedupe by conversation/line identity.
                guard let recordDate = self.date(from: object) ?? fallbackDate,
                      recordDate >= since,
                      let record = self.antigravityRecord(from: object, date: recordDate, model: currentModel) else {
                    continue
                }
                let id = self.antigravityIdentity(from: object, url: url, lineIndex: index)
                if let existing = recordsByID[id], existing.totalTokens >= record.totalTokens { continue }
                recordsByID[id] = record
            }
        }

        for brainRoot in brainRoots {
            enumerateAntigravityBrainTranscripts(in: brainRoot, since: since, handler: parseFile)
        }
        for root in roots {
            enumerateJSONL(in: root, since: since, handler: parseFile)
        }
        return buckets(from: Array(recordsByID.values), pricing: antigravityCost)
    }

    /// Scans `<brainRoot>/<conversation-id>/.system_generated/logs/transcript.jsonl`
    /// (falling back to `transcript_full.jsonl` only when the compact transcript is absent).
    /// `FileManager.enumerator` with `.skipsHiddenFiles` skips `.system_generated`, and a
    /// blind hidden-file walk would also double-count `transcript_full.jsonl` and `chunks/`.
    private func enumerateAntigravityBrainTranscripts(
        in brainRoot: URL,
        since: Date,
        handler: (URL) -> Void
    ) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: brainRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for convDir in children {
            guard convDir.lastPathComponent != "tempmediaStorage",
                  (try? convDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let logsDir = convDir.appendingPathComponent(".system_generated/logs", isDirectory: true)
            let compactURL = logsDir.appendingPathComponent("transcript.jsonl")
            let fullURL = logsDir.appendingPathComponent("transcript_full.jsonl")
            let candidateURL: URL
            if fileManager.fileExists(atPath: compactURL.path) {
                candidateURL = compactURL
            } else if fileManager.fileExists(atPath: fullURL.path) {
                candidateURL = fullURL
            } else {
                continue
            }
            if let mtime = (try? candidateURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < since {
                continue
            }
            handler(candidateURL)
        }
    }

    private func antigravityIdentity(from object: [String: Any], url: URL, lineIndex: Int) -> String {
        if let result = object["result"] as? [String: Any],
           let conv = stringValue(result["conversation_id"]) {
            return "conv:\(conv)"
        }
        if let conv = stringValue(object["conversation_id"]), object["usage"] != nil, object["event"] == nil {
            return "conv:\(conv)"
        }
        if let sessionId = stringValue(object["sessionId"]),
           let ts = stringValue(object["timestamp"]) {
            return "session:\(sessionId)#\(ts)"
        }
        let logsDir = url.deletingLastPathComponent()
        let sysDir = logsDir.deletingLastPathComponent()
        if logsDir.lastPathComponent == "logs",
           sysDir.lastPathComponent == ".system_generated",
           object["step_index"] != nil {
            let convID = sysDir.deletingLastPathComponent().lastPathComponent
            let stepIdx = intValue(object["step_index"])
            let created = stringValue(object["created_at"]) ?? String(lineIndex)
            return "transcript:\(convID)#\(stepIdx)#\(created)"
        }
        return "\(url.path)#\(lineIndex)"
    }

    private func antigravityRecord(from object: [String: Any], date: Date, model: String?) -> UsageRecord? {
        // Skip cumulative `result` event if streaming step updates are present in the same stream;
        // single-line `--output-format json` has no `event` key and is parsed directly.
        if (object["event"] as? String) == "result" { return nil }

        let usage: [String: Any]?
        if let step = object["step_update"] as? [String: Any],
           let stepUsage = step["usage"] as? [String: Any] {
            usage = stepUsage
        } else if let directUsage = object["usage"] as? [String: Any] {
            usage = directUsage
        } else if object["input_tokens"] != nil
            || object["output_tokens"] != nil
            || object["cache_read_tokens"] != nil
            || object["thinking_tokens"] != nil
            || object["total_tokens"] != nil
            || object["inputTokens"] != nil
            || object["outputTokens"] != nil
            || object["cacheReadTokens"] != nil
            || object["thinkingTokens"] != nil
            || object["totalTokens"] != nil {
            usage = object
        } else {
            usage = nil
        }
        guard let usage else { return nil }

        let input = intValue(usage["input_tokens"] ?? usage["inputTokens"])
        let cacheWrite = intValue(
            usage["cache_creation_tokens"]
                ?? usage["cache_creation_input_tokens"]
                ?? usage["cacheWriteTokens"]
                ?? usage["cacheCreationTokens"]
        )
        let cacheRead = intValue(
            usage["cache_read_tokens"]
                ?? usage["cache_read_input_tokens"]
                ?? usage["cacheReadTokens"]
                ?? usage["cachedInputTokens"]
        )
        let output = intValue(usage["output_tokens"] ?? usage["outputTokens"])
        let thinking = intValue(usage["thinking_tokens"] ?? usage["thinkingTokens"] ?? usage["thinkingOutputTokens"])
        let explicitTotal = intValue(usage["total_tokens"] ?? usage["totalTokens"])
        let combinedOutput = output > 0 ? output : thinking
        let resolvedTotal = explicitTotal > 0 ? explicitTotal : (input + cacheWrite + cacheRead + combinedOutput)
        guard resolvedTotal > 0 else { return nil }

        // In Antigravity `transcript.jsonl`, `input_tokens` is uncached input (`explicitTotal == 0`).
        // In CLI `usage` envelopes with `total_tokens`, `input_tokens` may already include `cache_read_tokens`
        // (`input + output == total_tokens`). Compare both sums against `explicitTotal` to disambiguate.
        let inputIncludesCache: Bool
        if explicitTotal > 0 && cacheRead > 0 && input >= cacheRead {
            let totalIfIncludes = input + cacheWrite + combinedOutput
            let totalIfExcludes = input + cacheWrite + cacheRead + combinedOutput
            inputIncludesCache = abs(totalIfIncludes - explicitTotal) < abs(totalIfExcludes - explicitTotal)
        } else {
            inputIncludesCache = false
        }
        let uncachedOnly = inputIncludesCache ? max(0, input - cacheRead) : input

        return UsageRecord(
            date: date,
            model: model,
            inputTokens: uncachedOnly,
            uncachedInput: uncachedOnly + cacheWrite,
            cachedInput: cacheRead,
            cacheCreationFiveMinuteTokens: cacheWrite,
            cacheCreationOneHourTokens: 0,
            cacheReadTokens: cacheRead,
            cachedInputTokens: cacheRead,
            outputTokens: combinedOutput,
            totalTokens: resolvedTotal,
            explicitCostUSD: explicitCost(from: object)
        )
    }

    private func antigravityCost(_ record: UsageRecord) -> Double? {
        let text = record.model?.lowercased() ?? ""
        if text.contains("claude") {
            return claudeCost(record)
        }
        if text.contains("gpt-") {
            if let tier = codexPricingTier(for: record.model) {
                let totalInput = record.uncachedInput + record.cachedInput
                let isLongContext = tier.longContextThreshold.map { totalInput > $0 } ?? false
                let inRate = isLongContext ? (tier.inputAboveThreshold ?? tier.input) : tier.input
                let cacheRate = isLongContext ? (tier.cacheReadAboveThreshold ?? tier.cacheRead) : tier.cacheRead
                let outRate = isLongContext ? (tier.outputAboveThreshold ?? tier.output) : tier.output
                return ((Double(record.uncachedInput) * inRate)
                    + (Double(record.cachedInput) * cacheRate)
                    + (Double(record.outputTokens) * outRate)) / 1_000_000
            }
            if text.contains("gpt-oss") {
                return ((Double(record.uncachedInput) * 0.15)
                    + (Double(record.cachedInput) * 0.075)
                    + (Double(record.outputTokens) * 0.60)) / 1_000_000
            }
        }
        let rates = antigravityRates(for: record.model)
        return ((Double(record.uncachedInput) * rates.input)
            + (Double(record.cacheReadTokens) * rates.cacheRead)
            + (Double(record.outputTokens) * rates.output)) / 1_000_000
    }

    private func antigravityRates(for model: String?) -> ModelRates {
        let text = model?.lowercased() ?? ""
        if text.contains("flash") {
            return ModelRates(input: 0.30, cacheWrite: 0.30, cacheRead: 0.03, output: 2.50, cacheReadExplicit: true)
        }
        if text.contains("neon") || text.contains("argon") || text.contains("orchestrator") {
            return ModelRates(input: 2.00, cacheWrite: 2.00, cacheRead: 0.20, output: 12.00, cacheReadExplicit: true)
        }
        // Default Gemini Pro / Carbon / Hydrogen tier
        return ModelRates(input: 1.25, cacheWrite: 1.25, cacheRead: 0.125, output: 10.00, cacheReadExplicit: true)
    }

    private func buckets(
        from records: [UsageRecord],
        pricing: (UsageRecord) -> Double?
    ) -> [Date: UsageBucket] {
        records.reduce(into: [Date: UsageBucket]()) { buckets, record in
            let day = calendar.startOfDay(for: record.date)
            let cost = record.explicitCostUSD ?? pricing(record)
            let cleanModel = record.model.map { raw -> String in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.lowercased().hasPrefix("openai/")
                    ? String(trimmed.dropFirst("openai/".count))
                    : trimmed
            }
            buckets[day, default: UsageBucket()].add(
                tokens: record.totalTokens,
                uncachedInput: record.uncachedInput,
                cachedInput: record.cachedInput,
                output: record.outputTokens,
                cost: cost,
                model: cleanModel
            )
        }
    }

    private func claudeRecord(from object: [String: Any], date: Date) -> UsageRecord? {
        guard let usage = usageObject(from: object) else { return nil }
        let input = intValue(usage["input_tokens"])
        let breakdown = cacheCreationBreakdown(from: usage)
        let fallbackCacheCreation = intValue(usage["cache_creation_input_tokens"])
        let cacheCreation = breakdown.total > 0 ? breakdown.total : fallbackCacheCreation
        let cacheCreationFiveMinute = breakdown.total > 0 ? breakdown.fiveMinute : cacheCreation
        let cacheCreationOneHour = breakdown.oneHour
        let cacheRead = intValue(usage["cache_read_input_tokens"])
        let output = intValue(usage["output_tokens"])
        let total = input + cacheCreation + cacheRead + output
        guard total > 0 else { return nil }

        return UsageRecord(
            date: date,
            model: model(from: object),
            inputTokens: input,
            uncachedInput: input + cacheCreation,
            cachedInput: cacheRead,
            cacheCreationFiveMinuteTokens: cacheCreationFiveMinute,
            cacheCreationOneHourTokens: cacheCreationOneHour,
            cacheReadTokens: cacheRead,
            cachedInputTokens: 0,
            outputTokens: output,
            totalTokens: total,
            explicitCostUSD: explicitCost(from: object)
        )
    }

    private func claudeCost(_ record: UsageRecord) -> Double? {
        let rates = claudeRates(for: record.model)
        return cost(
            inputTokens: record.inputTokens,
            cacheCreationFiveMinuteTokens: record.cacheCreationFiveMinuteTokens,
            cacheCreationOneHourTokens: record.cacheCreationOneHourTokens,
            cacheReadTokens: record.cacheReadTokens,
            outputTokens: record.outputTokens,
            rates: rates
        )
    }

    private func codexCost(_ record: UsageRecord) -> Double? {
        guard let tier = codexPricingTier(for: record.model) else { return nil }
        let cached = min(record.cachedInputTokens, record.inputTokens)
        let uncached = max(0, record.inputTokens - cached)
        let isLongContext = tier.longContextThreshold.map { record.inputTokens > $0 } ?? false
        let inRate = isLongContext ? (tier.inputAboveThreshold ?? tier.input) : tier.input
        let cacheRate = isLongContext ? (tier.cacheReadAboveThreshold ?? tier.cacheRead) : tier.cacheRead
        let outRate = isLongContext ? (tier.outputAboveThreshold ?? tier.output) : tier.output
        return ((Double(uncached) * inRate)
            + (Double(cached) * cacheRate)
            + (Double(record.outputTokens) * outRate)) / 1_000_000
    }

    private func cost(
        inputTokens: Int,
        cacheCreationFiveMinuteTokens: Int,
        cacheCreationOneHourTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        rates: ModelRates
    ) -> Double {
        ((Double(inputTokens) * rates.input)
            + (Double(cacheCreationFiveMinuteTokens) * rates.cacheWrite)
            + (Double(cacheCreationOneHourTokens) * rates.cacheWrite)
            + (Double(cacheReadTokens) * rates.cacheRead)
            + (Double(outputTokens) * rates.output)) / 1_000_000
    }

    private func claudeRates(for model: String?) -> ModelRates {
        let text = model?.lowercased() ?? ""
        if text.contains("fable-5") {
            return ModelRates(input: 10.0, cacheWrite: 12.5, cacheRead: 1.0, output: 50.0, cacheReadExplicit: true)
        }
        if text.contains("opus") {
            if usesModernOpusPricing(text) {
                return ModelRates(input: 5.0, cacheWrite: 6.25, cacheRead: 0.50, output: 25.0, cacheReadExplicit: true)
            }
            return ModelRates(input: 15.0, cacheWrite: 18.75, cacheRead: 1.50, output: 75.0, cacheReadExplicit: true)
        }
        if text.contains("haiku") {
            if text.contains("3-5") || text.contains("3.5") {
                return ModelRates(input: 0.80, cacheWrite: 1.0, cacheRead: 0.08, output: 4.0, cacheReadExplicit: true)
            }
            if text.contains("claude-3-haiku") || text.contains("haiku-3") {
                return ModelRates(input: 0.25, cacheWrite: 0.30, cacheRead: 0.03, output: 1.25, cacheReadExplicit: true)
            }
            return ModelRates(input: 1.0, cacheWrite: 1.25, cacheRead: 0.10, output: 5.0, cacheReadExplicit: true)
        }
        return ModelRates(input: 3.0, cacheWrite: 3.75, cacheRead: 0.30, output: 15.0, cacheReadExplicit: true)
    }

    private func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }
        if let datedRange = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            trimmed = String(trimmed[..<datedRange.lowerBound])
        }
        if trimmed == "gpt-5.6" || trimmed == "gpt-5.6-codex" || trimmed == "gpt-daybreak-blue-latest" {
            return "gpt-5.6-sol"
        }
        if trimmed == "gpt-reserve" {
            return "gpt-5.6-luna"
        }
        if trimmed == "gpt-daybreak-red-latest" {
            return "gpt-5.6-cyber"
        }
        return trimmed
    }

    private func codexPricingTier(for model: String?) -> CodexPricingTier? {
        guard let model, !model.isEmpty else { return nil }
        let normalized = normalizeCodexModel(model)
        switch normalized {
        case "gpt-6-astra":
            return CodexPricingTier(input: 10.0, cacheRead: 1.0, output: 50.0, longContextOutput: 75.0)
        case "gpt-6.2-astra":
            return CodexPricingTier(input: 8.0, cacheRead: 0.40, output: 40.0, longContextOutput: 60.0)
        case "gpt-6-sol":
            return CodexPricingTier(input: 2.0, cacheRead: 0.20, output: 10.0, longContextOutput: 15.0)
        case "gpt-6.1-sol", "gpt-6.2-sol":
            return CodexPricingTier(input: 2.0, cacheRead: 0.10, output: 10.0, longContextOutput: 15.0)
        case "gpt-6.1-terra":
            return CodexPricingTier(input: 1.0, cacheRead: 0.05, output: 5.0, longContextOutput: 7.50)
        case "gpt-6-luna":
            return CodexPricingTier(input: 0.10, cacheRead: 0.01, output: 0.50, longContextOutput: 0.75)
        case "gpt-5.6-sol":
            return CodexPricingTier(input: 4.0, cacheRead: 0.40, output: 20.0, longContextOutput: 30.0)
        case "gpt-5.6-terra":
            return CodexPricingTier(input: 2.0, cacheRead: 0.20, output: 12.0, longContextOutput: 18.0)
        case "gpt-5.6-luna":
            return CodexPricingTier(input: 0.20, cacheRead: 0.02, output: 1.20, longContextOutput: 1.80)
        case "gpt-5.6-cyber", "gpt-5.5-cyber":
            return CodexPricingTier(input: 12.5, cacheRead: 1.25, output: 75.0)
        case "gpt-5.5":
            return CodexPricingTier(input: 5.0, cacheRead: 0.50, output: 30.0, longContextOutput: 45.0)
        case "gpt-5.5-pro", "gpt-5.4-pro":
            return CodexPricingTier(input: 30.0, cacheRead: 30.0, output: 180.0, longContextOutput: 270.0)
        case "gpt-5.4":
            return CodexPricingTier(input: 2.5, cacheRead: 0.25, output: 15.0, longContextOutput: 22.5)
        case "gpt-5.4-mini":
            return CodexPricingTier(input: 0.75, cacheRead: 0.075, output: 4.5)
        case "gpt-5.4-nano":
            return CodexPricingTier(input: 0.20, cacheRead: 0.020, output: 1.25)
        case "gpt-5.3-codex-spark":
            return CodexPricingTier(input: 0.0, cacheRead: 0.0, output: 0.0)
        case "gpt-5.3-codex", "gpt-5.3-spark", "gpt-5.2", "gpt-5.2-codex":
            return CodexPricingTier(input: 1.75, cacheRead: 0.175, output: 14.0)
        case "gpt-5.2-pro":
            return CodexPricingTier(input: 21.0, cacheRead: 21.0, output: 168.0)
        case "gpt-5", "gpt-5-codex", "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max":
            return CodexPricingTier(input: 1.25, cacheRead: 0.125, output: 10.0)
        case "gpt-5-pro":
            return CodexPricingTier(input: 15.0, cacheRead: 15.0, output: 120.0)
        case "gpt-5-mini", "gpt-5.1-codex-mini":
            return CodexPricingTier(input: 0.25, cacheRead: 0.025, output: 2.0)
        case "gpt-5-nano":
            return CodexPricingTier(input: 0.05, cacheRead: 0.005, output: 0.40)
        case "o3", "gpt-4.1":
            return CodexPricingTier(input: 2.0, cacheRead: 0.50, output: 8.0)
        case "o3-mini", "o4-mini", "codex-mini-latest":
            return CodexPricingTier(input: 1.10, cacheRead: 0.275, output: 4.40)
        case "gpt-4.1-mini":
            return CodexPricingTier(input: 0.40, cacheRead: 0.10, output: 1.60)
        case "gpt-4.1-nano":
            return CodexPricingTier(input: 0.10, cacheRead: 0.025, output: 0.40)
        case "gpt-4o":
            return CodexPricingTier(input: 2.50, cacheRead: 1.25, output: 10.0)
        case "gpt-4o-mini":
            return CodexPricingTier(input: 0.15, cacheRead: 0.075, output: 0.60)
        default:
            return nil
        }
    }

    private func usesModernOpusPricing(_ model: String) -> Bool {
        if [
            "4-5", "4.5", "4_5", "4-6", "4.6", "4_6", "4-7", "4.7", "4_7",
            "4-8", "4.8", "4_8", "4-9", "4.9", "4_9", "latest"
        ].contains(where: { model.contains($0) }) {
            return true
        }
        return model.range(of: #"opus-[5-9]|-[5-9]([._-]|$)"#, options: .regularExpression) != nil
    }

    private func usageObject(from object: [String: Any]) -> [String: Any]? {
        if let usage = object["usage"] as? [String: Any] { return usage }
        if let message = object["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            return usage
        }
        if let message = claudeMessageObject(from: object),
           let usage = message["usage"] as? [String: Any] {
            return usage
        }
        return nil
    }

    private func claudeIdentity(from object: [String: Any]) -> String? {
        if let message = claudeMessageObject(from: object),
           let id = stringValue(message["id"]) {
            return id
        }
        if let envelope = claudeEnvelopeObject(from: object) {
            for key in ["messageID", "messageId", "requestId", "request_id", "uuid"] {
                if let value = stringValue(envelope[key]) { return value }
            }
        }
        for key in ["messageID", "messageId", "requestId", "uuid"] {
            if let value = stringValue(object[key]) { return value }
        }
        return nil
    }

    private func model(from object: [String: Any]) -> String? {
        if let value = stringValue(object["model"]) { return value }
        if let message = object["message"] as? [String: Any],
           let value = stringValue(message["model"]) {
            return value
        }
        if let message = claudeMessageObject(from: object),
           let value = stringValue(message["model"]) {
            return value
        }
        if let payload = object["payload"] as? [String: Any] {
            if let value = stringValue(payload["model"]) { return value }
            if let value = stringValue(payload["model_name"]) { return value }
            if let info = payload["info"] as? [String: Any] {
                if let value = stringValue(info["model"]) { return value }
                if let value = stringValue(info["model_name"]) { return value }
                if let metadata = info["metadata"] as? [String: Any],
                   let value = stringValue(metadata["model"]) {
                    return value
                }
            }
            if let nested = payload["payload"] as? [String: Any],
               let value = stringValue(nested["model"]) {
                return value
            }
        }
        return nil
    }

    private func date(from object: [String: Any]) -> Date? {
        if let value = stringValue(object["timestamp"])
            ?? stringValue(object["created_at"])
            ?? stringValue(object["createdAt"]) {
            return parseDate(value)
        }
        if let step = object["step_update"] as? [String: Any],
           let value = stringValue(step["timestamp"]) ?? stringValue(step["created_at"]) {
            return parseDate(value)
        }
        if let envelope = claudeEnvelopeObject(from: object),
           let value = stringValue(envelope["timestamp"]) {
            return parseDate(value)
        }
        if let payload = object["payload"] as? [String: Any],
           let value = stringValue(payload["timestamp"]) {
            return parseDate(value)
        }
        return nil
    }

    private func parseDate(_ value: String) -> Date? {
        if let d = iso8601Frac.date(from: value) ?? iso8601.date(from: value) {
            return d
        }
        if let num = Double(value), num > 0 {
            return Date(timeIntervalSince1970: num > 10_000_000_000 ? num / 1000 : num)
        }
        return nil
    }

    private func explicitCost(from object: [String: Any]) -> Double? {
        for key in ["totalCost", "costUSD"] {
            if let value = doubleValue(object[key]) { return value }
        }
        if let message = object["message"] as? [String: Any] {
            for key in ["totalCost", "costUSD"] {
                if let value = doubleValue(message[key]) { return value }
            }
        }
        if let envelope = claudeEnvelopeObject(from: object) {
            for key in ["totalCost", "costUSD"] {
                if let value = doubleValue(envelope[key]) { return value }
            }
        }
        if let message = claudeMessageObject(from: object) {
            for key in ["totalCost", "costUSD"] {
                if let value = doubleValue(message[key]) { return value }
            }
        }
        return nil
    }

    private func cacheCreationBreakdown(from usage: [String: Any]) -> (fiveMinute: Int, oneHour: Int, total: Int) {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else {
            return (0, 0, 0)
        }
        let fiveMinute = intValue(cacheCreation["ephemeral_5m_input_tokens"])
        let oneHour = intValue(cacheCreation["ephemeral_1h_input_tokens"])
        return (fiveMinute, oneHour, fiveMinute + oneHour)
    }

    private func claudeEnvelopeObject(from object: [String: Any]) -> [String: Any]? {
        guard let data = object["data"] as? [String: Any],
              let envelope = data["message"] as? [String: Any] else { return nil }
        return envelope
    }

    private func claudeMessageObject(from object: [String: Any]) -> [String: Any]? {
        if let message = object["message"] as? [String: Any] {
            return message
        }
        if let envelope = claudeEnvelopeObject(from: object),
           let message = envelope["message"] as? [String: Any] {
            return message
        }
        return nil
    }

    private func enumerateJSONL(in directory: URL, since: Date, handler: (URL) -> Void) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > 50_000 { break }
            guard url.pathExtension == "jsonl" else { continue }
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < since {
                continue
            }
            handler(url)
        }
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func intValue(_ value: Any?) -> Int {
        guard let value, !(value is NSNull) else { return 0 }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return 0 }
            return number.intValue
        }
        if value is Bool { return 0 }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String, let double = Double(string) { return Int(double) }
        return 0
    }

    private func doubleValue(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        }
        if value is Bool { return nil }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.stringValue
        }
        if value is Bool || value is [String: Any] || value is [Any] { return nil }
        return String(describing: value)
    }
}

private actor CodexRemoteUsageCache {
    private struct Entry {
        let fetchedAt: Date
        let summary: TokenUsageSummary
    }

    private let ttlSeconds: TimeInterval = 10 * 60
    private var entries: [String: Entry] = [:]
    private var backoffUntil: [String: Date] = [:]

    func cachedSummary(for key: String, now: Date) -> TokenUsageSummary? {
        guard let entry = entries[key],
              now.timeIntervalSince(entry.fetchedAt) < ttlSeconds else {
            return nil
        }
        return entry.summary
    }

    func isBackedOff(for key: String, now: Date) -> Bool {
        guard let until = backoffUntil[key] else { return false }
        if until <= now {
            backoffUntil.removeValue(forKey: key)
            return false
        }
        return true
    }

    func store(summary: TokenUsageSummary, for key: String, now: Date) {
        entries[key] = Entry(fetchedAt: now, summary: summary)
        backoffUntil.removeValue(forKey: key)
    }

    func recordBackoff(for key: String, seconds: TimeInterval, now: Date) {
        let clamped = min(max(seconds, 60), 3600)
        backoffUntil[key] = now.addingTimeInterval(clamped)
    }
}

