//
//  ProjectionMacro.swift
//  LiteRowMacros
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Diagnostics

enum ProjectionMacroMessage: DiagnosticMessage {
    case unsupportedDeclaration
    case genericTypeUnsupported
    case missingTypeAnnotation(property: String)
    case noFields
    case embeddedOnNonField(property: String)

    var message: String {
        switch self {
        case .unsupportedDeclaration:
            "@Projection can only be applied to a struct or a final class"
        case .genericTypeUnsupported:
            "@Projection does not support generic types"
        case let .missingTypeAnnotation(property):
            "Property '\(property)' needs an explicit type annotation: the column type is taken from it"
        case .noFields:
            "@Projection found no stored properties to project"
        case let .embeddedOnNonField(property):
            "'\(property)' is not a projection column, so @Embedded has no effect on it"
        }
    }

    var severity: DiagnosticSeverity { .error }

    var diagnosticID: MessageID {
        let id: String = switch self {
        case .unsupportedDeclaration: "projectionUnsupportedDeclaration"
        case .genericTypeUnsupported: "projectionGenericTypeUnsupported"
        case .missingTypeAnnotation: "projectionMissingTypeAnnotation"
        case .noFields: "projectionNoFields"
        case .embeddedOnNonField: "projectionEmbeddedOnNonField"
        }
        return MessageID(domain: "LiteRowMacros", id: id)
    }
}

struct ProjectionMacroError: Error {
    let diagnostic: Diagnostic

    init(_ message: ProjectionMacroMessage, at node: some SyntaxProtocol) {
        diagnostic = Diagnostic(node: Syntax(node), message: message)
    }
}

// MARK: - Model

/// One projection field: either an expression or a whole table (`@Embedded`).
struct ProjectionField {
    var propertyName: String
    /// The type as written: `String?`, `TypeInfo`, `TypeIcon?`.
    var declaredType: String
    /// The same type without `?`.
    var baseType: String
    var isOptional: Bool
    var isEmbedded: Bool
}

struct ProjectionModel {
    var typeName: String
    var access: String
    var fields: [ProjectionField]
}

extension ProjectionModel {
    init(declaration: some DeclGroupSyntax) throws {
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
            throw ProjectionMacroError(.unsupportedDeclaration, at: declaration)
        }

        if let generics {
            throw ProjectionMacroError(.genericTypeUnsupported, at: generics)
        }

        self.typeName = typeName.text
        access = TableModel.accessModifier(of: declaration)
        fields = try Self.fields(of: declaration)
        guard !fields.isEmpty else {
            throw ProjectionMacroError(.noFields, at: declaration)
        }
    }

    /// Same rules as `@Table`: stored `var`s and `let`s without an initial value become columns.
    private static func fields(of declaration: some DeclGroupSyntax) throws -> [ProjectionField] {
        var result: [ProjectionField] = []

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
            let isEmbedded = variable.attributes.contains { element in
                guard case let .attribute(attribute) = element else { return false }
                return attribute.attributeName.trailingIdentifier == "Embedded"
            }

            for binding in variable.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let propertyName = pattern.identifier.text

                let isSkipped = !TableModel.isStored(binding) || (isLet && binding.initializer != nil)
                if isSkipped {
                    // An attribute on a skipped property is almost certainly a mistake.
                    if isEmbedded {
                        throw ProjectionMacroError(.embeddedOnNonField(property: propertyName), at: binding)
                    }
                    continue
                }

                guard let type = binding.typeAnnotation?.type else {
                    throw ProjectionMacroError(.missingTypeAnnotation(property: propertyName), at: binding)
                }

                let declared = type.trimmedDescription
                let base = type.unwrappedOptional?.trimmedDescription ?? declared
                result.append(
                    ProjectionField(
                        propertyName: propertyName,
                        declaredType: declared,
                        baseType: base,
                        isOptional: base != declared,
                        isEmbedded: isEmbedded
                    )
                )
            }
        }

        return result
    }
}

// MARK: - Generation

