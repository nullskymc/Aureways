import Foundation
import Security

// The quota model lives in Quota/ProviderQuota.swift. This file keeps the
// shared networking helpers the provider adapters use.

// MARK: - Localhost Trust Session Delegate

/// Antigravity's language server presents a self-signed cert on loopback.
/// Evaluate first; only fall back to accepting that cert for 127.0.0.1 / localhost / ::1.
final class LocalhostTrustSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              Self.isLoopback(challenge.protectionSpace.host)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

// MARK: - Quota Fetcher

actor HarnessQuotaFetcher {
    static let localhostDelegate = LocalhostTrustSessionDelegate()
    static let localhostSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: localhostDelegate, delegateQueue: nil)
    }()

    static func parseDate(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let num = value as? NSNumber {
            return Date(timeIntervalSince1970: num.doubleValue)
        }
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) {
                return date
            }
            if let timestamp = Double(str) {
                return Date(timeIntervalSince1970: timestamp)
            }
        }
        return nil
    }

    /// Map Aureways agent id to normalized provider name for probing.
    static func mapAgentIdToProvider(_ agentId: String) -> String {
        switch agentId.lowercased() {
        case "codex": return "codex"
        case "claude", "claude-code": return "claude"
        case "antigravity", "gemini": return "antigravity"
        case "grok", "grok-build": return "grok"
        case "copilot", "github-copilot": return "copilot"
        case "cursor", "cursor-agent": return "cursor"
        case "opencode": return "opencode"
        default: return agentId.lowercased()
        }
    }

    /// Whether the (built-in) source config maps this harness to any quota source.
    static func supportsQuota(for agentId: String) -> Bool {
        !QuotaSourceConfig.builtIn.sourceIds(for: agentId).isEmpty
    }

    /// Maps a non-2xx response to a typed error (429 carries Retry-After).
    static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw QuotaFetchError.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 429:
            throw QuotaFetchError.rateLimited(retryAfter: parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        case 401, 403: throw QuotaFetchError.unauthorized(http.statusCode)
        default: throw QuotaFetchError.http(http.statusCode)
        }
    }

    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    static func transportError(_ error: Error) -> QuotaFetchError {
        if let typed = error as? QuotaFetchError { return typed }
        return .network(error.localizedDescription)
    }
}
