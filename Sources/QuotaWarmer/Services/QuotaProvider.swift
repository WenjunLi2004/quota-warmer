import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

protocol QuotaProviding {
    func fetchQuota(for tool: ToolID) async throws -> QuotaSnapshot
}

final class QuotaProvider: QuotaProviding {
    private let credentialStore = CredentialStore()
    private let warmupRunner = WarmupRunner()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchQuota(for tool: ToolID) async throws -> QuotaSnapshot {
        switch tool {
        case .claude: return try await fetchClaudeQuota()
        case .codex: return try await fetchCodexQuota()
        case .antigravity: return try await fetchAntigravityQuota()
        }
    }

    private func fetchClaudeQuota() async throws -> QuotaSnapshot {
        let credential: Credential
        do {
            credential = try await credentialStore.credential(for: .claude)
        } catch CredentialError.interactionRequired(_) {
            throw QuotaProviderError.credentialInteractionRequired(
                "Claude's Keychain item couldn't be read — the login keychain may be locked. Retrying automatically."
            )
        } catch {
            throw QuotaProviderError.missingCredentials(
                "Claude credentials not found; checked \(credentialStore.credentialSourceSummary(for: .claude))"
            )
        }

        if credential.isExpired {
            // Only the CLI may refresh its rotating token; it does so on its
            // next run, and the next read here picks the new one up.
            throw QuotaProviderError.cliRefreshRequired(
                "Claude is signed in, but its quota credential needs a CLI refresh."
            )
        }

        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        do {
            let payload = try await requestJSON(url: url, credential: credential)
            return try requireRecognizedMetrics(
                claudeSnapshot(payload: payload, source: "Claude OAuth usage", corroboratingSource: nil, message: credential.source)
            )
        } catch QuotaProviderError.authFailure {
            // Do not consume a potentially rotating refresh token here. Claude
            // Code refreshes and persists its own credential when it next runs.
            throw QuotaProviderError.cliRefreshRequired(
                "Claude is signed in, but its quota credential needs a CLI refresh."
            )
        }
    }

    private func fetchCodexQuota() async throws -> QuotaSnapshot {
        let credential: Credential
        do {
            credential = try await credentialStore.credential(for: .codex)
        } catch {
            throw QuotaProviderError.missingCredentials(
                "Codex credentials not found; checked \(credentialStore.credentialSourceSummary(for: .codex))"
            )
        }

        // The codex app-server `rateLimits/read` path is not reachable with a
        // bearer token (Cloudflare 403 / 404), so the wham usage endpoint — the
        // same source the Codex web analytics page uses — is the live quota.
        let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let payload = try await requestJSON(url: usageURL, credential: credential)
        return try requireRecognizedMetrics(
            codexSnapshot(payload: payload, source: "Codex usage", message: credential.source)
        )
    }

    private func fetchAntigravityQuota() async throws -> QuotaSnapshot {
        // 1. Fast path: probe the local Antigravity Desktop / IDE language server
        //    if the user already has Antigravity open (zero subprocess startup).
        if let localSnapshot = try? await fetchAntigravityLocalServerQuota() {
            return localSnapshot
        }

        // 2. Headless CLI path: `agy -p /usage --output-format json` works even
        //    when the desktop app is closed (e.g. morning pre-warm) and spends
        //    zero model tokens on agy 1.1.11+.
        guard let cliURL = await warmupRunner.resolveCLIURL(for: .antigravity) else {
            throw QuotaProviderError.missingCredentials(
                "Antigravity is not running and agy CLI was not found; launch Antigravity or install agy"
            )
        }

        let version = await AntigravityVersionCache.shared.version(for: cliURL, runner: warmupRunner)
        // Older agy builds (< 1.1.11) could send unrecognized slash commands as
        // real model prompts instead of printing the internal quota report.
        guard let version, version >= (1, 1, 11) else {
            throw QuotaProviderError.unavailable(
                "Antigravity CLI 1.1.11 or newer is required for /usage quota reports"
            )
        }

        return try await fetchAntigravityCLIUsageQuota(cliURL: cliURL)
    }

    private func fetchAntigravityLocalServerQuota() async throws -> QuotaSnapshot? {
        let psURL = URL(fileURLWithPath: "/bin/ps")
        guard FileManager.default.isExecutableFile(atPath: psURL.path) else { return nil }
        let psResult = await warmupRunner.runDirectCommand(
            executableURL: psURL,
            arguments: ["-ax", "-o", "pid=,command="],
            timeout: 3
        )
        guard psResult.exitCode == 0 else { return nil }

        let candidates = AntigravityLocalProbe.parseProcessList(psResult.stdout)
        guard !candidates.isEmpty else { return nil }

        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }

