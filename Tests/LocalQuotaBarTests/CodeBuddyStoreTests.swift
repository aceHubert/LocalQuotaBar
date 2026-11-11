import XCTest
@testable import LocalQuotaBar

final class CodeBuddyStoreTests: XCTestCase {
    @MainActor
    func testMissingCookieTriggersTwoBackgroundRetries() async {
        let initialAndRetries = expectation(description: "初次读取与两次补刷")
        initialAndRetries.expectedFulfillmentCount = 3
        let extraAttempt = expectation(description: "补刷用完后继续尝试")
        extraAttempt.isInverted = true

        let store = CodeBuddyStore(sessionRecoveryDelays: [0.01, 0.01]) { domain, allowKeychainUI in
            XCTAssertFalse(allowKeychainUI)
            return .failure(.cookieNotFound(host: "www.\(domain)"))
        }
        defer { store.stop() }
        var completed = 0
        store.onChange = { _, refreshing, error in
            guard !refreshing else { return }
            XCTAssertNotNil(error)
            completed += 1
            if completed <= 3 {
                initialAndRetries.fulfill()
            } else {
                extraAttempt.fulfill()
            }
        }

        store.start()
        await fulfillment(of: [initialAndRetries, extraAttempt], timeout: 0.5)
    }
}
