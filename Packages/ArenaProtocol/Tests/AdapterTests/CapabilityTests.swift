import ArenaAdapter
import Testing

@Test func everyInitialCapabilityIsUnverified() {
    let inventory = Phase0CapabilityInventory.assessments
    #expect(inventory.count == Phase0Capability.allCases.count)
    #expect(Set(inventory.keys) == Set(Phase0Capability.allCases))
    for assessment in inventory.values {
        #expect(assessment.state == .unknown)
        #expect(assessment.lastValidatedAt == nil)
        #expect(assessment.evidence.allSatisfy { $0.kind == .needsProtocolVerification })
    }
}
