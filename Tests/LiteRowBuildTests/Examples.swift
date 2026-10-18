//
//  Examples.swift
//  LiteRow
//
//  Created by Artem Shimanski on 10.08.2026.
//

@testable import LiteRow

// Sample models shared by the build tests.

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
    @Index var categoryID: UInt32
}

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
