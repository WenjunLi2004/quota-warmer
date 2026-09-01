import CryptoKit
import Foundation
import LocalAuthentication
import Security

final class CredentialStore {
    private let fileManager = FileManager.default

    func credential(
        for tool: ToolID,
        allowsUserInteraction: Bool = false
    ) async throws -> Credential {
        switch tool {
        case .claude:
            return try claudeCredential(allowsUserInteraction: allowsUserInteraction)
        case .codex: return try codexCredential()
        }
    }

    private func claudeCredential(allowsUserInteraction: Bool) throws -> Credential {
        // NOTE: a `claude setup-token` long-lived token was briefly preferred
        // here, to dodge the recurring Keychain approval dialog. It dodged the
        // dialog and broke the app: /api/oauth/usage rejects that token class
        // with 429, so quota display died completely for two days while the
        // logs cheerfully reported `prompt=no`. The last successful fetch was
        // 59 seconds before that token was adopted, and there was not one
        // afterwards. Those tokens are issued for CI, not for polling usage —
        // do not reintroduce one here without first proving a real 200 from
        // this endpoint. The mirror below already avoids most dialogs *and*
        // returns data that works.
        //
        // Claude Code owns its Keychain item, so every read of it can raise the
        // macOS approval dialog — the grant does not reliably survive the CLI
        // rewriting the item on each ~8h token rotation. Mirror the still-valid
        // access token into an item QuotaWarmer itself owns; reading our own item
        // never prompts, so a relaunch (every login) no longer costs a dialog.
        if let cached = cachedClaudeCredential(), !cached.isExpired {
            DiagnosticLogger.append("claude_credential_source=mirror prompt=no")
            return cached
        }
        DiagnosticLogger.append("claude_credential_source=claude-code-keychain prompt=possible")

        let services = claudeKeychainServices()
        var keychainNeedsApproval = false
        for service in services {
            switch claudeKeychainPassword(service: service, allowsUserInteraction: allowsUserInteraction) {
            case .data(let data):
                if let credential = parseClaudeCredential(data, source: "Keychain \(service)") {
                    storeCachedClaudeCredential(credential)
                    return credential
                }
            case .interactionRequired:
                keychainNeedsApproval = true
            case .notFound:
                break
            }
        }

        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return Credential(
                accessToken: token,
                refreshToken: nil,
                accountID: nil,
                source: "env CLAUDE_CODE_OAUTH_TOKEN",
                expiresAt: nil
            )
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: url),
           let credential = parseClaudeCredential(data, source: "~/.claude/.credentials.json") {
            return credential
        }

