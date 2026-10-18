//
//  TableModel.swift
//  LiteRowMacros
//

import SwiftDiagnostics
import SwiftSyntax

// MARK: - Diagnostics

/// `@Table` diagnostics, attached to the offending syntax node.
enum TableMacroMessage: DiagnosticMessage {
    case unsupportedDeclaration
    case genericTypeUnsupported
    case missingTableName
    case missingTypeAnnotation(property: String)
    case noColumns
    case duplicateIdentity
    case invalidColumnName
    case invalidIndexOrder
    case invalidIndexCondition
    case missingIndexFilterName
    case unknownIndexGroup(name: String, property: String)
    case markOnNonColumn(property: String, mark: String)

    var message: String {
        switch self {
        case .unsupportedDeclaration:
            "@Table can only be applied to a struct or a final class"
        case .genericTypeUnsupported:
            "@Table does not support generic types: the table name is shared by all specializations"
        case .missingTableName:
            #"@Table requires the table name as a string literal: @Table("invTypes")"#
        case let .missingTypeAnnotation(property):
            "Property '\(property)' needs an explicit type annotation: the column type is taken from it"
        case .noColumns:
            "@Table found no stored properties"
        case .duplicateIdentity:
            "Only one identity column is allowed: @Column(identity: true) appears more than once"
        case .invalidColumnName:
            "The column name must be a string literal without interpolation"
        case .invalidIndexOrder:
            "The @Index order must be a literal: .ascending or .descending"
        case .invalidIndexCondition:
            "The partial index condition must be a literal: .notNull, .null, .isTrue or .isFalse"
        case .missingIndexFilterName:
            #"@IndexFilter requires the index name as a string literal: @IndexFilter("byFlag", .isTrue)"#
        case let .unknownIndexGroup(name, property):
            "@IndexFilter(\"\(name)\") on property '\(property)': this table has no index with that name; "
                + "it must match a name used in @Index"
        case let .markOnNonColumn(property, mark):
            "'\(property)' is not a column, so \(mark) has no effect on it"
        }
    }

    var severity: DiagnosticSeverity { .error }

    var diagnosticID: MessageID {
        let id: String = switch self {
        case .unsupportedDeclaration: "unsupportedDeclaration"
        case .genericTypeUnsupported: "genericTypeUnsupported"
        case .missingTableName: "missingTableName"
        case .missingTypeAnnotation: "missingTypeAnnotation"
        case .noColumns: "noColumns"
        case .duplicateIdentity: "duplicateIdentity"
        case .invalidColumnName: "invalidColumnName"
        case .invalidIndexOrder: "invalidIndexOrder"
        case .invalidIndexCondition: "invalidIndexCondition"
        case .missingIndexFilterName: "missingIndexFilterName"
        case .unknownIndexGroup: "unknownIndexGroup"
        case .markOnNonColumn: "markOnNonColumn"
        }
        return MessageID(domain: "LiteRowMacros", id: id)
    }
}

struct TableMacroError: Error {
    let diagnostic: Diagnostic

    init(_ message: TableMacroMessage, at node: some SyntaxProtocol) {
        diagnostic = Diagnostic(node: Syntax(node), message: message)
    }
}

// MARK: - Model

/// One `@Index` attribute on one property. Attributes with the same name form one composite index.
struct IndexMark {
    var name: String?
    var isUnique: Bool = false
    var isDescending: Bool = false
    var collation: String?
    /// A partial index condition on this column (`@Index(where:)`).
    var condition: String?
}

/// One `@IndexFilter` attribute: a condition on this column for another column's index.
struct IndexFilterMark {
    var name: String
    var condition: String
}

struct ColumnModel {
    /// The Swift property name.
    var propertyName: String
    /// The column name in the database.
    var columnName: String
    /// The value type as written in the annotation.
    var valueType: String
    /// The default value as written; used by the memberwise initializer.
    var defaultValue: String?
    var isIdentity: Bool
    var isPrimaryKey: Bool
    /// `@Index` attributes on this property, in source order.
    var indexes: [IndexMark] = []
    /// `@IndexFilter` attributes: conditions for indexes declared on other columns.
    var filters: [IndexFilterMark] = []
}

