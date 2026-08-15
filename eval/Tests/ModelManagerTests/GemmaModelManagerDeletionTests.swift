import Foundation
import XCTest
@testable import RemliCore

final class GemmaModelManagerDeletionTests: XCTestCase {
    func testRemovalDeletesEveryKnownModelLocation() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let modelURLs = [
            directory.appendingPathComponent("active.litertlm"),
            directory.appendingPathComponent("staged.litertlm"),
            directory.appendingPathComponent("documents-fallback.litertlm"),
        ]

        for url in modelURLs {
            XCTAssertTrue(fileManager.createFile(atPath: url.path, contents: Data("model".utf8)))
        }

        try GemmaModelManager.removeExistingModelFiles(
            at: modelURLs + [modelURLs[0]],
            using: fileManager
        )

        for url in modelURLs {
            XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        }
    }
}
