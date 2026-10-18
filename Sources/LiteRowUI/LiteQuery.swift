//
//  LiteQuery.swift
//  LiteRowUI
//

import SwiftUI
import LiteRow

/// A database fetch as a view property.
///
/// ```swift
/// struct ShipList: View {
///     @LiteQuery private var ships: [TypeInfo]
///
///     init(query: SQLQuery<TypeInfo>?) {
///         _ships = LiteQuery(query)
///     }
///
///     var body: some View {
///         List(ships, id: \.id) { ShipRow($0) }
///     }
/// }
/// ```
///
/// ## No observation
///
/// The database is read-only and immutable, so the fetch reruns only when the query changes
/// (or when `Database.replace(_:with:)` swaps an attached file, tracked by `Database.revision`).
/// Fetches are synchronous, via `Database.readSync`.
///
/// ## Where the query comes from
///
/// Pass the query in as a view argument rather than building it from the view's own `@State`:
/// SwiftUI does not recreate a view when its own state changes, so such a query would go stale.
/// Keep filters in the parent and give the list view a ready `SQLQuery`.
///
/// ```swift
/// struct ShipsScreen: View {
///     @State private var search = ""
///
///     var body: some View {
///         ShipList(query: Self.query(search: search))
///             .searchable(text: $search)
///     }
/// }
/// ```
@propertyWrapper
public struct LiteQuery<Value: LiteQueryResult>: DynamicProperty {
    @Environment(\.liteDatabase) private var database
    @Environment(\.liteQueryFailure) private var failure

    // A non-observable class: writing to it must not invalidate the view.
    @State private var cache = QueryCache<Value>()

    private let query: SQLQuery<Value.Output>?

    /// A `nil` query is valid and yields `Value.empty`.
    public init(_ query: SQLQuery<Value.Output>?) {
        self.query = query
    }

    // Fetches here rather than in `update()`, so only when `body` actually reads the value.
    public var wrappedValue: Value {
        // Local copies instead of capturing `self`: the wrapper is not `Sendable`.
        let cache = cache
        let query = query
        let database = database
        let failure = failure

        // SwiftUI reads `wrappedValue` on the main thread, but it is declared nonisolated.
        return MainActor.assumeIsolated {
            cache.value(for: query, database: database, failure: failure)
        }
    }
}

/// Remembers the result of the last fetch only.
@MainActor
final class QueryCache<Value: LiteQueryResult> {
    private struct Key: Equatable {
        var query: SQLQuery<Value.Output>?
        var database: ObjectIdentifier?
        /// Increments on every attached file replacement.
        var revision: UInt64
    }

    private var loaded: (key: Key, value: Value)?

    /// Number of database fetches; used by tests.
    private(set) var fetchCount = 0

    nonisolated init() {}

    func value(for query: SQLQuery<Value.Output>?,
               database: Database?,
               failure: LiteQueryFailure) -> Value {
        let key = Key(
            query: query,
            database: database.map(ObjectIdentifier.init),
            revision: database?.revision ?? 0
        )
        if let loaded, loaded.key == key {
            return loaded.value
        }

        let value: Value
        switch (query, database) {
        case (nil, _):

            value = .empty

        case let (query?, database?):
            fetchCount += 1
            do {
                value = try database.readSync { reader in
                    try Value.fetch(reader, query)
                }
            }
            catch {
                failure.report(error)
                value = .empty
            }

        case (_?, nil):
            failure.report(LiteQueryError.databaseMissing)
            value = .empty
        }

        // Cached on failure too, so a broken query is not retried on every `body` evaluation.
        loaded = (key, value)
        return value
    }
}
