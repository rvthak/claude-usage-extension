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
}

final class UsageService: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    private var cachedToken: String?

    @MainActor
    func fetch() async {
        snapshot.isLoading = true
        do {
            let token = try accessToken()
            let response = try await fetchOAuthUsage(accessToken: token)
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
            if isRateLimit { cachedToken = nil }
            snapshot.error = error.localizedDescription
            snapshot.isLoading = false
            snapshot.isRateLimited = isRateLimit
        }
    }

    private func accessToken() throws -> String {
        if let token = cachedToken { return token }
        let token = try readOAuthAccessToken()
        cachedToken = token
        return token
    }
}

private func readOAuthAccessToken() throws -> String {
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
    return creds.claudeAiOauth.accessToken
}

private struct KeychainCredentials: Decodable {
    let claudeAiOauth: OAuthData
    struct OAuthData: Decodable {
        let accessToken: String
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
        let utilization: Double
        let resetsAt: String

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var resetsAtDate: Date? {
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
