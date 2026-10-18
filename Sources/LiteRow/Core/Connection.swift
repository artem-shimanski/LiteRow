//
//  Connection.swift
//  LiteRow
//
//  Created by Artem Shimanski on 08.08.2026.
//

import Foundation
import SQLite3

// Isolation is guaranteed by the ConnectionPool
final class Connection {
    private let handle: SQLiteConnectionHandle
    private let statements = StatementCache()
    
    init(_ cfg: Database.Configuration) throws(LiteRowError) {
        let uri = cfg.main.uri
        var rawHandle: SQLiteConnectionHandle.RawHandle?
        // `SQLITE_OPEN_READONLY` is required: without one of the access flags `sqlite3_open_v2`
        // fails with SQLITE_MISUSE before the URI (and its `mode=ro`) is parsed.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(uri, &rawHandle, flags, nil)
        guard status == SQLITE_OK, let rawHandle else {
            // Read the message before closing: the handle is invalid after `sqlite3_close_v2`.
            let failure = SQLiteFailure.current(code: status, connection: rawHandle)
            sqlite3_close_v2(rawHandle)
            throw LiteRowError.cannotOpenDatabase(path: uri, underlying: failure)
        }
        handle = SQLiteConnectionHandle(rawHandle: rawHandle)
        
        for (file, db) in cfg.attached {
            try attach(db, as: file, options: cfg.options)
        }
        try configure(cfg)
    }

    deinit {
        // Finalize statements before `handle` closes (properties are destroyed in declaration order).
        statements.removeAll()
    }

    /// Schemas attached to this connection and their sources (`main` excluded).
    private var attached: [DatabaseFile: Database.Source] = [:]

    /// Set when a reattach failed and the previous file could not be restored either;
    /// the pool drops such a connection.
    private(set) var isBroken = false
    
    private func attach(_ db: Database.Source, as schema: DatabaseFile, options: Database.Options) throws(LiteRowError) {

        let sql = "ATTACH DATABASE \(db.uri.quotedStringLiteral) AS \(schema.quotedSchemaName)"
        try exec(sql)
        attached[schema] = db
        if let size = db.fileSize {
            try exec("PRAGMA \(schema.quotedSchemaName).mmap_size = \(size)")
        }
        try verify(schema, options: options)
    }

    /// Replaces the file attached under `schema` without reopening the connection.
    ///
    /// `DETACH`/`ATTACH` are allowed under `query_only = 1`. Cached statements survive:
    /// `sqlite3_prepare_v2` statements re-prepare on the next `step`.
    ///
    /// On failure the previous file is restored; if that fails too, the connection is marked broken.
    func reattach(_ source: Database.Source, as schema: DatabaseFile, options: Database.Options) throws(LiteRowError) {
        precondition(schema != .main, "The main database cannot be replaced: the connection itself opens it.")
        guard attached[schema] != source else { return }

        let previous = attached[schema]
        try detach(schema)
        do {
            try attach(source, as: schema, options: options)
        }
        catch {
            // `attach` may have failed after `ATTACH` itself (on the stamp check), so detach first.
            do {
                try detach(schema)
                if let previous {
                    try attach(previous, as: schema, options: options)
                }
            }
            catch {
                isBroken = true
            }
            throw error
        }
    }

    /// Rolls the schema back after a reattach failed on **another** connection of the pool.
    ///
    /// `nil` means the schema was not attached before. On failure the connection is marked broken.
    func restore(_ source: Database.Source?, as schema: DatabaseFile, options: Database.Options) {
        do {
            if let source {
                try reattach(source, as: schema, options: options)
            }
            else {
                try detach(schema)
            }
        }
        catch {
            isBroken = true
        }
    }

    /// `DETACH` if the schema is attached (detaching a missing schema is an SQLite error).
    private func detach(_ schema: DatabaseFile) throws(LiteRowError) {
        guard attached[schema] != nil else { return }
        try exec("DETACH DATABASE \(schema.quotedSchemaName)")
        attached[schema] = nil
    }
    
    private func configure(_ cfg: Database.Configuration) throws(LiteRowError) {
        try exec("PRAGMA temp_store = MEMORY")
        try exec("PRAGMA cache_size = -8000")
        if let size = cfg.main.fileSize {
            try exec(#"PRAGMA "main".mmap_size = \#(size)"#)
        }
        try verify(.main, options: cfg.options)
        try exec("PRAGMA query_only = 1")
    }

    /// Checks the schema's header stamp before any query runs on it.
    private func verify(_ schema: DatabaseFile, options: Database.Options) throws(LiteRowError) {
        if let expected = options.applicationID {
            let actual = try intPragma("application_id", of: schema)
            guard actual == expected else {
                throw .schemaMismatch(SchemaMismatch(schema: schema.schemaName, stamp: .applicationID,
                                                     expected: expected, actual: actual))
            }
        }
        if let expected = options.schemaVersion {
            let actual = try intPragma("user_version", of: schema)
            guard actual == expected else {
                throw .schemaMismatch(SchemaMismatch(schema: schema.schemaName, stamp: .userVersion,
                                                     expected: expected, actual: actual))
            }
        }
    }

    /// Reads an integer pragma of one schema.
    private func intPragma(_ name: String, of schema: DatabaseFile) throws(LiteRowError) -> Int32 {
        let sql = "PRAGMA \(schema.quotedSchemaName).\(name)"
        var rawHandle: SQLiteStatementHandle.RawHandle?
        let code = sqlite3_prepare_v2(handle.rawHandle, sql, -1, &rawHandle, nil)
        guard code == SQLITE_OK, let rawHandle else {
            sqlite3_finalize(rawHandle)
            throw LiteRowError.sqlite(SQLiteFailure.current(code: code, connection: handle.rawHandle, sql: sql))
        }
        defer { sqlite3_finalize(rawHandle) }
        let status = sqlite3_step(rawHandle)
        guard status == SQLITE_ROW else {
            throw LiteRowError.sqlite(SQLiteFailure.current(code: status, connection: handle.rawHandle, sql: sql))
        }
        return sqlite3_column_int(rawHandle, 0)
    }
    
    private func exec(_ sql: String) throws(LiteRowError) {
        try expectOK(sqlite3_exec(handle.rawHandle, sql, nil, nil, nil),
                 connection: handle)
        
    }
    
    
    /// Prepares (or reuses, keyed by SQL text) a statement and binds the query's values.
    func statement<Q: Query>(for query: Q) throws(LiteRowError) -> PreparedStatement<Q.Output> {
        let statement = try statements.acquire(of: Q.Output.self,
            sql: query.sql,
            makeStatement: Statement.prepare(connection: handle, sql: query.sql)
        )
        var binder = Binder(statement: statement.rawHandle)
        try query.bind(to: &binder)
        return statement
    }
}
