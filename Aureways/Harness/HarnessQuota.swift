import Foundation
import Observation
import Security

// MARK: - Quota Severity

enum HarnessQuotaSeverity: String, Sendable, Codable, Comparable {
    case healthy
    case warning
    case critical
    case unknown

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .healthy: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: HarnessQuotaSeverity, rhs: HarnessQuotaSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Quota Rate Window

struct HarnessQuotaWindow: Identifiable, Sendable, Codable, Hashable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    var resetDescription: String?
    var windowMinutes: Int?

    var remainingPercent: Double {
        max(0.0, min(100.0, 100.0 - usedPercent))
    }

    var severity: HarnessQuotaSeverity {
        if remainingPercent <= 5.0 {
            return .critical
        } else if remainingPercent <= 20.0 {
            return .warning
        } else {
            return .healthy
        }
    }

    var countdownDescription: String? {
        if let resetDescription, !resetDescription.isEmpty {
            return resetDescription
        }
        guard let resetsAt else { return nil }
        let now = Date()
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 {
            return "已重置"
        }
        let totalMinutes = Int(ceil(interval / 60.0))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days) 天 \(hours) 小时后重置"
        } else if hours > 0 {
            return "\(hours) 小时 \(minutes) 分后重置"
        } else {
            return "\(max(1, minutes)) 分钟后重置"
        }
    }
}

// MARK: - Quota Breakdown Item

struct HarnessQuotaBreakdownItem: Identifiable, Sendable, Codable, Hashable {
    var id: String
    var title: String
    var usedPercent: Double
}

// MARK: - Quota Snapshot

struct HarnessQuotaSnapshot: Identifiable, Sendable, Codable, Hashable {
    var id: String { harnessId }
    var harnessId: String
    var providerTitle: String
    var planType: String?
    var accountEmail: String?
    var primaryWindow: HarnessQuotaWindow?
    var secondaryWindow: HarnessQuotaWindow?
    var extraWindows: [HarnessQuotaWindow] = []
    var usageBreakdown: [HarnessQuotaBreakdownItem] = []
    var creditsRemaining: Double?
    var creditsUnit: String?
    var resetCreditsAvailable: Int?
    var updatedAt: Date
    var error: String?

    var overallSeverity: HarnessQuotaSeverity {
        var highest: HarnessQuotaSeverity = .healthy
        if let primary = primaryWindow, primary.severity > highest {
            highest = primary.severity
        }
        if let secondary = secondaryWindow, secondary.severity > highest {
            highest = secondary.severity
        }
        for extra in extraWindows where extra.severity > highest {
            highest = extra.severity
        }
        return highest
    }

    var mostUrgentWindow: HarnessQuotaWindow? {
        var candidate = primaryWindow
        for window in [secondaryWindow].compactMap({ $0 }) + extraWindows {
            if let current = candidate {
                if window.remainingPercent < current.remainingPercent {
                    candidate = window
                }
            } else {
                candidate = window
            }
        }
        return candidate
    }

    var shortSummary: String {
        if let urgent = mostUrgentWindow {
            let pct = Int(round(urgent.remainingPercent))
            return "\(pct)%"
        }
        if let credits = creditsRemaining {
            return String(format: "%.0f", credits)
        }
        return "正常"
    }
}

// MARK: - Localhost Trust Session Delegate

