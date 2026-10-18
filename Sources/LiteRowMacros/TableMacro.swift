//
//  TableMacro.swift
//  LiteRowMacros
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct TableMacro {}

// MARK: - Members

extension TableMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let model: TableModel
        do {
            model = try TableModel(attribute: node, declaration: declaration)
        }
        catch let error as TableMacroError {
            context.diagnose(error.diagnostic)
            return []
        }

        var declarations: [DeclSyntax] = [model.columnsStruct, model.columnsValue]
        // Without the argument the protocol extension's `.main` default applies.
        if let schema = model.schema {
            declarations.append("\(raw: model.access)static let schema: LiteRow.DatabaseFile = \(schema)")
        }
        declarations.append("\(raw: model.access)static let tableName: String = \(raw: model.tableName.swiftStringLiteral)")
        if let identityIndex = model.identityIndex {
            declarations.append("\(raw: model.access)static let identityColumn: Int32 = \(raw: String(identityIndex))")
        }
        declarations.append(model.descriptorDeclaration)
        declarations.append(contentsOf: model.primaryKeyDeclarations)
        if let memberwiseInit = model.memberwiseInit {
            declarations.append(memberwiseInit)
        }
        return declarations
    }
}

// MARK: - Conformance and decoding

extension TableMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let model: TableModel
        do {
            model = try TableModel(attribute: node, declaration: declaration)
        }
        catch is TableMacroError {
            // Already diagnosed by the member expansion.
            return []
        }

        // Empty `protocols` means the conformance is declared by hand; only add the members.
        // `PrimaryKeyTable` is added only when the model has a key.
        var conformances: [String] = []
        for candidate in protocols {
            switch candidate.trailingIdentifier {
            case "Table":
                conformances.append("LiteRow.Table")
            case "PrimaryKeyTable" where model.hasPrimaryKey:
                conformances.append("LiteRow.PrimaryKeyTable")
            case "RowEncodable":
                conformances.append("LiteRow.RowEncodable")
            default:
                continue
            }
        }
        let conformance = conformances.isEmpty ? "" : ": \(conformances.joined(separator: ", "))"


        let source = """
            extension \(type.trimmedDescription)\(conformance) {
            \(model.rowInitializer)

            \(model.rowBinder)
            }
            """

        guard let extensionDecl = DeclSyntax("\(raw: source)").as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [extensionDecl]
    }
}

// MARK: - Generation

extension TableModel {
    /// The `Columns` struct with one typed column per property.
    ///
    /// A struct rather than a tuple: key paths into tuple elements fail to resolve when the
    /// root is a dependent type, as it is inside `join`/`filter` closures.
    var columnsStruct: DeclSyntax {
        var lines = ["\(access)struct Columns: Sendable {"]
        for (index, column) in columns.enumerated() {
            lines.append(
                "    \(access)let \(column.propertyName) = \(columnType(column))("
                    + "name: \(column.columnName.swiftStringLiteral), index: \(index))"
            )
        }
        lines.append("    \(access)init() {}")
        lines.append("}")
        return DeclSyntax("\(raw: lines.joined(separator: "\n"))")
    }

    /// A public memberwise initializer, for public models only (the synthesized one is `internal`).
    /// Default values are carried over as written.
    var memberwiseInit: DeclSyntax? {
        guard access == "public " else { return nil }
        let parameters = columns
            .map { column in
                let suffix = column.defaultValue.map { " = \($0)" } ?? ""
                return "\(column.propertyName): \(column.valueType)\(suffix)"
            }
            .joined(separator: ", ")
        var lines = ["\(access)init(\(parameters)) {"]
        for column in columns {
            lines.append("    self.\(column.propertyName) = \(column.propertyName)")
        }
        lines.append("}")
        return DeclSyntax("\(raw: lines.joined(separator: "\n"))")
    }

    /// The single `Columns` instance. Column indexes follow property order, which is the projection order.
    var columnsValue: DeclSyntax {
        DeclSyntax("\(raw: access)static let columns = Columns()")
    }

    /// The type-erased schema: columns, key and indexes, built from `columns`.
    var descriptorDeclaration: DeclSyntax {
        var lines = ["\(access)static let descriptor = LiteRow.TableDescriptor<Self>("]

        lines.append("    columns: [")
        for column in columns {
            lines.append("        \(accessor(column)).descriptor,")
        }
        lines.append("    ]")

        let key = primaryKey
        if !key.isEmpty {
            lines[lines.count - 1] += ","
            lines.append("    primaryKey: [")
            for column in key {
                lines.append("        \(accessor(column)).descriptor,")
            }
            lines.append("    ]")
        }

        let groups = indexGroups
        if !groups.isEmpty {
            lines[lines.count - 1] += ","
            lines.append("    indexes: [")
            for group in groups {
                let name = group.name.map { "name: \($0.swiftStringLiteral), " } ?? ""
                lines.append("        LiteRow.TableIndex<Self>(\(name)columns: [")
                for entry in group.columns {
                    lines.append("            \(indexColumnExpression(entry)),")
                }
                lines.append("        ], unique: \(group.isUnique)\(indexPredicates(group))),")
            }
            lines.append("    ]")
        }

        lines.append(")")
        return DeclSyntax("\(raw: lines.joined(separator: "\n"))")
    }

