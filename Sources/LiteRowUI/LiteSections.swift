//
//  LiteSections.swift
//  LiteRowUI
//

import SwiftUI
import LiteRow

/// A sectioned list: section headers from one query, each section's rows from another.
///
/// ```swift
/// SectionedQuery(
///     sections: MetaSection.query(categoryID: categoryID),
///     rows: { section in TypeInfo.all()
///         .filter { $0.categoryID == categoryID && $0.metaLevel == section.metaLevel }
///         .order(by: { $0.name })
///         .query() }
/// )
/// ```
public struct SectionedQuery<Section: RowDecodable & Hashable, Row: RowDecodable>: Sendable {
    /// Section headers, typically a `GROUP BY` with `COUNT(*)`.
    public var sections: SQLQuery<Section>?

    /// Rows of one section.
    ///
    /// Pass the section key as a **parameter**, not a literal, so all sections share one
    /// prepared statement.
    public var rows: @Sendable (Section) -> SQLQuery<Row>?

    public init(sections: SQLQuery<Section>?,
                rows: @escaping @Sendable (Section) -> SQLQuery<Row>?) {
        self.sections = sections
        self.rows = rows
    }
}

/// A sectioned fetch as a view property.
///
/// ```swift
/// struct ModulesView: View {
///     @LiteSections private var modules: SectionedResult<MetaSection, TypeInfo>
///
///     init(categoryID: UInt32) {
///         _modules = LiteSections(.init(sections: …, rows: { … }))
///     }
///
///     var body: some View {
///         List {
///             ForEach(modules.sections, id: \.self) { section in
///                 DisclosureGroup("\(section.metaLevel) (\(section.count))") {
///                     ForEach(modules[section], id: \.id) { ModuleRow($0) }
///                 }
///             }
///         }
///     }
/// }
/// ```
///
/// ## Laziness
///
/// A section's rows are read on first access to `modules[section]`. A plain
/// `List { Section { ForEach } }` builds every section at once, so loading is only deferred
/// for collapsible sections. If sections are always expanded, a single query sorted by the
/// section key and grouped in Swift is cheaper.
@propertyWrapper
public struct LiteSections<Section: RowDecodable & Hashable, Row: RowDecodable>: DynamicProperty {
    @Environment(\.liteDatabase) private var database
    @Environment(\.liteQueryFailure) private var failure

    @State private var cache = SectionsCache<Section, Row>()

    private let query: SectionedQuery<Section, Row>

    public init(_ query: SectionedQuery<Section, Row>) {
        self.query = query
    }

    public var wrappedValue: SectionedResult<Section, Row> {
        // Local copies instead of capturing `self`: the wrapper is not `Sendable`.
        let cache = cache
        let query = query
        let database = database
        let failure = failure

        return MainActor.assumeIsolated {
            cache.result(for: query, database: database, failure: failure)
        }
    }
}

/// Section headers plus on-demand access to each section's rows.
@MainActor
public struct SectionedResult<Section: RowDecodable & Hashable, Row: RowDecodable> {
    /// Section headers in query order.
    public let sections: [Section]

    private let cache: SectionsCache<Section, Row>

    init(sections: [Section], cache: SectionsCache<Section, Row>) {
        self.sections = sections
        self.cache = cache
    }

    /// Rows of a section; read from the database on first access, then cached.
    public subscript(section: Section) -> [Row] {
        cache.rows(in: section)
    }

    public var isEmpty: Bool { sections.isEmpty }
}

@MainActor
final class SectionsCache<Section: RowDecodable & Hashable, Row: RowDecodable> {
    private struct Key: Equatable {
        var query: SQLQuery<Section>?
        var database: ObjectIdentifier?
    }

    /// What is needed to load a section after `result(for:…)` has returned.
    private struct Source {
        var database: Database
        var makeRows: @Sendable (Section) -> SQLQuery<Row>?
        var failure: LiteQueryFailure
    }

    private var key: Key?
    private var sections: [Section] = []
    private var source: Source?

    // Keyed by the rows query, so a changed filter misses the cache by itself.
    // Cleared when the sections query changes.
    private var rows: [SQLQuery<Row>: [Row]] = [:]

    private(set) var fetchCount = 0

    nonisolated init() {}

    func result(for query: SectionedQuery<Section, Row>,
                database: Database?,
                failure: LiteQueryFailure) -> SectionedResult<Section, Row> {
        source = database.map { Source(database: $0, makeRows: query.rows, failure: failure) }

        let key = Key(query: query.sections, database: database.map(ObjectIdentifier.init))
        if self.key != key {
            self.key = key
            rows.removeAll(keepingCapacity: true)
            sections = load(query.sections, database: database, failure: failure)
        }
        return SectionedResult(sections: sections, cache: self)
    }

    func rows(in section: Section) -> [Row] {
        guard let source, let query = source.makeRows(section) else { return [] }
        if let cached = rows[query] { return cached }
        let value = load(query, database: source.database, failure: source.failure)
        rows[query] = value
        return value
    }

    private func load<Output: RowDecodable>(_ query: SQLQuery<Output>?,
                                            database: Database?,
                                            failure: LiteQueryFailure) -> [Output] {
        guard let query else { return [] }
        guard let database else {
            failure.report(LiteQueryError.databaseMissing)
            return []
        }
        fetchCount += 1
        do {
            return try database.readSync { reader in
                try reader.fetchAll(query)
            }
        }
        catch {
            failure.report(error)
            return []
        }
    }
}
