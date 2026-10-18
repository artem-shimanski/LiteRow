//
//  Utility.swift
//  LiteRow
//
//  Created by Artem Shimanski on 13.08.2026.
//

extension String {
    /// An SQL string literal: single quotes, with embedded apostrophes doubled.
    ///
    /// For places where a value cannot be bound as a parameter, e.g. `ATTACH DATABASE`.
    @_spi(Build)
    public var quotedStringLiteral: String {
        var result = "'"
        result.reserveCapacity(count + 2)
        for character in self {
            if character == "'" {
                result.append("''")
            }
            else {
                result.append(character)
            }
        }
        result.append("'")
        return result
    }

    /// A quoted SQL identifier.
    @inlinable public var quotedIdentifier: String {
        var result = "\""
        result.reserveCapacity(count + 2)
        for character in self {
            if character == "\"" {
                result.append("\"\"")
            }
            else {
                result.append(character)
            }
        }
        result.append("\"")
        return result
    }
}

/// Calls `body` with an expanded pack.
///
/// Works around a type checker limitation: `body(repeat each pack, extra)` does not compile,
/// so callers append the extra element at the tuple level and pass a single pack here.
@inlinable @inline(__always) func applyPack<each R, Result>(
    _ body: (repeat each R) -> Result,
    to references: (repeat each R)
) -> Result {
    body(repeat each references)
}
