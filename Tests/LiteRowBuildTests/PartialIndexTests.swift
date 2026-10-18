//
//  PartialIndexTests.swift
//  LiteRowBuildTests
//

import Foundation
import Testing

import LiteRowBuild
@testable import LiteRow

/// Models with partial indexes.
///
/// All three cases are real: a column filled in a minority of rows (`marketGroupID`,
/// `variationParentID`) and a flag raised in a minority (`hasShipRestrictions`).
/// A full index on such tables is mostly an index of `NULL`s.
@Table("partialTypes")
struct PartialType {
    @PrimaryKey var id: UInt32
    var name: String
    @Index(where: .notNull) var marketGroupID: UInt32?
    @Index("byVariation", where: .notNull) var variationParentID: UInt32?
}

@Table("partialItems")
struct PartialItem {
    @PrimaryKey @Index("byRestricted") var id: UInt32
    @IndexFilter("byRestricted", .isTrue) var hasShipRestrictions: Bool
    var value: Double
}

/// Two conditions on one index: joined with `AND` in property order.
@Table("partialPairs")
struct PartialPair {
    @PrimaryKey @Index("byBoth") var id: UInt32
    @IndexFilter("byBoth", .isTrue) var isPublished: Bool
    @IndexFilter("byBoth", .notNull) var groupID: UInt32?
    @Index("byMissing", where: .null) var note: String?
}

@Suite("CREATE INDEX … WHERE")
struct PartialIndexSQLTests {
    @Test("a condition on its own column comes from @Index(where:)")
    func selfColumnCondition() {
        #expect(TableDefinition(PartialType.self).createIndexSQL == [
            #"CREATE INDEX "main"."idx_partialTypes_marketGroupID" ON "partialTypes" ("marketGroupID") WHERE "marketGroupID" IS NOT NULL"#,
            #"CREATE INDEX "main"."byVariation" ON "partialTypes" ("variationParentID") WHERE "variationParentID" IS NOT NULL"#,
        ])
    }

    @Test("a condition on another column comes from @IndexFilter")
    func foreignColumnCondition() {
        // The flag is written as a bare column, not `= 1`: the planner picks a partial index
        // only when the predicate shape matches, and it no longer matches `= 1` with `"flag"`.
        #expect(TableDefinition(PartialItem.self).createIndexSQL == [
            #"CREATE INDEX "main"."byRestricted" ON "partialItems" ("id") WHERE "hasShipRestrictions""#
        ])
    }

    @Test("several conditions are joined with AND in property order")
    func conditionsAreAnded() {
        #expect(TableDefinition(PartialPair.self).createIndexSQL == [
            #"CREATE INDEX "main"."byBoth" ON "partialPairs" ("id") WHERE "isPublished" AND "groupID" IS NOT NULL"#,
            #"CREATE INDEX "main"."byMissing" ON "partialPairs" ("note") WHERE "note" IS NULL"#,
        ])
    }

    @Test("an index without conditions stays as it was")
    func plainIndexIsUnchanged() {
        #expect(TableDefinition(TypeInfo.self).createIndexSQL == [
            #"CREATE INDEX "main"."idx_invTypes_groupID" ON "invTypes" ("groupID")"#
        ])
    }
}

/// Query plan on a built database.
///
/// These tests are not about the DDL text (the suite above covers that) but about the planner
/// actually **using** the partial index. This has to be checked on data: SQLite can prove
/// predicate implication in different ways, and the difference between "used" and "not used"
/// shows up nowhere except in the plan.
@Suite("Partial index in the query plan")
struct PartialIndexPlanTests {
    private static let rowCount: UInt32 = 5_000

    /// Every 200th row with a non-null `marketGroupID`, every 200th with the flag raised.
    private static func build() throws -> (DatabaseBuilder, Database) {
        let name = "literow-partial-\(UUID().uuidString)"
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.create(PartialType.self, filledWith: (1 ... rowCount).map { id in
            PartialType(
                id: id,
                name: "type\(id)",
                marketGroupID: id % 200 == 0 ? id : nil,
                variationParentID: nil
            )
        })
        try builder.create(PartialItem.self, filledWith: (1 ... rowCount).map { id in
            PartialItem(id: id, hasShipRestrictions: id % 200 == 0, value: Double(id))
        })
        try builder.createIndexes(PartialType.self)
        try builder.createIndexes(PartialItem.self)
        try builder.analyze()
        return (builder, try Database(main: .memory(name: name), attached: [:]))
    }

    /// `EXPLAIN QUERY PLAN` on the same connection as an ordinary query: four columns,
    /// the plan text is the last.
    private static func plan<Output>(of query: SQLQuery<Output>, in database: Database) async throws -> String {
        let explained = SQLQuery<Tuple<Int, Int, Int, String>>(
            "EXPLAIN QUERY PLAN \(query.sql)",
            bindings: query.bindings
        )
        return try await database.read { reader in
            try reader.fetchAll(explained).map(\.values.3).joined(separator: "\n")
        }
    }

    @Test("a partial index on IS NOT NULL is chosen for an ordinary comparison with a parameter")
    func notNullIndexIsUsedWithParameter() async throws {
        let (builder, database) = try Self.build()

        // Key point: the right side is `?`, not a literal. Parameters do not hinder implication:
        // `col = ?` is true only for a non-null `col`, whatever the value.
        let query = PartialType.all().filter { $0.marketGroupID == 4000 }.query()
        let plan = try await Self.plan(of: query, in: database)

        #expect(plan.contains("idx_partialTypes_marketGroupID"), "\(plan)")
        withExtendedLifetime(builder) {}
    }

    @Test("a partial index on a flag is chosen by a filter on the column itself")
    func flagIndexIsUsedWithBareColumn() async throws {
        let (builder, database) = try Self.build()

        let query = PartialItem.all().filter { $0.hasShipRestrictions }.selectKey().query()
        let plan = try await Self.plan(of: query, in: database)

        #expect(plan.contains("byRestricted"), "\(plan)")
        withExtendedLifetime(builder) {}
    }

    @Test("comparing a flag with true does not choose the index: a trap, not a typo")
    func flagComparedToLiteralLosesTheIndex() async throws {
        // Regression documentation. `== true` goes out as a parameter (`"flag" = ?`), while the prover
        // matches `WHERE "flag"` only with the same bare column. Even a literal `= 1` does not choose
        // the index, so the parameter is not the cause: the predicate shapes must match.
        // The right way to write it is `filter { $0.flag }`.
        let (builder, database) = try Self.build()

        let query = PartialItem.all().filter { $0.hasShipRestrictions == true }.selectKey().query()
        let plan = try await Self.plan(of: query, in: database)

        #expect(!plan.contains("byRestricted"), "\(plan)")
        withExtendedLifetime(builder) {}
    }
}
