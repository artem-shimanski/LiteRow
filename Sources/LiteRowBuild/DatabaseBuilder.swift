//
//  DatabaseBuilder.swift
//  LiteRowBuild
//

import Foundation
import SQLite3

@_spi(Build) import LiteRow

/// A single-threaded write connection that creates and fills a database at build time.
///
/// Recommended build order:
///
/// ```swift
/// let builder = try DatabaseBuilder(creating: workURL)
/// try builder.create(TypeInfo.self)          // CREATE TABLE
/// try builder.insert(types)                  // one transaction per call
/// try builder.createIndexes(TypeInfo.self)   // indexes after the data
/// try builder.analyze()                      // statistics stored in the file
/// try builder.vacuum(into: finalURL)         // final file, no journal
/// builder.close()
/// ```
public final class DatabaseBuilder {
    private let raw: OpaquePointer
    private let options: Options

    /// How the database was opened; determines the VFS used by `vacuum(into:)`.
    private let storage: Storage

    /// Prepared statements, kept for the whole build.
    private var statements: [String: BuildStatement] = [:]

    private var transactionDepth = 0
    private var isClosed = false

    // MARK: - Opening

    /// Creates a new database file. An existing file and its journals are deleted;
    /// intermediate directories are created.
    public convenience init(creating url: URL, options: Options = .default) throws(LiteRowError) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let path = url.path(percentEncoded: false) + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            }
        }
        catch {
            throw LiteRowError.cannotOpenDatabase(
                path: url.path(percentEncoded: false),
                underlying: SQLiteFailure(
                    code: SQLITE_CANTOPEN,
                    message: "could not prepare the directory: \(error)"
                )
            )
        }

        // No `SQLITE_OPEN_URI`: `?` or `#` in the path stay part of the name.
        try self.init(
            uri: url.path(percentEncoded: false),
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            storage: .file,
            options: options
        )
    }

    /// An in-memory database under the name `Database.Source.memory(name:)` will open.
    ///
    /// The database lives while any connection to it is open, so keep the builder open
    /// until the reader has opened.
    public convenience init(inMemory name: String, options: Options = .default) throws(LiteRowError) {
        // Same leading `/` and escaping as `Database.Source.memory`, so the database is shared.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let escaped = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        try self.init(
            uri: "file:/\(escaped)?vfs=memdb",
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            storage: .memory,
            options: options
        )
    }

    /// Opens with `SQLITE_OPEN_FULLMUTEX`: in async code the thread may change between calls,
    /// and a `NOMUTEX` connection then asserts on Apple platforms.
    private init(uri: String, flags: Int32, storage: Storage, options: Options) throws(LiteRowError) {
        var rawHandle: OpaquePointer?
        let status = sqlite3_open_v2(uri, &rawHandle, flags, nil)
        guard status == SQLITE_OK, let rawHandle else {
            // Read the message before closing: the handle is invalid after `sqlite3_close_v2`.
            let failure = SQLiteFailure.current(code: status, connection: rawHandle)
            sqlite3_close_v2(rawHandle)
            throw LiteRowError.cannotOpenDatabase(path: uri, underlying: failure)
        }
        self.raw = rawHandle
        self.options = options
        self.storage = storage
        try configure()
    }

    /// Build pragmas, tuned for speed: a failed build is simply rerun.
    /// `page_size` must be set before the first table is created.
    private func configure() throws(LiteRowError) {
        if let pageSize = options.pageSize {
            try execute("PRAGMA page_size = \(pageSize)")
        }
        try execute("PRAGMA journal_mode = \(options.journalMode.rawValue)")
        try execute("PRAGMA synchronous = \(options.isSynchronous ? "FULL" : "OFF")")
        if options.isExclusiveLocking {
            try execute("PRAGMA locking_mode = EXCLUSIVE")
        }
        try execute("PRAGMA temp_store = MEMORY")
        try execute("PRAGMA cache_size = \(-options.cacheSizeKiB)")
    }

    deinit {
        // `close()` may already have closed the connection; closing twice is a use-after-free.
        guard !isClosed else { return }
        // Finalize statements first, or the database stays open until they are finalized.
        statements.removeAll()
        sqlite3_close_v2(raw)
    }

    /// Closes the connection; the builder cannot be used afterwards.
    ///
    /// An in-memory database is destroyed if no other connection to it remains.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        statements.removeAll()
        sqlite3_close_v2(raw)
    }

    // MARK: - Execution

    /// Executes arbitrary SQL without parameters (triggers, views, pragmas, …).
    public func execute(_ sql: String) throws(LiteRowError) {
        precondition(!isClosed, "DatabaseBuilder is already closed.")
        let code = sqlite3_exec(raw, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw LiteRowError.sqlite(SQLiteFailure.current(code: code, connection: raw, sql: sql))
        }
    }

    func prepared(_ sql: String) throws(LiteRowError) -> BuildStatement {
        precondition(!isClosed, "DatabaseBuilder is already closed.")
        if let statement = statements[sql] { return statement }
        let statement = try BuildStatement.prepare(connection: raw, sql: sql)
        statements[sql] = statement
        return statement
    }

    // MARK: - Transactions

    /// Runs `body` in a transaction. Nested calls join the outer transaction (no savepoints).
    public func transaction<R>(_ body: () throws -> R) throws -> R {
        try begin()
        do {
            let result = try body()
            try commit()
            return result
        }
        catch {
            rollback()
            throw error
        }
    }

    func begin() throws(LiteRowError) {
        if transactionDepth == 0 {
            try execute("BEGIN")
        }
        transactionDepth += 1
    }

    func commit() throws(LiteRowError) {
        precondition(transactionDepth > 0, "commit without begin.")
        transactionDepth -= 1
        if transactionDepth == 0 {
            try execute("COMMIT")
        }
    }

    /// Best-effort rollback: with `journalMode == .off` SQLite cannot roll back, and the
    /// file is only fit for a rebuild.
    func rollback() {
        guard transactionDepth > 0 else { return }
        transactionDepth = 0
        sqlite3_exec(raw, "ROLLBACK", nil, nil, nil)
    }

    // MARK: - Build stamp

    /// `user_version`: the build number, checked by `Database.Options.schemaVersion`.
    ///
    /// Use the same value for all files of one build. `VACUUM INTO` carries it over to the final file.
    public var userVersion: Int32 {
        get throws(LiteRowError) { try intPragma("user_version") }
    }

    public func setUserVersion(_ value: Int32) throws(LiteRowError) {
        try execute("PRAGMA \"main\".user_version = \(value)")
    }

    /// `application_id`: identifies the file format, checked by `Database.Options.applicationID`.
    public var applicationID: Int32 {
        get throws(LiteRowError) { try intPragma("application_id") }
    }

    public func setApplicationID(_ value: Int32) throws(LiteRowError) {
        try execute("PRAGMA \"main\".application_id = \(value)")
    }

    /// Reads an integer pragma.
    private func intPragma(_ name: String) throws(LiteRowError) -> Int32 {
        let statement = try prepared("PRAGMA \"main\".\(name)")
        return try statement.integer()
    }

    // MARK: - Finalization

    /// `ANALYZE`: stores `sqlite_stat1` in the file for the query planner.
    public func analyze() throws(LiteRowError) {
        precondition(transactionDepth == 0, "ANALYZE inside a transaction.")
        try execute("ANALYZE")
    }

    /// Writes the final file with `VACUUM INTO`: compact, self-contained, no journal.
    ///
    /// Readers open with `immutable=1`, which ignores any journal, so a plain copy is unsafe.
    /// An existing file at `url` is deleted. For an in-memory build the target gets an explicit
    /// default VFS, since `VACUUM INTO` would otherwise write into `memdb`.
    public func vacuum(into url: URL) throws(LiteRowError) {
        precondition(transactionDepth == 0, "VACUUM inside a transaction.")
        let path = url.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
        catch {
            throw LiteRowError.cannotOpenDatabase(
                path: path,
                underlying: SQLiteFailure(
                    code: SQLITE_CANTOPEN,
                    message: "could not prepare the directory: \(error)"
                )
            )
        }
        let target: String = switch storage {
        case .file:
            // Opened without `SQLITE_OPEN_URI`, so a plain path.
            path
        case .memory:
            "file:\(url.path(percentEncoded: true))?vfs=\(Self.defaultVFSName)"
        }
        try execute("VACUUM INTO \(target.quotedStringLiteral)")
    }

    /// The default VFS name, as reported by SQLite.
    private static var defaultVFSName: String {
        guard let vfs = sqlite3_vfs_find(nil), let name = vfs.pointee.zName else { return "unix" }
        return String(cString: name)
    }
}

