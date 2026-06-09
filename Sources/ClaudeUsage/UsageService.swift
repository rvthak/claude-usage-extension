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
            let isAuth = error.code == 401 || error.domain == "Keychain"
            // Any auth/rate-limit failure means our cached token is suspect; drop it
            // so the next attempt re-reads the Keychain for a freshly rotated token.
            if isRateLimit || error.code == 401 { invalidateToken() }
            snapshot.error = error.localizedDescription
            snapshot.isLoading = false
            snapshot.isRateLimited = isRateLimit
            snapshot.isAuthError = isAuth
        }
    }

    /// Fetches usage, transparently retrying once with a fresh Keychain read if the
    /// access token has expired (401). The CLI rotates the token every few hours.
    private func fetchWithFreshTokenIfNeeded() async throws -> OAuthUsageResponse {
        let token = try accessToken()
        do {
            return try await fetchOAuthUsage(accessToken: token)
        } catch let error as NSError where error.code == 401 {
            // Stale token — force a re-read and try once more before surfacing the error.
            invalidateToken()
            let fresh = try accessToken()
            return try await fetchOAuthUsage(accessToken: fresh)
        }
    }

    private func accessToken() throws -> String {
        // Reuse the cached token only while it is still valid (with a safety skew).
        if let token = cachedToken, let expiry = cachedTokenExpiry,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        let creds = try readOAuthCredentials()
        cachedToken = creds.accessToken
        cachedTokenExpiry = creds.expiresAtDate
        return creds.accessToken
    }

    private func invalidateToken() {
        cachedToken = nil
        cachedTokenExpiry = nil
    }
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
