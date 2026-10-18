//
//  SQLQuery.swift
//  LiteRow
//
//  Created by Artem Shimanski on 20.08.2026.
//

public struct SQLQuery<Output: RowDecodable>: Query {
    
    public let sql: String
    public let bindings: [SQLiteBinding]
    
    @inlinable public init(_ sql: String, bindings: [SQLiteBinding] = []) {
        self.sql = sql
        self.bindings = bindings
    }
    
    public func bind(to binder: inout Binder) throws(LiteRowError) {
        for binding in bindings {
            try binding.bind(to: &binder)
        }
    }

}
