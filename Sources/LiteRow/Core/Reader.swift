//
//  Reader.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

public struct Reader: ~Copyable {
    let connection: Connection

    public func fetch<Q: Query>(_ query: Q) throws(LiteRowError) -> Cursor<Q.Output> {
        try connection.statement(for: query).fetch()
    }

    public func fetchAll<Q: Query>(_ query: Q, minimumCapacity: Int = 0) throws(LiteRowError) -> [Q.Output] {
        try connection.statement(for: query).fetchAll(minimumCapacity: minimumCapacity)
    }

    public func fetchOne<Q: Query>(_ query: Q) throws(LiteRowError) -> Q.Output? {
        try connection.statement(for: query).fetchOne()
    }
}