        if keychainNeedsApproval {
            throw CredentialError.interactionRequired("Claude")
        }
        throw CredentialError.missing("Claude")
    }

    private func codexCredential() throws -> Credential {
        let paths = [
            ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("auth.json") },
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".config/codex/auth.json"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        ].compactMap { $0 }

        for url in paths {
            if let data = try? Data(contentsOf: url),
               let credential = parseCodexCredential(data, source: displayPath(url)) {
                return credential
            }
        }

        if let data = keychainPassword(service: "Codex Auth"),
           let credential = parseCodexCredential(data, source: "Keychain Codex Auth") {
            return credential
        }

        throw CredentialError.missing("Codex")
    }

    func credentialSourceSummary(for tool: ToolID) -> String {
        switch tool {
        case .claude:
            return (claudeKeychainServices().map { "Keychain \($0)" } + [
                "env CLAUDE_CODE_OAUTH_TOKEN",
                "~/.claude/.credentials.json"
            ]).joined(separator: ", ")
        case .codex:
            return [
                "$CODEX_HOME/auth.json",
                "~/.config/codex/auth.json",
                "~/.codex/auth.json",
                "Keychain Codex Auth"
            ].joined(separator: ", ")
        }
    }

    private func claudeKeychainServices() -> [String] {
        var services = ["Claude Code-credentials"]
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            let hash = SHA256.hash(data: Data(configDir.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            services.append("Claude Code-credentials-\(hash)")
            services.append("Claude Code-credentials-\(String(hash.prefix(16)))")
        }
        return services
    }

    private func keychainPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: - Cleanup of the withdrawn long-lived-token path

    private static let claudeLongLivedService = "com.quotawarmer.app.claude-long-lived-token"

    /// Removes the Keychain item and hand-off file left behind by the withdrawn
    /// `claude setup-token` path (see the note in `claudeCredential`). Runs once
    /// per launch so an existing install stops carrying a credential nothing
    /// reads any more — leaving a working token lying around unused is worse
    /// than either using it or not having it.
    func purgeWithdrawnLongLivedToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeLongLivedService
        ]
        if SecItemDelete(query as CFDictionary) == errSecSuccess {
            DiagnosticLogger.append("claude_long_lived_token purged=keychain")
        }
        let fileURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotawarmer/claude-token")
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
            DiagnosticLogger.append("claude_long_lived_token purged=file")
        }
    }

    /// Generic-password item created and owned by QuotaWarmer. Because this
    /// process added it, SecItemCopyMatching returns it without an approval
    /// dialog, which is the whole point of mirroring the token here.
    private static let claudeCacheService = "com.quotawarmer.app.claude-oauth-cache"

    private struct CachedClaudeCredential: Codable {
        let accessToken: String
        let expiresAt: Date?
        let source: String
    }

    /// Returns the mirrored credential, or nil when absent/unreadable/malformed.
    /// Never throws: a bad cache must always fall through to the real source.
    private func cachedClaudeCredential() -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeCacheService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let cached = try? JSONDecoder().decode(CachedClaudeCredential.self, from: data) else {
            return nil
        }
        return Credential(
            accessToken: cached.accessToken,
            // Deliberately not mirrored: QuotaWarmer never refreshes Claude's
            // rotating refresh token, so it has no reason to hold a copy.
            refreshToken: nil,
            accountID: nil,
            // Marked so the diagnostics log distinguishes a prompt-free mirror
            // read from a read that had to touch Claude Code's own item.
            source: "\(cached.source) (cached)",
            expiresAt: cached.expiresAt
        )
    }

    private func storeCachedClaudeCredential(_ credential: Credential) {
        // An access token with no known expiry can never be aged out, so it is
        // not safe to mirror — always re-read those from the owning source.
        guard credential.expiresAt != nil else { return }
        let cached = CachedClaudeCredential(
            accessToken: credential.accessToken,
            expiresAt: credential.expiresAt,
            source: credential.source
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeCacheService
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Cache only needs to be readable while the user is logged in, and
            // must never sync to another machine.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    /// Drops the mirror so the next read goes back to Claude Code's own item.
    /// Used when the mirrored token is rejected by the API.
    func invalidateCachedClaudeCredential() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeCacheService
        ]
        SecItemDelete(query as CFDictionary)
    }

    private enum ClaudeKeychainRead {
        case data(Data)
        case notFound
        case interactionRequired
    }

    /// Background quota polling must never summon a macOS password dialog.
    /// A user-initiated Refresh is the only path allowed to request access.
    private func claudeKeychainPassword(service: String, allowsUserInteraction: Bool) -> ClaudeKeychainRead {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowsUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return .data(data)
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            return .interactionRequired
        }
        return .notFound
    }

    private func parseClaudeCredential(_ data: Data, source: String) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let accessToken = string(in: json, keys: ["access_token", "accessToken", "claudeAiOauth.accessToken", "oauth.accessToken"])
        let refreshToken = string(in: json, keys: ["refresh_token", "refreshToken", "claudeAiOauth.refreshToken", "oauth.refreshToken"])
        let expiresAt = date(in: json, keys: ["expires_at", "expiresAt", "claudeAiOauth.expiresAt", "oauth.expiresAt"])

        guard let token = accessToken, !token.isEmpty else { return nil }
        return Credential(
            accessToken: token,
            refreshToken: refreshToken,
            accountID: nil,
            source: source,
            expiresAt: expiresAt
        )
    }

    private func parseCodexCredential(_ data: Data, source: String) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let accessToken = string(in: json, keys: [
            "access_token", "accessToken", "chatgpt_access_token",
            "tokens.access_token", "tokens.accessToken", "auth.access_token"
        ])
        let refreshToken = string(in: json, keys: ["refresh_token", "refreshToken", "tokens.refresh_token"])
        let accountID = string(in: json, keys: [
            "account_id", "accountId", "chatgpt_account_id",
            "ChatGPT-Account-Id", "tokens.account_id", "auth.account_id"
        ])
        let expiresAt = date(in: json, keys: ["expires_at", "expiresAt", "tokens.expires_at", "tokens.expiresAt"])

        guard let token = accessToken, !token.isEmpty else { return nil }
        return Credential(
            accessToken: token,
            refreshToken: refreshToken,
            accountID: accountID,
            source: source,
            expiresAt: expiresAt
        )
    }

    private func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = value(in: object, dottedKey: key) {
                if let string = value as? String, !string.isEmpty { return string }
                if let number = value as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }

    private func date(in object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = value(in: object, dottedKey: key) else { continue }
            if let seconds = value as? TimeInterval {
                return seconds > 10_000_000_000
                    ? Date(timeIntervalSince1970: seconds / 1000)
                    : Date(timeIntervalSince1970: seconds)
            }
            if let number = value as? NSNumber {
                let seconds = number.doubleValue
                return seconds > 10_000_000_000
                    ? Date(timeIntervalSince1970: seconds / 1000)
                    : Date(timeIntervalSince1970: seconds)
            }
            if let string = value as? String {
                if let seconds = TimeInterval(string) {
                    return seconds > 10_000_000_000
                        ? Date(timeIntervalSince1970: seconds / 1000)
                        : Date(timeIntervalSince1970: seconds)
                }
                if let date = ISO8601DateFormatter().date(from: string) { return date }
            }
        }
        return nil
    }

    private func value(in object: [String: Any], dottedKey: String) -> Any? {
        let parts = dottedKey.split(separator: ".").map(String.init)
        var current: Any = object
        for part in parts {
            guard let dict = current as? [String: Any], let next = dict[part] else { return nil }
            current = next
        }
        return current
    }

    private func displayPath(_ url: URL) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}
