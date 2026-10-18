//
//  SQLiteBinding.swift
//  LiteRow
//
//  Created by Artem Shimanski on 20.08.2026.
//

import Foundation

public enum SQLiteBinding: Hashable, SQLBindable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    
    public func bind(to binder: inout Binder) throws(LiteRowError) {
        switch self {
        case .null: try binder.bindNull()
        case let .integer(v): try binder.bind(v)
        case let .real(v): try binder.bind(v)
        case let .text(v): try binder.bind(v)
        case let .blob(v): try binder.bind(v)
        }
    }
}
