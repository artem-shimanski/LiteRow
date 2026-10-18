//
//  Plugin.swift
//  LiteRowMacros
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct LiteRowPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TableMacro.self,
        ColumnMacro.self,
        PrimaryKeyMacro.self,
        IndexMacro.self,
        IndexFilterMacro.self,
        ProjectionMacro.self,
        EmbeddedMacro.self,
    ]
}