        for candidate in candidates {
            var ports: [Int] = []
            if let lsofPath {
                let lsofResult = await warmupRunner.runDirectCommand(
                    executableURL: URL(fileURLWithPath: lsofPath),
                    arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)],
                    timeout: 3
                )
                if lsofResult.exitCode == 0 {
                    ports = AntigravityLocalProbe.parseListeningPorts(lsofResult.stdout)
                }
            }

            let endpoints = AntigravityLocalProbe.candidateEndpoints(for: candidate, listeningPorts: ports)
            guard !endpoints.isEmpty else { continue }

            let sourceLabel = candidate.kind == .app ? "Antigravity app" : "Antigravity IDE"
            for rpc in AntigravityLocalProbe.rpcTargets {
                for endpoint in endpoints {
                    guard let payload = try? await AntigravityLoopbackClient.shared.postJSON(
                        endpoint: endpoint,
                        path: rpc.path,
                        body: rpc.body,
                        timeout: 3.5
                    ) else { continue }
                    if let snapshot = try? requireRecognizedMetrics(
                        antigravitySnapshot(
                            payload: payload,
                            source: "Antigravity local server",
                            message: sourceLabel
                        )
                    ) {
                        return snapshot
                    }
                }
            }
        }
        return nil
    }

    private func fetchAntigravityCLIUsageQuota(cliURL: URL) async throws -> QuotaSnapshot {
        let stubDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("QuotaWarmerAgyProbe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stubDir) }

        // Stub `open` / `xdg-open` so a signed-out agy invocation cannot pop open
        // a browser login tab during unattended background polling.
        for cmd in ["open", "xdg-open"] {
            let stubPath = stubDir.appendingPathComponent(cmd).path
            _ = FileManager.default.createFile(
                atPath: stubPath,
                contents: Data("#!/bin/sh\nexit 1\n".utf8),
                attributes: [.posixPermissions: 0o700]
            )
        }

        let baseEnv = warmupRunner.environment(
            prependingPath: cliURL.deletingLastPathComponent().path,
            cliName: "agy"
        )
        let stubbedPath = stubDir.path + ":" + (baseEnv["PATH"] ?? "/usr/bin:/bin")
        let result = await warmupRunner.runDirectCommand(
            executableURL: cliURL,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "45s"],
            extraEnvironment: [
                "PATH": stubbedPath,
                "BROWSER": stubDir.appendingPathComponent("open").path,
                "AGY_CLI_DISABLE_AUTO_UPDATE": "true"
            ],
            pathPrefix: cliURL.deletingLastPathComponent().path,
            cliName: "agy",
            currentDirectoryURL: stubDir,
            timeout: 50
        )

        if result.timedOut {
            throw QuotaProviderError.unavailable("Antigravity CLI quota check timed out")
        }

        if result.exitCode == 0,
           let data = result.stdout.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) {
            if let dict = payload as? [String: Any],
               (dict["status"] as? String) == "ERROR",
               let errText = dict["error"] as? String,
               WarmupRunner.isAntigravityAuthenticationFailure(errText) {
                throw QuotaProviderError.authFailure(
                    "Antigravity CLI is not signed in. Run agy in Terminal to sign in, then Refresh."
                )
            }
            return try requireRecognizedMetrics(
                antigravitySnapshot(
                    payload: payload,
                    source: "Antigravity CLI usage",
                    message: "agy CLI"
                )
            )
        }

        let combined = "\(result.stdout)\n\(result.stderr)"
        if WarmupRunner.isAntigravityAuthenticationFailure(combined) {
            throw QuotaProviderError.authFailure(
                "Antigravity CLI is not signed in. Run agy in Terminal to sign in, then Refresh."
            )
        }
        let lower = combined.lowercased()
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("resource exhausted") {
            throw QuotaProviderError.rateLimited("Antigravity quota source rate-limited", retryAfter: nil)
        }
        throw QuotaProviderError.unavailable("Antigravity CLI quota check failed")
    }

    private func requestJSON(url: URL, credential: Credential) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if url.host == "api.anthropic.com", url.path == "/api/oauth/usage" {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            // Deliberately NOT identifying as `claude-code/<version>` here. Measured
            // 2026-08-04 against this endpoint while limited: the CLI user agent
            // returned Retry-After 3480s, the default agent 411s, in both request
            // orders. This endpoint throttles the CLI's own polling far harder, so
            // borrowing its identity would make our cooldowns ~8x longer.
        }
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return try JSONSerialization.jsonObject(with: data)
            case 401, 403:
                throw QuotaProviderError.authFailure("Authorization failed for \(url.host ?? "quota source")")
            case 429:
                let retryAfter = (response as? HTTPURLResponse).flatMap { retryAfterDelay(from: $0) }
                throw QuotaProviderError.rateLimited("Quota source rate limited requests", retryAfter: retryAfter)
            case 500..<600:
                throw QuotaProviderError.unavailable("Quota source is unavailable (\(status))")
            default:
                throw QuotaProviderError.unavailable("Quota source returned HTTP \(status)")
            }
        } catch let error as QuotaProviderError {
            throw error
        } catch {
            throw QuotaProviderError.unavailable("Could not reach quota source")
        }
    }

    private func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds > 0 {
            return seconds
        }
        if let date = HTTPDateFormatter.shared.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func requireRecognizedMetrics(_ snapshot: QuotaSnapshot) throws -> QuotaSnapshot {
        guard snapshot.fiveHour != nil || snapshot.weekly != nil || !snapshot.extras.isEmpty else {
            throw QuotaProviderError.malformed("Quota source returned no recognizable limit fields")
        }
        return snapshot
    }

    func snapshot(
        tool: ToolID,
        source: String,
        corroboratingSource: String?,
        payload: Any,
        message: String?
    ) -> QuotaSnapshot {
        let metrics = MetricExtractor(payload: payload).metrics()
        let now = Date()
        let weekly = selectWeeklyMetric(from: metrics, now: now)
        let fiveHour = selectFiveHourMetric(from: metrics, excluding: weekly, now: now)
        let extras = metrics.filter { metric in
            metric.id != fiveHour?.id && metric.id != weekly?.id
        }
        let keyParts = [
            source,
            fiveHour?.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset"
        ]

        return QuotaSnapshot(
            tool: tool,
            fetchedAt: Date(),
            primarySource: source,
            corroboratingSource: corroboratingSource,
            fiveHour: fiveHour,
            weekly: weekly,
            extras: extras,
            rawWindowKey: keyParts.joined(separator: "|"),
            message: message
        )
    }

    /// Claude's OAuth usage response reports the *active* rolling 5-hour window
    /// in `five_hour` (top-level) or `rate_limits.five_hour`. When the user
    /// hasn't touched Claude in the last 5 hours there is no active window and
    /// that slot comes back as an explicit `null`, which the generic extractor
    /// (correctly) drops — but for a tool whose whole job is the 5h window, a
    /// missing 5h metric renders as a broken-looking "--" and a blank menu-bar
    /// readout. Detect that explicit-null case and surface it as an idle, fully
    /// available window so the UI reads "100%" instead of empty.
    ///
    /// The idle window carries a *projected* reset of `now + windowDuration`
    /// (mirroring Codex's sliding "if you started now" projection) so the menu
    /// bar and panel show a countdown rather than a bare percentage. It is
    /// flagged `isIdle`, so it can be claimed by an opted-in auto-warm but cannot
    /// falsely confirm that a window already opened. Because that projection slides
    /// every poll, the dedup `rawWindowKey` is keyed on a stable "idle" marker
    /// instead of the moving timestamp. A populated `five_hour` still parses
    /// through the generic path.
    func claudeSnapshot(payload: Any, source: String, corroboratingSource: String?, message: String?) -> QuotaSnapshot {
        let base = snapshot(
            tool: .claude,
            source: source,
            corroboratingSource: corroboratingSource,
            payload: payload,
            message: message
        )
        // No usable 5h window when either the slot is an explicit `null`, or the
        // API returns a *populated* `five_hour` with no `resets_at` (e.g. right
        // after a window expires, or before the first request of a window: it
        // comes back `{ utilization: 0, resets_at: null }`). The latter parses as
        // a real, reset-less metric at ~100% left, which leaves the UI with a 5h
        // percentage but no countdown and makes the menu bar fall back to the
        // weekly window. Treat both as the idle case so a projected 5h reset is
        // shown instead. A real active window always carries a `resets_at`, so a
        // reset-less reading is only ever "no window" — guard on ~full remaining
        // to be safe (a reset-less reading with real usage is left untouched).
        let hasResetlessFullWindow = base.fiveHour.map {
            $0.resetAt == nil && $0.remainingFraction >= 0.95
        } ?? false
        guard base.fiveHour == nil || hasResetlessFullWindow,
              claudeReportsFiveHourSlot(payload) else { return base }

        let idleWindow = QuotaMetric(
            name: "5h",
            usedPercent: 0,
            remainingPercent: 1,
            resetAt: Date().addingTimeInterval(ToolID.claude.windowDuration),
            detail: nil,
            context: "5h idle window",
            isIdle: true
        )
        return QuotaSnapshot(
            tool: .claude,
            fetchedAt: base.fetchedAt,
            primarySource: base.primarySource,
            corroboratingSource: base.corroboratingSource,
            fiveHour: idleWindow,
            weekly: base.weekly,
            extras: base.extras,
            rawWindowKey: [base.primarySource, "idle"].joined(separator: "|"),
            message: base.message
        )
    }

    /// True when the payload is shaped like a Claude usage response that carries
    /// a `five_hour` slot (present even when its value is `null`) — so a missing
    /// parsed 5h metric means "no active window", not "unrecognized payload".
    private func claudeReportsFiveHourSlot(_ payload: Any) -> Bool {
        guard let dict = payload as? [String: Any] else { return false }
        if dict.keys.contains("five_hour") { return true }
        if let rateLimits = dict["rate_limits"] as? [String: Any],
           rateLimits.keys.contains("five_hour") {
            return true
        }
        return false
    }

    /// Parses the Codex `wham/usage` response, whose `rate_limit` block has a
    /// known shape: `primary_window` (the 5h window) and `secondary_window`
    /// (weekly). `used_percent` is on a 0–100 scale, so a value of `1` means
    /// 1% used — the generic heuristic extractor mis-reads that as 100% used,
    /// hence the explicit parse here. Falls back to the generic extractor if
    /// the response doesn't carry the expected windows.
    func codexSnapshot(payload: Any, source: String, message: String?) -> QuotaSnapshot {
        if let rateLimit = (payload as? [String: Any])?["rate_limit"] as? [String: Any],
           rateLimit["primary_window"] != nil || rateLimit["secondary_window"] != nil {
            let fiveHour = codexWindowMetric(rateLimit["primary_window"], defaultName: "5h")
            let weekly = codexWindowMetric(rateLimit["secondary_window"], defaultName: "Weekly")
            // An idle 5h window's projected reset slides every poll, so key it on a
            // stable marker instead of the moving timestamp.
            let fiveHourKey = (fiveHour?.isIdle == true)
                ? "idle"
                : (fiveHour?.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset")
            let keyParts = [source, fiveHourKey]
            return QuotaSnapshot(
                tool: .codex,
                fetchedAt: Date(),
                primarySource: source,
                corroboratingSource: nil,
                fiveHour: fiveHour,
                weekly: weekly,
                extras: [],
                rawWindowKey: keyParts.joined(separator: "|"),
                message: message
            )
        }

        return snapshot(
            tool: .codex,
            source: source,
            corroboratingSource: nil,
            payload: payload,
            message: message
        )
    }

    private func codexWindowMetric(_ value: Any?, defaultName: String) -> QuotaMetric? {
        guard let window = value as? [String: Any],
              let usedRaw = codexDouble(window["used_percent"]) else { return nil }
        let usedPercent = min(max(usedRaw / 100, 0), 1)

        let windowSeconds = codexDouble(window["limit_window_seconds"]) ?? 0
        let after = codexDouble(window["reset_after_seconds"])

        // An *idle* (not-yet-started) Codex window reports the full window length
        // as `reset_after_seconds` and a `reset_at` of now + the full window — a
        // "if you started now" projection that slides forward on every poll, not
        // a real boundary. We still surface that projected reset (the web shows it
        // too), but flag the metric idle so `canAutoWarm`/`showsActiveWindow` never
        // treat it as a freshly-opened window to warm or "claim".
        let isIdleWindow = windowSeconds > 0 && (after ?? 0) >= windowSeconds

        let resetAt: Date?
        if let epoch = codexDouble(window["reset_at"]), epoch > 0 {
            resetAt = Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        } else if let after, after > 0 {
            resetAt = Date().addingTimeInterval(after)
        } else {
            resetAt = nil
        }

        let name: String
        if windowSeconds >= 6 * 24 * 3600 {
            name = "Weekly"
        } else if windowSeconds > 0 && windowSeconds <= 6 * 3600 {
            name = "5h"
        } else {
            name = defaultName
        }

        return QuotaMetric(
            name: name,
            usedPercent: usedPercent,
            remainingPercent: 1 - usedPercent,
            resetAt: resetAt,
            detail: nil,
            context: isIdleWindow ? "\(name.lowercased()) idle" : name.lowercased(),
            isIdle: isIdleWindow
        )
    }

    private func codexDouble(_ value: Any?) -> Double? {
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

    // MARK: - Antigravity quota parsing

    /// Parses Antigravity quota payloads from:
    ///  1. `agy -p /usage --output-format json` (`status == "SUCCESS"`, `command.name == "usage"`, `command.data.groups`)
    ///  2. Local `RetrieveUserQuotaSummary` (`response.groups` / `summary.groups` / `groups`)
    ///  3. Legacy local `GetUserStatus` / `GetCommandModelConfigs` (`clientModelConfigs`)
    /// Falls back to the generic `MetricExtractor` only when none of those shapes is present.
    func antigravitySnapshot(
        payload: Any,
        source: String,
        message: String?,
        now: Date = Date()
    ) -> QuotaSnapshot {
        guard let rawDict = payload as? [String: Any] else {
            return emptySnapshot(tool: .antigravity, source: source, message: message, now: now)
        }

        // Unwrap CLI print report (`{"status":"SUCCESS","command":{"name":"usage","data":{...}}}`).
        let dict: [String: Any]
        if let status = rawDict["status"] as? String {
            guard status == "SUCCESS",
                  let command = rawDict["command"] as? [String: Any],
                  (command["name"] as? String) == "usage",
                  let data = command["data"] as? [String: Any] else {
                return emptySnapshot(tool: .antigravity, source: source, message: message, now: now)
            }
            dict = data
        } else {
            dict = rawDict
        }

        // Reject Connect RPC error envelopes (non-zero/non-OK `code`).
        if let code = dict["code"], !antigravityCodeIsOK(code) {
            return emptySnapshot(tool: .antigravity, source: source, message: message, now: now)
        }

        if let groups = extractAntigravityGroups(from: dict), !groups.isEmpty {
            return antigravityGroupsSnapshot(groups: groups, source: source, message: message, now: now)
        }

        if let configs = extractAntigravityModelConfigs(from: dict), !configs.isEmpty {
            return antigravityModelConfigsSnapshot(configs: configs, source: source, message: message, now: now)
        }

        return snapshot(
            tool: .antigravity,
            source: source,
            corroboratingSource: nil,
            payload: dict,
            message: message
        )
    }

    private func emptySnapshot(tool: ToolID, source: String, message: String?, now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            fetchedAt: now,
            primarySource: source,
            corroboratingSource: nil,
            fiveHour: nil,
            weekly: nil,
            extras: [],
            rawWindowKey: "\(source)|no-reset",
            message: message
        )
    }

    private func antigravityCodeIsOK(_ code: Any) -> Bool {
        if let intCode = code as? Int { return intCode == 0 }
        if let num = code as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return num.boolValue }
            return num.intValue == 0
        }
        if let str = code as? String {
            let lower = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower == "0" || lower == "ok" || lower == "success"
        }
        return false
    }

    private func extractAntigravityGroups(from dict: [String: Any]) -> [[String: Any]]? {
        if let groups = dict["groups"] as? [[String: Any]] { return groups }
        if let response = dict["response"] as? [String: Any],
           let groups = response["groups"] as? [[String: Any]] {
            return groups
        }
        if let summary = dict["summary"] as? [String: Any],
           let groups = summary["groups"] as? [[String: Any]] {
            return groups
        }
        return nil
    }

    private struct AntigravityParsedBucket {
        enum Cadence {
            case session
            case weekly
            case other
        }
        let identity: String
        let bucketId: String
        let groupLabel: String
        let groupRank: Int
        let bucketTitle: String
        let openUsageTitle: String
        let displayOrder: Int
        let cadence: Cadence
        let remainingFraction: Double
        let resetAt: Date?
    }

    private func antigravityGroupsSnapshot(
        groups: [[String: Any]],
        source: String,
        message: String?,
        now: Date
    ) -> QuotaSnapshot {
        var parsed: [AntigravityParsedBucket] = []
        for (groupIndex, group) in groups.enumerated() {
            let rawGroupName = ((group["displayName"] ?? group["display_name"] ?? group["name"]) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let (groupLabel, groupRank) = normalizeAntigravityGroup(rawGroupName)
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }

            for (bucketIndex, bucket) in buckets.enumerated() {
                if (bucket["disabled"] as? Bool) == true { continue }
                guard let remainingRaw = extractAntigravityRemainingFraction(from: bucket),
                      remainingRaw.isFinite else { continue }
                let remaining = min(max(remainingRaw, 0), 1)

                let bucketId = ((bucket["bucketId"] ?? bucket["bucket_id"] ?? bucket["id"]) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "bucket-\(groupIndex)-\(bucketIndex)"
                let bucketName = ((bucket["displayName"] ?? bucket["display_name"] ?? bucket["name"]) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? bucketId
                let windowStr = (bucket["window"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let cadence = classifyAntigravityCadence(window: windowStr, id: bucketId, name: bucketName)
                let resetAt = extractAntigravityDate(bucket["resetTime"] ?? bucket["reset_time"])
                let shortCadenceTitle: String
                switch cadence {
                case .session: shortCadenceTitle = "5h"
                case .weekly:  shortCadenceTitle = "Weekly"
                case .other:   shortCadenceTitle = bucketName
                }

                let (openUsageTitle, displayOrder) = formatAntigravityDisplaySlot(
                    bucketId: bucketId,
                    groupLabel: groupLabel,
                    cadence: cadence,
                    fallbackTitle: "\(groupLabel) \(shortCadenceTitle)"
                )

                parsed.append(AntigravityParsedBucket(
                    identity: "\(groupIndex):\(bucketId)",
                    bucketId: bucketId,
                    groupLabel: groupLabel,
                    groupRank: groupRank,
                    bucketTitle: "\(groupLabel) \(shortCadenceTitle)",
                    openUsageTitle: openUsageTitle,
                    displayOrder: displayOrder,
                    cadence: cadence,
                    remainingFraction: remaining,
                    resetAt: resetAt
                ))
            }
        }

        guard !parsed.isEmpty else {
            return emptySnapshot(tool: .antigravity, source: source, message: message, now: now)
        }

        let selectedSession = selectMostConstrainedAntigravityBucket(
            parsed.filter { $0.cadence == .session }
        )
        let selectedWeekly = selectMostConstrainedAntigravityBucket(
            parsed.filter { $0.cadence == .weekly }
        )

        let windowDuration = ToolID.antigravity.windowDuration
        let weeklyDuration = ToolID.antigravity.weeklyWindowDuration
        let fiveHour: QuotaMetric? = selectedSession.map { bucket in
            buildAntigravitySessionMetric(
                name: "5h",
                remainingFraction: bucket.remainingFraction,
                resetAt: bucket.resetAt,
                detail: bucket.groupLabel,
                windowDuration: windowDuration,
                now: now
            )
        }

        let weekly: QuotaMetric? = selectedWeekly.map { bucket in
            QuotaMetric(
                name: "Weekly",
                usedPercent: 1 - bucket.remainingFraction,
                remainingPercent: bucket.remainingFraction,
                resetAt: bucket.resetAt,
                detail: bucket.groupLabel,
                context: "\(bucket.groupLabel.lowercased()) weekly",
                isIdle: false,
                windowDurationSeconds: weeklyDuration
            )
        }

        let extras: [QuotaMetric] = parsed
            .filter { $0.identity != selectedSession?.identity && $0.identity != selectedWeekly?.identity }
            .map { bucket in
                QuotaMetric(
                    name: bucket.bucketTitle,
                    usedPercent: 1 - bucket.remainingFraction,
                    remainingPercent: bucket.remainingFraction,
                    resetAt: bucket.resetAt,
                    detail: bucket.groupLabel,
                    context: bucket.bucketTitle.lowercased(),
                    isIdle: false,
                    windowDurationSeconds: bucket.cadence == .weekly ? weeklyDuration : windowDuration
                )
            }

        let sortedDisplayBuckets = parsed.sorted { lhs, rhs in
            if lhs.displayOrder != rhs.displayOrder { return lhs.displayOrder < rhs.displayOrder }
            if lhs.groupRank != rhs.groupRank { return lhs.groupRank < rhs.groupRank }
            return lhs.identity < rhs.identity
        }
        var seenDisplayTitles = Set<String>()
        let displayMetrics: [QuotaMetric] = sortedDisplayBuckets.compactMap { bucket in
            guard seenDisplayTitles.insert(bucket.openUsageTitle).inserted else { return nil }
            switch bucket.cadence {
            case .session:
                return buildAntigravitySessionMetric(
                    name: bucket.openUsageTitle,
                    remainingFraction: bucket.remainingFraction,
                    resetAt: bucket.resetAt,
                    detail: bucket.groupLabel,
                    windowDuration: windowDuration,
                    now: now
                )
            case .weekly, .other:
                return QuotaMetric(
                    name: bucket.openUsageTitle,
                    usedPercent: 1 - bucket.remainingFraction,
                    remainingPercent: bucket.remainingFraction,
                    resetAt: bucket.resetAt,
                    detail: bucket.groupLabel,
                    context: "\(bucket.openUsageTitle.lowercased()) weekly",
                    isIdle: false,
                    windowDurationSeconds: bucket.cadence == .weekly ? weeklyDuration : windowDuration
                )
            }
        }

        let fiveHourKey = (fiveHour?.isIdle == true)
            ? "idle"
            : (fiveHour?.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset")

        return QuotaSnapshot(
            tool: .antigravity,
            fetchedAt: now,
            primarySource: source,
            corroboratingSource: nil,
            fiveHour: fiveHour,
            weekly: weekly,
            extras: extras,
            rawWindowKey: [source, fiveHourKey].joined(separator: "|"),
            message: message,
            displayMetrics: displayMetrics
        )
    }

    private func formatAntigravityDisplaySlot(
        bucketId: String,
        groupLabel: String,
        cadence: AntigravityParsedBucket.Cadence,
        fallbackTitle: String
    ) -> (title: String, order: Int) {
        let lowerId = bucketId.lowercased()
        let lowerGroup = groupLabel.lowercased()
        if lowerId == "gemini-5h" || (groupLabel == "Gemini" && cadence == .session) {
            return ("Gemini 5h", 0)
        }
        if lowerId == "gemini-weekly" || (groupLabel == "Gemini" && cadence == .weekly) {
            return ("Gemini", 1)
        }
        if lowerGroup.contains("argon") && cadence == .weekly {
            return ("Argon", 2)
        }
        if lowerId == "3p-5h" || (groupLabel == "Claude/GPT" && cadence == .session) {
            return ("Claude 5h", 3)
        }
        if lowerId == "3p-weekly" || (groupLabel == "Claude/GPT" && cadence == .weekly) {
            return ("Claude", 4)
        }
        return (fallbackTitle, 5)
    }

    private func buildAntigravitySessionMetric(
        name: String = "5h",
        remainingFraction: Double,
        resetAt: Date?,
        detail: String?,
        windowDuration: TimeInterval,
        now: Date
    ) -> QuotaMetric {
        let isResetlessFull = resetAt == nil && remainingFraction >= 0.999
        let isSlidingFull = remainingFraction >= 0.999
            && (resetAt.map { $0.timeIntervalSince(now) >= windowDuration - 15 } ?? false)
        let isIdle = isResetlessFull || isSlidingFull
        let effectiveReset = resetAt ?? (isIdle ? now.addingTimeInterval(windowDuration) : nil)

        return QuotaMetric(
            name: name,
            usedPercent: 1 - remainingFraction,
            remainingPercent: remainingFraction,
            resetAt: effectiveReset,
            detail: detail,
            context: isIdle ? "5h idle window" : "\((detail ?? "antigravity").lowercased()) 5h",
            isIdle: isIdle,
            windowDurationSeconds: windowDuration
        )
    }

    private func selectMostConstrainedAntigravityBucket(
        _ candidates: [AntigravityParsedBucket]
    ) -> AntigravityParsedBucket? {
        candidates.min { lhs, rhs in
            if abs(lhs.remainingFraction - rhs.remainingFraction) > 0.0001 {
                return lhs.remainingFraction < rhs.remainingFraction
            }
            if lhs.groupRank != rhs.groupRank {
                return lhs.groupRank < rhs.groupRank
            }
            if (lhs.resetAt != nil) != (rhs.resetAt != nil) {
                return lhs.resetAt != nil
            }
            return lhs.identity < rhs.identity
        }
    }

    private func normalizeAntigravityGroup(_ rawName: String) -> (label: String, rank: Int) {
        let lower = rawName.lowercased()
        // Plain "Gemini Models" is the primary pool; versioned pools like
        // "Gemini 4 Argon" have independent limits and keep their own title.
        if lower.contains("gemini"), !rawName.contains(where: \.isNumber) {
            return ("Gemini", 0)
        }
        if lower.contains("claude") || lower.contains("gpt") {
            return ("Claude/GPT", 1)
        }
        return (rawName.isEmpty ? "Quota" : rawName, 2)
    }

    private func classifyAntigravityCadence(
        window: String?,
        id: String,
        name: String
    ) -> AntigravityParsedBucket.Cadence {
        let probes = (window?.isEmpty == false ? [window!] : [id, name]).map {
            $0.lowercased().replacingOccurrences(of: "_", with: "-")
        }
        for p in probes {
            if p.contains("5h") || p.contains("5-hour") || p.contains("five hour") || p.contains("five-hour") || p == "session" {
                return .session
            }
        }
        for p in probes {
            if p.contains("weekly") || p.contains("7-day") || p.contains("7d") || p.contains("seven-day") || p.contains("week") {
                return .weekly
            }
        }
        return .other
    }

    private func extractAntigravityRemainingFraction(from dict: [String: Any]) -> Double? {
        if let direct = codexDouble(dict["remainingFraction"] ?? dict["remaining_fraction"]) {
            return direct
        }
        if let nested = dict["remaining"] as? [String: Any] {
            if let directNested = codexDouble(nested["remainingFraction"] ?? nested["remaining_fraction"]) {
                return directNested
            }
            if let oneofCase = nested["case"] as? String,
               (oneofCase == "remainingFraction" || oneofCase == "remaining_fraction"),
               let val = codexDouble(nested["value"]) {
                return val
            }
        }
        return nil
    }

    private func extractAntigravityDate(_ value: Any?) -> Date? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let iso = MetricExtractor.parseISODate(trimmed) {
                return iso
            }
            if let epoch = Double(trimmed), epoch > 0 {
                return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
            }
        }
        if let epoch = codexDouble(value), epoch > 0 {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        return nil
    }

    private func extractAntigravityModelConfigs(from dict: [String: Any]) -> [[String: Any]]? {
        if let configs = dict["clientModelConfigs"] as? [[String: Any]] {
            return configs
        }
        if let configs = dict["client_model_configs"] as? [[String: Any]] {
            return configs
        }
        if let userStatus = (dict["userStatus"] ?? dict["user_status"]) as? [String: Any],
           let cascade = (userStatus["cascadeModelConfigData"] ?? userStatus["cascade_model_config_data"]) as? [String: Any],
           let configs = (cascade["clientModelConfigs"] ?? cascade["client_model_configs"]) as? [[String: Any]] {
            return configs
        }
        return nil
    }

    private func antigravityModelConfigsSnapshot(
        configs: [[String: Any]],
        source: String,
        message: String?,
        now: Date
    ) -> QuotaSnapshot {
        struct ModelCandidate {
            let label: String
            let modelId: String
            let isGemini: Bool
            let remainingFraction: Double
            let resetAt: Date?
        }

        var candidates: [ModelCandidate] = []
        for config in configs {
            let label = (config["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let alias = (config["modelOrAlias"] ?? config["model_or_alias"]) as? [String: Any]
            let modelId = (alias?["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? label
            let combined = "\(label) \(modelId)".lowercased()
            // Auxiliary models (lite, autocomplete, image) carry separate internal pools
            // and must not mask the user's primary coding model quota.
            if combined.contains("lite") || combined.contains("autocomplete")
                || modelId.lowercased().hasPrefix("tab_") || combined.contains("image") {
                continue
            }
            guard let quotaInfo = (config["quotaInfo"] ?? config["quota_info"]) as? [String: Any],
                  let remRaw = codexDouble(quotaInfo["remainingFraction"] ?? quotaInfo["remaining_fraction"]),
                  remRaw.isFinite else { continue }
            let remaining = min(max(remRaw, 0), 1)
            let resetAt = extractAntigravityDate(quotaInfo["resetTime"] ?? quotaInfo["reset_time"])
            candidates.append(ModelCandidate(
                label: label.isEmpty ? modelId : label,
                modelId: modelId,
                isGemini: combined.contains("gemini"),
                remainingFraction: remaining,
                resetAt: resetAt
            ))
        }

        guard !candidates.isEmpty else {
            return emptySnapshot(tool: .antigravity, source: source, message: message, now: now)
        }

        let weeklyCandidates = candidates.filter { c in
            if c.label.lowercased().contains("week") { return true }
            if let resetAt = c.resetAt, resetAt.timeIntervalSince(now) > 24 * 3600 { return true }
            return false
        }
        let sessionCandidates = candidates.filter { c in
            !weeklyCandidates.contains(where: { $0.modelId == c.modelId && $0.label == c.label })
        }

        let pickBest: ([ModelCandidate]) -> ModelCandidate? = { list in
            list.min { lhs, rhs in
                if abs(lhs.remainingFraction - rhs.remainingFraction) > 0.0001 {
                    return lhs.remainingFraction < rhs.remainingFraction
                }
                if lhs.isGemini != rhs.isGemini {
                    return lhs.isGemini
                }
                return lhs.label < rhs.label
            }
        }

        let windowDuration = ToolID.antigravity.windowDuration
        let weeklyDuration = ToolID.antigravity.weeklyWindowDuration
        let chosenSession = pickBest(sessionCandidates)
        let chosenWeekly = pickBest(weeklyCandidates)

        let fiveHour = chosenSession.map { c in
            buildAntigravitySessionMetric(
                name: "5h",
                remainingFraction: c.remainingFraction,
                resetAt: c.resetAt,
                detail: c.label,
                windowDuration: windowDuration,
                now: now
            )
        }
        let weekly = chosenWeekly.map { c in
            QuotaMetric(
                name: "Weekly",
                usedPercent: 1 - c.remainingFraction,
                remainingPercent: c.remainingFraction,
                resetAt: c.resetAt,
                detail: c.label,
                context: "\(c.label.lowercased()) weekly",
                isIdle: false,
                windowDurationSeconds: weeklyDuration
            )
        }

        var displayMetrics: [QuotaMetric] = []
        if let g5 = pickBest(sessionCandidates.filter(\.isGemini)) {
            displayMetrics.append(buildAntigravitySessionMetric(
                name: "Gemini 5h",
                remainingFraction: g5.remainingFraction,
                resetAt: g5.resetAt,
                detail: g5.label,
                windowDuration: windowDuration,
                now: now
            ))
        }
        if let gw = pickBest(weeklyCandidates.filter(\.isGemini)) {
            displayMetrics.append(QuotaMetric(
                name: "Gemini",
                usedPercent: 1 - gw.remainingFraction,
                remainingPercent: gw.remainingFraction,
                resetAt: gw.resetAt,
                detail: gw.label,
                context: "gemini weekly",
                isIdle: false,
                windowDurationSeconds: weeklyDuration
            ))
        }
        if let c5 = pickBest(sessionCandidates.filter { !$0.isGemini }) {
            displayMetrics.append(buildAntigravitySessionMetric(
                name: "Claude 5h",
                remainingFraction: c5.remainingFraction,
                resetAt: c5.resetAt,
                detail: c5.label,
                windowDuration: windowDuration,
                now: now
            ))
        }
        if let cw = pickBest(weeklyCandidates.filter { !$0.isGemini }) {
            displayMetrics.append(QuotaMetric(
                name: "Claude",
                usedPercent: 1 - cw.remainingFraction,
                remainingPercent: cw.remainingFraction,
                resetAt: cw.resetAt,
                detail: cw.label,
                context: "claude weekly",
                isIdle: false,
                windowDurationSeconds: weeklyDuration
            ))
        }

        let fiveHourKey = (fiveHour?.isIdle == true)
            ? "idle"
            : (fiveHour?.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset")

        return QuotaSnapshot(
            tool: .antigravity,
            fetchedAt: now,
            primarySource: source,
            corroboratingSource: nil,
            fiveHour: fiveHour,
            weekly: weekly,
            extras: [],
            rawWindowKey: [source, fiveHourKey].joined(separator: "|"),
            message: message,
            displayMetrics: displayMetrics
        )
    }

    private func selectWeeklyMetric(from metrics: [QuotaMetric], now: Date) -> QuotaMetric? {
        bestMetric(from: metrics) { metric in
            let text = quotaText(metric)
            var score = 0
            if text.contains("weekly") || text.contains("week") || text.contains("sevenday") || text.contains("7day") {
                score += 100
            }
            if text.contains("allmodels") || text.contains("all models") { score += 8 }
            if metric.remainingPercent != nil { score += 5 }
            if let resetAt = metric.resetAt {
                let seconds = resetAt.timeIntervalSince(now)
                if seconds > 24 * 3600 { score += 45 }
                if seconds > 8 * 24 * 3600 { score -= 25 }
                if seconds > 0 { score += 3 }
            }
            if text.contains("5h") || text.contains("5hour") || text.contains("5 hour") || text.contains("session") {
                score -= 80
            }
            return score
        }
    }

    private func selectFiveHourMetric(from metrics: [QuotaMetric], excluding weekly: QuotaMetric?, now: Date) -> QuotaMetric? {
        let candidates = metrics.filter { $0.id != weekly?.id }
        if let best = bestMetric(from: candidates, minimumScore: 30, scoredBy: { metric in
            let text = quotaText(metric)
            var score = 0
            if text.contains("5h") || text.contains("5hour") || text.contains("5 hour")
                || text.contains("fivehour") || text.contains("five hour") {
                score += 120
            }
            if text.contains("session") || text.contains("current") {
                score += 70
            }
            if metric.remainingPercent != nil { score += 6 }
            if let resetAt = metric.resetAt {
                let seconds = resetAt.timeIntervalSince(now)
                if seconds > 0 && seconds <= 8 * 3600 { score += 55 }
                if seconds > 24 * 3600 { score -= 120 }
            }
            if text.contains("weekly") || text.contains("week") {
                score -= 120
            }
            return score
        }) {
            return best
        }

        let shortResetCandidates = candidates.filter { metric in
            guard let resetAt = metric.resetAt else { return false }
            let seconds = resetAt.timeIntervalSince(now)
            return seconds > 0 && seconds <= 8 * 3600
        }
        return shortResetCandidates.count == 1 ? shortResetCandidates[0] : nil
    }

    private func bestMetric(
        from metrics: [QuotaMetric],
        minimumScore: Int = 1,
        scoredBy scorer: (QuotaMetric) -> Int
    ) -> QuotaMetric? {
        var best: (metric: QuotaMetric, score: Int)?
        for metric in metrics {
            let score = scorer(metric)
            guard score >= minimumScore else { continue }
            if best == nil || score > best!.score {
                best = (metric, score)
            }
        }
        return best?.metric
    }

    private func quotaText(_ metric: QuotaMetric) -> String {
        "\(metric.name) \(metric.context) \(metric.detail ?? "")"
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

struct MetricExtractor {
    let payload: Any

    func metrics() -> [QuotaMetric] {
        var output: [QuotaMetric] = []
        collect(from: payload, path: [], output: &output)
        return output
    }

    private func collect(from value: Any, path: [String], output: inout [QuotaMetric]) {
        if let dict = value as? [String: Any] {
            if let metric = metric(from: dict, path: path), !containsEquivalent(metric, in: output) {
                output.append(metric)
            }
            for key in dict.keys.sorted() {
                guard let child = dict[key] else { continue }
                collect(from: child, path: path + [key], output: &output)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collect(from: child, path: path + ["\(index)"], output: &output)
            }
        }
    }

    private func metric(from dict: [String: Any], path: [String]) -> QuotaMetric? {
        let fields = normalizedFields(from: dict)
        let context = contextText(path: path, fields: fields)
        let usedPercentCandidate = firstNumber(fields, keys: [
            "usedpercent", "usedpercentage", "usagepercent", "usagepercentage",
            "consumedpercent", "percentused"
        ])
        // `utilization` (Anthropic's Claude OAuth usage field) is on a 0–100 scale
        // where 1 means 1% used — NOT a 0–1 fraction. It must be divided by 100
        // unconditionally; routing it through the ambiguous percent normalizer
        // misreads a freshly-warmed window (utilization ~1) as 100% used / 0% left.
        let utilizationCandidate = firstNumber(fields, keys: ["utilization"])
        let remainingPercentCandidate = firstNumber(fields, keys: [
            "remainingpercent", "remainingpercentage", "percentremaining",
            "availablepercent", "availablepercentage", "leftpercent", "percentleft"
        ])
        let genericPercent = firstNumber(fields, keys: ["percent", "percentage"])
        let used = firstNumber(fields, keys: ["used", "usage", "consumed", "current"])
        let remaining = firstNumber(fields, keys: ["remaining", "available", "left"])
        let limit = firstNumber(fields, keys: ["limit", "total", "max", "quota", "allowed", "cap"])

        let usedPercent: Double?
        let remainingPercent: Double?
        if let remainingPercentCandidate {
            remainingPercent = normalizePercent(remainingPercentCandidate)
            usedPercent = 1 - remainingPercent!
        } else if let usedPercentCandidate {
            remainingPercent = nil
            usedPercent = normalizePercent(usedPercentCandidate)
        } else if let utilizationCandidate {
            remainingPercent = nil
            usedPercent = min(max(utilizationCandidate / 100, 0), 1)
        } else if let genericPercent, contextContainsRemaining(context) {
            remainingPercent = normalizePercent(genericPercent)
            usedPercent = 1 - remainingPercent!
        } else if let genericPercent, contextContainsUsed(context) {
            remainingPercent = nil
            usedPercent = normalizePercent(genericPercent)
        } else if let remaining, let limit, limit > 0 {
            remainingPercent = normalizeRatio(remaining, limit: limit)
            usedPercent = 1 - remainingPercent!
        } else if let used, let limit, limit > 0 {
            remainingPercent = nil
            usedPercent = used / limit
        } else {
            remainingPercent = nil
            usedPercent = nil
        }

        guard let usedPercent else { return nil }
        let resetAt = firstDate(fields, keys: [
            "resetat", "resetsat", "resettime", "nextresetat",
            "endsat", "expiresat", "resetsin", "resetin"
        ])
        let name = firstString(fields, keys: [
            "name", "type", "window", "period", "interval", "model",
            "bucket", "label", "limittype", "limitname"
        ])
            ?? readableName(path: path)
        let detail: String?
        if let used, let limit {
            detail = "\(compactNumber(used)) / \(compactNumber(limit))"
        } else if let remaining, let limit {
            detail = "\(compactNumber(remaining)) left of \(compactNumber(limit))"
        } else {
            detail = nil
        }

        return QuotaMetric(
            name: name,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            detail: detail,
            context: context
        )
    }

    private func containsEquivalent(_ metric: QuotaMetric, in metrics: [QuotaMetric]) -> Bool {
        metrics.contains { existing in
            existing.name == metric.name
                && existing.context == metric.context
                && abs(existing.remainingFraction - metric.remainingFraction) < 0.001
        }
    }

    private func normalizedFields(from dict: [String: Any]) -> [Field] {
        dict.map { key, value in
            Field(originalKey: key, normalizedKey: normalizeKey(key), value: value)
        }
    }

    private func firstNumber(_ fields: [Field], keys: [String]) -> Double? {
        for key in keys {
            guard let field = fields.first(where: { $0.normalizedKey == key }) else { continue }
            if let number = field.value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { continue }
                return number.doubleValue
            }
            if field.value is Bool { continue }
            if let double = field.value as? Double { return double }
            if let int = field.value as? Int { return Double(int) }
            if let string = field.value as? String, let double = Double(string) { return double }
        }
        return nil
    }

    private func firstString(_ fields: [Field], keys: [String]) -> String? {
        for key in keys {
            if let field = fields.first(where: { $0.normalizedKey == key }),
               let string = field.value as? String,
               !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private func firstDate(_ fields: [Field], keys: [String]) -> Date? {
        for key in keys {
            guard let field = fields.first(where: { $0.normalizedKey == key }) else { continue }
            if let string = field.value as? String, let date = Self.parseISODate(string) {
                return date
            }
            if let number = field.value as? NSNumber {
                let seconds = number.doubleValue
                if field.normalizedKey.hasSuffix("in") {
                    return Date().addingTimeInterval(seconds)
                }
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            }
        }
        return nil
    }

    private func normalizePercent(_ value: Double) -> Double {
        min(max(value > 1 ? value / 100 : value, 0), 1)
    }

    private func normalizeRatio(_ value: Double, limit: Double) -> Double {
        min(max(value / limit, 0), 1)
    }

    private func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func contextText(path: [String], fields: [Field]) -> String {
        let stringValues = fields.compactMap { $0.value as? String }
        return (path + fields.map(\.originalKey) + stringValues)
            .joined(separator: " ")
            .lowercased()
    }

    private func contextContainsRemaining(_ context: String) -> Bool {
        context.contains("remaining") || context.contains("available") || context.contains("left")
    }

    private func contextContainsUsed(_ context: String) -> Bool {
        context.contains("used")
            || context.contains("consumed")
            || (context.contains("usage") && !context.contains("limit"))
    }

    private func readableName(path: [String]) -> String {
        let useful = path.reversed().first { part in
            Int(part) == nil && !["data", "limits", "usage", "quota", "rate_limits"].contains(part.lowercased())
        }
        return useful?
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized ?? "Quota"
    }

    private func compactNumber(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fm", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private struct Field {
        let originalKey: String
        let normalizedKey: String
        let value: Any
    }

    /// Some sources (e.g. Claude OAuth usage) emit ISO-8601 timestamps with
    /// fractional seconds — "2026-06-04T11:10:00.973380+00:00" — which a default
    /// `ISO8601DateFormatter` rejects. Try the fractional-seconds variant first,
    /// then fall back to the plain internet date-time format.
    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    static func parseISODate(_ string: String) -> Date? {
        for formatter in isoFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}

private enum HTTPDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

// MARK: - Antigravity Local Server & Version Helpers

enum AntigravityLocalProbe {
    enum ProcessKind: Equatable {
        case app
        case ide
    }

    struct ProcessCandidate: Equatable {
        let pid: Int
        let kind: ProcessKind
        let csrfToken: String
        let extensionPort: Int?
        let extensionServerCSRFToken: String?
    }

    struct Endpoint: Equatable {
        let scheme: String
        let port: Int
        let csrfToken: String
    }

    struct RPCTarget {
        let path: String
        let body: [String: Any]
    }

    static let rpcTargets: [RPCTarget] = [
        RPCTarget(
            path: "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            body: ["forceRefresh": true]
        ),
        RPCTarget(
            path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
            body: [
                "metadata": [
                    "ideName": "antigravity",
                    "extensionName": "antigravity",
                    "ideVersion": "unknown",
                    "locale": "en"
                ]
            ]
        ),
        RPCTarget(
            path: "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs",
            body: [
                "metadata": [
                    "ideName": "antigravity",
                    "extensionName": "antigravity",
                    "ideVersion": "unknown",
                    "locale": "en"
                ]
            ]
        )
    ]

    /// Parses `ps -ax -o pid=,command=` output and extracts running Antigravity
    /// Desktop / IDE language-server processes with their local CSRF tokens.
    /// App servers sort ahead of IDE extension servers because the app exposes
    /// the structured quota summary first.
    static func parseProcessList(_ output: String) -> [ProcessCandidate] {
        var candidates: [ProcessCandidate] = []
        for rawLine in output.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let command = String(parts[1])
            guard let kind = classifyCommandLine(command),
                  let csrf = extractFlag("--csrf_token", from: command),
                  !csrf.isEmpty else {
                continue
            }
            let extPort = extractFlag("--extension_server_port", from: command).flatMap { Int($0) }
            let extCsrf = extractFlag("--extension_server_csrf_token", from: command)
            candidates.append(ProcessCandidate(
                pid: pid,
                kind: kind,
                csrfToken: csrf,
                extensionPort: extPort,
                extensionServerCSRFToken: extCsrf
            ))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .app }
            return lhs.pid < rhs.pid
        }
    }

    private static func classifyCommandLine(_ command: String) -> ProcessKind? {
        let lower = command.lowercased()
        let isLanguageServer = lower.contains("language_server") || lower.contains("language-server")
        guard isLanguageServer else { return nil }
        guard lower.contains("antigravity") else { return nil }

        if lower.contains("--app_data_dir antigravity-ide")
            || lower.contains("--app_data_dir=antigravity-ide")
            || lower.contains("antigravity ide.app")
            || lower.contains("/extensions/antigravity/") {
            return .ide
        }
        return .app
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for (idx, token) in tokens.enumerated() {
            if token == flag, idx + 1 < tokens.count {
                let value = tokens[idx + 1]
                return value.hasPrefix("--") ? nil : value
            }
            let prefix = "\(flag)="
            if token.hasPrefix(prefix) {
                let value = String(token.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func parseListeningPorts(_ lsofOutput: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else {
            return []
        }
        let range = NSRange(lsofOutput.startIndex..<lsofOutput.endIndex, in: lsofOutput)
        var ports = Set<Int>()
        regex.enumerateMatches(in: lsofOutput, options: [], range: range) { match, _, _ in
            guard let match,
                  let portRange = Range(match.range(at: 1), in: lsofOutput),
                  let port = Int(lsofOutput[portRange]),
                  (1...65_535).contains(port) else { return }
            ports.insert(port)
        }
        return ports.sorted()
    }

    static func candidateEndpoints(for candidate: ProcessCandidate, listeningPorts: [Int]) -> [Endpoint] {
        var endpoints: [Endpoint] = []
        #if os(Linux)
        let schemes = ["https", "http"]
        #else
        let schemes = ["https"]
        #endif

        for port in listeningPorts {
            for scheme in schemes {
                endpoints.append(Endpoint(scheme: scheme, port: port, csrfToken: candidate.csrfToken))
            }
        }

        if let extPort = candidate.extensionPort {
            if let extToken = candidate.extensionServerCSRFToken, !extToken.isEmpty {
                let ep = Endpoint(scheme: "http", port: extPort, csrfToken: extToken)
                if !endpoints.contains(ep) { endpoints.append(ep) }
            }
            let fallbackEp = Endpoint(scheme: "http", port: extPort, csrfToken: candidate.csrfToken)
            if !endpoints.contains(fallbackEp) { endpoints.append(fallbackEp) }
        }

        return endpoints
    }
}

actor AntigravityVersionCache {
    static let shared = AntigravityVersionCache()

    private struct BinaryIdentity: Equatable {
        let path: String
        let mtime: Date
        let size: UInt64
    }

    private var cached: (identity: BinaryIdentity, version: (Int, Int, Int))?

    func version(for cliURL: URL, runner: WarmupRunner) async -> (Int, Int, Int)? {
        let resolvedPath = cliURL.resolvingSymlinksInPath().path
        let identity: BinaryIdentity? = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else {
                return nil
            }
            return BinaryIdentity(path: resolvedPath, mtime: mtime, size: size)
        }()

        if let identity, let cached, cached.identity == identity {
            return cached.version
        }

        let result = await runner.runDirectCommand(
            executableURL: cliURL,
            arguments: ["--version"],
            pathPrefix: cliURL.deletingLastPathComponent().path,
            cliName: "agy",
            timeout: 4
        )
        guard result.exitCode == 0,
              let parsed = Self.parseVersion(result.stdout) else {
            return nil
        }
        if let identity {
            cached = (identity, parsed)
        }
        return parsed
    }

    static func parseVersion(_ output: String) -> (Int, Int, Int)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d+)\.(\d+)\.(\d+)\b"#),
              let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
              let r1 = Range(match.range(at: 1), in: trimmed),
              let r2 = Range(match.range(at: 2), in: trimmed),
              let r3 = Range(match.range(at: 3), in: trimmed),
              let major = Int(trimmed[r1]),
              let minor = Int(trimmed[r2]),
              let patch = Int(trimmed[r3]) else {
            return nil
        }
        return (major, minor, patch)
    }
}

/// Loopback-only HTTP/HTTPS client for Antigravity's local language server,
/// which uses a self-signed certificate on `127.0.0.1`. Server-trust override
/// is strictly confined to loopback hosts.
private final class AntigravityLoopbackClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = AntigravityLoopbackClient()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func postJSON(
        endpoint: AntigravityLocalProbe.Endpoint,
        path: String,
        body: [String: Any],
        timeout: TimeInterval
    ) async throws -> Any {
        guard endpoint.port > 0,
              let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw QuotaProviderError.unavailable("Invalid local Antigravity endpoint")
        }

        let dataBody = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = dataBody
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.csrfToken.isEmpty {
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QuotaProviderError.unavailable("Local Antigravity server returned non-200")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    #if canImport(Security)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (host == "127.0.0.1" || host == "localhost"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
    #endif
}

#if os(Linux)
extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}
#endif