extension DatabaseBuilder {
    fileprivate enum Storage {
        case file
        case memory
    }
}

// MARK: - Options

extension DatabaseBuilder {
    public struct Options: Sendable, Hashable {
        /// Page size; `nil` uses SQLite's default. Only takes effect before the first table is created.
        public var pageSize: Int?

        /// Journal mode. `.off` is fastest but makes rollback impossible.
        public var journalMode: JournalMode

        /// `synchronous = FULL` instead of `OFF`.
        public var isSynchronous: Bool

        /// Page cache size in KiB.
        public var cacheSizeKiB: Int

        /// `locking_mode = EXCLUSIVE`. Off by default: a reader connection to the same database
        /// would get `SQLITE_BUSY`.
        public var isExclusiveLocking: Bool

        public init(
            pageSize: Int? = nil,
            journalMode: JournalMode = .off,
            isSynchronous: Bool = false,
            cacheSizeKiB: Int = 64_000,
            isExclusiveLocking: Bool = false
        ) {
            self.pageSize = pageSize
            self.journalMode = journalMode
            self.isSynchronous = isSynchronous
            self.cacheSizeKiB = cacheSizeKiB
            self.isExclusiveLocking = isExclusiveLocking
        }

        public static let `default` = Options()
    }

    public enum JournalMode: String, Sendable, Hashable {
        case off = "OFF"
        case memory = "MEMORY"
        case delete = "DELETE"
    }
}