/// An index built from attributes: one column, or several sharing a name.
struct IndexGroup {
    /// `nil` lets `TableIndex.resolvedName` derive the name.
    var name: String?
    var isUnique: Bool
    var columns: [(column: ColumnModel, mark: IndexMark)]
    /// Partial index conditions from `@Index(where:)` and `@IndexFilter`, in property order.
    var predicates: [(column: ColumnModel, condition: String)] = []
}

/// The parsed declaration.
struct TableModel {
    var typeName: String
    /// Access modifier for generated members (with a trailing space, or empty).
    var access: String
    var tableName: String
    /// The schema expression as written (`.icons`), or `nil` for the `.main` default.
    var schema: ExprSyntax?
    var columns: [ColumnModel]
    /// The identity column index; `nil` keeps the protocol default (0).
    var identityIndex: Int?
    /// Indexes, computed once in the initializer since building them can emit diagnostics.
    var indexGroups: [IndexGroup]
}

extension TableModel {
    /// Primary key columns in declaration order.
    var primaryKey: [ColumnModel] {
        columns.filter(\.isPrimaryKey)
    }

    var hasPrimaryKey: Bool {
        columns.contains(where: \.isPrimaryKey)
    }

    /// Groups index attributes by name.
    ///
    /// Groups are ordered by first mention, columns within a group by property order.
    /// Partial index conditions are collected in property order regardless of their source.
    static func makeIndexGroups(
        columns: [ColumnModel],
        declaration: some DeclGroupSyntax
    ) throws -> [IndexGroup] {
        var groups: [IndexGroup] = []
        var positionsByName: [String: Int] = [:]
        // Sorted before distribution so the order does not depend on the attribute kind.
        var predicates: [(group: Int, property: Int, column: ColumnModel, condition: String)] = []

        for (position, column) in columns.enumerated() {
            for mark in column.indexes {
                let group: Int
                if let name = mark.name, let existing = positionsByName[name] {
                    groups[existing].columns.append((column, mark))
                    // Unique if any attribute in the group says so.
                    groups[existing].isUnique = groups[existing].isUnique || mark.isUnique
                    group = existing
                }
                else {
                    if let name = mark.name {
                        positionsByName[name] = groups.count
                    }
                    group = groups.count
                    groups.append(
                        IndexGroup(name: mark.name, isUnique: mark.isUnique, columns: [(column, mark)])
                    )
                }
                if let condition = mark.condition {
                    predicates.append((group, position, column, condition))
                }
            }
        }

        for (position, column) in columns.enumerated() {
            for filter in column.filters {
                guard let group = positionsByName[filter.name] else {

                    throw TableMacroError(
                        .unknownIndexGroup(name: filter.name, property: column.propertyName),
                        at: declaration
                    )
                }
                predicates.append((group, position, column, filter.condition))
            }
        }

        for entry in predicates.sorted(by: { ($0.group, $0.property) < ($1.group, $1.property) }) {
            groups[entry.group].predicates.append((entry.column, entry.condition))
        }

        return groups
    }

    /// How generated code refers to a typed column.
    func accessor(_ column: ColumnModel) -> String {
        "Self.columns.\(column.propertyName)"
    }
}

// MARK: - Parsing

extension TableModel {
    init(attribute: AttributeSyntax, declaration: some DeclGroupSyntax) throws {
        let typeName: TokenSyntax
        let generics: GenericParameterClauseSyntax?

        if let structDecl = declaration.as(StructDeclSyntax.self) {
            typeName = structDecl.name
            generics = structDecl.genericParameterClause
        }
        else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            typeName = classDecl.name
            generics = classDecl.genericParameterClause
        }
        else {
            throw TableMacroError(.unsupportedDeclaration, at: declaration)
        }

        if let generics {
            throw TableMacroError(.genericTypeUnsupported, at: generics)
        }

        self.typeName = typeName.text
        access = Self.accessModifier(of: declaration)

        let arguments = attribute.arguments?.as(LabeledExprListSyntax.self)
        var tableName: String?
        var schema: ExprSyntax?

