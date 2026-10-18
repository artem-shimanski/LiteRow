//
//  SQLOperator.swift
//  LiteRow
//
//  Created by Artem Shimanski on 13.08.2026.
//


/// An SQL operator with its precedence, used to parenthesize only where needed.
///
/// Precedences follow SQLite: OR < AND < NOT < equality < ordering < bitwise < additive
/// < multiplicative < concatenation.
public struct SQLOperator: Sendable, Hashable {
    public let text: String
    public let precedence: Int

    public init(text: String, precedence: Int) {
        self.text = text
        self.precedence = precedence
    }
}

extension SQLOperator {
    public static let or = SQLOperator(text: "OR", precedence: 1)
    public static let and = SQLOperator(text: "AND", precedence: 2)
    public static let not = SQLOperator(text: "NOT", precedence: 3)

    public static let equal = SQLOperator(text: "=", precedence: 4)
    public static let notEqual = SQLOperator(text: "<>", precedence: 4)
    public static let identical = SQLOperator(text: "IS", precedence: 4)
    public static let notIdentical = SQLOperator(text: "IS NOT", precedence: 4)
    public static let like = SQLOperator(text: "LIKE", precedence: 4)
    public static let glob = SQLOperator(text: "GLOB", precedence: 4)
    public static let match = SQLOperator(text: "MATCH", precedence: 4)

    public static let less = SQLOperator(text: "<", precedence: 5)
    public static let lessOrEqual = SQLOperator(text: "<=", precedence: 5)
    public static let greater = SQLOperator(text: ">", precedence: 5)
    public static let greaterOrEqual = SQLOperator(text: ">=", precedence: 5)

    public static let bitwiseAnd = SQLOperator(text: "&", precedence: 6)
    public static let bitwiseOr = SQLOperator(text: "|", precedence: 6)
    public static let shiftLeft = SQLOperator(text: "<<", precedence: 6)
    public static let shiftRight = SQLOperator(text: ">>", precedence: 6)

    public static let add = SQLOperator(text: "+", precedence: 7)
    public static let subtract = SQLOperator(text: "-", precedence: 7)

    public static let multiply = SQLOperator(text: "*", precedence: 8)
    public static let divide = SQLOperator(text: "/", precedence: 8)
    public static let modulo = SQLOperator(text: "%", precedence: 8)

    public static let concatenate = SQLOperator(text: "||", precedence: 9)
    public static let negate = SQLOperator(text: "-", precedence: 10)
    public static let coma = SQLOperator(text: ",", precedence: 1)
}
