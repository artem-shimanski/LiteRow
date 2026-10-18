//
//  PrimaryKeyTests.swift
//  LiteRowTests
//

import Testing
@testable import LiteRow

// MARK: - Test models

/// The key is not in the first column: the `LEFT JOIN` anchor must be the key column,
/// not column zero by default, because `NULL` in it means the row is absent.
@Table("invTypes")
struct KeyedNotFirst {
    @Column("typeName") var name: String
    @PrimaryKey @Column("typeID") var id: UInt32
    var groupID: UInt32
}

/// An explicit `identity` mark overrides the key: they answer different questions, "what is unique"
/// and "what shows a join miss".
@Table("invTypes")
struct IdentityOverridesKey {
    @PrimaryKey @Column("typeID") var id: UInt32
    @Column("typeName", identity: true) var name: String
    var groupID: UInt32
}

/// `@Index` marks plus a hand-written composite index.
@Table("invTypes")
struct IndexedType {
    @PrimaryKey @Column("typeID") var id: UInt32
    @Column("typeName") @Index("invTypes_byNameAndGroup", order: .ascending) var name: String
    @Index @Index("invTypes_byNameAndGroup", order: .descending) var groupID: UInt32
}

/// A unique index with an explicit name.
@Table("eveIcons")
struct UniquelyIndexedIcon {
    @PrimaryKey @Column("iconID") var id: UInt32
    @Index("eveIcons_byType", unique: true) var typeID: UInt32
    @Column("iconFile") var path: String
}

// MARK: - Primary key

typealias AsString<T> = String

func columnNames<each T: Table, each V: SQLiteValue>(_ columns: (repeat Column<each T, each V>)) -> (repeat AsString<each T>) {
    (repeat (each columns).name)
}

@Suite("Primary key")
struct PrimaryKeyTests {
    @Test("a simple key is the type of the column itself")
    func simpleKeyType() {
        #expect(TypeInfo.PrimaryKey.columns.name == "typeID")
        let row = TypeInfo(id: 3, name: "Raven", groupID: 27)
        #expect(row.primaryKey == 3)
        // Key == UInt32, so no wrapper is needed in the call.
        let key: TypeInfo.PrimaryKey.Key = 3
        #expect(key == row.primaryKey)
    }

    @Test("a composite key is assembled into a struct with named fields")
    func compositeKeyType() {
        #expect(columnNames(TypeAttribute.PrimaryKey.columns) == ("typeID", "attributeID"))
        let row = TypeAttribute(
            typeID: TypeID(rawValue: 1),
            attributeID: AttributeID(rawValue: 9),
            value: 350
        )
        #expect(row.primaryKey == TypeAttribute.PrimaryKey.Key(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 9)))
    }

