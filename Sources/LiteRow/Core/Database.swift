//
//  Database.swift
//  LiteRow
//
//  Created by Artem Shimanski on 08.08.2026.
//

import SQLite3

import Foundation
import Synchronization

/// A read-only SQLite database with a pool of connections.
public final class Database: Sendable {
    /// Immutable options. The set of attached files lives in the pool, since `replace(_:with:)` changes it.
    private let options: Options
    private let connections: ConnectionPool
    
    nonisolated(unsafe)
    private let mainConnection: Connection

    private let revisionCounter = Atomic<UInt64>(0)
    
    public convenience init(url: URL, options: Options = .default) throws(LiteRowError) {
        try self.init(main: .file(url), attached: [:], options: options)
    }
    
    public convenience init(main: URL, attached: [DatabaseFile: URL] = [:], options: Options = .default) throws(LiteRowError) {
        try self.init(main: .file(main), attached: attached.mapValues{.file($0)}, options: options)
    }
    
    public convenience init(main: Source, attached: [DatabaseFile: Source] = [:], options: Options = .default) throws(LiteRowError) {
        try self.init(configuration: Configuration(main: main, attached: attached, options: options))
    }
    
    init(configuration: Configuration) throws(LiteRowError) {
        self.options = configuration.options
        // At least one: `activeProcessorCount - 1` is zero on a single-core machine.
        let maxConnections = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        self.connections = ConnectionPool(configuration: configuration, maxConnections: maxConnections)
        // Keeps the database open for the lifetime of `Database`; required for in-memory databases.
        mainConnection = try Connection(configuration)
    }
    
    @MainActor public func readSync<R, Failure: Error>(_ body: (borrowing Reader) throws(Failure) -> R) throws -> R {
        try body(Reader(connection: mainConnection))
    }
    
    public func read<R: Sendable, Failure: Error>(_ body: (borrowing Reader) throws(Failure) -> R) async throws -> sending R {
        try await connections.withConnection { connection in
            try body(Reader(connection: connection))
        }
    }
}

// MARK: - Replacing an attached file

extension Database {
    /// Increments on every successful `replace(_:with:)`; include it in memoization keys.
    public var revision: UInt64 {
        revisionCounter.load(ordering: .relaxed)
    }

    /// Replaces the file attached under `schema` without reopening the main database.
    ///
    /// Cached statements survive the replacement. The new file is validated with a separate
    /// connection first, then the pool and the main connection switch, and only then does
    /// `revision` increment.
    ///
    /// `@MainActor` because `readSync` uses the main connection on the main actor.
    @MainActor
    public func replace(_ schema: DatabaseFile, with source: Source) async throws(LiteRowError) {
        precondition(schema != .main, "The main database cannot be replaced: the connection itself opens it.")

        // Validate the new file (exists, right build) before detaching anything.
        do {
            _ = try Connection(Configuration(main: source, attached: [:], options: options))
        }
        catch {
            throw Self.attributing(error, to: schema)
        }

        try await connections.reattach(source, as: schema)
        try mainConnection.reattach(source, as: schema, options: options)
        revisionCounter.wrappingAdd(1, ordering: .relaxed)
    }

    /// Reports a validation mismatch under the replaced schema's name rather than `main`.
    private static func attributing(_ error: LiteRowError, to schema: DatabaseFile) -> LiteRowError {
        guard case let .schemaMismatch(mismatch) = error else { return error }
        return .schemaMismatch(
            SchemaMismatch(
                schema: schema.schemaName,
                stamp: mismatch.stamp,
                expected: mismatch.expected,
                actual: mismatch.actual
            )
        )
    }
}

extension Database {
    public struct Options: Sendable {
        public var mmapSizePolicy: MMapSizePolicy

        /// The expected `user_version`, the same for **all** schemas including `main`; `nil` skips the check.
        ///
        /// Checked on every connection open and every `ATTACH`. Set by `LiteRowBuild` (`setUserVersion`).
        public var schemaVersion: Int32?

        /// The expected `application_id`, the same for all schemas; `nil` skips the check.
        public var applicationID: Int32?

        public init(
            mmapSizePolicy: MMapSizePolicy = .wholeFile,
            schemaVersion: Int32? = nil,
            applicationID: Int32? = nil
        ) {
            self.mmapSizePolicy = mmapSizePolicy
            self.schemaVersion = schemaVersion
            self.applicationID = applicationID
        }
        
        public static let `default` = Options()
    }

    public enum MMapSizePolicy: Hashable, Sendable {
        case disabled
        case wholeFile
        case bytes(Int64)

        func bytes(for url: URL) -> Int64 {
            switch self {
            case .disabled:
                return 0
            case let .bytes(value):
                return value
            case .wholeFile:
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
    }
}

extension Database {
    public enum Source: Sendable, Hashable {
        /// A file on disk, opened read-only with `immutable=1`: it must not change while open.
        case file(URL)

        /// An in-memory database shared by all connections in the process with the same name.
        ///
        /// Fill it from another connection before creating `Database`, and keep that connection
        /// open until then: the database is destroyed with its last connection.
        case memory(name: String)
    }

    struct Configuration: Sendable {
        let main: Source
        let attached: [DatabaseFile: Source]
        let options: Options
    }
}

extension Database.Source {
    /// An in-memory name is escaped as a single path segment.
    private static let memoryNameAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    var uri: String {
        switch self {
        case .file(let url):
            precondition(url.isFileURL, "Database.Source.file expects a file URL, got \(url)")
            let path = url.path(percentEncoded: true)
            return "file:\(path)?immutable=1&mode=ro"

        case .memory(name: let name):
            // The `memdb` VFS rather than `cache=shared`: each connection keeps its own page cache,
            // regular locking and a working `mode=ro`. The leading `/` makes the database shared.
            let escaped = name.addingPercentEncoding(withAllowedCharacters: Self.memoryNameAllowed) ?? name
            return "file:/\(escaped)?vfs=memdb&mode=ro"
        }
    }

    var fileSize: Int? {
        switch self {
        case .file(let url):
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return values?.fileSize
        case .memory:
            return nil
        }
    }
}
