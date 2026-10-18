//
//  Environment.swift
//  LiteRowUI
//

import SwiftUI
import LiteRow

extension EnvironmentValues {
    /// The database the property wrappers of this module read from.
    ///
    /// Optional on purpose: previews, tests and screens built outside the hierarchy have none.
    @Entry public var liteDatabase: Database? = nil

    /// Handler for failed fetches; `assertionFailure` by default.
    @Entry public var liteQueryFailure: LiteQueryFailure = .default
}

extension View {
    /// Provides the database to every `@LiteQuery` and `@LiteSections` below in the hierarchy.
    @inlinable public func liteDatabase(_ database: Database) -> some View {
        environment(\.liteDatabase, database)
    }

    /// Handles fetch errors instead of calling `assertionFailure`.
    @inlinable public func liteQueryFailure(_ handler: @escaping @Sendable (any Error) -> Void) -> some View {
        environment(\.liteQueryFailure, LiteQueryFailure(handler))
    }
}

/// A handler for failed fetches.
public struct LiteQueryFailure: Sendable {
    @usableFromInline let handler: @Sendable (any Error) -> Void

    @inlinable public init(_ handler: @escaping @Sendable (any Error) -> Void) {
        self.handler = handler
    }

    @inlinable public func report(_ error: any Error) {
        handler(error)
    }

    /// Triggers an assertion failure.
    ///
    /// The database is read-only, so a failed fetch means a programmer error (bad SQL,
    /// a schema mismatch, a missing table), not a screen state.
    public static let `default` = LiteQueryFailure { error in
        assertionFailure("LiteRowUI: fetch failed: \(error)")
    }

    /// Ignores the error.
    public static let silent = LiteQueryFailure { _ in }
}

/// Errors of the SwiftUI bridge itself.
public enum LiteQueryError: Error, Hashable, Sendable {
    /// No database in the environment: the view was built without `.liteDatabase(_:)`.
    case databaseMissing
}
