# LiteRow

A type-safe, read-only wrapper over SQLite3 for Swift: a generic query builder, a connection
pool and a `@Table` macro that describes a table once and gives the builder, the row decoder and
the schema metadata from the same property list.

LiteRow was built for an EVE Online companion app that ships a large static game database and only
ever reads it.

## Scope

* **Read-only by construction.** Connections are opened with `SQLITE_OPEN_READONLY`, files with
  `immutable=1&mode=ro`, and `PRAGMA query_only = 1` is set on top. The `LiteRow` target has no
  write path at all.
* The database is assumed not to change while the app runs. There is no change observation;
  `LiteRowUI` re-runs a query only when the query itself changes.
* Supported beyond plain joins: nested subqueries (`IN (SELECT ...)`, `NOT IN`, `EXISTS`,
  `NOT EXISTS`, correlated subqueries, a subquery as a projection or ordering expression) and
  compound queries (`union`, `unionAll`, `intersect`, `except`).
* Not supported: writes from the reading side, migrations, an ORM object graph.
* The one thing that can change underneath a `Database` is an attached file:
  `Database.replace(_:with:)` swaps it (for example when the language changes) without reopening
  the main database.

## Requirements

* Swift 6.4 / Xcode 27; macOS 26 and iOS 26 (see `Package.swift`).
* Dependency: [swift-syntax](https://github.com/swiftlang/swift-syntax) 600.x, for the macros.

## Products and targets

| Target            | Kind        | Purpose |
|-------------------|-------------|---------|
| `LiteRow`         | library     | Reading: `Database`, the pool, the query builder, row decoding, `@Table`, FTS5 patterns. This is what an app links. |
| `LiteRowBuild`    | library     | Building a database file: `CREATE TABLE`, indexes, inserts, FTS5 tables, `VACUUM INTO`. Linked only by a dev-time tool run once per build; it depends on `LiteRow` for the models, never the other way round. |
| `LiteRowUI`       | library     | SwiftUI bridge: `@LiteQuery`, `LiteSections`, the `liteDatabase` environment value. Kept separate so the core builds where SwiftUI is not available. |
| `LiteRowMacros`   | macro       | Compiler plugin behind `@Table`, `@Column`, `@PrimaryKey`, `@Index`, `@Projection` and friends. Not a product; pulled in by `LiteRow`. |

Test targets: `LiteRowTests`, `LiteRowBuildTests`, `LiteRowUITests`.

## Concepts

### Models: `@Table`

```swift
import LiteRow

@Table("invTypes")
struct TypeInfo {
    @PrimaryKey @Column("typeID") var id: UInt32
    @Column("typeName") var name: String
    @Index var groupID: UInt32
}

@Table("invGroups")
struct TypeGroup {
    @PrimaryKey @Column("groupID") var id: UInt32
    @Column("groupName") var name: String
}
```

The macro generates the column list, the row decoder (`RowDecodable`), the primary key type
(composite keys: several `@PrimaryKey`) and `RowEncodable`, which `LiteRowBuild` uses so that
`INSERT` and `SELECT` list columns in the same order. `@Table("name", schema: .other)` puts a
table into an attached file. `@Projection` does the same for an ad-hoc result row (several
tables, named fields, `@Embedded` for a whole table).

### Opening a database and running a query

```swift
let database = try Database(url: url, options: Database.Options(schemaVersion: 1))

let names = try await database.read { reader in
    let query = TypeInfo.all()
        .join(TypeGroup.self) { type, group in type.groupID == group.id }
        .filter { type, group in group.name.like("Frig%") && type.id > 0 }
        .order(by: { type, _ in type.name })
        .limit(50)
        .query()
    return try reader.fetchAll(query).map { "\($0.left.name)/\($0.right.name)" }
}
```

* `T.all()` starts a `QueryBuilder`; `filter`, `order`, `group`, `having`, `join`, `leftJoin`,
  `crossJoin`, `select`, `limit` return a new builder; `query()` produces a `SQLQuery<Output>`,
  which is the end of the chain and also the query's identity (SQL text plus values).
* Values are always bound as parameters, never written into the SQL text, so the statement cache
  keys on the text alone.
* `Reader` offers `fetch` (a `Cursor`), `fetchAll` and `fetchOne`. `Database.read` is async and
  uses the pool; `Database.readSync` is `@MainActor` and uses a dedicated main connection.
* A join's `Output` is a nested pair (`left`, `right`, ...); `select { ... }` projects it.
* `Database(main:attached:options:)` takes `.file(URL)` or `.memory(name:)` sources and a
  `[DatabaseFile: Source]` of attached files (`DatabaseFile(schemaName:)`).
* `Options.schemaVersion` and `Options.applicationID` are checked against `user_version` and
  `application_id` of the main file and of every attached file, on every connection and on every
  `ATTACH`; a mismatch throws from the initializer. `nil` (the default) skips the check.

### The pool

`Database` is `Sendable` and owns a connection pool (an actor, up to `min(4, cores - 1)`
connections, at least one). Each connection has its own prepared-statement cache. In-memory
databases live only while some connection to them is open; `Database` keeps its main connection
for that reason, and whoever fills a memory database must keep the writer open until the
`Database` exists.

### Building a database: `LiteRowBuild`

```swift
import LiteRowBuild

let builder = try DatabaseBuilder(creating: url)          // or DatabaseBuilder(inMemory: name)
try builder.transaction {
    try builder.create(TypeInfo.self, filledWith: types)  // CREATE TABLE + INSERT, no indexes
    try builder.create(TypeGroup.self, filledWith: groups)
}
try builder.createIndexes(TypeInfo.self)                  // after the data, on purpose
try builder.setUserVersion(1)
try builder.setApplicationID(0x4C52)
try builder.analyze()
try builder.vacuum(into: finalURL)                        // carries both stamps over
builder.close()
```

`create(_:)`, `insert(_:)`, `createIndexes(_:)` and `execute(_:)` are available separately.
FTS5 tables are created with `create(fts:indexing:rowID:)`; the model that reads such a table is
an ordinary `@Table`, and the builder treats virtual tables like any other.

### In a SwiftUI view: `@LiteQuery`

```swift
import LiteRowUI

struct ShipList: View {
    @LiteQuery private var ships: [TypeInfo]

    init(query: SQLQuery<TypeInfo>?) { _ships = LiteQuery(query) }

    var body: some View { List(ships, id: \.id) { Text($0.name) } }
}

ShipList(query: TypeInfo.all().order(by: { $0.name }).query())
    .liteDatabase(database)
```

The query is an argument of the view, not its state: filters such as a search string live in the
parent. A `nil` query yields an empty value. `liteQueryFailure(_:)` sets the error handler.
`LiteSections` / `SectionedQuery` read a list of sections and the rows of each.

## Tests

The tests build **only** with the native build system. The default one (swiftbuild) fails at
linking the test bundle: the `LiteRowMacros` symbols (SwiftSyntax, SwiftCompilerPlugin) are not
found because the macro target is pulled into the test bundle. The flag is mandatory:

```
xcrun swift test --build-system native
xcrun swift test --build-system native --filter TableMacroTests
xcrun swift test --build-system native --filter LiteRowBuildTests
```

## License

LiteRow is available under the MIT license. See [LICENSE](LICENSE).