/// Antigravity's language server presents a self-signed cert on loopback.
/// Evaluate first; only fall back to accepting that cert for 127.0.0.1 / localhost / ::1.
private final class LocalhostTrustSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
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
    private static let localhostDelegate = LocalhostTrustSessionDelegate()
    private static let localhostSession: URLSession = {
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

    static func supportsQuota(for agentId: String) -> Bool {
        switch mapAgentIdToProvider(agentId) {
        case "antigravity", "codex", "grok":
            return true
        default:
            return false
        }
    }

    func fetchQuota(for agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let provider = Self.mapAgentIdToProvider(agent.id)

        switch provider {
        case "antigravity":
            return await fetchAntigravityNative(agent: agent)
        case "codex":
            return await fetchCodexNative(agent: agent)
        case "grok":
            return await fetchGrokNative(agent: agent)
        default:
            return nil
        }
    }

    // MARK: - Antigravity

    private struct AntigravityEndpoint {
        let port: Int
        let csrfToken: String
        let requiresCSRF: Bool
    }

    /// ps + lsof: the language server does not publish a stable port file.
    static func isAntigravityProcess(_ commandLine: String) -> Bool {
        let lower = commandLine.lowercased()
        if lower.contains("--extension_server_port") {
            return true
        }
        let separators = CharacterSet(charactersIn: "/\\ :")
        let tokens = lower.components(separatedBy: separators).filter { !$0.isEmpty }
        if tokens.contains(where: { $0 == "antigravity" || $0.hasPrefix("antigravity") }) {
            return true
        }
        if tokens.contains(where: { $0 == "cloudcode" || $0.hasPrefix("cloudcode") }) {
            return true
        }
        if tokens.contains("agy") {
            return true
        }
        if lower.contains("language_server") {
            return lower.contains("gemini") || lower.contains("antigravity") || lower.contains("cloudcode")
        }
        return false
    }

    private func findAntigravityEndpoints() async -> [AntigravityEndpoint] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let psProcess = Process()
                psProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
                psProcess.arguments = ["-ax", "-o", "pid=,command="]
                psProcess.environment = ProcessInfo.processInfo.environment

                let stdoutPipe = Pipe()
                psProcess.standardOutput = stdoutPipe
                psProcess.standardError = Pipe()

                do {
                    try psProcess.run()
                    let psData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    psProcess.waitUntilExit()

                    guard let psOutput = String(data: psData, encoding: .utf8) else {
                        continuation.resume(returning: [])
                        return
                    }

                    var pidsWithPorts: [(pid: Int, port: Int, csrf: String)] = []

                    for line in psOutput.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        guard Self.isAntigravityProcess(trimmed) else { continue }

                        let scanner = Scanner(string: trimmed)
                        guard let pid = scanner.scanInt() else { continue }

                        var port: Int? = nil
                        var csrf = ""

                        let components = trimmed.components(separatedBy: .whitespaces)
                        for (idx, comp) in components.enumerated() {
                            if comp.contains("--extension_server_port=") {
                                let parts = comp.components(separatedBy: "=")
                                if parts.count > 1, let p = Int(parts[1]) {
                                    port = p
                                }
                            } else if comp == "--extension_server_port", idx + 1 < components.count {
                                port = Int(components[idx + 1])
                            } else if comp.contains("--csrf_token=") {
                                let parts = comp.components(separatedBy: "=")
                                if parts.count > 1 {
                                    csrf = parts[1]
                                }
                            } else if comp == "--csrf_token", idx + 1 < components.count {
                                csrf = components[idx + 1]
                            }
                        }

                        if let p = port {
                            pidsWithPorts.append((pid: pid, port: p, csrf: csrf))
                        } else {
                            let lsofPorts = Self.discoverListeningPorts(forPid: pid)
                            for lp in lsofPorts {
                                pidsWithPorts.append((pid: pid, port: lp, csrf: csrf))
                            }
                        }
                    }

                    var endpoints: [AntigravityEndpoint] = []
                    var seenPorts = Set<Int>()

                    for item in pidsWithPorts {
                        guard !seenPorts.contains(item.port) else { continue }
                        seenPorts.insert(item.port)
                        endpoints.append(AntigravityEndpoint(port: item.port, csrfToken: item.csrf, requiresCSRF: !item.csrf.isEmpty))
                    }

                    continuation.resume(returning: endpoints)
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private static func discoverListeningPorts(forPid pid: Int) -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-i", "TCP", "-s", "TCP:LISTEN", "-F", "n"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return [] }
            var ports: [Int] = []
            for line in output.components(separatedBy: .newlines) {
                if line.hasPrefix("n") {
                    let address = String(line.dropFirst())
                    if let colonIdx = address.lastIndex(of: ":") {
                        let portStr = String(address[address.index(after: colonIdx)...])
                        if let port = Int(portStr) {
                            ports.append(port)
                        }
                    }
                }
            }
            return ports
        } catch {
            return []
        }
    }

    private func sendAntigravityRequest(path: String, body: [String: Any], endpoint: AntigravityEndpoint) async throws -> Data {
        guard let url = URL(string: "https://127.0.0.1:\(endpoint.port)\(path)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        if !endpoint.csrfToken.isEmpty {
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-CSRF-Token")
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Code-Assist-Csrf-Token")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.localhostSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func looksLikeAntigravityUserStatus(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if json["userStatus"] != nil { return true }
        if json["email"] != nil { return true }
        if json["userTier"] != nil { return true }
        if json["planStatus"] != nil { return true }
        if let response = json["response"] as? [String: Any] {
            return response["userStatus"] != nil || response["email"] != nil
        }
        return false
    }

    private func probeAntigravityEndpoint(_ endpoint: AntigravityEndpoint, agent: AgentProfile) async -> (email: String?, plan: String?, models: [HarnessQuotaWindow])? {
        guard let userData = try? await sendAntigravityRequest(
            path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
            body: [
                "metadata": [
                    "ideName": "antigravity",
                    "extensionName": "antigravity",
                    "ideVersion": "unknown",
                    "locale": "en"
                ]
            ],
            endpoint: endpoint
        ), looksLikeAntigravityUserStatus(userData) else {
            return nil
        }
        return Self.parseAntigravityUserStatus(userData, agentId: agent.id)
    }

    private func fetchAntigravityNative(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let endpoints = await findAntigravityEndpoints()

        for endpoint in endpoints {
            guard let probed = await probeAntigravityEndpoint(endpoint, agent: agent) else {
                continue
            }

            var primaryWindow: HarnessQuotaWindow? = nil
            var secondaryWindow: HarnessQuotaWindow? = nil
            var extraWindows: [HarnessQuotaWindow] = []

            if let quotaData = try? await sendAntigravityRequest(
                path: "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
                body: ["forceRefresh": true],
                endpoint: endpoint
            ), let (p, s, extras) = Self.parseAntigravityQuotaSummary(quotaData, agentId: agent.id) {
                primaryWindow = p
                secondaryWindow = s
                extraWindows = extras
            }

            if primaryWindow == nil && !probed.models.isEmpty {
                primaryWindow = probed.models.first
                if probed.models.count > 1 {
                    extraWindows.append(contentsOf: probed.models.dropFirst())
                }
            }

            guard primaryWindow != nil || secondaryWindow != nil || !extraWindows.isEmpty else {
                continue
            }

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: probed.plan,
                accountEmail: probed.email,
                primaryWindow: primaryWindow,
                secondaryWindow: secondaryWindow,
                extraWindows: extraWindows,
                usageBreakdown: [],
                creditsRemaining: nil,
                creditsUnit: nil,
                resetCreditsAvailable: nil,
                updatedAt: Date()
            )
        }

        return await fetchAntigravityCloudCode(agent: agent)
    }

    private func fetchAntigravityCloudCode(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let tokenPath = NSString(string: "~/.gemini/jetski-standalone-oauth-token").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: tokenPath),
              let tokenData = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)),
              let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let tokenDict = tokenJSON["token"] as? [String: Any],
              let accessToken = tokenDict["access_token"] as? String,
              !accessToken.isEmpty
        else {
            return nil
        }

        let authMethod = tokenJSON["auth_method"] as? String

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aureways/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }

            var primary: HarnessQuotaWindow? = nil
            var secondary: HarnessQuotaWindow? = nil
            var extras: [HarnessQuotaWindow] = []

            if let buckets = json["buckets"] as? [[String: Any]] {
                for (idx, bucket) in buckets.enumerated() {
                    let title = bucket["modelName"] as? String ?? bucket["title"] as? String ?? "Model Limit"
                    let used = (bucket["usedPercent"] as? NSNumber)?.doubleValue ?? 0.0
                    let resetsAt = Self.parseDate(bucket["resetsAt"] ?? bucket["resetTime"])
                    let win = HarnessQuotaWindow(
                        id: "agy-window-\(idx)",
                        title: title,
                        usedPercent: used,
                        resetsAt: resetsAt,
                        resetDescription: nil,
                        windowMinutes: nil
                    )
                    if primary == nil {
                        primary = win
                    } else if secondary == nil {
                        secondary = win
                    } else {
                        extras.append(win)
                    }
                }
            }

            guard primary != nil || secondary != nil || !extras.isEmpty else {
                return nil
            }

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: authMethod,
                accountEmail: nil,
                primaryWindow: primary,
                secondaryWindow: secondary,
                extraWindows: extras,
                usageBreakdown: [],
                creditsRemaining: nil,
                creditsUnit: nil,
                resetCreditsAvailable: nil,
                updatedAt: Date()
            )
        } catch {
            return nil
        }
    }

    static func parseAntigravityQuotaSummary(_ data: Data, agentId: String) -> (primary: HarnessQuotaWindow?, secondary: HarnessQuotaWindow?, extras: [HarnessQuotaWindow])? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let payload = (json["response"] as? [String: Any]) ?? (json["summary"] as? [String: Any]) ?? json
        guard let groups = payload["groups"] as? [[String: Any]], !groups.isEmpty else {
            return nil
        }

        var primary: HarnessQuotaWindow? = nil
        var secondary: HarnessQuotaWindow? = nil
        var extras: [HarnessQuotaWindow] = []

        for group in groups {
            let groupName = (group["displayName"] as? String) ?? "Quota"
            let isGeminiGroup = groupName.lowercased().contains("gemini")
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }

            for bucket in buckets {
                let disabled = (bucket["disabled"] as? Bool) ?? false
                guard !disabled else { continue }

                var remainingFraction: Double? = nil
                if let frac = (bucket["remainingFraction"] as? NSNumber)?.doubleValue {
                    remainingFraction = frac
                } else if let remDict = bucket["remaining"] as? [String: Any],
                          let frac = (remDict["remainingFraction"] as? NSNumber)?.doubleValue {
                    remainingFraction = frac
                }
                guard let remaining = remainingFraction else { continue }

                let usedPercent = max(0.0, min(100.0, (1.0 - remaining) * 100.0))
                let bucketId = (bucket["bucketId"] as? String) ?? UUID().uuidString
                let bucketName = (bucket["displayName"] as? String) ?? bucketId
                let resetTime = parseDate(bucket["resetTime"])
                let resetDesc = bucket["description"] as? String
                let windowKind = (bucket["window"] as? String)?.lowercased()

                let is5h = windowKind == "5h" || bucketId.contains("5h") || bucketName.contains("5") || bucketName.contains("Five")
                let isWeekly = windowKind == "weekly" || bucketId.contains("weekly") || bucketName.contains("Weekly")
                let windowMinutes = is5h ? 300 : (isWeekly ? 10080 : nil)

                let windowTitle: String
                if isGeminiGroup {
                    windowTitle = is5h ? "Gemini 5-hour" : (isWeekly ? "Gemini Weekly" : "Gemini \(bucketName)")
                } else {
                    windowTitle = is5h ? "Claude & GPT 5-hour" : (isWeekly ? "Claude & GPT Weekly" : "\(groupName) \(bucketName)")
                }

                let window = HarnessQuotaWindow(
                    id: "\(agentId)-\(bucketId)",
                    title: windowTitle,
                    usedPercent: usedPercent,
                    resetsAt: resetTime,
                    resetDescription: resetDesc,
                    windowMinutes: windowMinutes
                )

                if isGeminiGroup {
                    if is5h {
                        primary = window
                    } else if isWeekly {
                        secondary = window
                    } else {
                        extras.append(window)
                    }
                } else {
                    extras.append(window)
                }
            }
        }

        if primary != nil || secondary != nil || !extras.isEmpty {
            return (primary, secondary, extras)
        }
        return nil
    }

    static func parseAntigravityUserStatus(_ data: Data, agentId: String) -> (email: String?, plan: String?, models: [HarnessQuotaWindow]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, [])
        }

        let userStatus = json["userStatus"] as? [String: Any]
        let email = userStatus?["email"] as? String

        let userTier = userStatus?["userTier"] as? [String: Any]
        let planStatus = userStatus?["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]

        let planName = (userTier?["name"] as? String) ?? (planInfo?["planDisplayName"] as? String) ?? (planInfo?["planName"] as? String)

        var modelWindows: [HarnessQuotaWindow] = []
        if let cascadeData = userStatus?["cascadeModelConfigData"] as? [String: Any],
           let configs = cascadeData["clientModelConfigs"] as? [[String: Any]] {
            for config in configs {
                guard let quota = config["quotaInfo"] as? [String: Any],
                      let remFrac = (quota["remainingFraction"] as? NSNumber)?.doubleValue
                else { continue }

                let label = (config["label"] as? String) ?? "Model"
                let resetDate = parseDate(quota["resetTime"])
                let used = max(0.0, min(100.0, (1.0 - remFrac) * 100.0))

                modelWindows.append(
                    HarnessQuotaWindow(
                        id: "\(agentId)-\(label)",
                        title: label,
                        usedPercent: used,
                        resetsAt: resetDate,
                        resetDescription: nil,
                        windowMinutes: nil
                    )
                )
            }
        }

        return (email, planName, modelWindows)
    }

    // MARK: - Native Grok Quota Probing

    private func fetchGrokNative(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let authPath = NSString(string: "~/.grok/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath),
              let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let firstEntry = authJSON.values.first as? [String: Any],
              let token = (firstEntry["key"] as? String) ?? (firstEntry["refresh_token"] as? String) ?? (firstEntry["access_token"] as? String),
              !token.isEmpty
        else {
            return nil
        }

        let email = firstEntry["email"] as? String
        let authMode = firstEntry["auth_mode"] as? String

        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok/1.0 (Aureways)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = json["config"] as? [String: Any]
            else {
                return nil
            }

            var usedPercent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue
            if usedPercent == nil {
                if let onDemandUsed = (config["onDemandUsed"] as? [String: Any])?["val"] as? NSNumber,
                   let onDemandCap = (config["onDemandCap"] as? [String: Any])?["val"] as? NSNumber,
                   onDemandCap.doubleValue > 0 {
                    usedPercent = (onDemandUsed.doubleValue / onDemandCap.doubleValue) * 100.0
                }
            }
            let totalUsed = usedPercent ?? 0.0

            var resetsAt: Date? = nil
            if let currentPeriod = config["currentPeriod"] as? [String: Any] {
                resetsAt = Self.parseDate(currentPeriod["end"])
            } else if let endStr = config["billingPeriodEnd"] as? String {
                resetsAt = Self.parseDate(endStr)
            }

            let primaryWindow = HarnessQuotaWindow(
                id: "grok-weekly-window",
                title: "共享周限额 (Weekly)",
                usedPercent: totalUsed,
                resetsAt: resetsAt,
                resetDescription: nil,
                windowMinutes: 10080
            )

            var breakdown: [HarnessQuotaBreakdownItem] = []
            if let productUsage = config["productUsage"] as? [[String: Any]] {
                for item in productUsage {
                    if let product = item["product"] as? String,
                       let usage = (item["usagePercent"] as? NSNumber)?.doubleValue {
                        let friendlyTitle: String
                        switch product.lowercased() {
                        case "grokbuild": friendlyTitle = "Grok Build"
                        case "grokchat": friendlyTitle = "Grok Chat"
                        case "grokimagine": friendlyTitle = "Grok Imagine"
                        default: friendlyTitle = product
                        }
                        breakdown.append(
                            HarnessQuotaBreakdownItem(
                                id: "grok-\(product.lowercased())",
                                title: friendlyTitle,
                                usedPercent: usage
                            )
                        )
                    }
                }
            }

            let planTitle = authMode?.lowercased() == "oidc" ? "SuperGrok" : (authMode ?? "xAI Grok")

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: planTitle,
                accountEmail: email,
                primaryWindow: primaryWindow,
                secondaryWindow: nil,
                extraWindows: [],
                usageBreakdown: breakdown,
                creditsRemaining: nil,
                creditsUnit: nil,
                resetCreditsAvailable: nil,
                updatedAt: Date()
            )
        } catch {
            return nil
        }
    }

    // MARK: - Native Codex Quota Probing

    private func parseCodexWindow(_ dict: [String: Any]?, id: String = UUID().uuidString, defaultTitle: String) -> HarnessQuotaWindow? {
        guard let dict, let used = (dict["used_percent"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let resetsAt = Self.parseDate(dict["reset_at"])
        let windowSec = dict["limit_window_seconds"] as? Int
        let windowMin = windowSec.map { $0 / 60 }

        return HarnessQuotaWindow(
            id: id,
            title: defaultTitle,
            usedPercent: used,
            resetsAt: resetsAt,
            resetDescription: nil,
            windowMinutes: windowMin
        )
    }

    static func extractCodexAuth(_ authJSON: [String: Any]) -> (token: String, accountId: String?, email: String?, planType: String?)? {
        let tokens = authJSON["tokens"] as? [String: Any]
        let token = (tokens?["access_token"] as? String)
            ?? (authJSON["access_token"] as? String)
            ?? (authJSON["token"] as? String)
        guard let token, !token.isEmpty else { return nil }
        let accountId = (tokens?["account_id"] as? String) ?? (authJSON["account_id"] as? String)
        let email = (tokens?["email"] as? String) ?? (authJSON["email"] as? String)
        let planType = (tokens?["plan_type"] as? String) ?? (authJSON["plan_type"] as? String)
        return (token, accountId, email, planType)
    }

    private func fetchCodexNative(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath),
              let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let auth = Self.extractCodexAuth(authJSON)
        else {
            return nil
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        if let accountId = auth.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex/1.0 (Aureways)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }

            let email = (json["email"] as? String) ?? auth.email
            let planType = (json["plan_type"] as? String) ?? auth.planType

            var primary: HarnessQuotaWindow? = nil
            var secondary: HarnessQuotaWindow? = nil
            var extras: [HarnessQuotaWindow] = []

            if let rateLimit = json["rate_limit"] as? [String: Any] {
                primary = parseCodexWindow(rateLimit["primary_window"] as? [String: Any], id: "codex-primary", defaultTitle: "主限额 (Session)")
                secondary = parseCodexWindow(rateLimit["secondary_window"] as? [String: Any], id: "codex-secondary", defaultTitle: "周限额 (Weekly)")
            }

            if let codeReview = json["code_review_rate_limit"] as? [String: Any],
               let win = parseCodexWindow(codeReview["primary_window"] as? [String: Any], id: "codex-code-review", defaultTitle: "代码审查限额") {
                extras.append(win)
            }

            if let additional = json["additional_rate_limits"] as? [[String: Any]] {
                for item in additional {
                    let title = (item["limit_name"] as? String) ?? "额外限额"
                    if let win = parseCodexWindow(item["rate_limit"] as? [String: Any], id: UUID().uuidString, defaultTitle: title) {
                        extras.append(win)
                    }
                }
            }

            var creditsVal: Double? = nil
            var creditsUnit: String? = nil
            if let creditsDict = json["credits"] as? [String: Any] {
                if let balance = (creditsDict["balance"] as? NSNumber)?.doubleValue {
                    creditsVal = balance
                } else if let balance = creditsDict["balance"] as? String, let parsed = Double(balance) {
                    creditsVal = parsed
                }
                if creditsVal != nil {
                    creditsUnit = creditsDict["unit"] as? String ?? "Credits"
                }
            }

            var resetsAvail: Int? = nil
            if let resetsDict = json["resets"] as? [String: Any] {
                resetsAvail = (resetsDict["available"] as? NSNumber)?.intValue
            }
            if resetsAvail == nil, let resetCreditsDict = json["rate_limit_reset_credits"] as? [String: Any] {
                resetsAvail = (resetCreditsDict["available_count"] as? NSNumber)?.intValue
                    ?? resetCreditsDict["available_count"] as? Int
            }

            guard primary != nil || secondary != nil || !extras.isEmpty || creditsVal != nil else {
                return nil
            }

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: planType?.capitalized,
                accountEmail: email,
                primaryWindow: primary,
                secondaryWindow: secondary,
                extraWindows: extras,
                usageBreakdown: [],
                creditsRemaining: creditsVal,
                creditsUnit: creditsUnit,
                resetCreditsAvailable: resetsAvail,
                updatedAt: Date()
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Quota State Service

@Observable
@MainActor
final class HarnessQuotaService {
    private(set) var snapshots: [String: HarnessQuotaSnapshot] = [:]
    private(set) var isRefreshing: [String: Bool] = [:]
    private var lastFetchTimes: [String: Date] = [:]
    private let cacheTTL: TimeInterval = 60.0
    private let fetcher = HarnessQuotaFetcher()
    private static let persistKey = "harnessQuotaSnapshots"

    init(loadPersisted: Bool = true) {
        if loadPersisted { self.loadPersisted() }
    }

    func snapshot(for agentId: String) -> HarnessQuotaSnapshot? {
        snapshots[agentId]
    }

    func updateSnapshot(_ snapshot: HarnessQuotaSnapshot) {
        snapshots[snapshot.harnessId] = snapshot
        persist()
    }

    func refreshQuota(for agent: AgentProfile, force: Bool = false) async {
        let agentId = agent.id
        guard HarnessQuotaFetcher.supportsQuota(for: agentId) else { return }

        if !force, let lastFetch = lastFetchTimes[agentId], Date().timeIntervalSince(lastFetch) < cacheTTL {
            return
        }
        if isRefreshing[agentId] == true { return }

        isRefreshing[agentId] = true
        defer { isRefreshing[agentId] = false }

        let snapshot = await fetcher.fetchQuota(for: agent)
        lastFetchTimes[agentId] = Date()
        if let snapshot {
            snapshots[agentId] = snapshot
            persist()
        }
    }

    func refreshAll(agents: [AgentProfile], force: Bool = false) async {
        for agent in agents where HarnessQuotaFetcher.supportsQuota(for: agent.id) {
            await refreshQuota(for: agent, force: force)
        }
    }

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let decoded = try? JSONDecoder().decode([String: HarnessQuotaSnapshot].self, from: data)
        else { return }
        snapshots = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistKey)
    }
}
