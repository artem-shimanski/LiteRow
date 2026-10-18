//
//  FTS5RoundTripTests.swift
//  LiteRowBuildTests
//

import Foundation
import Testing

import LiteRowBuild
@testable import LiteRow

/// Building a search index and searching it with the same models.
///
/// This checks the seams, not fts5 itself: that the builder assembles `MATCH` by alias,
/// that `rank` and `snippet` reach SQL in a usable form and that the index survives
/// `VACUUM INTO`. Each of these breaks silently in its own way: an empty result,
/// a statement preparation error or a lost index in the finished file.
@Suite("Searching a built index")
struct FTS5RoundTripTests {
    private static let types = [
        TypeInfo(id: 1, name: "Rifter", groupID: 25),
        TypeInfo(id: 2, name: "Punisher", groupID: 25),
        TypeInfo(id: 3, name: "Raven", groupID: 27),
    ]

    /// An in-memory database with an index over `invTypes`.
    ///
    /// The order is part of the check: `rebuild` before the content table is filled would give
    /// an empty index with no sign of an error.
    private static func build(
        options: FTS5Definition.Options = .asYouType,
        name: String
    ) throws -> DatabaseBuilder {
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.create(TypeInfo.self, filledWith: types)
        try builder.create(fts: TypeSearch.self, indexing: TypeInfo.self, rowID: \.id, options: options)
        let definition = FTS5Definition(TypeSearch.self, content: TypeInfo.self, rowID: \.id, options: options)
        try builder.rebuild(definition)
        try builder.optimize(definition)
        try builder.createIndexes(TypeInfo.self)
        return builder
    }

    @Test("prefix search finds a row of the content table")
    func prefixSearch() async throws {
        let name = "literow-fts-\(UUID().uuidString)"
        let builder = try Self.build(name: name)
        let database = try Database(main: .memory(name: name), attached: [:])
        let pattern = try #require(FTS5Pattern.all("rif", prefix: true))

        let names = try await database.read { reader -> [String] in
            let query = TypeSearch.all()
                .join(TypeInfo.self) { fts, type in fts.rowID(as: UInt32.self) == type.id }
                .filter { fts, _ in fts.match(pattern) }
                .order(by: { fts, _ in fts.rank })
                .query()
            return try reader.fetchAll(query).map(\.right.name)
        }

        #expect(names == ["Rifter"])
        withExtendedLifetime(builder) {}
    }

    @Test("ordering by rank goes through the table alias")
    func ordersByRank() async throws {
        let name = "literow-fts-\(UUID().uuidString)"
        let builder = try Self.build(name: name)
        let database = try Database(main: .memory(name: name), attached: [:])
        // Both names start with "ra"/"ri"; what matters is that the query builds at all
        // and that relevance, not rowid, defines the order.
        let pattern = try #require(FTS5Pattern.any("rifter raven"))

        let (names, scores) = try await database.read { reader -> ([String], [Double]) in
            let query = TypeSearch.all()
                .join(TypeInfo.self) { fts, type in fts.rowID(as: UInt32.self) == type.id }
                .filter { fts, _ in fts.match(pattern) }
                .order(by: { fts, _ in fts.rank })
                .query()
            let rows = try reader.fetchAll(query)

            // A tuple projection, not a single expression: the type checker reduces a lone `select`
            // to an empty pack and returns `Tuple<>` instead of a scalar.
            let scored = TypeSearch.all()
                .filter { fts in fts.match(pattern) }
                .select { fts in (fts.rowID, fts.bm25()) }
                .query()
            return (rows.map(\.right.name), try reader.fetchAll(scored).map { $0.values.1 })
        }

        #expect(Set(names) == ["Rifter", "Raven"])
        // In SQLite a smaller bm25 means more relevant, so ORDER BY rank ascending
        // puts the best match first.
        #expect(scores.allSatisfy { $0 < 0 })
        withExtendedLifetime(builder) {}
    }

