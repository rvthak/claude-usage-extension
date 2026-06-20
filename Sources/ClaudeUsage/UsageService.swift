import Foundation
import Security
import Combine

struct UsageSnapshot {
    var fiveHourUtilization: Int = 0
    var sevenDayUtilization: Int = 0
    var fiveHourResetAt: Date?
    var sevenDayResetAt: Date?
    var lastUpdated: Date?
    var error: String?
    var isLoading: Bool = false
    var isRateLimited: Bool = false
    var isAuthError: Bool = false
    // Authoritative auth state from `claude auth status`: true only when the CLI
    // itself reports we're signed out (refresh token gone / revoked), as opposed
    // to a merely stale access token the CLI will refresh on its next run.
    var loggedOut: Bool = false
}

final class UsageService: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?

    @MainActor
    func fetch() async {
        snapshot.isLoading = true
        do {
            let response = try await fetchWithFreshTokenIfNeeded()
            snapshot = UsageSnapshot(
                fiveHourUtilization: Int(response.fiveHour?.utilization ?? 0),
                sevenDayUtilization: Int(response.sevenDay?.utilization ?? 0),
                fiveHourResetAt: response.fiveHour?.resetsAtDate,
                sevenDayResetAt: response.sevenDay?.resetsAtDate,
                lastUpdated: Date(),
                error: nil,
                isLoading: false,
                isRateLimited: false
            )
        } catch let error as NSError {
            let isRateLimit = error.code == 429
            let isAuth = error.code == 401 || error.domain == "Keychain" || error.domain == "Auth"
            // Any auth/rate-limit failure means our cached token is suspect; drop it
            // so the next attempt re-reads the Keychain for a freshly rotated token.
            if isRateLimit || isAuth { invalidateToken() }

            var message = error.localizedDescription
            var loggedOut = false
            if isAuth {
                // Ask Claude Code itself for the authoritative state. This lets us
                // tell a genuinely signed-out user (must run `claude /login`) apart
                // from a merely stale access token (the CLI will refresh it on its
                // next run — no user action needed). Falls through to the raw error
                // if the CLI can't be found or doesn't answer.
                if let status = await cliAuthStatus() {
                    if status.loggedIn {
                        message = "Claude Code's access token is stale. It refreshes automatically the next time you run any Claude Code command."
                    } else {
                        loggedOut = true
                        message = "Not signed in to Claude Code. Run `claude /login` in a terminal, then hit Refresh."
                    }
                }
            }

            snapshot.error = message
            snapshot.isLoading = false
            snapshot.isRateLimited = isRateLimit
            snapshot.isAuthError = isAuth
            snapshot.loggedOut = loggedOut
        }
    }

    /// Fetches usage with whatever access token Claude Code currently has stored.
    /// There is deliberately no retry-on-401 here: the extension can't refresh
    /// tokens (that's Claude Code's job), so re-reading the Keychain would return
    /// the same rejected token and the extra request would only burn the account's
    /// shared rate limit — which can in turn starve the CLI's own token refresh.
    private func fetchWithFreshTokenIfNeeded() async throws -> OAuthUsageResponse {
        let token = try accessToken()
        return try await fetchOAuthUsage(accessToken: token)
    }

    private func accessToken() throws -> String {
        // Reuse the cached token only while it is still valid (with a safety skew).
        if let token = cachedToken, let expiry = cachedTokenExpiry,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        let creds = try readOAuthCredentials()
        // The extension can't refresh tokens — that's Claude Code's job. If the
        // token Claude Code stored has already expired (e.g. after the laptop slept
        // through its lifetime), don't send it to the API: that just 401-storms and
        // can trip an account-level rate limit that interferes with the CLI's own
        // refresh. Surface a clean auth state and wait for the CLI to rotate it.
        if let expiry = creds.expiresAtDate, expiry.timeIntervalSinceNow <= 60 {
            invalidateToken()
            throw NSError(
                domain: "Auth",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Access token expired. Waiting for Claude Code to refresh it — run any Claude Code command to renew."]
            )
        }
        cachedToken = creds.accessToken
        cachedTokenExpiry = creds.expiresAtDate
        return creds.accessToken
    }

    private func invalidateToken() {
        cachedToken = nil
        cachedTokenExpiry = nil
    }
}

// MARK: - Authoritative auth state via the Claude Code CLI

private struct CLIAuthStatus: Decodable {
    let loggedIn: Bool
}

/// Shells out to `claude auth status --json` to get an authoritative auth state.
/// Read-only: when the token is healthy this is a pure read (it does not rotate
/// the refresh token), so it's safe to call without risking the double-writer
/// race that self-refreshing would introduce. Returns nil if the CLI can't be
/// located or doesn't answer in time.
private func cliAuthStatus() async -> CLIAuthStatus? {
    await Task.detached(priority: .utility) { () -> CLIAuthStatus? in
        guard let exe = findClaudeBinary() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["auth", "status", "--json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        // Watchdog: never let a hung CLI block a refresh cycle.
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()

        guard proc.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(CLIAuthStatus.self, from: data)
    }.value
}

/// Locates the `claude` executable. A menu-bar app launched from Finder doesn't
/// inherit the user's shell PATH, so probe the known install locations first and
/// fall back to resolving through a login shell.
private func findClaudeBinary() -> String? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let candidates = [
        "\(home)/.local/bin/claude",
        "\(home)/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]
    for path in candidates where fm.isExecutableFile(atPath: path) {
        return path
    }
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-lc", "command -v claude"]
    let out = Pipe()
    shell.standardOutput = out
    shell.standardError = Pipe()
    do { try shell.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    shell.waitUntilExit()
    let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let path, !path.isEmpty, fm.isExecutableFile(atPath: path) {
        return path
    }
    return nil
}

private struct OAuthCredentials {
    let accessToken: String
    let expiresAtDate: Date?
}

private func readOAuthCredentials() throws -> OAuthCredentials {
    var result: AnyObject?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw NSError(
            domain: "Keychain",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Claude Code credentials not found in Keychain. Make sure Claude Code is installed and logged in. (status \(status))"]
        )
    }
    let creds = try JSONDecoder().decode(KeychainCredentials.self, from: data)
    return OAuthCredentials(
        accessToken: creds.claudeAiOauth.accessToken,
        expiresAtDate: creds.claudeAiOauth.expiresAtDate
    )
}

private struct KeychainCredentials: Decodable {
    let claudeAiOauth: OAuthData
    struct OAuthData: Decodable {
        let accessToken: String
        // Claude Code stores this as a Unix timestamp in milliseconds.
        let expiresAt: Double?

        var expiresAtDate: Date? {
            guard let expiresAt else { return nil }
            return Date(timeIntervalSince1970: expiresAt / 1000)
        }
    }
}

private struct OAuthUsageResponse: Decodable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct UsagePeriod: Decodable {
        // Optional + defaulted so a partial response (e.g. around a reset window, or
        // an account without a given bucket) degrades gracefully instead of throwing
        // a "data couldn't be read because it is missing" decode error.
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try c.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
            resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
        }

        var resetsAtDate: Date? {
            guard let resetsAt else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: resetsAt) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: resetsAt)
        }
    }
}

private func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    guard http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? "<no body>"
        throw NSError(
            domain: "OAuthUsage",
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(200))"]
        )
    }
    return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
}
