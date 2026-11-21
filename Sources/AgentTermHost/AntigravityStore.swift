#if os(macOS)
import Foundation
import SQLite3

/// Antigravity's own list of its conversations (#224): since 1.0.16 a
/// SQLite store, `~/.gemini/antigravity-cli/conversation_summaries.db`,
/// with a row for each conversation in its table `conversation_summaries`.
/// Antigravity 1.5.12 writes no `cache/conversation_metadata.json` at all.
///
/// It is only ever read. Antigravity keeps it in SQLite's write-ahead mode
/// (its header says so), and with no Antigravity running the one file is
/// there, without its `-wal` and `-shm`. Tried with the system's SQLite
/// 3.54.0 on a copy, 2026-11-21: opened read-only the ordinary way it is
/// not read at all ("unable to open database file"), and opened so that
/// it can be, SQLite makes the two files beside it and takes locks in
/// them, which a checkpoint of Antigravity's then has to wait behind. So
/// it is opened read-only with `immutable=1`: SQLite then reads the one
/// file, makes nothing beside it and takes no lock at all, and nothing
/// here can be in Antigravity's way. The price: what Antigravity has
/// written to its `-wal` and not yet brought into the store is not seen.
/// Its changelog says it brings it in when it exits, so a conversation of
/// a session still running may be listed late, or with the title and time
/// it had before. A store that changed while it was read is read again.
enum AntigravityStore {
    struct Row: Equatable {
        var id: String
        var title: String
        var preview: String
        /// As written: "2026-11-20 01:02:03.123456+07:00".
        var modified: String
        /// A JSON list of `file://` addresses.
        var workspaces: String
    }

    enum Reading: Equatable {
        /// No store: an Antigravity before 1.0.16, or none.
        case none
        case rows([Row])
        /// There, and not read: why, for the user.
        case unreadable(String)
    }

    static let table = "conversation_summaries"
    /// The columns History is made of. A store without one of them is of a
    /// version not known here, and is said to be, not guessed at.
    static let columns = ["conversation_id", "title", "preview", "last_modified_time", "workspace_uris"]

    static func file(in home: URL) -> URL {
        home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
    }

    /// What the store lists. Tried again, briefly, when it changed while
    /// it was read or SQLite could not read it: a tenth of a second in
    /// all, and then it is said, never waited on.
    static func read(home: URL, tries: Int = 3, pause: TimeInterval = 0.05) -> Reading {
        let file = file(in: home)
        guard FileManager.default.fileExists(atPath: file.path) else { return .none }
        var reading = Reading.unreadable(changed)
        for attempt in 0..<max(tries, 1) {
            if attempt > 0 { Thread.sleep(forTimeInterval: pause) }
            let before = stamp(of: file)
            let once = readOnce(file)
            // Read without a lock, so only as good as the file was still:
            // Antigravity writes to it when it checkpoints.
            guard before != nil, before == stamp(of: file) else {
                reading = .unreadable(changed)
                continue
            }
            reading = once.reading
            if !once.again { break }
        }
        return reading
    }

    private static let changed = "Antigravity was writing to it each time it was read."

    private static func stamp(of file: URL) -> [String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        return [String(describing: attributes[.size]), String(describing: attributes[.modificationDate]), String(describing: attributes[.systemFileNumber])]
    }

    /// `again` when another try may read what this one could not.
    private static func readOnce(_ file: URL) -> (reading: Reading, again: Bool) {
        // The file's address with its path escaped, as SQLite reads one.
        let address = file.absoluteString + "?mode=ro&immutable=1"
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(address, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(opened) }
        guard result == SQLITE_OK, let database = opened else { return (.unreadable(reason(opened, result)), true) }
        sqlite3_busy_timeout(database, 100)

        // Its columns first: what is asked for below is known to be there.
        var statement: OpaquePointer?
        var prepared = sqlite3_prepare_v2(database, "SELECT name FROM pragma_table_info('\(table)')", -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            sqlite3_finalize(statement)
            return (.unreadable(reason(database, prepared)), true)
        }
        var found: Set<String> = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let name = text(statement, 0) { found.insert(name) }
            step = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        guard step == SQLITE_DONE else { return (.unreadable(reason(database, step)), true) }
        let missing = columns.filter { !found.contains($0) }
        guard missing.isEmpty else {
            let what = found.isEmpty ? "It has no table “\(table)”" : "Its table “\(table)” has no “\(missing.joined(separator: "”, “"))”"
            return (.unreadable(what + ", so it is not of a version of Antigravity that AgentTerm knows."), false)
        }

        statement = nil
        prepared = sqlite3_prepare_v2(database, "SELECT \(columns.joined(separator: ", ")) FROM \(table)", -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            sqlite3_finalize(statement)
            return (.unreadable(reason(database, prepared)), true)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            // A row that is not as expected is left out, as a line of
            // another agent's file is.
            if let id = text(statement, 0), let modified = text(statement, 3), let workspaces = text(statement, 4) {
                rows.append(Row(id: id, title: text(statement, 1) ?? "", preview: text(statement, 2) ?? "", modified: modified, workspaces: workspaces))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return (.unreadable(reason(database, step)), true) }
        return (.rows(rows), false)
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    /// SQLite's own words for what went wrong, as a sentence.
    private static func reason(_ database: OpaquePointer?, _ code: Int32) -> String {
        let said = database.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
        switch code & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED: return "It is in use (\(said))."
        case SQLITE_NOTADB, SQLITE_CORRUPT: return "It is not a database that can be read (\(said))."
        default: return "SQLite said: \(said)."
        }
    }
}
#endif
