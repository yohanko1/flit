import Foundation
import SQLite3

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var double: Double? {
        switch self {
        case .real(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    var string: String? { if case .text(let v) = self { return v }; return nil }
    var data: Data? { if case .blob(let v) = self { return v }; return nil }

    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ d: Data?) { self = d.map { .blob($0) } ?? .null }
}

/// The few lines of SQLite flit needs. The library ships with macOS.
final class SQLite {
    struct Failure: Error { let message: String }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw Failure(message: message)
        }
    }

    deinit { sqlite3_close_v2(handle) }

    /// Runs one or more statements that take no parameters and return nothing.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// Runs one statement and returns its rows. A failure is logged and
    /// yields no rows: history is best-effort and must never take the app down.
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) -> [[SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.info("sqlite prepare failed: \(String(cString: sqlite3_errmsg(handle))) — \(sql)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let n = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, n)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .real(let v): sqlite3_bind_double(stmt, n, v)
            case .text(let v): sqlite3_bind_text(stmt, n, v, -1, Self.transient)
            case .blob(let v):
                if v.isEmpty {
                    sqlite3_bind_zeroblob(stmt, n, 0)
                } else {
                    _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(v.count), Self.transient) }
                }
            }
        }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let n = sqlite3_column_count(stmt)
                var row: [SQLValue] = []
                row.reserveCapacity(Int(n))
                for c in 0..<n {
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                    case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(stmt, c)))
                    case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(stmt, c))
                        if let bytes = sqlite3_column_blob(stmt, c), count > 0 {
                            row.append(.blob(Data(bytes: bytes, count: count)))
                        } else {
                            row.append(.blob(Data()))
                        }
                    default: row.append(.null)
                    }
                }
                rows.append(row)
            } else {
                if rc != SQLITE_DONE {
                    Log.info("sqlite step failed: \(String(cString: sqlite3_errmsg(handle))) — \(sql)")
                }
                break
            }
        }
        return rows
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
}
