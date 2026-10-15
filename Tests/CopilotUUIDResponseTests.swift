import Foundation
import Testing
@testable import Fabric

@Suite("Copilot UUID Response")
struct CopilotUUIDResponseTests {
    @Test("An identity container does not turn nested user fields into identities")
    func nestedIdentityContainer() throws {
        let original = UUID().uuidString
        let replacement = UUID().uuidString
        let object: [String: Any] = ["nodeIDs": [["id": original, "value": original, "text": [original]]]]
        let result = try #require(Graph.remapUUIDs(in: object, remap: [original: replacement]) as? [String: Any])
        let members = try #require(result["nodeIDs"] as? [[String: Any]])
        let member = try #require(members.first)
        #expect(member["id"] as? String == replacement)
        #expect(member["value"] as? String == original)
        #expect(member["text"] as? [String] == [original])
    }
}
