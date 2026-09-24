import GRDB
import MCP

// Read-only diagnostics against an in-memory database; no archive schema or MCP surface.
let database = try DatabaseQueue()
try database.read { db in
    print("sqlite_version=\(try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown")")
    for option in try String.fetchAll(db, sql: "PRAGMA compile_options").sorted() {
        print(option)
    }
}
