import Foundation
import SQLite3

struct SessionLink: Equatable, Sendable {
    var agentId: String
    var acpSessionId: String
    var cwd: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

struct WorkspaceRecord: Equatable, Identifiable, Sendable {
    var path: String
    var addedAt: Date
    var lastUsedAt: Date

    var id: String { path }

    var name: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    static var homePath: String {
        normalized(FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    static func isHome(_ path: String) -> Bool {
        let candidate = normalized(path)
        return !candidate.isEmpty && candidate == homePath
    }
}

enum SessionStoreError: LocalizedError {
    case open(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "Failed to open session store: \(message)"
        case .execute(let message): return message
        }
    }
}

final class SessionStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()

    static func applicationDefault() throws -> SessionStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.aureways.client", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SessionStore(url: root.appendingPathComponent("aureways.sqlite"))
    }

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
            if let handle { sqlite3_close(handle) }
            throw SessionStoreError.open(message)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS session_links (
                agent_id TEXT NOT NULL,
                acp_session_id TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (agent_id, acp_session_id)
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS session_links_updated ON session_links(agent_id, updated_at DESC);")
        try exec("""
            CREATE TABLE IF NOT EXISTS workspaces (
                path TEXT PRIMARY KEY,
                added_at REAL NOT NULL,
                last_used_at REAL NOT NULL
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS workspaces_last_used ON workspaces(last_used_at DESC);")
    }

    deinit {
        sqlite3_close(db)
    }

    func list(agentId: String? = nil) throws -> [SessionLink] {
        try locked {
            let sql: String
            if agentId == nil {
                sql = "SELECT agent_id, acp_session_id, cwd, title, created_at, updated_at FROM session_links ORDER BY updated_at DESC;"
            } else {
                sql = "SELECT agent_id, acp_session_id, cwd, title, created_at, updated_at FROM session_links WHERE agent_id = ? ORDER BY updated_at DESC;"
            }
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let agentId {
                bind(statement, 1, agentId)
            }
            var rows: [SessionLink] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(row(statement))
            }
            return rows
        }
    }

    func upsert(_ link: SessionLink) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO session_links (agent_id, acp_session_id, cwd, title, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent_id, acp_session_id) DO UPDATE SET
                    cwd = excluded.cwd,
                    title = excluded.title,
                    updated_at = excluded.updated_at;
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, link.agentId)
            bind(statement, 2, link.acpSessionId)
            bind(statement, 3, link.cwd)
            bind(statement, 4, link.title)
            sqlite3_bind_double(statement, 5, link.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, link.updatedAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    func delete(agentId: String, acpSessionId: String) throws {
        try locked {
            let statement = try prepare("DELETE FROM session_links WHERE agent_id = ? AND acp_session_id = ?;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, agentId)
            bind(statement, 2, acpSessionId)
            try stepDone(statement)
        }
    }

    func listWorkspaces() throws -> [WorkspaceRecord] {
        try locked {
            let statement = try prepare(
                "SELECT path, added_at, last_used_at FROM workspaces ORDER BY last_used_at DESC;"
            )
            defer { sqlite3_finalize(statement) }
            var rows: [WorkspaceRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    WorkspaceRecord(
                        path: string(statement, 0),
                        addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                    )
                )
            }
            return rows
        }
    }

    func insertWorkspaceIfNeeded(_ workspace: WorkspaceRecord) throws {
        try locked {
            let statement = try prepare("""
                INSERT OR IGNORE INTO workspaces (path, added_at, last_used_at)
                VALUES (?, ?, ?);
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, workspace.path)
            sqlite3_bind_double(statement, 2, workspace.addedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, workspace.lastUsedAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    func touchWorkspace(path: String, at date: Date = Date()) throws {
        try locked {
            let statement = try prepare("UPDATE workspaces SET last_used_at = ? WHERE path = ?;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            bind(statement, 2, path)
            try stepDone(statement)
        }
    }

    func deleteWorkspace(path: String) throws {
        try locked {
            let statement = try prepare("DELETE FROM workspaces WHERE path = ?;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, path)
            try stepDone(statement)
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage {
            let text = String(cString: errorMessage)
            sqlite3_free(errorMessage)
            if status != SQLITE_OK {
                throw SessionStoreError.execute(text)
            }
        } else if status != SQLITE_OK {
            throw SessionStoreError.execute(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw SessionStoreError.execute(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw SessionStoreError.execute(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func row(_ statement: OpaquePointer) -> SessionLink {
        SessionLink(
            agentId: string(statement, 0),
            acpSessionId: string(statement, 1),
            cwd: string(statement, 2),
            title: string(statement, 3),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }
}
