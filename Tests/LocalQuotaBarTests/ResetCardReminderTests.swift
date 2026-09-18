import Foundation
import XCTest
@testable import LocalQuotaBar

final class ResetCardReminderTests: XCTestCase {
    func testCodexSnapshotUsesEarliestAvailableCard() {
        let now = Date()
        let snapshot = QuotaSnapshot(
            fiveHour: nil, weekly: nil, resetCreditCount: nil,
            resetCreditCards: [
                // status 为空视为可用，与面板"使用这张重置卡"的口径一致。
                .init(issuedAt: nil, expiresAt: now.addingTimeInterval(20 * 60)),
                .init(id: "a", status: "available", issuedAt: nil, expiresAt: now.addingTimeInterval(10 * 60)),
                .init(id: "b", status: "redeemed", issuedAt: nil, expiresAt: now.addingTimeInterval(5 * 60)),
                .init(issuedAt: nil, expiresAt: now.addingTimeInterval(-5 * 60))
            ],
            creditBalance: nil, planType: nil, fetchedAt: now
        )
        let buckets = snapshot.reminderBuckets
        XCTAssertEqual(buckets.count, 1)
        let card = buckets[0]
        XCTAssertEqual(card.kind, .resetCard)
        XCTAssertEqual(card.id, "codex.resetCard")
        XCTAssertEqual(card.cardCount, 2)
        XCTAssertEqual(card.resetsAt?.timeIntervalSince(now) ?? 0, 10 * 60, accuracy: 1)
    }

    func testCodexSnapshotOmitsResetCardBucketWithoutUsableCards() {
        let snapshot = QuotaSnapshot(
            fiveHour: nil, weekly: nil, resetCreditCount: nil,
            resetCreditCards: [], creditBalance: nil, planType: nil, fetchedAt: Date()
        )
        XCTAssertTrue(snapshot.reminderBuckets.isEmpty)
    }

    func testZAISnapshotGroupsResetCardsByKind() {
        let now = Date()
        let snapshot = ZAIQuotaSnapshot(
            kind: .codingPlan,
            limits: [],
            balances: [],
            resetCreditCards: [
                .init(kind: .fiveHour, expiresAt: now.addingTimeInterval(25 * 60)),
                .init(kind: .fiveHour, expiresAt: now.addingTimeInterval(15 * 60)),
                .init(kind: .week, expiresAt: now.addingTimeInterval(3 * 86_400))
            ],
            fetchedAt: now
        )
        let buckets = snapshot.reminderBuckets
        XCTAssertEqual(buckets.count, 2)
        let fiveHour = buckets.first { $0.id == "zai.resetCard.fiveHour" }
        XCTAssertEqual(fiveHour?.cardCount, 2)
        XCTAssertEqual(fiveHour?.resetsAt?.timeIntervalSince(now) ?? 0, 15 * 60, accuracy: 1)
        let week = buckets.first { $0.id == "zai.resetCard.week" }
        XCTAssertEqual(week?.cardCount, 1)
    }

    @MainActor
    func testDescribeResetCardUsesExpiryPhrase() {
        let now = Date()
        let single = ReminderHit(
            bucket: ReminderBucket(
                source: .zai,
                id: "describe-single",
                title: "ZAI 5小时重置卡",
                shortTitle: "5H重置卡",
                remainingPercent: 100,
                resetsAt: now.addingTimeInterval(20 * 60 - 1),
                kind: .resetCard,
                cardCount: 1
            ),
            level: .resetSoon
        )
        XCTAssertEqual(ReminderCenter.describe(hit: single, now: now), "你有一张重置卡将于20分钟后过期")

        let multiple = ReminderHit(
            bucket: ReminderBucket(
                source: .codex,
                id: "describe-multiple",
                title: "Codex 重置卡",
                shortTitle: "重置卡",
                remainingPercent: 100,
                resetsAt: now.addingTimeInterval(20 * 60 - 1),
                kind: .resetCard,
                cardCount: 3
            ),
            level: .resetSoon
        )
        XCTAssertEqual(ReminderCenter.describe(hit: multiple, now: now), "你有3张重置卡将于20分钟后过期")
    }

    func testResetCardExpiryPhraseFormats() {
        let now = Date()
        XCTAssertEqual(
            ReminderConfiguration.resetCardExpiryPhrase(until: now.addingTimeInterval(20 * 60), now: now),
            "20分钟后"
        )
        XCTAssertEqual(
            ReminderConfiguration.resetCardExpiryPhrase(until: now.addingTimeInterval(90 * 60), now: now),
            "1小时后"
        )
        XCTAssertEqual(
            ReminderConfiguration.resetCardExpiryPhrase(until: now.addingTimeInterval(25 * 3600), now: now),
            "2天后"
        )
    }
}
