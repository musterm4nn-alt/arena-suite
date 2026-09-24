import ApplicationActions
import Foundation
import SuiteDomain
import Testing

@Test func operationRetainsAccountAcrossSelectionAndRotation() async throws {
    let a = AccountContext(accountID: AccountID(), principal: nil, credentialGeneration: 1)
    let b = AccountContext(accountID: AccountID(), principal: nil, credentialGeneration: 1)
    var selection = a
    let operation = OperationContext(account: selection)
    selection = b
    let lateResult = await Task { operation.account }.value
    #expect(lateResult == a)
    #expect(lateResult != selection)
    selection = AccountContext(accountID: a.accountID, principal: nil, credentialGeneration: 2)
    #expect(operation.account.credentialGeneration == 1)
    #expect(operation.account != selection)
    let decoded = try JSONDecoder().decode(AccountContext.self, from: JSONEncoder().encode(a))
    #expect(decoded == a)
}

@Test func engineDoesNotClaimFeasibility() async {
    #expect(await ArenaSuiteEngine().feasibilitySummary().contains("pending"))
}
