//
//  Examples.swift
//  LiteRow
//
//  Created by Artem Shimanski on 10.08.2026.
//

@testable import LiteRow

// Sample models shared by the tests; they match the tables in `MemoryDatabaseFixture`.

@Table("invTypes")
struct TypeInfo {
    @PrimaryKey @Column("typeID") var id: UInt32
    @Column("typeName") var name: String
    @Index var groupID: UInt32
    var group: Relation<TypeGroup> {
        TypeGroup.all().filter { $0.id == groupID }.limit(1)
    }
}

@Table("invGroups")
struct TypeGroup {
    @PrimaryKey @Column("groupID") var id: UInt32
    @Column("groupName") var name: String
    @Index var categoryID: UInt32

    var types: Relation<TypeInfo> {
        TypeInfo.all().filter{ $0.groupID == id }
    }
}

@Table("eveIcons")
struct TypeIcon {
    @PrimaryKey @Column("iconID") var id: UInt32
    @Index var typeID: UInt32
    @Column("iconFile") var path: String
}

/// FTS5 index over `invTypes`; the column name matches the content table's column.
@Table("invTypes_fts")
struct TypeSearchIndex {
    @Column("typeName") var name: String
}

/// A second-language FTS5 index over the same `invTypes`.
@Table("invTypes_fts_ru")
struct TypeSearchIndexRU {
    @Column("typeName") var name: String
}

// MARK: - Strongly typed keys

struct TypeID: RawRepresentable, Hashable, SQLiteValue {
    var rawValue: UInt32
}

struct AttributeID: RawRepresentable, Hashable, SQLiteValue {
    var rawValue: UInt32
}

/// Composite key `PRIMARY KEY (typeID, attributeID)` plus a composite index with a descending column.
@Table("dgmTypeAttributes")
struct TypeAttribute {
    @PrimaryKey @Column("typeID") var typeID: TypeID
    @PrimaryKey @Index("dgmTypeAttributes_byAttributeValue") @Column("attributeID") var attributeID: AttributeID
    @Index("dgmTypeAttributes_byAttributeValue", order: .descending) var value: Double
}

enum Examples {
    /// Searches both language indexes with a `UNION` of two ranked, limited operands.
    ///
    /// Returns `nil` when the text yields no tokens: an empty `MATCH` is an FTS5 syntax error.
    static func search(_ text: String, bothLanguages: Bool) -> SQLQuery<TypeInfo>? {
        guard let pattern = FTS5Pattern.all(text, prefix: true) else { return nil }

        let english = TypeSearchIndex.all()
            .join(TypeInfo.self) { fts, type in
                fts.rowID(as: UInt32.self) == type.id
            }
            .filter { fts, _ in fts.match(pattern) }
            .order(by: { fts, _ in fts.rank })
            .limit(25)
            .select { _, type in type }

        let russian = TypeSearchIndexRU.all()
            .join(TypeInfo.self) { fts, type in
                fts.rowID(as: UInt32.self) == type.id
            }
            .filter { fts, _ in fts.match(pattern) }
            .order(by: { fts, _ in fts.rank })
            .limit(25)
            .select { _, type in type }

        return english
            .union(russian)
            .order(by: \.name)
            .limit(50)
            .query()
    }
}
