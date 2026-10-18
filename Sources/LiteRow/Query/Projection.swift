//
//  Projection.swift
//  LiteRow
//

/// A query projection onto a named type.
///
/// Built by the generated factory `Type.projection(field: expression, …)`.
/// It is not an `Expression` so that `select` cannot pick the scalar overload for it.
public struct Projection<Row: RowDecodable>: Sendable {
    public let columns: [any Expression]

    @inlinable public init(_ columns: [any Expression]) {
        self.columns = columns
    }
}

/// The projection's column list in `SELECT`. Elements are written at comma precedence,
/// so a whole-table projection gets no parentheses.
struct ProjectionList: Expression<Never> {
    let columns: [any Expression]

    var precedence: Int { SQLOperator.coma.precedence }

    func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        for (position, column) in columns.enumerated() {
            if position > 0 {
                sql.write(", ")
            }
            writeErased(column, to: &sql, minimumPrecedence: SQLOperator.coma.precedence)
        }
    }
}

// MARK: - Macros

/// A result row built from arbitrary expressions, with named fields; like `@Table`, but for a projection.
///
/// ```swift
/// @Projection
/// struct TypeListItem {
///     var id: TypeID
///     var name: String
///     var groupName: String
///     var iconFile: String?
/// }
///
/// let query = withIcon
///     .select { type, group, icon in
///         TypeListItem.projection(
///             id: type.id,
///             name: type.name,
///             groupName: group.name,
///             iconFile: icon.path
///         )
///     }
///     .query()
/// ```
///
/// Generates the `RowDecodable` conformance and a `projection(...)` factory with one labeled
/// parameter per property, so the projection and the decoding order always agree.
///
/// Expression types are matched to property types by `Value.Base`, so a column from a
/// `LEFT JOIN` (still `Expression<String>`) can fill a `String?` field. Use `@Embedded`
/// for a whole-table field.
@attached(extension, conformances: RowDecodable, names: named(init), named(width), named(projection))
public macro Projection() = #externalMacro(module: "LiteRowMacros", type: "ProjectionMacro")

/// A projection field holding a whole table rather than one column.
///
/// The factory takes a `TableRef` for it and expands it to the table's columns in descriptor order.
///
/// ```swift
/// @Projection
/// struct ShipRow {
///     @Embedded var type: TypeInfo
///     @Embedded var icon: TypeIcon?   // `nil` when the LEFT JOIN finds no row
///     var groupName: String
/// }
/// ```
///
/// An optional field is the right side of a `LEFT JOIN`, as in `Join<A, B?>`; the factory
/// still takes a non-optional reference.
@attached(peer)
public macro Embedded() = #externalMacro(module: "LiteRowMacros", type: "EmbeddedMacro")
