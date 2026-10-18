//
//  ConnectionPool.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

import SQLite3

actor ConnectionPool {
    /// The current set of files; `reattach` updates it, and new connections open with it.
    private(set) var configuration: Database.Configuration
    private var available: [Connection] = []
    private let maxConnections: Int
    private var openCount: Int = 0
    private var idCounter: Int = 0
    private var waiters: [Waiter] = []
    
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Connection, Error>
    }
    
    init(configuration: Database.Configuration, maxConnections: Int) {
        self.configuration = configuration
        self.maxConnections = max(1, maxConnections)
    }
    
    nonisolated
    func withConnection<R: Sendable, Failure: Error>(_ body:  (Connection) throws(Failure) -> R) async throws -> R {
        let connection = try await acquire()
        do {
            try Task.checkCancellation()
            let result = try body(connection)
            await release(connection)
            return result
        }
        catch {
            await release(connection)
            throw error
        }
    }
    
    private func acquire() async throws -> sending Connection {
        if let connection = available.sendingPopLast() {
            return connection
        }
        
        if openCount < maxConnections {
            let connection = try Connection(configuration)
            openCount += 1
            return connection
        }
        
        let id = idCounter
        idCounter &+= 1

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }
    
    private func release(_ connection: sending Connection) {
        if waiters.isEmpty {
            available.append(connection)
        } else {
            waiters.removeFirst().continuation.resume(returning: connection)
        }
    }

    /// Replaces the file attached under `schema` on **every** connection of the pool.
    ///
    /// The configuration changes first, then the pool's whole limit (not `openCount`) is acquired:
    /// that way every existing connection is held, and any connection opened meanwhile already
    /// uses the new file. On failure, connections already switched are restored.
    func reattach(_ source: Database.Source, as schema: DatabaseFile) async throws(LiteRowError) {
        let previous = configuration
        var attached = previous.attached
        attached[schema] = source
        configuration = Database.Configuration(main: previous.main, attached: attached, options: previous.options)

        var held: [Connection] = []
        var failure: LiteRowError?

        for _ in 0 ..< maxConnections {
            do {
                held.append(try await acquire())
            }
            catch let error as LiteRowError {
                failure = error
                break
            }
            catch {
                // `acquire` is untyped because of the continuation; in practice these are open errors.
                failure = .sqlite(SQLiteFailure(code: SQLITE_ERROR, message: "\(error)"))
                break
            }
        }

        // Connections already switched; rolled back if a later one fails.
        var applied: [Connection] = []
        if failure == nil {
            for connection in held {
                do {
                    try connection.reattach(source, as: schema, options: previous.options)
                    applied.append(connection)
                }
                catch {
                    failure = error
                    break
                }
            }
        }

        if failure != nil {
            for connection in applied {
                connection.restore(previous.attached[schema], as: schema, options: previous.options)
            }
            configuration = previous
        }

        // Consumed rather than iterated: `release` takes a `sending` value.
        while let connection = held.sendingPopLast() {
            // A connection that could neither switch nor roll back is dropped from the pool.
            if connection.isBroken {
                discard()
            }
            else {
                release(connection)
            }
        }

        if let failure {
            throw failure
        }
    }

    /// Drops a broken connection and opens a replacement for waiters, since only `release` wakes them.
    private func discard() {
        openCount -= 1
        guard !waiters.isEmpty else { return }
        do {
            let replacement = try Connection(configuration)
            openCount += 1
            release(replacement)
        }
        catch {
            waiters.removeFirst().continuation.resume(throwing: error)
        }
    }
}

extension Array {
    mutating func sendingPopLast() -> sending Element? {
        nonisolated(unsafe) let last = popLast()
        return last
    }
}