extension ProjectionModel {
    /// Column offsets as expressions, e.g. `offset + 2 + TypeInfo.width`: an embedded table's width
    /// is only known to its type.
    private func offsets() -> (offsets: [String], width: String) {
        var constant = 0
        var terms: [String] = []
        var result: [String] = []

        func expression(_ prefix: String?) -> String {
            var parts: [String] = []
            if let prefix { parts.append(prefix) }
            if constant > 0 || parts.isEmpty { parts.append(String(constant)) }
            parts.append(contentsOf: terms)
            return parts.joined(separator: " + ")
        }

        for field in fields {
            result.append(expression("offset"))
            if field.isEmbedded {
                terms.append("\(field.baseType).width")
            }
            else {
                constant += 1
            }
        }

        return (result, expression(nil))
    }

    var declarations: (width: String, initializer: String, factory: String) {
        let (offsets, width) = offsets()

        var initializer = [
            "\(access)init(_ row: borrowing LiteRow.Row, offset: Int32) throws(LiteRow.LiteRowError) {"
        ]
        for (field, offset) in zip(fields, offsets) {
            if field.isEmbedded {

                let type = field.isOptional ? "Optional<\(field.baseType)>" : field.baseType
                initializer.append("    self.\(field.propertyName) = try \(type)(row, offset: \(offset))")
            }
            else {
                initializer.append(
                    "    self.\(field.propertyName) = try \(field.declaredType)(from: row, at: \(offset))"
                )
            }
        }
        initializer.append("}")

        return (
            "\(access)static var width: Int32 { \(width) }",
            initializer.joined(separator: "\n"),
            factory()
        )
    }

    /// The projection factory: one labeled parameter per property.
    ///
    /// Expressions are matched by `Value.Base`, so a non-optional column from a `LEFT JOIN`
    /// can fill an optional field.
    private func factory() -> String {
        var parameters: [String] = []
        var generics: [String] = []
        var constraints: [String] = []
        var arguments: [String] = []

        for (position, field) in fields.enumerated() {
            if field.isEmbedded {
                parameters.append("\(field.propertyName): LiteRow.TableRef<\(field.baseType)>")
                arguments.append(
                    "LiteRow.TableProjection<\(field.baseType)>(alias: \(field.propertyName).alias)"
                )
            }
            else {
                let name = "E\(position)"
                generics.append("\(name): LiteRow.Expression")
                constraints.append("\(name).Value.Base == \(field.baseType).Base")
                parameters.append("\(field.propertyName): \(name)")
                arguments.append(field.propertyName)
            }
        }

        let genericClause = generics.isEmpty ? "" : "<\(generics.joined(separator: ", "))>"
        let whereClause = constraints.isEmpty ? "" : " where \(constraints.joined(separator: ", "))"

        return """
            \(access)static func projection\(genericClause)(
                \(parameters.joined(separator: ",\n    "))
            ) -> LiteRow.Projection<Self>\(whereClause) {
                LiteRow.Projection([\(arguments.joined(separator: ", "))])
            }
            """
    }
}

// MARK: - Macros

public struct ProjectionMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let model: ProjectionModel
        do {
            model = try ProjectionModel(declaration: declaration)
        }
        catch let error as ProjectionMacroError {
            context.diagnose(error.diagnostic)
            return []
        }

        // Empty `protocols` means the conformance is declared by hand; only add the members.
        let conformance = protocols.contains { $0.trailingIdentifier == "RowDecodable" }
            ? ": LiteRow.RowDecodable"
            : ""

        let parts = model.declarations
        let source = """
            extension \(type.trimmedDescription)\(conformance) {
            \(parts.width)

            \(parts.initializer)

            \(parts.factory)
            }
            """

        guard let extensionDecl = DeclSyntax("\(raw: source)").as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [extensionDecl]
    }
}

/// Marks a whole-table field; read by `@Projection`.
public struct EmbeddedMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

// MARK: - Syntax

extension TypeSyntax {
    /// `String` for both `String?` and `Optional<String>`.
    var unwrappedOptional: TypeSyntax? {
        if let optional = self.as(OptionalTypeSyntax.self) {
            return optional.wrappedType
        }
        if let identifier = self.as(IdentifierTypeSyntax.self),
           identifier.name.text == "Optional",
           let argument = identifier.genericArgumentClause?.arguments.first {
            return argument.argument.as(TypeSyntax.self)
        }
        return nil
    }
}
