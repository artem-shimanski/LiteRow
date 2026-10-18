//
//  LiteQueryResult.swift
//  LiteRowUI
//

import LiteRow

/// The value a `@LiteQuery` wrapper produces from its query.
///
/// The fetch method follows the property's type: `[T]` uses `fetchAll`, `T?` uses `fetchOne`.
public protocol LiteQueryResult: Sendable {
    /// The row type fetched from the database (`T` for both `[T]` and `T?`).
    associatedtype Output: RowDecodable

    /// The value used when there is no query, no database, or the fetch failed.
    static var empty: Self { get }

    static func fetch(_ reader: borrowing Reader, _ query: SQLQuery<Output>) throws(LiteRowError) -> Self
}

extension Array: LiteQueryResult where Element: RowDecodable {
    public typealias Output = Element

    @inlinable public static var empty: Self { [] }

    @inlinable public static func fetch(
        _ reader: borrowing Reader,
        _ query: SQLQuery<Element>
    ) throws(LiteRowError) -> Self {
        try reader.fetchAll(query)
    }
}

extension Optional: LiteQueryResult where Wrapped: RowDecodable {
    public typealias Output = Wrapped

    @inlinable public static var empty: Self { nil }

    /// Uses `fetchOne`; the query should carry its own `LIMIT 1`.
    @inlinable public static func fetch(
        _ reader: borrowing Reader,
        _ query: SQLQuery<Wrapped>
    ) throws(LiteRowError) -> Self {
        try reader.fetchOne(query)
    }
}
