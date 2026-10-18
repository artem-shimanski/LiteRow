//
//  DatabaseFile.swift
//  LiteRow
//
//  Created by Artem Shimanski on 08.08.2026.
//


/// A schema: an attached database and its name within a connection.
///
/// The same value is used as a key in `Database`'s `attached` and as `@Table`'s `schema:` argument.
///
/// ```swift
/// extension DatabaseFile {
///     static let icons = DatabaseFile(schemaName: "aux")
/// }
///
/// @Table("eveIcons", schema: .icons)
/// struct Icon { … }
///
/// let database = try Database(main: .file(url), attached: [.icons: .file(iconsURL)])
/// ```
///
/// The value is a schema **name**, not a file: `attached` decides which file is mounted under it.
/// The `in:` argument of `all`/`join`/`find` is for when several copies are attached at once.
public struct DatabaseFile: Hashable, Sendable {
    /// The raw name; equality and hashing use it.
    public let schemaName: String

    /// The name quoted for SQL, computed once.
    public let quotedSchemaName: String

    /// - Parameter schemaName: The unquoted name.
    public init(schemaName: String) {
        precondition(!schemaName.isEmpty, "Schema name must not be empty")
        self.schemaName = schemaName
        self.quotedSchemaName = schemaName.quotedIdentifier
    }

    public static func == (lhs: DatabaseFile, rhs: DatabaseFile) -> Bool {
        lhs.schemaName == rhs.schemaName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaName)
    }

    /// The main database opened by the connection itself.
    public static let main = DatabaseFile(schemaName: "main")
}
