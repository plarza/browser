import Foundation
import SQLite3

/// A value a statement's `?` can take.
protocol SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32)
}

extension String: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) {
        // SQLite copies the text before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, self, -1, transient)
    }
}

extension Int: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(self))
    }
}

extension Double: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_double(statement, index, self)
    }
}

/// A SQLite file, open. Each statement is prepared the first time it runs
/// and kept, since the same few run on every keystroke. It has no lock of
/// its own: whoever opens it uses it from one place.
final class SQLite {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init?(_ file: URL) {
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            NSLog("SQLite: can't open \(file.path): \(trouble)")
            sqlite3_close(handle)
            return nil
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    /// The row a statement has stepped to.
    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }

    /// Several statements at once, with nothing to bind: a schema, a pragma.
    @discardableResult
    func execute(_ script: String) -> Bool {
        guard sqlite3_exec(handle, script, nil, nil, nil) == SQLITE_OK else {
            NSLog("SQLite: \(trouble)")
            return false
        }
        return true
    }

    /// A statement that changes rows and answers nothing.
    func run(_ sql: String, _ values: [any SQLiteValue] = []) {
        scan(sql, values) { _ in true }
    }

    func rows(_ sql: String, _ values: [any SQLiteValue] = [], _ each: (Row) -> Void) {
        scan(sql, values) { each($0); return true }
    }

    /// What `read` makes of the first row, if there is one.
    func first<Value>(_ sql: String, _ values: [any SQLiteValue] = [], _ read: (Row) -> Value) -> Value? {
        var value: Value?
        scan(sql, values) { value = read($0); return false }
        return value
    }

    /// Steps through the rows until `each` returns false.
    func scan(_ sql: String, _ values: [any SQLiteValue] = [], _ each: (Row) -> Bool) {
        guard let statement = prepare(sql) else { return }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, value) in values.enumerated() { value.bind(to: statement, at: Int32(index + 1)) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                if each(Row(statement: statement)) { continue } else { return }
            }
            if step != SQLITE_DONE { NSLog("SQLite: \(trouble)") }
            return
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK else {
            NSLog("SQLite: \(trouble)")
            return nil
        }
        statements[sql] = statement
        return statement
    }

    private var trouble: String { String(cString: sqlite3_errmsg(handle)) }
}
