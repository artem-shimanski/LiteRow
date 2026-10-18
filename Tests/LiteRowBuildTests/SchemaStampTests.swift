//
//  SchemaStampTests.swift
//  LiteRowBuildTests
//

import Foundation
import Testing

import LiteRowBuild
@testable import LiteRow

/// The build number in the file header.
///
/// These tests are about the seam between two sides: the build stamps the working database, and
/// the app checks it on the **final** file, so `VACUUM INTO` sits between them.
/// If vacuum did not carry the stamp over, the check at open would always fail on zero,
/// so the transfer gets its own test rather than being assumed.
@Suite("Build stamp: writing")
struct SchemaStampTests {
    private static func memoryName() -> String {
        "literow-stamp-\(UUID().uuidString)"
    }

    @Test("the stamp reads back")
    func stampRoundTrips() throws {
        let builder = try DatabaseBuilder(inMemory: Self.memoryName())
        try builder.setUserVersion(7)
        try builder.setApplicationID(0x4C_52_30_31)

        #expect(try builder.userVersion == 7)
        #expect(try builder.applicationID == 0x4C_52_30_31)
        withExtendedLifetime(builder) {}
    }

    @Test("VACUUM INTO carries the stamp to the final file")
    func stampSurvivesVacuum() async throws {
        let directory = URL.temporaryDirectory.appending(
            path: "literow-stamp-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite", directoryHint: .notDirectory)

        let builder = try DatabaseBuilder(inMemory: Self.memoryName())
        try builder.create(TypeInfo.self, filledWith: [TypeInfo(id: 1, name: "Rifter", groupID: 25)])
        try builder.setUserVersion(7)
        try builder.setApplicationID(0x4C_52_30_31)
        try builder.vacuum(into: url)
        builder.close()

        // Opening with the expected stamp is the check of the transfer: if it did not match,
        // the initializer would throw `schemaMismatch` before any query.
        let database = try Database(
            main: .file(url),
            attached: [:],
            options: Database.Options(schemaVersion: 7, applicationID: 0x4C_52_30_31)
        )
        let name = try await database.read { reader in
            try reader.fetchOne(TypeInfo.self, key: 1)?.name
        }

        #expect(name == "Rifter")
    }

    @Test("a database without a stamp does not match the expectation")
    func unstampedBuildIsRejected() throws {
        let name = Self.memoryName()
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.create(TypeInfo.self, filledWith: [TypeInfo(id: 1, name: "Rifter", groupID: 25)])

        // Forgetting the stamp at build time is the same mistake as setting a foreign one: a new file
        // has `user_version` zero, and the expectation will not accept it.
        #expect(throws: LiteRowError.self) {
            _ = try Database(
                main: .memory(name: name),
                attached: [:],
                options: Database.Options(schemaVersion: 7)
            )
        }
        withExtendedLifetime(builder) {}
    }
}