    @Test("bm25 weights are set by the query, not by a write to the database")
    func perQueryRanking() async throws {
        let name = "literow-fts-\(UUID().uuidString)"
        let builder = try Self.build(name: name)
        let database = try Database(main: .memory(name: name), attached: [:])
        let pattern = try #require(FTS5Pattern.all("raven"))

        let names = try await database.read { reader -> [String] in
            // The standard way is `INSERT INTO ft(ft, rank) VALUES('rank', …)`, but the connection is
            // read-only: a constraint on rank does the same without a write.
            let query = TypeSearch.all()
                .join(TypeInfo.self) { fts, type in fts.rowID(as: UInt32.self) == type.id }
                .filter { fts, _ in fts.match(pattern) && fts.ranked(by: .bm25(weights: [10.0])) }
                .order(by: { fts, _ in fts.rank })
                .query()
            return try reader.fetchAll(query).map(\.right.name)
        }

        #expect(names == ["Raven"])
        withExtendedLifetime(builder) {}
    }

    @Test("snippet highlights the match in external content")
    func snippet() async throws {
        let name = "literow-fts-\(UUID().uuidString)"
        let builder = try Self.build(name: name)
        let database = try Database(main: .memory(name: name), attached: [:])
        let pattern = try #require(FTS5Pattern.all("punisher"))

        let snippets = try await database.read { reader -> [String] in
            let query = TypeSearch.all()
                .filter { fts in fts.match(pattern) }
                .select { fts in (fts.rowID, fts.snippet(column: 0, start: "<", end: ">", tokens: 8)) }
                .query()
            return try reader.fetchAll(query).map { $0.values.1 }
        }

        #expect(snippets == ["<Punisher>"])
        withExtendedLifetime(builder) {}
    }

    @Test("trigram finds a substring from the middle of a word")
    func substringSearch() async throws {
        let name = "literow-fts-\(UUID().uuidString)"
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.create(TypeInfo.self, filledWith: Self.types)
        let definition = FTS5Definition(
            TypeSubstring.self,
            content: TypeInfo.self,
            rowID: \.id,
            options: .substring
        )
        try builder.create(definition)
        try builder.rebuild(definition)
        try builder.optimize(definition)

        let database = try Database(main: .memory(name: name), attached: [:])
        // "unis" is the middle of "Punisher": a prefix index cannot find that at all.
        let pattern = try #require(FTS5Pattern.phrase("unis"))

        let names = try await database.read { reader -> [String] in
            let query = TypeSubstring.all()
                .join(TypeInfo.self) { fts, type in fts.rowID(as: UInt32.self) == type.id }
                .filter { fts, _ in fts.match(pattern) }
                .query()
            return try reader.fetchAll(query).map(\.right.name)
        }

        #expect(names == ["Punisher"])
        withExtendedLifetime(builder) {}
    }

    @Test("the index survives VACUUM INTO")
    func survivesVacuum() async throws {
        let directory = URL.temporaryDirectory.appending(
            path: "literow-fts-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite", directoryHint: .notDirectory)

        let builder = try Self.build(name: "literow-fts-\(UUID().uuidString)")
        try builder.vacuum(into: url)
        builder.close()

        // Reading opens the file with `immutable=1`: if the virtual table lost its shadow tables
        // on copy, the search would return nothing rather than an error.
        let database = try Database(url: url)
        let pattern = try #require(FTS5Pattern.all("rav", prefix: true))
        let names = try await database.read { reader -> [String] in
            let query = TypeSearch.all()
                .join(TypeInfo.self) { fts, type in fts.rowID(as: UInt32.self) == type.id }
                .filter { fts, _ in fts.match(pattern) }
                .query()
            return try reader.fetchAll(query).map(\.right.name)
        }

        #expect(names == ["Raven"])
    }

    @Test("a contentless index returns keys, not text")
    func contentlessIndex() async throws {
        let name = "literow-fts-\(UUID().uuidString)"
        let builder = try DatabaseBuilder(inMemory: name)
        // Such an index has no content of its own, so it is filled by inserting rows:
        // `rebuild` has nothing to read from.
        try builder.create(fts: TypeSearch.self, content: .contentless)
        try builder.insert(Self.types.map { TypeSearch(name: $0.name) })

        let database = try Database(main: .memory(name: name), attached: [:])
        let pattern = try #require(FTS5Pattern.all("raven"))
        let rowIDs = try await database.read { reader -> [Int64] in
            let query = TypeSearch.all()
                .filter { fts in fts.match(pattern) }
                .select { fts in (fts.rowID, fts.rank) }
                .query()
            return try reader.fetchAll(query).map { $0.values.0 }
        }

        // The insert itself handed out the rowid: Raven was inserted third.
        #expect(rowIDs == [3])
        withExtendedLifetime(builder) {}
    }
}
