import Foundation
import Testing
@testable import SagaCore

@Suite struct PhoneContactsTests {
    func vault(with json: String) throws -> Vault {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v = try Vault(url: dir.appendingPathComponent("v"))
        try v.writeConfig(Data(json.utf8), name: PhoneContacts.fileName)
        return v
    }

    let sample = """
    {"contacts":[
      {"id":"1","name":"Shagun Ohri","numbers":["919833052771","919606809771"]},
      {"id":"2","name":"Amma","numbers":["919800000001"]}
    ]}
    """

    @Test func aTwoNumberContactBecomesOneGroup() throws {
        let groups = PhoneContacts.groups(in: try vault(with: sample))
        #expect(groups.count == 1)
        #expect(groups.first?.keys.sorted() == ["9606809771", "9833052771"])
    }

    @Test func namesCoverEveryNumber() throws {
        let names = PhoneContacts.names(in: try vault(with: sample))
        #expect(names["9833052771"] == "Shagun Ohri")
        #expect(names["9606809771"] == "Shagun Ohri")
        #expect(names["9800000001"] == "Amma")
        #expect(names.count == 3)
    }

    @Test func aMissingFileIsNotAnError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v = try Vault(url: dir.appendingPathComponent("v"))
        #expect(PhoneContacts.groups(in: v).isEmpty)
    }
}