    /// Decodes from an offset, since the table may not come first in a join.
    var rowInitializer: String {
        var lines = [
            "    \(access)init(_ row: borrowing LiteRow.Row, offset: Int32) throws(LiteRow.LiteRowError) {"
        ]
        for column in columns {
            lines.append(
                "        self.\(column.propertyName) = try \(accessor(column))"
                    + ".decode(from: row, offset: offset)"
            )
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    /// The counterpart of `rowInitializer`: binds the same columns in `descriptor.columns` order.
    var rowBinder: String {
        var lines = [
            "    \(access)func bind(to binder: inout Binder) throws(LiteRowError) {"
        ]
        for column in columns {
            lines.append("        try binder.bind(\(column.propertyName))")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    /// The `PrimaryKeyTable` members: a nested `PrimaryKey` type and a `primaryKey` property.
    ///
    /// `PrimaryKey.Key` is the column type for a single-column key, or the `PrimaryKey` struct
    /// itself for a composite key. `columns` and `values(of:)` are unlabeled tuples so they
    /// match `(repeat each V)`.
    var primaryKeyDeclarations: [DeclSyntax] {
        let key = primaryKey
        guard !key.isEmpty else { return [] }

        // Fully qualified: a bare `columns` inside `PrimaryKey` would refer to its own member.
        func column(_ column: ColumnModel) -> String {
            "\(typeName).columns.\(column.propertyName)"
        }

        let isSimple = key.count == 1
        // `Hashable` only for a composite key; a simple key's value is the column type.
        let conformances = isSimple
            ? "LiteRow.PrimaryKeyProtocol"
            : "LiteRow.PrimaryKeyProtocol, Hashable"

        var lines = ["\(access)struct PrimaryKey: \(conformances) {"]
        lines.append("    \(access)typealias Key = \(isSimple ? key[0].valueType : "Self")")
        lines.append(
            "    \(access)typealias Values = "
                + (isSimple
                    ? key[0].valueType
                    : "(\(key.map(\.valueType).joined(separator: ", ")))")
        )

        if !isSimple {
            for keyColumn in key {
                lines.append("    \(access)var \(keyColumn.propertyName): \(keyColumn.valueType)")
            }
            let parameters = key
                .map { "\($0.propertyName): \($0.valueType)" }
                .joined(separator: ", ")
            lines.append("    \(access)init(\(parameters)) {")
            for keyColumn in key {
                lines.append("        self.\(keyColumn.propertyName) = \(keyColumn.propertyName)")
            }
            lines.append("    }")
        }

        lines.append(
            "    \(access)static let columns = "
                + (isSimple
                    ? column(key[0])
                    : "(\(key.map { column($0) }.joined(separator: ", ")))")
        )
        lines.append("    \(access)static let size: Int32 = \(key.count)")
        lines.append(
            "    \(access)static func values(of key: Key) -> Values { "
                + (isSimple
                    ? "key"
                    : "(\(key.map { "key.\($0.propertyName)" }.joined(separator: ", ")))")
                + " }"
        )
        lines.append(contentsOf: primaryKeyDecoder(key, column: column))
        lines.append("}")

        let keyValue = isSimple
            ? key[0].propertyName
            : "PrimaryKey(\(key.map { "\($0.propertyName): \($0.propertyName)" }.joined(separator: ", ")))"

        return [
            DeclSyntax("\(raw: lines.joined(separator: "\n"))"),
            DeclSyntax("\(raw: access)var primaryKey: PrimaryKey.Key { \(raw: keyValue) }"),
        ]
    }

    /// Reads a key from a key-only projection; positions follow key order, not `Column.index`.
    ///
    /// Locals are named positionally (`component0`, …) so a property name cannot shadow `row` or `offset`.
    private func primaryKeyDecoder(
        _ key: [ColumnModel],
        column: (ColumnModel) -> String
    ) -> [String] {
        var lines = [
            "    \(access)static func decode("
                + "_ row: borrowing LiteRow.Row, offset: Int32"
                + ") throws(LiteRow.LiteRowError) -> Key {"
        ]

        if key.count == 1 {
            lines.append("        try \(column(key[0])).decode(from: row, at: offset)")
        }
        else {
            for (position, keyColumn) in key.enumerated() {
                let at = position == 0 ? "offset" : "offset + \(position)"
                lines.append(
                    "        let component\(position) = try \(column(keyColumn))"
                        + ".decode(from: row, at: \(at))"
                )
            }
            let arguments = key.enumerated()
                .map { position, keyColumn in "\(keyColumn.propertyName): component\(position)" }
                .joined(separator: ", ")
            lines.append("        return Key(\(arguments))")
        }

        lines.append("    }")
        return lines
    }

    /// Partial index predicates, with column names resolved from the model.
    private func indexPredicates(_ group: IndexGroup) -> String {
        guard !group.predicates.isEmpty else { return "" }
        let items = group.predicates.map { entry in
            "LiteRow.IndexPredicate(column: \(entry.column.columnName.swiftStringLiteral), "
                + "condition: .\(entry.condition))"
        }
        return ", predicates: [\(items.joined(separator: ", "))]"
    }

    private func columnType(_ column: ColumnModel) -> String {
        "LiteRow.Column<\(typeName), \(column.valueType)>"
    }

    /// `.column(Self.columns.value, .descending, collate: "NOCASE")`, omitting default arguments.
    private func indexColumnExpression(_ entry: (column: ColumnModel, mark: IndexMark)) -> String {
        var arguments = [accessor(entry.column)]
        if entry.mark.isDescending {
            arguments.append(".descending")
        }
        if let collation = entry.mark.collation {
            arguments.append("collate: \(collation.swiftStringLiteral)")
        }
        return ".column(\(arguments.joined(separator: ", ")))"
    }
}

// MARK: - Markers

/// Marker read by `@Table`; expands to nothing.
public struct ColumnMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Primary key marker read by `@Table`.
public struct PrimaryKeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Index marker read by `@Table`, which merges same-named attributes into one composite index.
public struct IndexMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Partial index condition marker read by `@Table`, which rejects unknown index names.
public struct IndexFilterMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
