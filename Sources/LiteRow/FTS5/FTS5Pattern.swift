//
//  FTS5Pattern.swift
//  LiteRow
//

/// A `MATCH` pattern built so that user input cannot break the FTS5 query syntax.
///
/// Input is split into tokens and each token is quoted; the caller picks the operators
/// by choosing a factory. Factories that parse text return `nil` when the input has no
/// tokens, since an empty `MATCH` is a syntax error.
///
/// ```swift
/// guard let pattern = FTS5Pattern.all(userInput, prefix: true) else { return [] }
/// let query = TypeSearch.all()
///     .filter { fts in fts.match(pattern) }
///     .order(by: { fts in fts.rank })
/// ```
public struct FTS5Pattern: Sendable, Hashable {
    /// The pattern in FTS5 query syntax.
    public let query: String

    /// A raw pattern, used as is. The caller is responsible for its syntax.
    @inlinable public init(unsafe query: String) {
        self.query = query
    }
}

// MARK: - Building from user input

extension FTS5Pattern {
    /// All tokens are required: `"rif" AND "arm"`.
    ///
    /// `prefix` appends `*` to the **last** token only, for search-as-you-type.
    public static func all(_ text: String, prefix: Bool = false) -> FTS5Pattern? {
        combine(text, separator: " AND ", prefix: prefix)
    }

    /// Any token matches: `"rifter" OR "punisher"`.
    public static func any(_ text: String, prefix: Bool = false) -> FTS5Pattern? {
        combine(text, separator: " OR ", prefix: prefix)
    }

    /// Tokens adjacent and in order: `"heavy assault missile"`. Requires `detail=full`.
    ///
    /// With the `trigram` tokenizer this is a substring search.
    public static func phrase(_ text: String, prefix: Bool = false) -> FTS5Pattern? {
        let tokens = self.tokens(of: text)
        guard !tokens.isEmpty else { return nil }
        var result = "\""
        for (index, token) in tokens.enumerated() {
            if index > 0 { result += " " }
            result += escaped(token)
        }
        result += "\""
        if prefix { result += "*" }
        return FTS5Pattern(unsafe: result)
    }

    /// Tokens within a window: `NEAR("shield" "booster", 10)`.
    public static func near(_ text: String, distance: Int = 10) -> FTS5Pattern? {
        let tokens = self.tokens(of: text)
        guard !tokens.isEmpty else { return nil }
        var result = "NEAR("
        for (index, token) in tokens.enumerated() {
            if index > 0 { result += " " }
            result += "\"\(escaped(token))\""
        }
        result += ", \(distance))"
        return FTS5Pattern(unsafe: result)
    }

    private static func combine(_ text: String, separator: String, prefix: Bool) -> FTS5Pattern? {
        let tokens = self.tokens(of: text)
        guard !tokens.isEmpty else { return nil }
        var result = ""
        for (index, token) in tokens.enumerated() {
            if index > 0 { result += separator }
            result += "\"\(escaped(token))\""

            if prefix, index == tokens.count - 1 { result += "*" }
        }
        return FTS5Pattern(unsafe: result)
    }

    /// Splits input roughly like the `unicode61` tokenizer: letters and digits form tokens,
    /// everything else separates them. The goal is to leave nothing the query parser treats as syntax.
    private static func tokens(of text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    /// Doubles quotes inside a token.
    private static func escaped(_ token: Substring) -> String {
        var result = ""
        result.reserveCapacity(token.count)
        for character in token {
            if character == "\"" {
                result.append("\"\"")
            }
            else {
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - Combinators

extension FTS5Pattern {
    /// Both patterns. Operands are always parenthesized.
    public static func && (lhs: FTS5Pattern, rhs: FTS5Pattern) -> FTS5Pattern {
        FTS5Pattern(unsafe: "(\(lhs.query)) AND (\(rhs.query))")
    }

    /// Either pattern.
    public static func || (lhs: FTS5Pattern, rhs: FTS5Pattern) -> FTS5Pattern {
        FTS5Pattern(unsafe: "(\(lhs.query)) OR (\(rhs.query))")
    }

    /// Matches `self` but not `other` (FTS5 `NOT` is binary only).
    public func excluding(_ other: FTS5Pattern) -> FTS5Pattern {
        FTS5Pattern(unsafe: "(\(query)) NOT (\(other.query))")
    }

    /// Restricts the pattern to a column: `{typeName} : (…)`. Requires `detail=full` or `detail=column`.
    public func restricted(to column: String) -> FTS5Pattern {
        FTS5Pattern(unsafe: "{\(column)} : (\(query))")
    }
}
