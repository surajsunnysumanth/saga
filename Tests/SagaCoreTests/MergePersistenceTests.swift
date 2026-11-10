import Foundation
import Testing
@testable import SagaCore

/// The only thing a merge has to do: survive. If this passes, the storage layer is fine and any
/// "my merge disappeared" report is an app-layer problem, not a file-format one.
@Suite struct MergePersistenceTests {
    func tempVault() throws -> Vault {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Vault(url: dir.appendingPathComponent("v"))
    }

    @Test func aMergeSurvivesAFreshRead() throws {
        let v = try tempVault()
        try MergeConfig.add(keys: ["a", "b"], name: "Amma", to: v)
        let reloaded = try MergeConfig.loadChecked(v)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.keys.sorted() == ["a", "b"])
        #expect(reloaded.first?.name == "Amma")
    }

    @Test func mergingTheSameKeyTwiceDoesNotDuplicate() throws {
        let v = try tempVault()
        try MergeConfig.add(keys: ["a", "b"], name: "Amma", to: v)
        try MergeConfig.add(keys: ["b", "c"], name: "Amma", to: v)
        let reloaded = try MergeConfig.loadChecked(v)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.keys.sorted() == ["a", "b", "c"])
    }

    @Test func anEmptyFileReadsAsNoMerges() throws {
        let v = try tempVault()
        #expect(try MergeConfig.loadChecked(v).isEmpty)
    }
}
