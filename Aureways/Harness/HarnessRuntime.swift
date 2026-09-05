import Foundation

@MainActor
class HarnessRuntime {
    let harness: Harness
    private(set) var connection: ACPConnection?
    private(set) var capabilities = AgentCapabilities()
    private(set) var agentInfo = ""
    private var startTask: Task<Void, Error>?
    var didSyncList = false

    var agent: AgentProfile { harness.profile }
    var canLoad: Bool { capabilities.canLoad }
    var canList: Bool { capabilities.canList }
    var canDelete: Bool { capabilities.canDelete }
    var canPersistHistory: Bool { capabilities.canPersistHistory }

    init(harness: Harness) {
        self.harness = harness
    }

    func ensureStarted(
        cwd: String,
        autoApprove: Bool,
        environment: [String: String],
        handlers: ACPHandlers
    ) async throws {
        if let connection, await connection.isActive() {
            return
        }
        if let startTask {
            try await startTask.value
            if let connection, await connection.isActive() {
                return
            }
        }
        let task = Task {
            try await launch(
                cwd: cwd,
                autoApprove: autoApprove,
                environment: environment,
                handlers: handlers
            )
        }
        startTask = task
        do {
            try await task.value
        } catch {
            if startTask == task {
                startTask = nil
            }
            throw error
        }
    }

    func shutdown() async {
        startTask?.cancel()
        startTask = nil
        let current = connection
        connection = nil
        capabilities = AgentCapabilities()
        agentInfo = ""
        didSyncList = false
        await current?.shutdown()
    }

    func markDead() {
        connection = nil
        startTask = nil
        didSyncList = false
    }

    func launch(
        cwd: String,
        autoApprove: Bool,
        environment: [String: String],
        handlers: ACPHandlers
    ) async throws {
        await connection?.shutdown()
        connection = nil
        // The harness owns its own protocol quirks; hand them to the connection.
        var handlers = handlers
        handlers.normalizeRequest = { [harness] method, params in
            harness.normalizeClientRequest(method: method, params: params)
        }
        let launched = try ACPConnection.launch(
            ACPLaunch(
                command: harness.launchCommand(),
                arguments: harness.launchArguments(autoApprove: autoApprove),
                cwd: cwd,
                environment: harness.environment(environment)
            ),
            handlers: handlers
        )
        connection = launched
        try await handshake(launched, handlers: handlers)
    }

    func handshake(_ connection: ACPConnection, handlers: ACPHandlers) async throws {
        let initResponse = try await connection.initialize()
        if let info = initResponse.agentInfo {
            agentInfo = [info.title ?? info.name, info.version].filter { !$0.isEmpty }.joined(separator: " ")
        }
        capabilities = initResponse.agentCapabilities ?? AgentCapabilities()
        if let version = initResponse.protocolVersion, version != 1 {
            await handlers.onLog("Negotiated protocol version \(version)")
        }
        if !initResponse.authMethods.isEmpty {
            let method = initResponse.authMethods[0]
            let label = method.name ?? method.id
            await handlers.onLog("Authenticating with \(label)")
            do {
                try await connection.authenticate(methodId: method.id)
            } catch {
                throw ACPError.launch("Authentication required (\(label)): \(error.localizedDescription)")
            }
        }
    }
}
