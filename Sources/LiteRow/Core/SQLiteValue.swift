//
//  SQLiteValue.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

import Foundation
import SQLite3

public enum StorageClass: String, Sendable, Hashable, CaseIterable {
    case integer = "INTEGER"
    case real = "REAL"
    case text = "TEXT"
    case blob = "BLOB"
}

extension StorageClass {
    @inlinable
    public init?(columnType: Int32) {
        switch columnType {
        case SQLITE_INTEGER: self = .integer
        case SQLITE_FLOAT: self = .real
        case SQLITE_TEXT: self = .text
        case SQLITE_BLOB: self = .blob
        default: return nil
        }
    }
}

public protocol SQLiteValue: Sendable, Hashable {
    associatedtype Base: SQLiteValue
    static var storageClass: StorageClass { get }
    static var isNullable: Bool { get }

    var binding: SQLiteBinding { get }

    init(from row: borrowing Row, at column: Int32) throws(LiteRowError)
    func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError)
}

extension SQLiteValue {
    public typealias Base = Self
}

extension SQLiteValue {
    public static var isNullable: Bool { false }
}

// MARK: - Integer

public protocol SQLiteIntegerValue: SQLiteValue, FixedWidthInteger {}

extension SQLiteIntegerValue {
    public static var storageClass: StorageClass { .integer }


    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        let raw = try row.integer(at: column)
        guard let value = Self(exactly: raw) else {
            throw row.failure(.integerOutOfRange(raw), at: column)
        }
        self = value
    }
    
    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        try expectOK(sqlite3_bind_int64(statement, parameter, Int64(self)), statement: statement)
    }
    
    @inlinable public var binding: SQLiteBinding {.integer(Int64(self))}
}

extension Int: SQLiteIntegerValue {}
extension Int8: SQLiteIntegerValue {}
extension Int16: SQLiteIntegerValue {}
extension Int32: SQLiteIntegerValue {}
extension Int64: SQLiteIntegerValue {}
extension UInt8: SQLiteIntegerValue {}
extension UInt16: SQLiteIntegerValue {}
extension UInt32: SQLiteIntegerValue {}

// MARK: - Bool

extension Bool: SQLiteValue {
    public static var storageClass: StorageClass { .integer }


    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        self = try row.integer(at: column) != 0
    }

    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        try expectOK(sqlite3_bind_int64(statement, parameter, self ? 1 : 0), statement: statement)
    }
    
    @inlinable public var binding: SQLiteBinding {.integer(Int64(self ? 1 : 0))}
}

// MARK: - Double

extension Double: SQLiteValue {
    public static var storageClass: StorageClass { .real }


    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        self = try row.double(at: column)
    }

    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        try expectOK(sqlite3_bind_double(statement, parameter, self), statement: statement)
    }
    
    @inlinable public var binding: SQLiteBinding {.real(self)}
}

// MARK: - String

extension String: SQLiteValue {
    public static var storageClass: StorageClass { .text }


    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        self = try row.text(at: column)
    }

    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        try expectOK(
            sqlite3_bind_text(statement, parameter, self, -1, SQLiteDestructor.transient),
            statement: statement
        )
    }
    
    @inlinable public var binding: SQLiteBinding {.text(self)}
}

// MARK: - Data

extension Data: SQLiteValue {
    public static var storageClass: StorageClass { .blob }


    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        if let blob = try row.blob(at: column) {
            self = blob.withUnsafeBytes { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count)
            }
        }
        else {
            self = Data()
        }
    }

    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        let code = withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                parameter,
                bytes.baseAddress,
                Int32(bytes.count),
                SQLiteDestructor.transient
            )
        }
        try expectOK(code, statement: statement)
    }
    
    @inlinable public var binding: SQLiteBinding {.blob(self)}
}

// MARK: - RawRepresentable

extension SQLiteValue where Self: RawRepresentable, Self.RawValue: SQLiteValue {
    public static var storageClass: StorageClass { RawValue.storageClass }


    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        let raw = try RawValue(from: row, at: column)
        guard let value = Self(rawValue: raw) else {
            throw row.failure(.invalidRawValue(String(describing: raw)), at: column)
        }
        self = value
    }

    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        try rawValue.bind(to: statement, at: parameter)
    }
    
    @inlinable public var binding: SQLiteBinding {rawValue.binding}
}

// MARK: - Optional

extension Optional: SQLiteValue where Wrapped: SQLiteValue {
    public typealias Base = Wrapped
    public static var storageClass: StorageClass { Wrapped.storageClass }

    public static var isNullable: Bool { true }

    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        if row.isNull(at: column) {
            self = .none
        } else {
            self = .some(try Wrapped(from: row, at: column))
        }
    }

    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        switch self {
        case .none:
            try expectOK(sqlite3_bind_null(statement, parameter), statement: statement)
        case let .some(value):
            try value.bind(to: statement, at: parameter)
        }
    }
    
    @inlinable public var binding: SQLiteBinding { self?.binding ?? .null }
}
