import Foundation

final class CustomHarness: Harness {
    static func profile(title: String, commandLine: String) -> AgentProfile? {
        let parts = AgentCatalog.splitCommandLine(commandLine)
        guard let command = parts.first, !command.isEmpty else { return nil }
        return AgentProfile(
            id: "custom-\(UUID().uuidString.lowercased())",
            title: title.isEmpty ? command : title,
            subtitle: commandLine,
            command: command,
            arguments: Array(parts.dropFirst()),
            builtIn: false,
            notes: "User-defined ACP agent."
        )
    }
}
