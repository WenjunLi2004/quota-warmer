import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct QuotaExtractorRegression {
    static func main() {
        let provider = QuotaProvider()
        let formatter = ISO8601DateFormatter()
        let sessionReset = Date().addingTimeInterval((4 * 3600) + (57 * 60))
        let weeklyReset = Date().addingTimeInterval(5 * 24 * 3600)

        let loggedOutAuth = ClaudeCLIAuthSnapshot.parse("""
        {"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}
        """)
        require(loggedOutAuth?.loggedIn == false, "Claude auth status should parse logged-out JSON")
        require(loggedOutAuth?.authMethod == "none", "Claude auth status should parse auth method")

        let loggedInAuth = ClaudeCLIAuthSnapshot.parse("""
        {"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}
        """)
        require(loggedInAuth?.loggedIn == true, "Claude auth status should parse logged-in JSON")
        require(
            ToolID.claude.warmupCommand.contains("--max-turns 1")
                && ToolID.claude.warmupCommand.contains("--tools ''"),
            "Claude warmup should be bounded to one no-tool turn"
        )
        require(ToolID.claude.fallbackWarmupCommand != nil, "Claude warmup should have a default-model fallback")
        // A pinned Codex model gets retired (gpt-5.4-mini was refused for
        // ChatGPT accounts), failing every warm-up until the app is rebuilt.
        require(
            !ToolID.codex.warmupCommand.contains("--model")
                && !(ToolID.codex.fallbackWarmupCommand ?? "").contains("--model"),
            "Codex warmup must use the configured default model, not a pinned one"
        )

        let cliRefreshError = QuotaProviderError.cliRefreshRequired("Claude needs its CLI refresh")
        require(
            cliRefreshError.errorDescription == "Claude needs its CLI refresh",
            "An expired Claude quota credential must be recoverable without reporting a false logout"
        )

        let codexPayload: [String: Any] = [
            "data": [
                "limits": [
                    [
                        "label": "5 hour usage limit",
                        "remaining": 99,
                        "limit": 100,
                        "resets_at": formatter.string(from: sessionReset)
                    ],
                    [
                        "label": "Weekly usage limit",
                        "remaining_percent": 60,
                        "resets_at": formatter.string(from: weeklyReset)
                    ]
                ]
            ]
        ]
        let codex = provider.snapshot(
            tool: .codex,
            source: "test",
            corroboratingSource: nil,
            payload: codexPayload,
            message: nil
        )
        requireClose(codex.fiveHour?.remainingFraction, 0.99, "Codex 5h remaining")
        requireClose(codex.weekly?.remainingFraction, 0.60, "Codex weekly remaining")
        require(codex.fiveHour?.resetAt != nil, "Codex 5h reset should be extracted")

        // Real Codex `wham/usage` shape: used_percent is on a 0–100 scale, so
        // 1 means 1% used (99% remaining). The generic extractor would mis-read
        // a value of 1 as 100% used; the dedicated parser must not.
        let whamPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 1,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 13466,
                    "reset_at": Int(sessionReset.timeIntervalSince1970)
                ],
                "secondary_window": [
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_at": Int(weeklyReset.timeIntervalSince1970)
                ]
            ]
        ]
        let wham = provider.codexSnapshot(payload: whamPayload, source: "test", message: nil)
        requireClose(wham.fiveHour?.remainingFraction, 0.99, "Codex wham 5h remaining (1% used)")
        requireClose(wham.weekly?.remainingFraction, 1.0, "Codex wham weekly remaining (0% used)")
        require(wham.fiveHour?.resetAt != nil, "Codex wham 5h reset should be extracted")
        require(wham.fiveHour?.name == "5h", "Codex wham primary window should be 5h")
        require(wham.weekly?.name == "Weekly", "Codex wham secondary window should be weekly")

        var whamLaterPayload = whamPayload
        var whamLaterRateLimit = whamLaterPayload["rate_limit"] as! [String: Any]
        var whamLaterPrimary = whamLaterRateLimit["primary_window"] as! [String: Any]
        whamLaterPrimary["used_percent"] = 5
        whamLaterRateLimit["primary_window"] = whamLaterPrimary
        whamLaterPayload["rate_limit"] = whamLaterRateLimit
        let whamLater = provider.codexSnapshot(payload: whamLaterPayload, source: "test", message: nil)
        require(wham.rawWindowKey == whamLater.rawWindowKey, "Codex window key should not change as usage changes")

        let now = Date()
        let freshWindowPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 1,
                    "limit_window_seconds": 18000,
                    "reset_at": Int(now.addingTimeInterval((5 * 3600) - 120).timeIntervalSince1970)
                ]
            ]
        ]
        let freshWindow = provider.codexSnapshot(payload: freshWindowPayload, source: "test", message: nil)
        require(
            freshWindow.canAutoWarm(now: now, windowDuration: 5 * 3600),
            "Fresh window should allow auto warmup"
        )

        let alreadyActiveWindowPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 18000,
                    "reset_at": Int(now.addingTimeInterval((4 * 3600) + (20 * 60)).timeIntervalSince1970)
                ]
            ]
        ]
        let alreadyActiveWindow = provider.codexSnapshot(payload: alreadyActiveWindowPayload, source: "test", message: nil)
        require(
            !alreadyActiveWindow.canAutoWarm(now: now, windowDuration: 5 * 3600),
            "Already-active window should not allow auto warmup just because remaining is high"
        )

        // An idle (not-yet-started) Codex 5h window reports the full window length
        // as `reset_after_seconds` and a `reset_at` of now + the full window — a
        // sliding "if you started now" projection. It is a genuine, claimable
        // window: warming it (sending `hi`) is exactly the point, so auto-warm IS
        // allowed. The stable "idle" key plus `lastAutoWarmWindowEndsAt` prevent the
        // re-warm-every-poll storm, not a blanket exclusion from auto-warm.
        let idleWindowPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 1,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 18000,
                    "reset_at": Int(now.addingTimeInterval(5 * 3600).timeIntervalSince1970)
                ]
            ]
        ]
        let idleWindow = provider.codexSnapshot(payload: idleWindowPayload, source: "test", message: nil)
        // The projected reset is still surfaced for display (the web shows it too)…
        require(idleWindow.fiveHour?.resetAt != nil, "Idle Codex 5h window should still surface its projected reset for display")
        require(idleWindow.fiveHour?.isIdle == true, "Idle Codex 5h window must be flagged idle")
        require(idleWindow.fiveHour?.isIdleFiveHourWindow == true, "Idle Codex 5h window must read as an idle 5h window")
        // It IS claimable, so auto-warm is allowed (this is the whole point for
        // Codex — open the not-yet-started window)…
        require(
            idleWindow.canAutoWarm(now: now, windowDuration: 5 * 3600),
            "Idle (not-yet-started) Codex window must allow auto warmup"
        )
        // …but until the window actually opens, it must not *confirm* a claim.
        require(
            !idleWindow.showsActiveWindow(now: now),
            "Idle (sliding-reset) Codex window must not confirm a phantom warm-up claim"
        )
        require(idleWindow.rawWindowKey == "test|idle", "Idle Codex window key must be stable (not the sliding reset)")

        // Auto-warm dedup for idle windows must ignore the stable "idle" key and
        // gate purely on the just-warmed window's end time. Otherwise a stored
        // "…|idle" key (e.g. left by an older build, or the previous idle period)
        // would permanently block claiming every later idle window.
        require(
            AutoWarmDedup.shouldWarm(
                currentWindowKey: "test|idle",
                lastWarmedWindowKey: "test|idle",
                lastWarmedWindowEndsAt: nil,
                currentWindowIsIdle: true,
                now: now
            ),
            "Idle window with a stale matching key but no live warmed-window end must be claimable"
        )
        require(
            !AutoWarmDedup.shouldWarm(
                currentWindowKey: "test|idle",
                lastWarmedWindowKey: "test|idle",
                lastWarmedWindowEndsAt: now.addingTimeInterval(3600),
                currentWindowIsIdle: true,
                now: now
            ),
            "Idle window must not re-warm while the just-claimed window is still open"
        )
        // A non-idle window keeps the strict key dedup (same active window key blocks).
        require(
            !AutoWarmDedup.shouldWarm(
                currentWindowKey: "test|2026-01-01T00:00:00Z",
                lastWarmedWindowKey: "test|2026-01-01T00:00:00Z",
                lastWarmedWindowEndsAt: nil,
                currentWindowIsIdle: false,
                now: now
            ),
            "Active window with a matching key must remain deduped"
        )

        let scheduledAt = Date(timeIntervalSince1970: 1_780_560_000)
        let scheduledDayKey = "2026-6-4"
        let catchUpNow = scheduledAt.addingTimeInterval(3 * 3600)
        let missedSchedule = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: scheduledAt.addingTimeInterval(-3600),
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(missedSchedule.shouldRun && missedSchedule.caughtUp, "Missed schedule should catch up within horizon")

        let alreadySucceededSchedule = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: scheduledDayKey,
            lastActivity: nil,
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(!alreadySucceededSchedule.shouldRun, "Per-tool successful scheduled warmup should dedupe same day")

        let userStartedAfterSchedule = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: scheduledAt.addingTimeInterval(60),
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(!userStartedAfterSchedule.shouldRun, "User activity after scheduled time should skip catch-up")

        let activeWindowOverlap = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: scheduledAt.addingTimeInterval(-30 * 60),
            activeWindowStartedAt: scheduledAt.addingTimeInterval(-30 * 60),
            windowDuration: 5 * 3600
        )
        require(!activeWindowOverlap.shouldRun, "Current active local window should skip scheduled catch-up")

        let outsideCatchUpHorizon = MorningWarmupPolicy.decision(
            now: scheduledAt.addingTimeInterval((5 * 3600) + 1),
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: nil,
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(!outsideCatchUpHorizon.shouldRun, "Missed schedule outside the window horizon should not catch up")

        require(
            MorningWarmupPolicy.resolvedLastSuccessfulDay(
                perToolDay: nil,
                legacyDay: scheduledDayKey,
                currentDay: scheduledDayKey
            ) == scheduledDayKey,
            "Legacy morning warm day should preserve today's dedup during migration"
        )
        require(
            MorningWarmupPolicy.resolvedLastSuccessfulDay(
                perToolDay: nil,
                legacyDay: "2026-6-3",
                currentDay: scheduledDayKey
            ) == nil,
            "Legacy morning warm day should not migrate stale days"
        )
        require(
            MorningWarmupPolicy.resolvedLastSuccessfulDay(
                perToolDay: scheduledDayKey,
                legacyDay: nil,
                currentDay: scheduledDayKey
            ) == scheduledDayKey,
            "Per-tool morning warm day should remain authoritative"
        )

        let postWarmFetchedAt = now.addingTimeInterval(2)
        let postWarmSnapshot = QuotaSnapshot(
            tool: .codex,
            fetchedAt: postWarmFetchedAt,
            primarySource: "test",
            corroboratingSource: nil,
            fiveHour: nil,
            weekly: nil,
            extras: [],
            rawWindowKey: "test|post-warm-window",
            message: nil
        )
        require(
            postWarmSnapshot.isClaimableAutoWindow(previousFetchedAt: now, now: postWarmFetchedAt.addingTimeInterval(1)),
            "Scheduled warmup should claim a fresh post-warm quota window"
        )

        let unchangedSnapshot = QuotaSnapshot(
            tool: .codex,
            fetchedAt: now,
            primarySource: "test",
            corroboratingSource: nil,
            fiveHour: nil,
            weekly: nil,
            extras: [],
            rawWindowKey: "test|old-window",
            message: nil
        )
        require(
            !unchangedSnapshot.isClaimableAutoWindow(previousFetchedAt: now, now: postWarmFetchedAt),
            "Scheduled warmup should not claim an unchanged quota snapshot"
        )

        let stalePostWarmSnapshot = QuotaSnapshot(
            tool: .codex,
            fetchedAt: now.addingTimeInterval(-31 * 60),
            primarySource: "test",
            corroboratingSource: nil,
            fiveHour: nil,
            weekly: nil,
            extras: [],
            rawWindowKey: "test|stale-window",
            message: nil
        )
        require(
            !stalePostWarmSnapshot.isClaimableAutoWindow(previousFetchedAt: nil, now: now),
            "Scheduled warmup should not claim stale quota snapshots"
        )

        let claudePayload: [String: Any] = [
            "plan_usage_limits": [
                [
                    "period": "Current session",
                    "usage_percent": 81,
                    "reset_at": formatter.string(from: sessionReset)
                ],
                [
                    "period": "Weekly limits All models",
                    "used_percent": 11,
                    "reset_at": formatter.string(from: weeklyReset)
                ]
            ]
        ]
        let claude = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: claudePayload,
            message: nil
        )
        requireClose(claude.fiveHour?.remainingFraction, 0.19, "Claude current-session remaining")
        requireClose(claude.weekly?.remainingFraction, 0.89, "Claude weekly remaining")

        // Claude OAuth usage emits ISO timestamps with fractional seconds and a
        // five_hour/seven_day shape — the reset must still be parsed.
        let claudeFractionalPayload: [String: Any] = [
            "five_hour": [
                "utilization": 22.0,
                "resets_at": "2026-06-04T11:10:00.973380+00:00"
            ],
            "seven_day": [
                "utilization": 17.0,
                "resets_at": "2026-06-09T20:00:00.973402+00:00"
            ]
        ]
        let claudeFractional = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: claudeFractionalPayload,
            message: nil
        )
        requireClose(claudeFractional.fiveHour?.remainingFraction, 0.78, "Claude five_hour remaining")
        require(claudeFractional.fiveHour?.resetAt != nil, "Claude fractional-seconds reset must parse")
        require(claudeFractional.weekly?.resetAt != nil, "Claude seven_day reset must parse")

        let claudeZeroUtilizationPayload: [String: Any] = [
            "five_hour": [
                "utilization": 0,
                "resets_at": "2026-06-05T16:20:01.015861+00:00"
            ],
            "seven_day": [
                "utilization": 27,
                "resets_at": "2026-06-09T20:00:01.015888+00:00"
            ]
        ]
        let claudeZeroUtilization = provider.claudeSnapshot(
            payload: claudeZeroUtilizationPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        requireClose(claudeZeroUtilization.fiveHour?.remainingFraction, 1.0, "Claude zero-utilization 5h remaining")
        require(claudeZeroUtilization.fiveHour?.resetAt != nil, "Claude zero-utilization 5h reset must parse")
        require(
            claudeZeroUtilization.fiveHour?.context != "5h idle window",
            "Claude zero-utilization active 5h window must not be converted to idle fallback"
        )
        requireClose(claudeZeroUtilization.weekly?.remainingFraction, 0.73, "Claude zero-utilization weekly remaining")

        // After a 5h window expires (and before the next request opens one), the
        // OAuth API returns a *populated* five_hour with no `resets_at`:
        // `{ utilization: 0, resets_at: null }`. That parses as a real, reset-less
        // metric at 100% left — leaving the UI with a 5h percentage but no
        // countdown, which made the menu bar fall back to the weekly window. It
        // must be surfaced as the idle 5h window (projected reset) instead.
        let claudeResetlessPayload: [String: Any] = [
            "five_hour": [
                "utilization": 0,
                "resets_at": NSNull()
            ],
            "seven_day": [
                "utilization": 27,
                "resets_at": "2026-06-09T20:00:01.015888+00:00"
            ]
        ]
        let claudeResetless = provider.claudeSnapshot(
            payload: claudeResetlessPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(claudeResetless.fiveHour?.isIdle == true,
                "Reset-less full Claude 5h window must be surfaced as idle")
        require(claudeResetless.fiveHour?.resetAt != nil,
                "Reset-less Claude 5h window must surface a projected reset so the menu bar shows a 5h countdown, not the weekly window")
        require(claudeResetless.rawWindowKey == "Claude OAuth usage|idle",
                "Reset-less Claude 5h window must use the stable idle key")
        requireClose(claudeResetless.fiveHour?.remainingFraction, 1.0, "Reset-less Claude 5h window reads fully available")

        let claudeRateLimitsPayload: [String: Any] = [
            "rate_limits": [
                "five_hour": [
                    "utilization": 81,
                    "resets_at": Int(sessionReset.timeIntervalSince1970)
                ],
                "seven_day": [
                    "utilization": 11,
                    "resets_at": Int(weeklyReset.timeIntervalSince1970)
                ]
            ]
        ]
        let claudeRateLimits = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: claudeRateLimitsPayload,
            message: nil
        )
        requireClose(claudeRateLimits.fiveHour?.remainingFraction, 0.19, "Claude rate_limits five_hour remaining")
        requireClose(claudeRateLimits.weekly?.remainingFraction, 0.89, "Claude rate_limits seven_day remaining")

        // Claude reports "no active 5h window" as an explicit null `five_hour`
        // (the user hasn't touched Claude in 5h). The app must surface that as an
        // idle, fully-available window — never a blank "--".
        let claudeIdlePayload: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": [
                "utilization": 26.0,
                "resets_at": formatter.string(from: weeklyReset)
            ]
        ]
        let claudeIdle = provider.claudeSnapshot(
            payload: claudeIdlePayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(claudeIdle.fiveHour != nil, "Claude idle 5h window must surface a metric, not nil")
        requireClose(claudeIdle.fiveHour?.remainingFraction, 1.0, "Claude idle 5h window reads fully available")
        require(claudeIdle.fiveHour?.isIdle == true, "Claude idle 5h window must be flagged idle")
        require(claudeIdle.fiveHour?.isIdleFiveHourWindow == true, "Claude idle 5h window must read as an idle 5h window")
        // The idle window now carries a *projected* (sliding "if you started now")
        // reset of now + windowDuration so the menu bar/panel show a countdown
        // instead of a bare "100%". It must be in the future and ~5h out.
        require(claudeIdle.fiveHour?.resetAt != nil, "Claude idle 5h window must surface a projected reset for display")
        if let idleReset = claudeIdle.fiveHour?.resetAt {
            let projected = idleReset.timeIntervalSinceNow
            require(projected > 4.5 * 3600 && projected <= 5 * 3600 + 5,
                    "Claude idle 5h projected reset must be ~5h out, was \(projected)s")
        }
        // The projection slides every poll, so the dedup key must be the stable
        // "idle" marker, never the moving timestamp.
        require(claudeIdle.rawWindowKey == "Claude OAuth usage|idle",
                "Claude idle window key must be stable (not the sliding reset)")
        requireClose(claudeIdle.weekly?.remainingFraction, 0.74, "Claude idle weekly still parses")
        // The idle fallback is the absence of a claimed window. It must be
        // claimable by auto-warm, but it cannot confirm success until live quota
        // becomes active. Temporal dedup prevents the sliding projection from
        // sending another warm-up during the claimed five-hour duration.
        require(!claudeIdle.showsActiveWindow(), "Claude idle 5h fallback must not count as an active claimed window")
        require(claudeIdle.canAutoWarm(windowDuration: ToolID.claude.windowDuration),
                "Claude idle 5h window must allow an opted-in auto warmup")
        require(
            AutoWarmDedup.shouldWarm(
                currentWindowKey: claudeIdle.rawWindowKey,
                lastWarmedWindowKey: claudeIdle.rawWindowKey,
                lastWarmedWindowEndsAt: nil,
                currentWindowIsIdle: true,
                now: now
            ),
            "Claude idle window must remain claimable when no warmed duration is active"
        )
        require(
            !AutoWarmDedup.shouldWarm(
                currentWindowKey: claudeIdle.rawWindowKey,
                lastWarmedWindowKey: nil,
                lastWarmedWindowEndsAt: now.addingTimeInterval(ToolID.claude.windowDuration),
                currentWindowIsIdle: true,
                now: now
            ),
            "Claude idle window must not warm again during the already-claimed duration"
        )

        // A freshly-warmed window carries a live reset in the future and *must*
        // confirm the warm-up claim.
        let claudeActiveWindowPayload: [String: Any] = [
            "five_hour": [
                "utilization": 1.0,
                "resets_at": formatter.string(from: sessionReset)
            ],
            "seven_day": [
                "utilization": 20.0,
                "resets_at": formatter.string(from: weeklyReset)
            ]
        ]
        let claudeActiveWindow = provider.claudeSnapshot(
            payload: claudeActiveWindowPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(claudeActiveWindow.showsActiveWindow(), "A live future-reset 5h window must confirm a warm-up claim")
        // The regression that motivated this: utilization is a 0–100 scale, so a
        // freshly-warmed window at 1% used must read as 99% left — not 0% (which
        // happened when `utilization: 1.0` was misread as a 0–1 fraction).
        requireClose(claudeActiveWindow.fiveHour?.remainingFraction, 0.99, "utilization 1.0 means 1% used (99% left), not 100% used")

        // Right at a window rollover the API can pair the *new* window's reset
        // (just opened, ~5h left) with the just-ended window's high utilization
        // (reads as ~0% left). That's physically impossible in the first minutes,
        // so it must be flagged as an unsettled artifact (UI shows "settling").
        let claudeRolloverArtifactPayload: [String: Any] = [
            "five_hour": [
                "utilization": 99.0,
                "resets_at": formatter.string(from: sessionReset)
            ],
            "seven_day": [
                "utilization": 9.0,
                "resets_at": formatter.string(from: weeklyReset)
            ]
        ]
        let claudeRollover = provider.claudeSnapshot(
            payload: claudeRolloverArtifactPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(
            claudeRollover.isUnsettledRolloverReading(windowDuration: ToolID.claude.windowDuration),
            "A just-opened 5h window reading ~0% left must be flagged as an unsettled rollover artifact"
        )
        // A genuinely active window (settled, plenty left) must NOT be flagged.
        require(
            !claudeActiveWindow.isUnsettledRolloverReading(windowDuration: ToolID.claude.windowDuration),
            "A settled active window with quota left must not be treated as a rollover artifact"
        )
        // The idle (null five_hour) fallback is a separate state and must not be
        // flagged as a rollover artifact either (its reset is an idle projection,
        // not a freshly-opened window).
        require(
            !claudeIdle.isUnsettledRolloverReading(windowDuration: ToolID.claude.windowDuration),
            "Idle 5h fallback must not be treated as a rollover artifact"
        )

        // A populated five_hour must still parse normally through claudeSnapshot.
        let claudeActive = provider.claudeSnapshot(
            payload: claudeFractionalPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        requireClose(claudeActive.fiveHour?.remainingFraction, 0.78, "Claude active 5h still parses via claudeSnapshot")

        let genericRemainingPayload: [String: Any] = [
            "limits": [
                [
                    "window": "5h current remaining",
                    "percent": 99,
                    "resets_in": 17_820
                ]
            ]
        ]
        let generic = provider.snapshot(
            tool: .codex,
            source: "test",
            corroboratingSource: nil,
            payload: genericRemainingPayload,
            message: nil
        )
        requireClose(generic.fiveHour?.remainingFraction, 0.99, "Generic remaining-percent context")
        require(generic.fiveHour?.resetAt != nil, "Relative reset should be extracted")

        let empty = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: ["status": "ok"],
            message: nil
        )
        require(empty.fiveHour == nil, "Missing quota fields should not fabricate a 5h metric")
        require(empty.weekly == nil, "Missing quota fields should not fabricate a weekly metric")

        testLocalClaudeTokenUsage()
        testLocalClaudeOpenUsageCostCompatibility()
        testLocalCodexTokenUsage()

        let visibleReadySources = [
            "Sources/QuotaWarmer/Views/MenuBarLabel.swift",
            "Sources/QuotaWarmer/Views/ToolTabView.swift",
            "Sources/QuotaWarmer/Views/MenuContent.swift"
        ]
        for sourcePath in visibleReadySources {
            let source = readSource(sourcePath)
            require(!source.contains("\"ready\""), "\(sourcePath) must not render a lowercase ready status")
            require(!source.contains("\"Ready\""), "\(sourcePath) must not render an uppercase Ready status")
        }

        let appStateSource = readSource("Sources/QuotaWarmer/AppState.swift")
        require(
            appStateSource.contains("liveMetric?.resetAt == nil || liveMetric?.isIdle == true")
                && appStateSource.contains("state.rememberConfirmedWarmup(startedAt: result.date, duration: tool.windowDuration)"),
            "Successful warmup must persist a confirmed reset fallback when live quota has no real (non-idle) reset"
        )

        let credentialStoreSource = readSource("Sources/QuotaWarmer/Services/CredentialStore.swift")
        // Claude Code writes its item with /usr/bin/security, which resets the
        // item's partition list to `apple-tool:` on every ~8h token rotation. A
        // SecItemCopyMatching read from this ad-hoc-signed app loses its
        // partition each time and raises the approval dialog again ("Always
        // Allow" never stuck; LAContext.interactionNotAllowed didn't stop it).
        // Reading through the same tool carries the partition the writer set.
        let claudeReadBody = credentialStoreSource
            .components(separatedBy: "private func claudeKeychainPassword(")[1]
            .components(separatedBy: "\n    }\n")[0]
        require(
            claudeReadBody.contains("runSecurityTool([\"find-generic-password\"")
                && !claudeReadBody.contains("SecItemCopyMatching")
                && credentialStoreSource.contains("URL(fileURLWithPath: \"/usr/bin/security\")"),
            "Claude Code's Keychain item must be read through /usr/bin/security, never SecItemCopyMatching"
        )
        require(
            claudeReadBody.contains("loginKeychainIsLocked()"),
            "A locked login keychain must be skipped, not unlocked through a dialog"
        )
        require(
            credentialStoreSource.contains("SecKeychainSetUserInteractionAllowed(false)"),
            "Any remaining direct Keychain read must fail rather than open a password dialog"
        )
        let credentialStoreCode = credentialStoreSource.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for writeCall in ["SecItemAdd", "SecItemUpdate", "SecItemDelete", "add-generic-password", "delete-generic-password"] {
            require(
                !credentialStoreCode.contains(writeCall),
                "QuotaWarmer must not write to the Keychain at all, least of all Claude Code's item (\(writeCall))"
            )
        }
        require(
            !credentialStoreSource.contains("/v1/oauth/token")
                && !credentialStoreSource.contains("grant_type=refresh_token"),
            "QuotaWarmer must not run a Claude token-refresh chain of its own"
        )
        // The Refresh button was a silent no-op for the whole backoff window: a
        // 4h rate-limit Retry-After pinned the menu bar to a stale reading and
        // every click returned before making a request.
        require(
            appStateSource.contains("if force {\n                clearQuotaBackoff(for: state)"),
            "A user-initiated refresh must clear and bypass the quota rate-limit backoff"
        )
        require(
            appStateSource.contains("func refreshQuotaManually")
                && appStateSource.components(separatedBy: "func refreshQuotaManually")[1]
                    .components(separatedBy: "\n    }")[0]
                    .contains("force: true"),
            "The Refresh button must force its fetch through, not return early on backoff"
        )
        for viewPath in ["Sources/QuotaWarmer/Views/MainTabView.swift", "Sources/QuotaWarmer/Views/MenuContent.swift"] {
            require(
                !readSource(viewPath).contains("appState.refreshQuota(for:"),
                "\(viewPath) must route its Refresh control through refreshQuotaManually"
            )
        }
        // A blocked poll must not make the menu bar lie. While the known reset is
        // still ahead the old numbers stay valid (keep counting down even when the
        // dot is yellow); once it passes, the window rolled over and the old
        // percentage would badly understate the quota actually available.
        require(
            appStateSource.contains("quotaSnapshot?.primaryWindowRolledOver()"),
            "ToolState must derive the rolled-over window from the snapshot"
        )

        // Behavioral coverage for the rollover rule itself: the user's screenshot
        // showed a stale 29% long after that window had already reset.
        let rolloverNow = Date()
        func claudeWindow(resetOffset: TimeInterval) -> QuotaSnapshot {
            provider.snapshot(
                tool: .claude,
                source: "test",
                corroboratingSource: nil,
                payload: [
                    "rate_limits": [
                        "five_hour": [
                            "utilization": 71,
                            "resets_at": Int(rolloverNow.addingTimeInterval(resetOffset).timeIntervalSince1970)
                        ]
                    ]
                ],
                message: nil
            )
        }
        require(
            !claudeWindow(resetOffset: 2 * 3600).primaryWindowRolledOver(now: rolloverNow),
            "A stale snapshot whose reset is still ahead is accurate and must keep its countdown"
        )
        require(
            claudeWindow(resetOffset: -60).primaryWindowRolledOver(now: rolloverNow),
            "Once the known reset has passed the window rolled over and 29% must not be reported as current"
        )
        require(
            !claudeIdle.primaryWindowRolledOver(now: rolloverNow),
            "An idle projection has no real window to roll over"
        )
        let menuBarSource = readSource("Sources/QuotaWarmer/Views/MenuBarLabel.swift")
        require(
            menuBarSource.contains("st.primaryWindowRolledOver")
                && menuBarSource.range(of: "primaryWindowRolledOver")!.lowerBound
                    < menuBarSource.range(of: "Int(metric.remainingFraction * 100)")!.lowerBound,
            "The menu bar must report a rolled-over window as restored before falling back to the stale percentage"
        )
        require(
            !readSource("Sources/QuotaWarmer/Services/QuotaProvider.swift")
                .contains("forHTTPHeaderField: \"User-Agent\""),
            "Must not borrow the Claude Code user agent: measured 2026-08-04, it returns an ~8x longer Retry-After"
        )

        // The bug the user actually hit: forcing the fetch through the backoff in
        // AppState is useless while the control that triggers it is greyed out for
        // the entire retry window, which is precisely when a retry is wanted.
        for viewPath in ["Sources/QuotaWarmer/Views/MainTabView.swift", "Sources/QuotaWarmer/Views/ToolTabView.swift"] {
            let source = readSource(viewPath)
            require(
                !source.contains("isFetchingQuota || state.quotaBackoffActive")
                    && !source.contains("isFetchingQuota || toolState.quotaBackoffActive"),
                "\(viewPath) must not disable Refresh while a quota rate-limit backoff is active"
            )
        }
        require(
            appStateSource.contains("guard tool != .claude || !state.isFetchingQuota else { return }"),
            "Concurrent Claude refresh triggers must collapse to a single in-flight request chain"
        )
        require(
            appStateSource.contains("let shouldAutoWarm = tool == .claude && state(for: tool).isAutoWarmEnabled"),
            "A manual Claude refresh must immediately resume an opted-in auto-warm after credential approval"
        )
        require(
            appStateSource.contains("if tool == .claude { state.isFetchingQuota = false }"),
            "Claude auto-warm must release the outer fetch before post-warm verification"
        )
        let quotaProviderSource = readSource("Sources/QuotaWarmer/Services/QuotaProvider.swift")
        require(
            !quotaProviderSource.contains("credential.isExpired, let refreshed = try?"),
            "An expired Claude credential refresh failure must not be swallowed before another request"
        )
        require(
            quotaProviderSource.contains("QuotaProviderError.cliRefreshRequired")
                && !quotaProviderSource.contains("/v1/oauth/token"),
            "Expired Claude credentials must defer refresh-token rotation to Claude Code and re-read its fresh credential"
        )
        require(
            appStateSource.contains("allowsClaudeCLIRecovery")
                && appStateSource.contains("triggerWarmup(tool: .claude, mode: \"auto\")"),
            "Auto-warm must run Claude Code once to recover its own expired credential before retrying quota"
        )
        require(
            !appStateSource.contains("let cliReady = await applyCLIAuthenticationStatusIfNeeded(for: tool, to: state)")
                && appStateSource.contains("if allowAutomaticWarmup {"),
            "A successful Claude OAuth quota fetch must not be overridden by headless CLI auth status"
        )
        let warmupRunnerSource = readSource("Sources/QuotaWarmer/Services/WarmupRunner.swift")
        require(
            !warmupRunnerSource.contains("switch await claudeAuthenticationStatus(pathPrefix: pathPrefix)"),
            "Claude warmup must let the actual command, not a headless status preflight, determine auth failure"
        )
        testProviderEnableDisableControls()
        testAntigravityQuotaAndParser()
        testAntigravityLocalUsageAndActivity()
        testSmartSchedulingAndAlertPolicies()

        let asyncDone = DispatchSemaphore(value: 0)
        Task.detached {
            await testAntigravityLiveSubprocessFlow()
            asyncDone.signal()
        }
        asyncDone.wait()

        print("quota extractor regression tests passed")
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            fatalError(message)
        }
    }

    private static func requireClose(_ actual: Double?, _ expected: Double, _ message: String) {
        guard let actual, abs(actual - expected) < 0.0001 else {
            fatalError("\(message): expected \(expected), got \(String(describing: actual))")
        }
    }

    private static func testLocalClaudeTokenUsage() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("claude-local-usage")
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project-a")
        createDirectory(project)
        writeJSONL([
            #"{"timestamp":"2026-06-15T10:00:00Z","message":{"id":"msg_today","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":4000}}}"#,
            #"{"timestamp":"2026-06-15T10:00:01Z","message":{"id":"msg_today","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":4000}}}"#,
            #"{"timestamp":"2026-06-14T09:00:00Z","message":{"id":"msg_yesterday","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":500}}}"#
        ], to: project.appendingPathComponent("session.jsonl"))

        let summary = provider.usage(for: .claude, baseURL: root, now: now)
        require(summary.today.totalTokens == 10_000, "Claude local usage should dedupe repeated message ids")
        require(summary.yesterday.totalTokens == 1_000, "Claude local usage should bucket yesterday")
        require(summary.last30Days.totalTokens == 11_000, "Claude local usage should aggregate the last 30 days")
        requireClose(summary.today.costUSD, 0.0714, "Claude local usage should price Sonnet input/cache/output tokens")
        requireClose(summary.yesterday.costUSD, 0.0030, "Claude local usage should price Haiku tokens")
        requireClose(summary.last30Days.costUSD, 0.0744, "Claude local usage should aggregate token cost")
    }

    private static func testLocalClaudeOpenUsageCostCompatibility() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("claude-openusage-cost")
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project-a")
        createDirectory(project)
        writeJSONL([
            #"{"type":"assistant","data":{"message":{"timestamp":"2026-06-15T08:00:00Z","costUSD":0.42,"message":{"id":"nested_explicit","model":"claude-opus-4-5-20251101","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}}}"#,
            #"{"timestamp":"2026-06-15T09:00:00Z","message":{"id":"modern_opus","model":"claude-opus-4-5-20251101","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000}}}"#,
            #"{"timestamp":"2026-06-15T10:00:00Z","message":{"id":"cache_breakdown","model":"claude-sonnet-4-20250514","usage":{"input_tokens":0,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"cache_read_input_tokens":0,"output_tokens":0}}}"#,
            #"{"timestamp":"2026-06-15T11:00:00Z","message":{"id":"fable","model":"claude-fable-5","usage":{"input_tokens":100,"cache_creation_input_tokens":100,"cache_read_input_tokens":100,"output_tokens":100}}}"#
        ], to: project.appendingPathComponent("session.jsonl"))

        let summary = provider.usage(for: .claude, baseURL: root, now: now)
        require(summary.today.totalTokens == 2_702, "Claude local usage should parse OpenUsage-compatible nested records")
        requireClose(summary.today.costUSD, 0.458475, "Claude local usage should match ccusage cost compatibility rules")
    }

    private static func testLocalCodexTokenUsage() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("codex-local-usage")
        defer { try? FileManager.default.removeItem(at: root) }

        createDirectory(root)
        writeJSONL([
            #"{"timestamp":"2026-06-15T08:00:00Z","payload":{"type":"session_meta","model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-06-15T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300,"total_tokens":1300},"total_token_usage":{"input_tokens":100000,"cached_input_tokens":20000,"output_tokens":30000,"total_tokens":130000}}}}"#,
            #"{"timestamp":"2026-06-14T09:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550},"total_token_usage":{"input_tokens":110000,"cached_input_tokens":21000,"output_tokens":31000,"total_tokens":141000}}}}"#,
            #"{"timestamp":"2026-06-15T11:00:00Z","payload":{"type":"session_meta","model":"codex-auto-review"}}"#,
            #"{"timestamp":"2026-06-15T11:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10,"total_tokens":110}}}}"#
        ], to: root.appendingPathComponent("session.jsonl"))

        let summary = provider.usage(for: .codex, baseURL: root, now: now)
        require(summary.today.totalTokens == 1_410, "Codex local usage should use per-turn token deltas")
        require(summary.yesterday.totalTokens == 550, "Codex local usage should bucket yesterday")
        require(summary.last30Days.totalTokens == 1_960, "Codex local usage should not aggregate cumulative token totals")
        requireClose(summary.today.costUSD, 0.01310, "Codex local usage should price cached input like ccusage model pricing")
        requireClose(summary.yesterday.costUSD, 0.00355, "Codex local usage should price yesterday's turn")
        requireClose(summary.last30Days.costUSD, 0.01665, "Codex local usage should aggregate token cost")
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func isoDate(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: text) else {
            fatalError("Invalid fixture date \(text)")
        }
        return date
    }

    private static func temporaryDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotawarmer-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func createDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create fixture directory \(url.path): \(error)")
        }
    }

    private static func writeJSONL(_ lines: [String], to url: URL) {
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fatalError("Could not write fixture \(url.path): \(error)")
        }
    }

    private static func readSource(_ relativePath: String) -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
            .path
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("Could not read source file at \(relativePath)")
        }
        return source
    }

    // MARK: - Provider Enable/Disable Regression Coverage

    private static func testProviderEnableDisableControls() {
        let suiteName = "com.quotawarmer.regression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default: every provider starts enabled.
        for tool in ToolID.allCases {
            require(
                ToolEnablementPolicy.isEnabled(for: tool, defaults: defaults),
                "\(tool.rawValue) should default to enabled"
            )
        }

        // Actively turning Claude off persists and suppresses monitoring, auto-warm, and menu bar pin.
        ToolEnablementPolicy.setEnabled(false, for: .claude, defaults: defaults)
        require(!ToolEnablementPolicy.isEnabled(for: .claude, defaults: defaults), "Claude should persist as disabled")
        require(ToolEnablementPolicy.isEnabled(for: .codex, defaults: defaults), "Disabling Claude must not affect Codex")
        require(ToolEnablementPolicy.isEnabled(for: .antigravity, defaults: defaults), "Disabling Claude must not affect Antigravity")
        require(
            !ToolEnablementPolicy.effectiveMonitored(isEnabled: false, mode: .monitor)
                && !ToolEnablementPolicy.effectiveMonitored(isEnabled: false, mode: .autoWarm),
            "Disabled Claude must never poll quota regardless of stored mode"
        )
        require(
            !ToolEnablementPolicy.effectiveAutoWarm(isEnabled: false, mode: .autoWarm),
            "Disabled Claude must never auto-warm"
        )
        require(
            !ToolEnablementPolicy.effectiveMenuBarVisible(isEnabled: false, menuBarVisible: true),
            "Disabled Claude must be hidden from the menu bar even when menuBarVisible was pinned"
        )

        // Turning Claude back on restores monitoring and preserves prior mode/pin preferences.
        ToolEnablementPolicy.setEnabled(true, for: .claude, defaults: defaults)
        require(ToolEnablementPolicy.isEnabled(for: .claude, defaults: defaults), "Claude must turn back on cleanly")
        require(
            ToolEnablementPolicy.restoredModeOnEnable(currentMode: .off) == .monitor,
            "Re-enabling a provider left on .off should resume safe read-only monitoring"
        )
        require(
            ToolEnablementPolicy.restoredModeOnEnable(currentMode: .autoWarm) == .autoWarm
                && ToolEnablementPolicy.restoredModeOnEnable(currentMode: .monitor) == .monitor,
            "Re-enabling a provider must preserve its prior .monitor or .autoWarm mode"
        )
        require(
            ToolEnablementPolicy.effectiveMenuBarVisible(isEnabled: true, menuBarVisible: true),
            "Re-enabling Claude must restore its menu bar pin"
        )

        // Verify UI and AppState wiring for provider enable/disable across all entry points.
        let appStateSource = readSource("Sources/QuotaWarmer/AppState.swift")
        require(
            appStateSource.contains("func setToolEnabled(_ enabled: Bool, for tool: ToolID)")
                && appStateSource.contains("guard state.isEnabled else { return }")
                && appStateSource.contains("guard state.isEnabled, !state.isWarming else { return false }"),
            "AppState must gate quota polling and warmup execution on state.isEnabled"
        )
        require(
            readSource("Sources/QuotaWarmer/Views/MenuBarLabel.swift")
                .contains("ToolEnablementPolicy.effectiveMenuBarVisible"),
            "MenuBarLabel must hide disabled providers"
        )
        require(
            readSource("Sources/QuotaWarmer/Views/MenuContent.swift")
                .contains("ForEach(appState.enabledTools)"),
            "Sidebar must hide disabled providers"
        )
        let mainTabSource = readSource("Sources/QuotaWarmer/Views/MainTabView.swift")
        require(
            mainTabSource.contains("appState.enabledTools")
                && mainTabSource.contains("appState.disabledTools")
                && mainTabSource.contains("setToolEnabled(false, for: tool)")
                && mainTabSource.contains("setToolEnabled(true, for: tool)"),
            "MainTabView must allow turning a provider off and turning it back on directly"
        )
        require(
            readSource("Sources/QuotaWarmer/Views/SettingsTabView.swift")
                .contains("group(\"PROVIDERS\")"),
            "SettingsTabView must expose a PROVIDERS section to toggle tools on and off"
        )
        require(
            readSource("Sources/QuotaWarmer/AppDelegate.swift")
                .contains("toggleProviderEnabled"),
            "Menu bar right-click menu must allow toggling providers on and off"
        )
    }

    // MARK: - Antigravity Quota, Probe, and Warmup Regression Coverage

    private static func testAntigravityQuotaAndParser() {
        let provider = QuotaProvider()
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let geminiSessionReset = now.addingTimeInterval((3 * 3600) + (48 * 60))
        let geminiWeeklyReset = now.addingTimeInterval(4 * 24 * 3600)
        let claudeSessionReset = now.addingTimeInterval((4 * 3600) + (29 * 60))
        let claudeWeeklyReset = now.addingTimeInterval(5 * 24 * 3600)

        // ToolID metadata & asset checks.
        require(ToolID.allCases.contains(.antigravity), "ToolID.allCases must include .antigravity")
        require(ToolID.antigravity.cliExecutableName == "agy", "Antigravity CLI executable must be agy")
        require(ToolID.antigravity.assetName == "Antigravity", "Antigravity asset name must match Assets.xcassets")
        require(
            !ToolID.antigravity.warmupCommand.contains("--model")
                && ToolID.antigravity.warmupCommand.contains("--effort low")
                && ToolID.antigravity.warmupCommand.contains("-p 'hi'"),
            "Antigravity warmup must use agy headless low-effort mode without a brittle pinned model"
        )
        require(
            ToolID.antigravity.fallbackWarmupCommand != nil
                && !(ToolID.antigravity.fallbackWarmupCommand ?? "").contains("--effort")
                && !(ToolID.antigravity.fallbackWarmupCommand ?? "").contains("--model"),
            "Antigravity fallback warmup must drop --effort without pinning a model"
        )
        let svgAsset = readSource("Sources/QuotaWarmer/Assets.xcassets/Antigravity.imageset/antigravity.svg")
        require(svgAsset.contains("fill=\"currentColor\""), "Antigravity SVG asset must be a template currentColor vector")

        // 1. Structured `agy -p /usage --output-format json` payload with multiple model groups.
        let cliUsagePayload: [String: Any] = [
            "conversation_id": "",
            "status": "SUCCESS",
            "response": "Quota report",
            "duration_seconds": 0,
            "num_turns": 0,
            "command": [
                "name": "usage",
                "data": [
                    "description": "Models share limits",
                    "groups": [
                        [
                            "name": "Gemini Models",
                            "buckets": [
                                [
                                    "id": "gemini-weekly",
                                    "name": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "remaining_fraction": 0.86,
                                    "reset_time": formatter.string(from: geminiWeeklyReset)
                                ],
                                [
                                    "id": "gemini-5h",
                                    "name": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "remaining_fraction": 0.95,
                                    "reset_time": formatter.string(from: geminiSessionReset)
                                ]
                            ]
                        ],
                        [
                            "name": "Claude and GPT models",
                            "buckets": [
                                [
                                    "id": "3p-weekly",
                                    "name": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "remaining_fraction": 0.89,
                                    "reset_time": formatter.string(from: claudeWeeklyReset)
                                ],
                                [
                                    "id": "3p-5h",
                                    "name": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "remaining_fraction": 1.0,
                                    "reset_time": formatter.string(from: claudeSessionReset)
                                ]
                            ]
                        ],
                        [
                            "name": "Gemini 4 Argon",
                            "buckets": [
                                [
                                    "id": "gemini-argon-wtu-weekly",
                                    "name": "Gemini 4 Argon Weekly Limit",
                                    "window": "weekly",
                                    "remaining_fraction": 0.53,
                                    "reset_time": formatter.string(from: geminiWeeklyReset)
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let cliSnap = provider.antigravitySnapshot(
            payload: cliUsagePayload,
            source: "Antigravity CLI usage",
            message: "agy CLI",
            now: now
        )
        requireClose(cliSnap.fiveHour?.remainingFraction, 0.95, "Antigravity must pick active 0.95 Gemini 5h over untouched 1.0 3p 5h")
        requireClose(cliSnap.weekly?.remainingFraction, 0.53, "Antigravity must pick most constrained weekly pool (0.53 Argon)")
        require(cliSnap.fiveHour?.isIdle == false, "Active Antigravity 5h window must not be flagged idle")
        require(cliSnap.extras.count == 3, "Remaining Antigravity buckets must be preserved in extras")

        // Tie-breaker: when Gemini and 3P have equal remaining quota, Gemini wins.
        let tiedPayload: [String: Any] = [
            "groups": [
                [
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.80, "resetTime": formatter.string(from: claudeSessionReset)]
                    ]
                ],
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.80, "resetTime": formatter.string(from: geminiSessionReset)]
                    ]
                ]
            ]
        ]
        let tiedSnap = provider.antigravitySnapshot(payload: tiedPayload, source: "test", message: nil, now: now)
        require(tiedSnap.fiveHour?.detail == "Gemini", "Equal-remaining Antigravity pools must prefer Gemini")

        // Error CLI report must be rejected (no fabricated metrics).
        let failedCLIPayload: [String: Any] = [
            "status": "ERROR",
            "error": "authentication required"
        ]
        let failedCLISnap = provider.antigravitySnapshot(payload: failedCLIPayload, source: "test", message: nil, now: now)
        require(failedCLISnap.fiveHour == nil && failedCLISnap.weekly == nil && failedCLISnap.extras.isEmpty,
                "Non-SUCCESS Antigravity CLI report must produce no metrics")

        // 2. Local RetrieveUserQuotaSummary protobuf oneof + disabled/unknown bucket filtering.
        let localSummaryPayload: [String: Any] = [
            "response": [
                "groups": [
                    [
                        "displayName": "Gemini Models",
                        "buckets": [
                            [
                                "bucketId": "gemini-5h",
                                "displayName": "Five Hour Limit",
                                "disabled": true,
                                "remaining": ["remainingFraction": 0.10]
                            ],
                            [
                                "bucketId": "gemini-weekly",
                                "displayName": "Weekly Limit",
                                "remaining": ["case": "remainingFraction", "value": 0.64],
                                "resetTime": formatter.string(from: geminiWeeklyReset)
                            ],
                            [
                                "bucketId": "gemini-mystery",
                                "displayName": "Unknown Bucket"
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let localSummarySnap = provider.antigravitySnapshot(
            payload: localSummaryPayload,
            source: "Antigravity local server",
            message: "Antigravity app",
            now: now
        )
        require(localSummarySnap.fiveHour == nil, "Disabled Antigravity 5h bucket must be ignored")
        requireClose(localSummarySnap.weekly?.remainingFraction, 0.64, "Protobuf oneof remainingFraction must parse")
        require(localSummarySnap.extras.isEmpty, "Buckets without remainingFraction must not render as 0% exhausted")

        // Non-OK RPC code must be rejected.
        let rpcErrorSnap = provider.antigravitySnapshot(
            payload: ["code": 16, "groups": [["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-5h", "remainingFraction": 0.5]]]]],
            source: "test",
            message: nil,
            now: now
        )
        require(rpcErrorSnap.fiveHour == nil, "Non-zero RPC code must be rejected")

        // 3. Antigravity idle (unopened) vs freshly-claimed 5h window semantics.
        let resetlessIdlePayload: [String: Any] = [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1.0],
                        ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.92, "resetTime": formatter.string(from: geminiWeeklyReset)]
                    ]
                ]
            ]
        ]
        let idleSnap = provider.antigravitySnapshot(
            payload: resetlessIdlePayload,
            source: "Antigravity CLI usage",
            message: nil,
            now: now
        )
        require(idleSnap.fiveHour?.isIdle == true && idleSnap.fiveHour?.isIdleFiveHourWindow == true,
                "Reset-less full Antigravity 5h bucket must surface as an idle 5h window")
        require(idleSnap.fiveHour?.resetAt != nil, "Idle Antigravity 5h window must carry a projected reset")
        require(idleSnap.rawWindowKey == "Antigravity CLI usage|idle", "Idle Antigravity window must use stable idle key")
        require(idleSnap.canAutoWarm(now: now, windowDuration: ToolID.antigravity.windowDuration),
                "Idle Antigravity 5h window must be claimable by auto-warm")
        require(!idleSnap.showsActiveWindow(now: now),
                "Idle Antigravity 5h window must not falsely confirm an unopened claim")

        // Sliding 5h projection (`remaining: 1.0`, `resetTime: now + 5h`) is also idle.
        let slidingIdlePayload: [String: Any] = [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1.0, "resetTime": formatter.string(from: now.addingTimeInterval(5 * 3600))]
                    ]
                ]
            ]
        ]
        let slidingIdleSnap = provider.antigravitySnapshot(payload: slidingIdlePayload, source: "test", message: nil, now: now)
        require(slidingIdleSnap.fiveHour?.isIdle == true && !slidingIdleSnap.showsActiveWindow(now: now),
                "Full 5h sliding reset projection must stay flagged idle")

        // 30s after warm-up, even if a tiny 'hi' leaves remaining_fraction rounded at 1.0,
        // the anchored resetTime (now + 5h - 30s) proves the window actually opened.
        let openedAt100Payload: [String: Any] = [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1.0, "resetTime": formatter.string(from: now.addingTimeInterval(5 * 3600 - 30))]
                    ]
                ]
            ]
        ]
        let openedAt100Snap = provider.antigravitySnapshot(payload: openedAt100Payload, source: "test", message: nil, now: now)
        require(openedAt100Snap.fiveHour?.isIdle == false && openedAt100Snap.showsActiveWindow(now: now),
                "Anchored <5h reset must confirm an opened Antigravity window even when remaining rounds to 100%")

        // 4. Legacy GetUserStatus / GetCommandModelConfigs (`clientModelConfigs`) fallback.
        let legacyUserStatusPayload: [String: Any] = [
            "code": 0,
            "userStatus": [
                "email": "dev@example.com",
                "cascadeModelConfigData": [
                    "clientModelConfigs": [
                        [
                            "label": "Gemini Flash Lite",
                            "modelOrAlias": ["model": "gemini-flash-lite"],
                            "quotaInfo": ["remainingFraction": 0.05, "resetTime": formatter.string(from: geminiSessionReset)]
                        ],
                        [
                            "label": "Tab Autocomplete",
                            "modelOrAlias": ["model": "tab_flash"],
                            "quotaInfo": ["remainingFraction": 0.10, "resetTime": formatter.string(from: geminiSessionReset)]
                        ],
                        [
                            "label": "Gemini 3.8 Flash (High)",
                            "modelOrAlias": ["model": "gemini-3.8-flash-high"],
                            "quotaInfo": ["remainingFraction": 0.77, "resetTime": formatter.string(from: geminiSessionReset)]
                        ]
                    ]
                ]
            ]
        ]
        let legacySnap = provider.antigravitySnapshot(payload: legacyUserStatusPayload, source: "Antigravity local server", message: nil, now: now)
        requireClose(legacySnap.fiveHour?.remainingFraction, 0.77, "Legacy clientModelConfigs must ignore lite/tab_ models and pick primary Gemini model")

        // 5. Local process list, listening ports, version parsing, and credential parsing.
        let psSample = """
          101 /usr/sbin/syslogd
          412 /Applications/Antigravity IDE.app/Contents/Resources/extensions/antigravity/bin/language_server_macos_arm --app_data_dir antigravity-ide --csrf_token ide-secret-token --extension_server_port 49100
          389 /Applications/Antigravity.app/Contents/Helpers/language_server_macos_arm --app_data_dir antigravity --csrf_token app-secret-token --extension_server_port=49200 --extension_server_csrf_token=ext-secret-token
          510 /Applications/Antigravity.app/Contents/Helpers/language_server_macos_arm --app_data_dir antigravity
        """
        let processes = AntigravityLocalProbe.parseProcessList(psSample)
        require(processes.count == 2, "Only tokenized Antigravity language_server processes should match")
        require(processes[0].kind == .app && processes[0].pid == 389 && processes[0].csrfToken == "app-secret-token",
                "Antigravity 2.0 app server must sort ahead of IDE extension server")
        require(processes[0].extensionPort == 49200 && processes[0].extensionServerCSRFToken == "ext-secret-token",
                "Equals-form extension port and token flags must parse")
        require(processes[1].kind == .ide && processes[1].pid == 412, "IDE language server must classify as .ide")

        let lsofSample = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_ 389 user   12u  IPv4 0x1234      0t0  TCP 127.0.0.1:54321 (LISTEN)
        language_ 389 user   15u  IPv4 0x1235      0t0  TCP 127.0.0.1:54322 (LISTEN)
        """
        let ports = AntigravityLocalProbe.parseListeningPorts(lsofSample)
        require(ports == [54321, 54322], "lsof LISTEN ports must be extracted and sorted")
        let endpoints = AntigravityLocalProbe.candidateEndpoints(for: processes[0], listeningPorts: ports)
        require(endpoints.first?.scheme == "https" && endpoints.first?.port == 54321,
                "HTTPS language-server port must be probed first")
        require(endpoints.contains(where: { $0.scheme == "http" && $0.port == 49200 && $0.csrfToken == "ext-secret-token" }),
                "Extension server HTTP fallback must carry extensionServerCSRFToken")

        require(AntigravityVersionCache.parseVersion("1.5.7\n")! == (1, 5, 7), "Plain semver must parse")
        require(AntigravityVersionCache.parseVersion("agy version 1.2.3 (darwin/arm64)")! == (1, 2, 3), "Prefixed semver must parse")
        require(AntigravityVersionCache.parseVersion("invalid") == nil, "Invalid version output must return nil")

        let agyTokenJSON = """
        {
          "token": {
            "access_token": "ya29.a0AfH6SMBxMockTokenValue123456",
            "token_type": "Bearer",
            "refresh_token": "1//0gMockRefreshTokenValue123456",
            "expiry": "2026-12-01T10:20:30.456789Z"
          },
          "auth_method": "consumer"
        }
        """.data(using: .utf8)!
        let parsedCred = CredentialStore().parseAntigravityCredential(agyTokenJSON, source: "test")
        require(parsedCred?.accessToken == "ya29.a0AfH6SMBxMockTokenValue123456", "Antigravity file token access_token must parse")
        require(parsedCred?.refreshToken == "1//0gMockRefreshTokenValue123456", "Antigravity file token refresh_token must parse")
        require(parsedCred?.expiresAt != nil, "Antigravity fractional ISO8601 expiry must parse")

        require(WarmupRunner.isAntigravityAuthenticationFailure("Select login method:\n1. Google"),
                "Interactive login prompt must classify as Antigravity auth failure")
        require(WarmupRunner.isAntigravityAuthenticationFailure("Error: authentication required; run agy to sign in"),
                "Headless auth error must classify as Antigravity auth failure")
    }

    private static func testAntigravityLocalUsageAndActivity() {
        let usageProvider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("antigravity-local-usage")
        defer { try? FileManager.default.removeItem(at: root) }
        createDirectory(root)

        writeJSONL([
            #"{"timestamp":"2026-06-15T09:00:00Z","conversation_id":"conv_1","model":"gemini-3.8-flash-medium","usage":{"input_tokens":2000,"cache_read_tokens":1000,"output_tokens":500,"total_tokens":2500}}"#,
            #"{"timestamp":"2026-06-15T09:00:01Z","conversation_id":"conv_1","model":"gemini-3.8-flash-medium","usage":{"input_tokens":2000,"cache_read_tokens":1000,"output_tokens":500,"total_tokens":2500}}"#,
            #"{"timestamp":1781431200000,"sessionId":"sess_yesterday","model":"gemini-4-neon-high","inputTokens":1000,"cacheReadTokens":0,"outputTokens":200,"totalTokens":1200}"#
        ], to: root.appendingPathComponent("sessions.jsonl"))

        let summary = usageProvider.usage(for: .antigravity, baseURL: root, now: now)
        require(summary.source == "Antigravity local usage", "Antigravity local usage source label")
        require(summary.today.totalTokens == 2_500, "Antigravity local usage must dedupe repeated conversation envelopes")
        require(summary.yesterday.totalTokens == 1_200, "Antigravity local usage must parse epoch-ms tokscale records")
        require(summary.last30Days.totalTokens == 3_700, "Antigravity 30-day token aggregation")
        // Flash: (1000 uncached * 0.30 + 1000 cached * 0.03 + 500 output * 2.50) / 1e6 = 0.00158
        requireClose(summary.today.costUSD, 0.00158, "Antigravity Gemini Flash pricing")
        // Neon: (1000 * 2.00 + 200 * 12.00) / 1e6 = 0.0044
        requireClose(summary.yesterday.costUSD, 0.0044, "Antigravity Gemini Neon pricing")

        // ActivityScanner must ignore `conversation_summaries.db` and detect real `.db` conversations.
        let convDir = temporaryDirectory("antigravity-conversations")
        defer { try? FileManager.default.removeItem(at: convDir) }
        createDirectory(convDir)

        let summaryDB = convDir.appendingPathComponent("conversation_summaries.db")
        FileManager.default.createFile(atPath: summaryDB.path, contents: Data("index".utf8))
        let scanner = ActivityScanner()
        require(
            scanner.lastActivity(for: .antigravity, directories: [convDir]) == nil
                && scanner.windowStartTime(for: .antigravity, directories: [convDir]) == nil,
            "conversation_summaries.db index file must not count as user conversation activity"
        )

        let realSessionDB = convDir.appendingPathComponent("ab12cd34-session.db")
        FileManager.default.createFile(atPath: realSessionDB.path, contents: Data("sqlite".utf8))
        require(
            scanner.lastActivity(for: .antigravity, directories: [convDir]) != nil
                && scanner.windowStartTime(for: .antigravity, directories: [convDir]) != nil,
            "Real Antigravity conversation .db files must register local activity"
        )
    }

    private static func testAntigravityLiveSubprocessFlow() async {
        let dir = temporaryDirectory("antigravity-live-cli")
        defer {
            unsetenv("ANTIGRAVITY_CLI_PATH")
            try? FileManager.default.removeItem(at: dir)
        }
        createDirectory(dir)

        let mockAgy = dir.appendingPathComponent("agy")
        let markerFile = dir.appendingPathComponent("warmup-invocations.log")
        let resetISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(4 * 3600))
        let weeklyISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 24 * 3600))

        // Phase 1: Healthy `agy` supporting `--version`, `-p /usage --output-format json`,
        // and rejecting `--effort` once so WarmupRunner exercises its fallback command!
        let healthyScript = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "1.5.7"
          exit 0
        fi
        if [ "$1" = "-p" ] && [ "$2" = "/usage" ]; then
          if [ "$AGY_CLI_DISABLE_AUTO_UPDATE" != "true" ]; then
            echo "missing AGY_CLI_DISABLE_AUTO_UPDATE" >&2
            exit 2
          fi
          cat <<'JSON'
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.88,"reset_time":"\(resetISO)"},{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.75,"reset_time":"\(weeklyISO)"}]}]}}}
        JSON
          exit 0
        fi
        echo "args:$* auto_update:$AGY_CLI_DISABLE_AUTO_UPDATE browser:$BROWSER" >> "\(markerFile.path)"
        for arg in "$@"; do
          if [ "$arg" = "--effort" ]; then
            echo "model does not support --effort override" >&2
            exit 1
          fi
        done
        echo "hi!"
        exit 0
        """
        do {
            try healthyScript.write(to: mockAgy, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockAgy.path)
        } catch {
            fatalError("Failed to write mock agy script: \(error)")
        }

        setenv("ANTIGRAVITY_CLI_PATH", mockAgy.path, 1)

        // Live end-to-end fetchQuota(for: .antigravity) through mock `agy` binary!
        do {
            let liveSnapshot = try await QuotaProvider().fetchQuota(for: .antigravity)
            require(liveSnapshot.tool == .antigravity, "Live Antigravity snapshot tool id")
            requireClose(liveSnapshot.fiveHour?.remainingFraction, 0.88, "Live Antigravity 5h quota via agy /usage")
            requireClose(liveSnapshot.weekly?.remainingFraction, 0.75, "Live Antigravity weekly quota via agy /usage")
        } catch {
            fatalError("Live Antigravity fetchQuota failed unexpectedly: \(error)")
        }

        // Live end-to-end WarmupRunner().warmup(.antigravity) including primary -> fallback retry!
        do {
            let warmupResult = try await WarmupRunner().warmup(.antigravity)
            require(
                warmupResult.output.contains("Primary warmup command failed; retried with the configured fallback command."),
                "WarmupRunner must automatically retry with fallbackWarmupCommand when --effort fails"
            )
            let invocations = (try? String(contentsOf: markerFile, encoding: .utf8)) ?? ""
            require(
                invocations.contains("auto_update:true") && invocations.contains("browser:/usr/bin/false"),
                "WarmupRunner must pass AGY_CLI_DISABLE_AUTO_UPDATE=true and no-op BROWSER to agy"
            )
        } catch {
            fatalError("Live Antigravity warmup failed unexpectedly: \(error)")
        }

        // Phase 2: Signed-out `agy` must surface authFailure (QuotaProvider) and authenticationRequired (WarmupRunner).
        let signedOutAgy = dir.appendingPathComponent("agy-signed-out")
        let signedOutScript = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "1.5.7"
          exit 0
        fi
        echo "Select login method:" >&2
        exit 1
        """
        try! signedOutScript.write(to: signedOutAgy, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signedOutAgy.path)
        setenv("ANTIGRAVITY_CLI_PATH", signedOutAgy.path, 1)

        do {
            _ = try await QuotaProvider().fetchQuota(for: .antigravity)
            fatalError("Signed-out agy should throw QuotaProviderError.authFailure")
        } catch QuotaProviderError.authFailure {
            // Expected
        } catch {
            fatalError("Expected QuotaProviderError.authFailure for signed-out agy, got \(error)")
        }

        do {
            _ = try await WarmupRunner().warmup(.antigravity)
            fatalError("Signed-out agy warmup should throw WarmupError.authenticationRequired")
        } catch WarmupError.authenticationRequired {
            // Expected
        } catch {
            fatalError("Expected WarmupError.authenticationRequired for signed-out agy, got \(error)")
        }
    }

    private static func testSmartSchedulingAndAlertPolicies() {
        let baseNow = isoDate("2026-04-17T02:15:00Z")

        // 1. SmartRefreshPolicy accelerates right to reset + 5s when reset is sooner than refreshInterval.
        let farReset = baseNow.addingTimeInterval(2 * 3600)
        let normalNext = SmartRefreshPolicy.nextRefreshDate(now: baseNow, refreshInterval: 900, windowResetAt: farReset)
        require(abs(normalNext.timeIntervalSince(baseNow) - 900) < 0.5, "Far reset should keep normal refresh interval")

        let imminentReset = baseNow.addingTimeInterval(40)
        let acceleratedNext = SmartRefreshPolicy.nextRefreshDate(now: baseNow, refreshInterval: 900, windowResetAt: imminentReset)
        require(abs(acceleratedNext.timeIntervalSince(baseNow) - 45) < 0.5, "Imminent reset should accelerate poll to resetAt + 5s")

        let pastReset = baseNow.addingTimeInterval(-30)
        let pastNext = SmartRefreshPolicy.nextRefreshDate(now: baseNow, refreshInterval: 300, windowResetAt: pastReset)
        require(abs(pastNext.timeIntervalSince(baseNow) - 300) < 0.5, "Past reset should use normal refresh interval")

        // 2. ActiveHoursPolicy supports daytime and overnight spans in UTC.
        let cal = utcCalendar
        require(
            ActiveHoursPolicy.isWithinActiveHours(now: baseNow, enabled: false, startHour: 8, endHour: 23, calendar: cal),
            "Disabled active-hours guard must allow all hours"
        )
        require(
            !ActiveHoursPolicy.isWithinActiveHours(now: baseNow, enabled: true, startHour: 8, endHour: 23, calendar: cal),
            "02:15 UTC must be outside 08:00-23:00 active window"
        )
        let daytime = isoDate("2026-04-17T10:30:00Z")
        require(
            ActiveHoursPolicy.isWithinActiveHours(now: daytime, enabled: true, startHour: 8, endHour: 23, calendar: cal),
            "10:30 UTC must be inside 08:00-23:00 active window"
        )
        require(
            ActiveHoursPolicy.isWithinActiveHours(now: baseNow, enabled: true, startHour: 22, endHour: 6, calendar: cal),
            "02:15 UTC must be inside overnight 22:00-06:00 active window"
        )
        require(
            !ActiveHoursPolicy.isWithinActiveHours(now: daytime, enabled: true, startHour: 22, endHour: 6, calendar: cal),
            "10:30 UTC must be outside overnight 22:00-06:00 active window"
        )
        if let nextStart = ActiveHoursPolicy.nextActiveStart(after: baseNow, startHour: 8, calendar: cal) {
            require(cal.component(.hour, from: nextStart) == 8, "nextActiveStart should land on hour 8")
            require(nextStart > baseNow, "nextActiveStart must be strictly after now")
        } else {
            fatalError("nextActiveStart should resolve a valid date")
        }

        // 3. LowQuotaAlertPolicy alerts once per active 5h window and ignores rollover artifacts.
        let activeReset = daytime.addingTimeInterval(3600)
        let lowSnap = QuotaSnapshot(
            tool: .codex,
            fetchedAt: daytime,
            primarySource: "Codex test",
            corroboratingSource: nil,
            fiveHour: QuotaMetric(name: "5h window", usedPercent: 0.82, remainingPercent: 0.18, resetAt: activeReset, detail: nil),
            weekly: nil,
            extras: [],
            rawWindowKey: "codex|low",
            message: nil
        )
        let firstKey = LowQuotaAlertPolicy.shouldAlert(
            enabled: true,
            snapshot: lowSnap,
            windowDuration: 5 * 3600,
            lastAlertedKey: nil,
            now: daytime
        )
        require(firstKey != nil, "18% remaining on an active 5h window should trigger low-quota alert")

        let jitteredSnap = QuotaSnapshot(
            tool: .codex,
            fetchedAt: daytime.addingTimeInterval(60),
            primarySource: "Codex test",
            corroboratingSource: nil,
            fiveHour: QuotaMetric(name: "5h window", usedPercent: 0.85, remainingPercent: 0.15, resetAt: activeReset.addingTimeInterval(20), detail: nil),
            weekly: nil,
            extras: [],
            rawWindowKey: "codex|low2",
            message: nil
        )
        require(
            LowQuotaAlertPolicy.shouldAlert(
                enabled: true,
                snapshot: jitteredSnap,
                windowDuration: 5 * 3600,
                lastAlertedKey: firstKey,
                now: daytime.addingTimeInterval(60)
            ) == nil,
            "Same 5h window with minor reset_after_seconds jitter must not duplicate low-quota alert"
        )

        let unsettledSnap = QuotaSnapshot(
            tool: .claude,
            fetchedAt: daytime,
            primarySource: "Claude test",
            corroboratingSource: nil,
            fiveHour: QuotaMetric(name: "5h window", usedPercent: 0.99, remainingPercent: 0.01, resetAt: daytime.addingTimeInterval(5 * 3600 - 60), detail: nil),
            weekly: nil,
            extras: [],
            rawWindowKey: "claude|unsettled",
            message: nil
        )
        require(
            LowQuotaAlertPolicy.shouldAlert(
                enabled: true,
                snapshot: unsettledSnap,
                windowDuration: 5 * 3600,
                lastAlertedKey: nil,
                now: daytime
            ) == nil,
            "Unsettled rollover artifact right after window open must not fire false low-quota alert"
        )

        // 4. MenuBarDisplayStyle resolution.
        require(MenuBarDisplayStyle.resolve(rawValue: nil) == .both, "Default menu bar style should be .both")
        require(MenuBarDisplayStyle.resolve(rawValue: "percent") == .percentOnly, "Percent menu bar style should resolve")
        require(MenuBarDisplayStyle.resolve(rawValue: "countdown") == .countdownOnly, "Countdown menu bar style should resolve")
    }
}
