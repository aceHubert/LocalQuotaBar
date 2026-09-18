import Foundation
import XCTest
@testable import LocalQuotaBar

final class CodexResetProtocolTests: XCTestCase {
    func testResetParametersKeepCreditIDSeparateFromIdempotencyKey() throws {
        let params = try CodexRateLimitClient.resetCreditParams(
            creditID: "credit-123", idempotencyKey: "attempt-456"
        )
        XCTAssertEqual(params, ["creditId": "credit-123", "idempotencyKey": "attempt-456"])
        XCTAssertThrowsError(try CodexRateLimitClient.resetCreditParams(creditID: " ", idempotencyKey: "key"))
        XCTAssertThrowsError(try CodexRateLimitClient.resetCreditParams(creditID: "credit", idempotencyKey: ""))
    }

    func testOnlyKnownOutcomesAreAccepted() throws {
        for value in ["reset", "alreadyRedeemed", "noCredit", "nothingToReset"] {
            XCTAssertEqual(try CodexRateLimitClient.parseResetOutcome(["outcome": value]).rawValue, value)
        }
        XCTAssertThrowsError(try CodexRateLimitClient.parseResetOutcome([:]))
        XCTAssertThrowsError(try CodexRateLimitClient.parseResetOutcome(["outcome": "unknown"]))
    }

    func testCardParsingPreservesIDAndStatusWithoutGrantDate() throws {
        let cards = try XCTUnwrap(CodexRateLimitClient.parseResetCreditCards(from: [
            "rateLimitResetCredits": ["credits": [
                ["id": "credit-a", "status": "available"],
                ["id": "credit-b", "status": "redeemed", "grantedAt": 1_800_000_000]
            ]]
        ]))
        XCTAssertEqual(cards.map(\.id), ["credit-a", "credit-b"])
        XCTAssertEqual(cards.map(\.status), ["available", "redeemed"])
        XCTAssertNil(cards[0].issuedAt)
        XCTAssertNotNil(cards[1].issuedAt)
    }

    func testOldCachedCardCanDecodeWithoutID() throws {
        let card = try JSONDecoder().decode(ResetCreditCard.self, from: Data("{}".utf8))
        XCTAssertNil(card.id)
        XCTAssertNil(card.status)
    }
}
