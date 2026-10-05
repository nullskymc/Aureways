import Foundation
import Security

// MARK: - Antigravity Quota Probing

extension HarnessQuotaFetcher {
    func fetchAntigravity(agent: AgentProfile) async throws -> HarnessQuotaSnapshot {
        guard let snapshot = await fetchAntigravityNative(agent: agent) else { throw QuotaFetchError.unavailable }
        return snapshot
    }

    // MARK: - Antigravity

    private struct AntigravityEndpoint {
        let port: Int
        let csrfToken: String
        let requiresCSRF: Bool
    }

    /// Local HTTPS language server from Antigravity.app / `agy` CLI.
    /// `agy_acp_server` is stdio-only and talks to CloudCode itself — do not probe it.
    static func isAntigravityProcess(_ commandLine: String) -> Bool {
        let lower = commandLine.lowercased()
        if lower.contains("agy_acp_server") {
            return false
        }
        if lower.contains("--extension_server_port") {
            return true
        }
        if lower.contains("antigravity.app") {
            return true
        }
        let separators = CharacterSet(charactersIn: "/\\ :")
        let tokens = lower.components(separatedBy: separators).filter { !$0.isEmpty }
        if tokens.contains(where: { $0 == "agy" }) {
            return true
        }
        if tokens.contains(where: { $0 == "cloudcode" || $0.hasPrefix("cloudcode") }) {
            return true
        }
        if lower.contains("language_server") {
            return lower.contains("gemini") || lower.contains("antigravity") || lower.contains("cloudcode")
        }
        return false
    }

    /// ACP consumer OAuth from `~/.gemini/antigravity-acp/acp_token.json`.
    struct AntigravityACPCredentials: Equatable, Sendable {
        var clientId: String
        var clientSecret: String
        var refreshToken: String
        var tokenURI: String
        var accessToken: String?
    }

    static func extractAntigravityACPCredentials(_ json: [String: Any]) -> AntigravityACPCredentials? {
        let nested = json["token"] as? [String: Any]
        func string(_ key: String) -> String? {
            let raw = (json[key] as? String) ?? (nested?[key] as? String)
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }
        guard let clientId = string("client_id"),
              let clientSecret = string("client_secret"),
              let refreshToken = string("refresh_token")
        else { return nil }
        return AntigravityACPCredentials(
            clientId: clientId,
            clientSecret: clientSecret,
            refreshToken: refreshToken,
            tokenURI: string("token_uri") ?? "https://oauth2.googleapis.com/token",
            accessToken: string("access_token")
        )
    }

    /// Consumer (Free / Google AI Pro / Ultra) → daily; enterprise GCP ToS → prod.
    static func antigravityCloudCodeEndpoint(usesGcpTos: Bool) -> String {
        usesGcpTos
            ? "https://cloudcode-pa.googleapis.com"
            : "https://daily-cloudcode-pa.googleapis.com"
    }

    static func parseAntigravityLoadCodeAssist(
        _ json: [String: Any]
    ) -> (project: String?, plan: String?, usesGcpTos: Bool) {
        let project = json["cloudaicompanionProject"] as? String
        let paid = json["paidTier"] as? [String: Any]
        let current = json["currentTier"] as? [String: Any]
        let plan = (paid?["name"] as? String) ?? (current?["name"] as? String)
        let usesGcpTos = (paid?["usesGcpTos"] as? Bool) ?? false
        return (project, plan, usesGcpTos)
    }

    static func antigravityACPUserAgent() -> String {
        #if arch(x86_64)
        let arch = "amd64"
        #else
        let arch = "arm64"
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.2"
        return "antigravity/acp/1.1.1 (aidev_client; os_type=darwin; arch=\(arch); host_path=aureways/\(version); proxy_client=antigravity/sdk)"
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
        if let snapshot = await fetchAntigravityACP(agent: agent) {
            return snapshot
        }

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

        return nil
    }

    private func geminiHomeDirectory() -> String {
        let env = ProcessInfo.processInfo.environment["GEMINI_HOME"]
        if let env, !env.isEmpty {
            return env
        }
        return NSString(string: "~/.gemini").expandingTildeInPath
    }

    private func loadAntigravityACPCredentials() -> AntigravityACPCredentials? {
        let tokenPath = (geminiHomeDirectory() as NSString).appendingPathComponent("antigravity-acp/acp_token.json")
        guard FileManager.default.fileExists(atPath: tokenPath),
              let tokenData = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)),
              let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let creds = Self.extractAntigravityACPCredentials(tokenJSON)
        else {
            return nil
        }
        return creds
    }

    private func formEncode(_ pairs: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = pairs.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func refreshGoogleAccessToken(_ creds: AntigravityACPCredentials) async -> String? {
        guard let url = URL(string: creds.tokenURI) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode([
            "grant_type": "refresh_token",
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "refresh_token": creds.refreshToken,
        ])
        request.timeoutInterval = 8.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("[quota] antigravity: token refresh HTTP %d", code)
                return nil
            }
            return access
        } catch {
            NSLog("[quota] antigravity: token refresh error %@", error.localizedDescription)
            return nil
        }
    }

    private func postCloudCodeJSON(url: URL, accessToken: String, body: [String: Any]) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.antigravityACPUserAgent(), forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 8.0
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }

    /// ACP has its own OAuth (`acp_token.json`) and talks to CloudCode directly.
    private func fetchAntigravityACP(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        guard let creds = loadAntigravityACPCredentials() else {
            NSLog("[quota] antigravity: no ACP credentials at antigravity-acp/acp_token.json")
            return nil
        }
        guard let accessToken = await refreshGoogleAccessToken(creds) else {
            return nil
        }

        let bootstrap = {
            if let override = ProcessInfo.processInfo.environment["AGY_ACP_CCPA_BASE_URL"], !override.isEmpty {
                return override.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return "https://cloudcode-pa.googleapis.com"
        }()

        guard let loadURL = URL(string: "\(bootstrap)/v1internal:loadCodeAssist") else { return nil }
        do {
            let load = try await postCloudCodeJSON(
                url: loadURL,
                accessToken: accessToken,
                body: ["metadata": ["ideType": "ANTIGRAVITY"]]
            )
            guard (200...299).contains(load.status),
                  let loadJSON = try JSONSerialization.jsonObject(with: load.data) as? [String: Any]
            else {
                NSLog("[quota] antigravity: loadCodeAssist HTTP %d", load.status)
                return nil
            }

            let loaded = Self.parseAntigravityLoadCodeAssist(loadJSON)
            guard let project = loaded.project, !project.isEmpty else {
                NSLog("[quota] antigravity: loadCodeAssist missing cloudaicompanionProject")
                return nil
            }

            let endpoint = Self.antigravityCloudCodeEndpoint(usesGcpTos: loaded.usesGcpTos)
            guard let quotaURL = URL(string: "\(endpoint)/v1internal:retrieveUserQuotaSummary") else { return nil }
            let quota = try await postCloudCodeJSON(
                url: quotaURL,
                accessToken: accessToken,
                body: ["project": project]
            )
            guard (200...299).contains(quota.status) else {
                NSLog("[quota] antigravity: retrieveUserQuotaSummary HTTP %d", quota.status)
                return nil
            }
            guard let (primary, secondary, extras) = Self.parseAntigravityQuotaSummary(quota.data, agentId: agent.id) else {
                NSLog("[quota] antigravity: quota summary parse failed")
                return nil
            }

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: loaded.plan,
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
            NSLog("[quota] antigravity: ACP CloudCode error %@", error.localizedDescription)
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
}