        for argument in arguments ?? [] {
            switch argument.label?.text {
            case nil:
                guard let value = argument.expression.staticStringValue else {
                    throw TableMacroError(.missingTableName, at: argument.expression)
                }
                tableName = value
            case "schema":
                // Passed through as is; the compiler type-checks it as `DatabaseFile`.
                schema = argument.expression.trimmed
            default:
                break
            }
        }

        guard let tableName, !tableName.isEmpty else {
            throw TableMacroError(.missingTableName, at: attribute)
        }
        self.tableName = tableName
        self.schema = schema

        // A local, since closures cannot capture `self` before all properties are initialized.
        let parsed = try Self.columns(of: declaration)
        guard !parsed.isEmpty else {
            throw TableMacroError(.noColumns, at: declaration)
        }
        columns = parsed
        indexGroups = try Self.makeIndexGroups(columns: parsed, declaration: declaration)

        let identities = parsed.indices.filter { parsed[$0].isIdentity }
        if identities.count > 1 {
            throw TableMacroError(.duplicateIdentity, at: declaration)
        }
        // Defaults to the first key column, or the protocol default (column 0) without a key.
        identityIndex = identities.first ?? parsed.firstIndex(where: \.isPrimaryKey)
    }

    /// The access modifier for generated members; shared with `@Projection`.
    static func accessModifier(of declaration: some DeclGroupSyntax) -> String {
        for modifier in declaration.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return "public "
            case .keyword(.package):
                return "package "
            default:
                continue
            }
        }
        return ""
    }

    private static func columns(of declaration: some DeclGroupSyntax) throws -> [ColumnModel] {
        var result: [ColumnModel] = []

        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }

            let isTypeLevel = variable.modifiers.contains { modifier in
                switch modifier.name.tokenKind {
                case .keyword(.static), .keyword(.class): true
                default: false
                }
            }
            if isTypeLevel { continue }

            let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
            let marks = try PropertyMarks(attributes: variable.attributes)

            for binding in variable.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let propertyName = pattern.identifier.text

                // A `let` with a default value cannot be assigned in an initializer, so it is not a column.
                let isSkipped = !Self.isStored(binding) || (isLet && binding.initializer != nil)
                if isSkipped {
                    // An attribute on a skipped property is almost certainly a mistake.
                    if let mark = marks.firstMarkName {
                        throw TableMacroError(
                            .markOnNonColumn(property: propertyName, mark: mark),
                            at: binding
                        )
                    }
                    continue
                }

                guard let type = binding.typeAnnotation?.type else {
                    throw TableMacroError(.missingTypeAnnotation(property: propertyName), at: binding)
                }

                result.append(
                    ColumnModel(
                        propertyName: propertyName,
                        columnName: marks.name ?? propertyName,
                        valueType: type.trimmedDescription,
                        defaultValue: binding.initializer?.value.trimmedDescription,
                        isIdentity: marks.isIdentity,
                        isPrimaryKey: marks.isPrimaryKey,
                        indexes: marks.indexes,
                        filters: marks.filters
                    )
                )
            }
        }

        return result
    }

    /// A stored property: no accessors, or only observers. Shared with `@Projection`.
    static func isStored(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessors = binding.accessorBlock else { return true }
        switch accessors.accessors {
        case let .accessors(list):
            return list.allSatisfy { accessor in
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.willSet), .keyword(.didSet): true
                default: false
                }
            }
        case .getter:
            return false
        }
    }
}

// MARK: - @Column, @PrimaryKey, @Index

/// What the attributes say about one property.
private struct PropertyMarks {
    var name: String?
    var isIdentity: Bool = false
    var isPrimaryKey: Bool = false
    var indexes: [IndexMark] = []
    var filters: [IndexFilterMark] = []

    /// For diagnostics: the attribute found on a property that is not a column.
    var firstMarkName: String? {
        if isPrimaryKey { return "@PrimaryKey" }
        if !indexes.isEmpty { return "@Index" }
        if !filters.isEmpty { return "@IndexFilter" }
        if name != nil || isIdentity { return "@Column" }
        return nil
    }

    /// The `IndexCondition` case name from `.notNull` / `IndexCondition.notNull`, validated
    /// here so the diagnostic points at the attribute.
    private static func condition(_ expression: ExprSyntax) throws -> String {
        guard let value = expression.trailingMemberName,
              ["notNull", "null", "isTrue", "isFalse"].contains(value)
        else {
            throw TableMacroError(.invalidIndexCondition, at: expression)
        }
        return value
    }

