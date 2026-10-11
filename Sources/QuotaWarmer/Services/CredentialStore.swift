import CryptoKit
import Foundation
import Security

final class CredentialStore {
    private let fileManager = FileManager.default

    func credential(for tool: ToolID) async throws -> Credential {
        switch tool {
        case .claude: return try claudeCredential()
        case .codex: return try codexCredential()
        }
    }

    private func claudeCredential() throws -> Credential {
        // NOTE: a `claude setup-token` long-lived token was briefly preferred
        // here, to dodge the recurring Keychain approval dialog. It dodged the
        // dialog and broke the app: /api/oauth/usage rejects that token class
        // with 429, so quota display died completely for two days while the
        // logs cheerfully reported `prompt=no`. The last successful fetch was
        // 59 seconds before that token was adopted, and there was not one
        // afterwards. Those tokens are issued for CI, not for polling usage —
        // do not reintroduce one here without first proving a real 200 from
        // this endpoint.
        //
        // Claude Code's item is read through /usr/bin/security, never through
        // SecItemCopyMatching. Claude Code itself writes the item with that
        // tool (`security add-generic-password -U`), and every such write
        // resets the item's partition list to `apple-tool:` alone. A
        // SecItemCopyMatching call from QuotaWarmer (partition `cdhash:…`, since
        // the app is ad-hoc signed) therefore needs approval again after every
        // ~8h token rotation, no matter how often "Always Allow" was clicked —
        // the app stays in the ACL, but its partition is gone. The dialog also
        // ignored LAContext.interactionNotAllowed and blocked the background
        // poll until someone answered it. `security` itself carries the
        // `apple-tool:` partition the writer just set, so reading through it
        // can't prompt.
        let services = claudeKeychainServices()
        var keychainUnreadable = false
        for service in services {
            switch claudeKeychainPassword(service: service) {
            case .data(let data):
                if let credential = parseClaudeCredential(data, source: "Keychain \(service)") {
                    DiagnosticLogger.append("claude_credential_source=security-tool prompt=no")
                    return credential
                }
            case .unreadable:
                keychainUnreadable = true
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

        if keychainUnreadable {
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
        // This direct read is only reached when Codex keeps no auth.json. An
        // item another app owns would need approval here, so make this process
        // fail such reads instead of showing a dialog.
        SecKeychainSetUserInteractionAllowed(false)
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

    private enum ClaudeKeychainRead {
        case data(Data)
        case notFound
        case unreadable
    }

    private func claudeKeychainPassword(service: String) -> ClaudeKeychainRead {
        // A locked login keychain would make even `security` ask for the
        // password. Background polling must never raise a dialog, so report it
        // as unreadable and let the caller back off instead.
        if loginKeychainIsLocked() {
            DiagnosticLogger.append("claude_credential_source=security-tool skipped=keychain-locked")
            return .unreadable
        }
        guard let result = runSecurityTool(["find-generic-password", "-s", service, "-w"]) else {
            // Still running after the timeout, which only waiting on a dialog
            // explains. It has been terminated; back off rather than retry.
            DiagnosticLogger.append("claude_credential_source=security-tool timed_out=yes")
            return .unreadable
        }
        // 44 is errSecItemNotFound's exit status for this subcommand.
        guard result.status == 0 else { return .notFound }
        guard let data = Self.decodeSecurityToolPassword(result.output) else { return .notFound }
        return .data(data)
    }

    /// `security find-generic-password -w` prints the secret followed by a
    /// newline, or as bare hex when the secret isn't printable text.
    private static func decodeSecurityToolPassword(_ output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.first == "{" { return Data(text.utf8) }
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return Data(text.utf8) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Runs /usr/bin/security, returning its exit status and stdout — or nil
    /// when it hadn't finished within `timeout` and was terminated.
    private func runSecurityTool(_ arguments: [String], timeout: TimeInterval = 10) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain concurrently so a full pipe can never stall the tool. It
        // spawns no children, so EOF follows its exit.
        let output = SecurityToolOutput()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        drained.wait()
        return (process.terminationStatus, output.data)
    }

    private final class SecurityToolOutput: @unchecked Sendable {
        var data = Data()
    }

    /// Reads the lock state without asking to unlock (deprecated API, but
    /// the only one that reports this for the file-based login keychain).
    private func loginKeychainIsLocked() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) == 0
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
