//
//  FTS5Tests.swift
//  LiteRowBuildTests
//

import Foundation
import Testing

import LiteRowBuild
@testable import LiteRow

// MARK: - Models

/// An index over `invTypes`: column names match the content table, which is how fts5
/// links the index to the text.
@Table("invTypes_fts")
struct TypeSearch {
    @Column("typeName") var name: String
}

/// The same text with the `trigram` tokenizer: substring search from the middle of a word.
@Table("invTypes_tri")
struct TypeSubstring {
    @Column("typeName") var name: String
}

/// Its own copy of the text plus an unindexed column.
@Table("notes_fts")
struct NoteSearch {
    var title: String
    var body: String
}

// MARK: - DDL

@Suite("CREATE VIRTUAL TABLE")
struct FTS5SchemaTests {
    @Test("external content: the text stays in an ordinary table")
    func externalContent() {
        let definition = FTS5Definition(
            TypeSearch.self,
            content: TypeInfo.self,
            rowID: \.id,
            options: .asYouType
        )
        #expect(definition.createTableSQL == """
            CREATE VIRTUAL TABLE "main"."invTypes_fts" USING fts5(
                "typeName",
                tokenize = 'unicode61 remove_diacritics 2',
                prefix = '2 3',
                content = 'invTypes',
                content_rowid = 'typeID'
            )
            """)
    }

    @Test("trigram is declared without a prefix index")
    func trigram() {
        let definition = FTS5Definition(
            TypeSubstring.self,
            content: TypeInfo.self,
            rowID: \.id,
            options: .substring
        )
        #expect(definition.createTableSQL.contains("tokenize = 'trigram'"))
        // Trigrams match from the middle of a word on their own: a prefix index would only
        // bloat the file.
        #expect(!definition.createTableSQL.contains("prefix"))
    }

    @Test("an UNINDEXED column is stored but not indexed")
    func unindexedColumn() {
        let definition = FTS5Definition(NoteSearch.self, unindexed: ["body"])
        #expect(definition.createTableSQL.contains(#""title","#))
        #expect(definition.createTableSQL.contains(#""body" UNINDEXED"#))
    }

    @Test("detail is written only when it is not full")
    func detail() {
        let full = FTS5Definition(NoteSearch.self)
        #expect(!full.createTableSQL.contains("detail"))

        let none = FTS5Definition(
            NoteSearch.self,
            content: .contentless,
            options: .init(detail: .none)
        )
        #expect(none.createTableSQL.contains("content = ''"))
        #expect(none.createTableSQL.contains("detail = none"))
    }

    @Test("commands address the table by its own hidden column")
    func commands() {
        let definition = FTS5Definition(
            TypeSearch.self,
            content: TypeInfo.self,
            rowID: \.id,
            options: .init(pageSize: 4072)
        )
        #expect(definition.rebuildSQL
            == #"INSERT INTO "main"."invTypes_fts"("invTypes_fts") VALUES('rebuild')"#)
        #expect(definition.optimizeSQL
            == #"INSERT INTO "main"."invTypes_fts"("invTypes_fts") VALUES('optimize')"#)
        #expect(definition.pageSizeSQL
            == #"INSERT INTO "main"."invTypes_fts"("invTypes_fts", "rank") VALUES('pgsz', 4072)"#)
    }

    @Test("pgsz does not appear until requested")
    func pageSizeIsOptional() {
        #expect(FTS5Definition(NoteSearch.self).pageSizeSQL == nil)
    }
}

// MARK: - MATCH pattern

@Suite("MATCH pattern")
struct FTS5PatternTests {
    @Test("tokens are quoted, the asterisk goes to the last one")
    func tokens() {
        #expect(FTS5Pattern.all("heavy missile")?.query == #""heavy" AND "missile""#)
        // Only the last word is treated as a prefix: the user has finished the earlier ones.
        #expect(FTS5Pattern.all("heavy mis", prefix: true)?.query == #""heavy" AND "mis"*"#)
        #expect(FTS5Pattern.any("rifter punisher")?.query == #""rifter" OR "punisher""#)
        #expect(FTS5Pattern.phrase("heavy missile")?.query == #""heavy missile""#)
        #expect(FTS5Pattern.near("shield booster", distance: 5)?.query
            == #"NEAR("shield" "booster", 5)"#)
    }

    @Test("fts5 syntax cannot be built from input")
    func inputIsInert() {
        // Each of these values would be an fts5 syntax error if it reached MATCH as is.
        #expect(FTS5Pattern.all("AT-1")?.query == #""AT" AND "1""#)
        #expect(FTS5Pattern.all(#"rifter" OR "raven"#)?.query
            == #""rifter" AND "OR" AND "raven""#)
        #expect(FTS5Pattern.all("a*b")?.query == #""a" AND "b""#)
    }

    @Test("input without tokens is nil, not an empty MATCH")
    func emptyInput() {
        // An empty string to the right of MATCH is a syntax error again, so the caller
        // must handle "nothing to search for".
        #expect(FTS5Pattern.all("") == nil)
        #expect(FTS5Pattern.all("???") == nil)
        #expect(FTS5Pattern.phrase("  ") == nil)
    }

    @Test("combinators add parentheses")
    func combinators() {
        let left = FTS5Pattern(unsafe: "a OR b")
        let right = FTS5Pattern(unsafe: "c")
        #expect((left && right).query == "(a OR b) AND (c)")
        #expect((left || right).query == "(a OR b) OR (c)")
        #expect(left.excluding(right).query == "(a OR b) NOT (c)")
        #expect(right.restricted(to: "typeName").query == "{typeName} : (c)")
    }
}
