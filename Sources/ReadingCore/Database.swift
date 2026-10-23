import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif

public enum StorageError: Error, LocalizedError {
    case database(String), invalidArchive(String)
    public var errorDescription: String? { switch self { case .database(let s), .invalidArchive(let s): return s } }
}
public final class Database {
    private var db: OpaquePointer?
    public init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path,&db,flags|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else { throw StorageError.database("Cannot open database") }
        sqlite3_busy_timeout(db,5000)
        if !readOnly { try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;") }
    }
    deinit { sqlite3_close(db) }
    public func execute(_ sql: String, values: [String] = []) throws {
        if values.isEmpty {
            guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw failure() }; return
        }
        let statement=try prepare(sql,values:values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement)==SQLITE_DONE else { throw failure() }
    }
    public func rows(_ sql: String, values: [String] = []) throws -> [[String]] {
        let s=try prepare(sql,values:values); defer { sqlite3_finalize(s) }
        var result:[[String]]=[]
        while true {
            let status=sqlite3_step(s)
            if status==SQLITE_DONE { return result }
            guard status==SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(s)).map { i in sqlite3_column_text(s,i).map{String(cString:$0)} ?? "" })
        }
    }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result=try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, values: [String]) throws -> OpaquePointer {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK, let s=statement else { throw failure() }
        for (i,v) in values.enumerated() {
            if sqlite3_bind_text(s,Int32(i+1),v,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) != SQLITE_OK { sqlite3_finalize(s); throw failure() }
        }
        return s
    }
    private func failure() -> StorageError { .database(db.map{String(cString:sqlite3_errmsg($0))} ?? "Database unavailable") }
}
public final class LibraryStore {
    private let database: Database
    public init(url: URL) throws {
        database=try Database(url:url)
        try database.execute("CREATE TABLE IF NOT EXISTS library(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, payload TEXT NOT NULL);")
    }
    public func load() throws -> LibraryState {
        guard let row=try database.rows("SELECT version,payload FROM library WHERE id=1").first else { return LibraryState() }
        guard row[0]=="1" else { throw StorageError.invalidArchive("Unsupported library version. Update the app before opening it.") }
        return try JSONDecoder().decode(LibraryState.self,from:Data(row[1].utf8))
    }
    public func save(_ state: LibraryState) throws {
        let payload=String(decoding:try JSONEncoder().encode(state),as:UTF8.self)
        try database.transaction { try database.execute("INSERT INTO library VALUES(1,1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",values:[payload]) }
    }
}