    init(attributes: AttributeListSyntax) throws {
        for element in attributes {
            guard case let .attribute(attribute) = element else { continue }
            let arguments = attribute.arguments?.as(LabeledExprListSyntax.self)

            switch attribute.attributeName.trailingIdentifier {
            case "Column":
                for argument in arguments ?? [] {
                    switch argument.label?.text {
                    case nil:
                        guard let value = argument.expression.staticStringValue else {
                            throw TableMacroError(.invalidColumnName, at: argument.expression)
                        }
                        name = value
                    case "identity":
                        isIdentity = argument.expression.booleanValue ?? false
                    default:
                        break
                    }
                }

            case "PrimaryKey":
                isPrimaryKey = true

            case "Index":
                var mark = IndexMark()
                for argument in arguments ?? [] {
                    switch argument.label?.text {
                    case nil:
                        // `@Index(nil)` is a valid unnamed index.
                        if argument.expression.isNilLiteral { break }
                        guard let value = argument.expression.staticStringValue else {
                            throw TableMacroError(.invalidColumnName, at: argument.expression)
                        }
                        mark.name = value
                    case "unique":
                        mark.isUnique = argument.expression.booleanValue ?? false
                    case "order":
                        guard let value = argument.expression.trailingMemberName else {
                            throw TableMacroError(.invalidIndexOrder, at: argument.expression)
                        }
                        switch value {
                        case "descending": mark.isDescending = true
                        case "ascending": mark.isDescending = false
                        default: throw TableMacroError(.invalidIndexOrder, at: argument.expression)
                        }
                    case "collate":
                        if argument.expression.isNilLiteral { break }
                        guard let value = argument.expression.staticStringValue else {
                            throw TableMacroError(.invalidColumnName, at: argument.expression)
                        }
                        mark.collation = value
                    case "where":
                        if argument.expression.isNilLiteral { break }
                        mark.condition = try Self.condition(argument.expression)
                    default:
                        break
                    }
                }
                indexes.append(mark)

            case "IndexFilter":
                // Two required unlabeled arguments: the index name and the condition.
                var name: String?
                var condition: String?
                for argument in arguments ?? [] {
                    guard argument.label == nil else { continue }
                    if name == nil {
                        guard let value = argument.expression.staticStringValue else {
                            throw TableMacroError(.missingIndexFilterName, at: argument.expression)
                        }
                        name = value
                    }
                    else {
                        condition = try Self.condition(argument.expression)
                    }
                }
                guard let name else {
                    throw TableMacroError(.missingIndexFilterName, at: attribute)
                }
                guard let condition else {
                    throw TableMacroError(.invalidIndexCondition, at: attribute)
                }
                filters.append(IndexFilterMark(name: name, condition: condition))

            default:
                continue
            }
        }
    }
}

// MARK: - Syntax helpers

extension ExprSyntaxProtocol {
    /// The value of a string literal without interpolation, or `nil`.
    var staticStringValue: String? {
        guard let literal = self.as(StringLiteralExprSyntax.self) else { return nil }
        var result = ""
        for segment in literal.segments {
            guard case let .stringSegment(text) = segment else { return nil }
            result += text.content.text
        }
        return result
    }

    var booleanValue: Bool? {
        guard let literal = self.as(BooleanLiteralExprSyntax.self) else { return nil }
        return literal.literal.tokenKind == .keyword(.true)
    }

    var isNilLiteral: Bool {
        self.as(NilLiteralExprSyntax.self) != nil
    }

    /// The member name in both `.descending` and `Order.descending`.
    var trailingMemberName: String? {
        self.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }
}

extension TypeSyntax {
    /// The last name component, so `@Column` and `@LiteRow.Column` match.
    var trailingIdentifier: String? {
        if let identifier = self.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = self.as(MemberTypeSyntax.self) {
            return member.name.text
        }
        return nil
    }
}

extension String {
    /// A Swift string literal for generated code.
    var swiftStringLiteral: String {
        var result = "\""
        for character in self {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        result += "\""
        return result
    }
}
