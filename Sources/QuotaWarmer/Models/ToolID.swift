import Foundation

enum ToolID: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:      return "Claude Code"
        case .codex:       return "Codex CLI"
        case .antigravity: return "Antigravity"
        }
    }

    /// Short, brand-only name for in-app screen labels.
    var shortName: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var assetName: String {
        switch self {
        case .claude:      return "ClaudeCode"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var cliExecutableName: String {
        switch self {
        case .claude:      return "claude"
        case .codex:       return "codex"
        case .antigravity: return "agy"
        }
    }

    var installURLString: String {
        switch self {
        case .claude:      return "https://docs.anthropic.com/en/docs/claude-code"
        case .codex:       return "https://github.com/openai/codex"
        case .antigravity: return "https://antigravity.google/docs/cli/"
        }
    }

    var icon: String {
        switch self {
        case .claude:      return "bolt.circle.fill"
        case .codex:       return "terminal.fill"
        case .antigravity: return "sparkles"
        }
    }

    var accentColor: String {
        switch self {
        case .claude:      return "orange"
        case .codex:       return "purple"
        case .antigravity: return "blue"
        }
    }

    var warmupCommand: String {
        switch self {
        case .claude:
            return "claude --model haiku --effort low --no-session-persistence --max-turns 1 --tools '' -p 'hi'"
        // No pinned model: a pinned one is retired out from under the app
        // (gpt-5.4-mini now fails for ChatGPT accounts), while the configured
        // default is whatever Codex itself currently accepts.
        case .codex:
            return "codex exec -c model_reasoning_effort=\"low\" --skip-git-repo-check --ephemeral --ignore-rules 'hi'"
        // Antigravity headless mode exits non-zero if --model names a retired
        // slug, so rely on the user's configured default model with low effort.
        case .antigravity:
            return "agy --effort low --print-timeout 45s -p 'hi'"
        }
    }

    var fallbackWarmupCommand: String? {
        switch self {
        case .claude:
            return "claude --effort low --no-session-persistence --max-turns 1 --tools '' -p 'hi'"
        case .codex:
            // For a default model that rejects the low-effort override.
            return "codex exec --skip-git-repo-check --ephemeral --ignore-rules 'hi'"
        case .antigravity:
            return "agy --print-timeout 45s -p 'hi'"
        }
    }

    var logDirectoryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return home.appendingPathComponent(".claude/projects")
        case .codex:
            return home.appendingPathComponent(".codex/sessions")
        case .antigravity:
            let geminiHome = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let geminiRoot = (geminiHome?.isEmpty == false)
                ? URL(fileURLWithPath: geminiHome!)
                : home.appendingPathComponent(".gemini")
            return geminiRoot.appendingPathComponent("antigravity-cli/conversations")
        }
    }

    /// Directories inspected for local CLI/app session activity and token usage.
    var activityDirectoryURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return [logDirectoryURL].compactMap { $0 }
        case .codex:
            var codexHomes: [URL] = []
            if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
                for raw in envHome.split(separator: ",") {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        codexHomes.append(URL(fileURLWithPath: trimmed, isDirectory: true))
                    }
                }
            }
            codexHomes.append(home.appendingPathComponent(".config/codex", isDirectory: true))
            codexHomes.append(home.appendingPathComponent(".codex", isDirectory: true))

            var seen = Set<String>()
            var activeDirs: [URL] = []
            var archivedDirs: [URL] = []
            for base in codexHomes {
                let canonicalHome = base.standardizedFileURL.path
                guard seen.insert(canonicalHome).inserted else { continue }
                activeDirs.append(base.appendingPathComponent("sessions", isDirectory: true))
                archivedDirs.append(base.appendingPathComponent("archived_sessions", isDirectory: true))
            }
            return activeDirs + archivedDirs
        case .antigravity:
            let geminiHome = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let geminiRoot = (geminiHome?.isEmpty == false)
                ? URL(fileURLWithPath: geminiHome!)
                : home.appendingPathComponent(".gemini")
            let tokscaleHome = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tokscaleRoot = (tokscaleHome?.isEmpty == false)
                ? URL(fileURLWithPath: tokscaleHome!)
                : home.appendingPathComponent(".config/tokscale")
            return [
                geminiRoot.appendingPathComponent("antigravity-cli/conversations"),
                geminiRoot.appendingPathComponent("antigravity/conversations"),
                tokscaleRoot.appendingPathComponent("antigravity-cache/sessions")
            ]
        }
    }

    /// Rolling quota window duration. Claude Code, Codex, and Antigravity use
    /// 5 h rolling session windows server-side.
    var windowDuration: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "windowDurationSecs")
        return stored > 0 ? TimeInterval(stored) : 5 * 3600
    }

    /// Weekly quota window length (7 days). Used by the in-app pace marker to
    /// show how much of the weekly window's *time* remains versus quota.
    var weeklyWindowDuration: TimeInterval { 7 * 24 * 3600 }
}

/// Pure rules for turning an entire provider on or off (hiding it from the menu
/// bar, sidebar, and overview while stopping all background checks/warmups, and
/// restoring its mode when turned back on).
enum ToolEnablementPolicy {
    static func defaultsKey(for tool: ToolID) -> String {
        "toolEnabled.\(tool.rawValue)"
    }

    static func isEnabled(for tool: ToolID, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey(for: tool)) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, for tool: ToolID, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey(for: tool))
    }

    /// Re-enabling a provider that was left on `.off` resumes safe read-only
    /// monitoring; `.monitor` and `.autoWarm` keep the user's prior choice.
    static func restoredModeOnEnable(currentMode: ToolMode) -> ToolMode {
        currentMode == .off ? .monitor : currentMode
    }

    static func effectiveMonitored(isEnabled: Bool, mode: ToolMode) -> Bool {
        isEnabled && mode != .off
    }

    static func effectiveAutoWarm(isEnabled: Bool, mode: ToolMode) -> Bool {
        isEnabled && mode == .autoWarm
    }

    static func effectiveMenuBarVisible(isEnabled: Bool, menuBarVisible: Bool) -> Bool {
        isEnabled && menuBarVisible
    }
}

/// How QuotaWarmer treats a tool. Monitoring (read-only visibility) is the
/// safe default; automatic warm-up is an explicit opt-in on top of it.
///
/// - `.off`      — not watched at all.
/// - `.monitor`  — polls quota and shows status/alerts, but never sends anything.
/// - `.autoWarm` — monitors *and* auto-claims a fresh window.
enum ToolMode: String, CaseIterable, Codable {
    case off
    case monitor
    case autoWarm

    /// Short label for compact controls.
    var label: String {
        switch self {
        case .off:      return "Off"
        case .monitor:  return "Monitor"
        case .autoWarm: return "Auto-warm"
        }
    }

    /// Descriptive label for the dropdown menu items.
    var menuLabel: String {
        switch self {
        case .off:      return "Off — don't watch"
        case .monitor:  return "Monitor only — watch quota"
        case .autoWarm: return "Auto-warm — claim windows"
        }
    }

    /// Next mode when cycling the control: Off → Monitor → Auto-warm → Off.
    var next: ToolMode {
        switch self {
        case .off:      return .monitor
        case .monitor:  return .autoWarm
        case .autoWarm: return .off
        }
    }
}
