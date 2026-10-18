//
//  RowEncodable.swift
//  LiteRow
//

/// A type that can bind its column values, in `Table.columns` order.
///
/// The counterpart of `RowDecodable`; it knows nothing about `INSERT` or connections
/// (`LiteRowBuild` does the writing). `@Table` generates the conformance.
public protocol RowEncodable: SQLBindable {
}