    @Test("find by a simple key renders as a condition on the key column")
    func rendersSimpleKeyPredicate() {
        let sql = TypeInfo.find(3).sql
        #expect(
            sql == #"SELECT * FROM "main"."invTypes" AS t0 WHERE t0."typeID" = ? LIMIT ?"#
        )
    }

    @Test("find by a composite key lists all key columns")
    func rendersCompositeKeyPredicate() {
        let query = TypeAttribute.find(
            TypeAttribute.PrimaryKey.Key(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 9))
        )
        #expect(query.sql.hasSuffix(#"WHERE t0."typeID" = ? AND t0."attributeID" = ? LIMIT ?"#))
    }

    @Test("a row is fetched from the database by a simple key")
    func fetchesBySimpleKey() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let row = try await database.read { reader in
            try reader.fetchOne(TypeInfo.self, key: 3)
        }

        #expect(row?.name == "Raven")
        withExtendedLifetime(fixture) {}
    }

    @Test("a row is fetched from the database by a composite key")
    func fetchesByCompositeKey() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let key = TypeAttribute.PrimaryKey.Key(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 9))
        let row = try await database.read { reader in
            try reader.fetchOne(TypeAttribute.self, key: key)
        }

        #expect(row?.value == 350)
        // The key of the row read equals the one looked up: typed IDs survived both binding and decoding.
        #expect(row?.primaryKey == key)
        withExtendedLifetime(fixture) {}
    }

    @Test("the halves of a composite key are not swapped")
    func compositeKeyHalvesAreDistinct() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        // (9, 4) instead of (1, 9) matches no row; with the key columns swapped the query would
        // return something.
        let key = TypeAttribute.PrimaryKey.Key(typeID: TypeID(rawValue: 9), attributeID: AttributeID(rawValue: 4))
        let row = try await database.read { reader in
            try reader.fetchOne(TypeAttribute.self, key: key)
        }

        #expect(row == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("selectKey projects only the key columns")
    func rendersKeyProjection() {
        #expect(
            TypeInfo.all().selectKey().query().sql
                == #"SELECT t0."typeID" FROM "main"."invTypes" AS t0"#
        )
        #expect(
            TypeAttribute.all().selectKey().query().sql
                == #"SELECT t0."typeID", t0."attributeID" FROM "main"."dgmTypeAttributes" AS t0"#
        )
    }

    @Test("selectKey keeps the filter and ordering")
    func keyProjectionKeepsRefinements() {
        let sql = TypeInfo.all()
            .filter { type in type.groupID == UInt32(25) }
            .order(by: { type in type.name })
            .selectKey()
            .query()
            .sql
        // Ordering by an unprojected column is legal and must not be dropped:
        // the key projection exists for `ORDER BY … LIMIT` over an index.
        #expect(sql.hasSuffix(#"WHERE t0."groupID" = ? ORDER BY t0."typeName" ASC"#))
    }

    @Test("simple keys arrive unwrapped")
    func fetchesSimpleKeys() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let keys = try await database.read { reader in
            try reader.fetchAll(
                TypeInfo.all()
                    .filter { type in type.groupID == UInt32(25) }
                    .order(by: { type in type.id })
                    .selectKey()
                    .query()
            )
        }

        #expect(keys.map{$0.key} == [1, 2])
        withExtendedLifetime(fixture) {}
    }

    @Test("a composite key is assembled from the whole projection")
    func fetchesCompositeKeys() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let keys = try await database.read { reader in
            try reader.fetchAll(
                TypeAttribute.all()
                    .filter { attribute in attribute.typeID == TypeID(rawValue: 1) }
                    .order(by: { attribute in attribute.attributeID })
                    .selectKey()
                    .query()
            )
        }

        #expect(
            keys.map{$0.key} == [
                TypeAttribute.PrimaryKey.Key(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 4)),
                TypeAttribute.PrimaryKey.Key(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 9)),
            ]
        )
        withExtendedLifetime(fixture) {}
    }

    @Test("the key is read by projection position, not table position")
    func decodesKeyOfTableWhereKeyIsNotFirst() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        // In `KeyedNotFirst` the key is the second table column, but in the key projection it is the
        // only one, at position zero. The offset from `Column.index` would miss to the neighbouring
        // column and read `groupID`.
        let key = try await database.read { reader in
            try reader.fetchOne(
                KeyedNotFirst.all().filter { type in type.name == "Raven" }.selectKey().query()
            )
        }

        #expect(key?.key == 3)
        withExtendedLifetime(fixture) {}
    }

    @Test("a page loads in two steps: keys first, then rows")
    func fetchesRowsByKeysFromKeyQuery() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader -> [String] in
            let keys = try reader.fetchAll(
                TypeInfo.all().order(by: { type in type.name }).limit(2).selectKey().query()
            )
            // A loop, not `map`: `Reader` is `~Copyable` and cannot be captured in a closure.
            var result = [String]()
            for key in keys {
                guard let row = try reader.fetchOne(TypeInfo.self, key: key.key) else { continue }
                result.append(row.name)
            }
            return result
        }

        #expect(names == ["Punisher", "Raven"])
        withExtendedLifetime(fixture) {}
    }

    @Test("the anchor column defaults to the first key column")
    func identityFollowsPrimaryKey() {
        #expect(KeyedNotFirst.identityColumn == 1)
        // An explicit mark beats the key.
        #expect(IdentityOverridesKey.identityColumn == 1)
        // The key is in the first column: the default does not change.
        #expect(TypeInfo.identityColumn == 0)
    }
}

// MARK: - Indexes

@Suite("Indexes")
struct TableIndexTests {
    @Test("@Index gives a single-column index with the default name")
    func columnIndex() throws {
        let index = try #require(IndexedType.descriptor.indexes.last)
        #expect(index.columns.map(\.name) == ["groupID"])
        #expect(index.isUnique == false)
        #expect(index.name == nil)
        // The automatic name includes the table name: index names are global to a schema.
        #expect(index.resolvedName == "idx_invTypes_groupID")
    }

    @Test("hand-written indexes follow the generated ones")
    func customIndexesAreAppended() {
        #expect(IndexedType.descriptor.indexes.count == 2)
        let custom = IndexedType.descriptor.indexes[0]
        #expect(custom.resolvedName == "invTypes_byNameAndGroup")
        #expect(custom.columns.map(\.name) == ["typeName", "groupID"])
        #expect(custom.columns.map(\.direction) == [.ascending, .descending])
    }

    @Test("name and uniqueness come from @Index")
    func uniqueIndex() throws {
        let index = try #require(UniquelyIndexedIcon.descriptor.indexes.first)
        #expect(index.resolvedName == "eveIcons_byType")
        #expect(index.isUnique)
    }

    @Test("a table without marks has no indexes")
    func noIndexes() {
        #expect(KeyedNotFirst.descriptor.indexes.isEmpty)
    }

    @Test("without any @Index mark the list consists of the manual indexes")
    func onlyCustomIndexes() throws {
        #expect(TypeAttribute.descriptor.indexes.count == 1)
        let index = try #require(TypeAttribute.descriptor.indexes.first)
        #expect(index.resolvedName == "dgmTypeAttributes_byAttributeValue")
        #expect(index.columns.map(\.name) == ["attributeID", "value"])
    }
}

