//
//  TableMacro.swift
//  LiteRow
//

/// Generates the `Table` conformance from a struct declaration.
///
/// Expands to `Columns` with its `columns` value, `tableName`/`schema`, `descriptor` and
/// `init(_:offset:)`. Column order is property order, and column indexes are assigned automatically.
///
/// Stored properties become columns: every `var`, and every `let` without a default value.
/// Computed properties, `static` properties and `let`s with an initializer are skipped.
///
/// ```swift
/// @Table("invTypes")
/// struct TypeInfo {
///     @PrimaryKey @Column("typeID") var id: TypeID
///     @Column("typeName") var name: String
///     @Index var groupID: GroupID
/// }
/// ```
///
/// `TypeInfo.columns.groupID` is a `Column<TypeInfo, GroupID>`; the type-erased schema
/// (columns, key columns, indexes) is in `descriptor`.
///
/// A **public** model also gets a public memberwise initializer, since the synthesized one is
/// `internal`. Default values are carried over as written.
///
/// If any property is marked `@PrimaryKey`, the type also conforms to `PrimaryKeyTable`, with a
/// nested `PrimaryKey` type and a `primaryKey` property.
///
/// The `RowEncodable.bind(to:)` conformance is generated as well, binding values in the same
/// column order `SELECT` reads them.
///
/// - Parameters:
///   - tableName: The physical table name.
///   - schema: The schema the table lives in, the same value used as a key in `Database`'s `attached`:
///
///     ```swift
///     extension DatabaseFile {
///         static let icons = DatabaseFile(schemaName: "aux")
///     }
///
///     @Table("eveIcons", schema: .icons)
///     struct Icon { … }
///     ```
///
///     This is the query default; a query can pick another attached copy with `all(in:)`,
///     `join(_:in:)` or `find(_:in:)`.
@attached(
    member,
    names: named(Columns), named(columns), named(schema), named(tableName),
    named(identityColumn), named(descriptor),
    named(PrimaryKey), named(primaryKey), named(init)
)
@attached(
    extension,
    conformances: Table, PrimaryKeyTable, RowEncodable,
    names: named(init), named(bind(to:))
)
public macro Table(_ tableName: String, schema: DatabaseFile = .main) =
    #externalMacro(module: "LiteRowMacros", type: "TableMacro")

/// Configures a column within `@Table`. Without it, the column name is the property name.
///
/// - Parameters:
///   - name: The column name in the database.
///   - identity: Marks the column whose `NULL` means a missing row in a `LEFT JOIN`.
///     Defaults to the first key column, or the first column if there is no key.
@attached(peer)
public macro Column(_ name: String? = nil, identity: Bool = false) =
    #externalMacro(module: "LiteRowMacros", type: "ColumnMacro")

/// Marks a primary key column.
///
/// Several attributes make a composite key, with columns in property order.
///
/// ```swift
/// @Table("dgmTypeAttributes")
/// struct TypeAttribute {
///     @PrimaryKey var typeID: TypeID
///     @PrimaryKey var attributeID: AttributeID
///     var value: Double
/// }
/// ```
@attached(peer)
public macro PrimaryKey() = #externalMacro(module: "LiteRowMacros", type: "PrimaryKeyMacro")

/// Adds the column to an index.
///
/// Without a name, it is a single-column index named `idx_<table>_<column>`. **Several attributes
/// with the same name form one composite index**, with columns in property order.
///
/// ```swift
/// @Table("dgmTypeAttributes")
/// struct TypeAttribute {
///     @PrimaryKey var typeID: TypeID
///     @PrimaryKey @Index("dgmTypeAttributes_byAttributeValue") var attributeID: AttributeID
///     @Index("dgmTypeAttributes_byAttributeValue", order: .descending) var value: Double
/// }
/// ```
///
/// The index is unique if any attribute in the group says so.
///
/// - Parameters:
///   - name: The index name; shared names merge columns into one composite index.
///   - unique: `UNIQUE INDEX`.
///   - order: This column's order within the index.
///   - collate: The collation name (`NOCASE`, `BINARY`, …); `nil` uses the column's collation.
///   - where: A partial index condition on **this** column: `@Index(where: .notNull)` gives
///     `CREATE INDEX … WHERE "column" IS NOT NULL`. For a condition on another column, use `@IndexFilter`.
@attached(peer)
public macro Index(
    _ name: String? = nil,
    unique: Bool = false,
    order: Order = .ascending,
    collate: String? = nil,
    where condition: IndexCondition? = nil
) = #externalMacro(module: "LiteRowMacros", type: "IndexMacro")

/// A partial index condition on this column, for an index declared on **another** column.
///
/// ```swift
/// @Table("dogmaItems")
/// struct DogmaItem {
///     @PrimaryKey @Index("byRestricted") var id: DogmaItemID
///     @IndexFilter("byRestricted", .isTrue) var hasShipRestrictions: Bool
/// }
/// ```
///
/// Gives `CREATE INDEX "byRestricted" ON "dogmaItems" ("id") WHERE "hasShipRestrictions"`.
/// Several conditions for the same index are joined with `AND` in property order.
///
/// - Parameters:
///   - name: The index name; must match a name used in `@Index`.
///   - condition: The condition; see `IndexCondition` for how queries must be written to use the index.
@attached(peer)
public macro IndexFilter(
    _ name: String,
    _ condition: IndexCondition
) = #externalMacro(module: "LiteRowMacros", type: "IndexFilterMacro")
