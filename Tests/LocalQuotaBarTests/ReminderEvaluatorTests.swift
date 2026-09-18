import Foundation
import XCTest
@testable import LocalQuotaBar

final class ReminderEvaluatorTests: XCTestCase {
    // 评估器状态按桶 id 存在 UserDefaults；测试用随机 id 避免相互污染。
    private func unique(_ label: String) -> String {
        "test.\(label).\(UUID().uuidString)"
    }

    private func configuration(
        isEnabled: Bool = true,
        resetSoonMinutes: Double = 30,
        cooldown: TimeInterval = 600
    ) -> ReminderConfiguration {
        ReminderConfiguration(
            isEnabled: isEnabled,
            warningRemainingPercent: 20,
            criticalRemainingPercent: 10,
            resetSoonMinutes: resetSoonMinutes,
            cooldown: cooldown
        )
    }

    private func resetCardBucket(
        id: String,
        expiresInSeconds: TimeInterval,
        from now: Date,
        count: Int = 1
    ) -> ReminderBucket {
        ReminderBucket(
            source: .zai,
            id: id,
            title: "ZAI 5小时重置卡",
            shortTitle: "5H重置卡",
            remainingPercent: 100,
            resetsAt: now.addingTimeInterval(expiresInSeconds),
            kind: .resetCard,
            cardCount: count
        )
    }

    func testResetCardWithinFixedWindowTriggersEvenWhenResetSoonReminderOff() {
        // "重置还剩"设为关闭、提醒间隔拉长到 1 小时，重置卡仍按固定 30 分钟窗口触发。
        let evaluator = ReminderEvaluator(configuration: configuration(resetSoonMinutes: 0, cooldown: 3600))
        let now = Date()
        let bucket = resetCardBucket(id: unique("window"), expiresInSeconds: 20 * 60, from: now)
        let presentation = evaluator.evaluate([bucket], source: .zai, now: now)
        XCTAssertTrue(presentation.isActive)
        XCTAssertEqual(presentation.level, .resetSoon)
        XCTAssertEqual(presentation.hits.first?.bucket.id, bucket.id)
    }

    func testResetCardBeyondFixedWindowDoesNotTrigger() {
        let evaluator = ReminderEvaluator(configuration: configuration())
        let now = Date()
        let bucket = resetCardBucket(id: unique("far"), expiresInSeconds: 40 * 60, from: now)
        XCTAssertFalse(evaluator.evaluate([bucket], source: .zai, now: now).isActive)
    }

    func testResetCardRepeatsEveryFiveMinutesRegardlessOfSettings() {
        // 剩余百分比恒为 100、提醒间隔设置 1 小时，也必须按固定 5 分钟重复提醒。
        let evaluator = ReminderEvaluator(configuration: configuration(cooldown: 3600))
        let now = Date()
        let bucket = resetCardBucket(id: unique("repeat"), expiresInSeconds: 30 * 60, from: now)
        XCTAssertTrue(evaluator.evaluate([bucket], source: .zai, now: now).isActive)
        XCTAssertFalse(evaluator.evaluate([bucket], source: .zai, now: now.addingTimeInterval(4 * 60)).isActive)
        XCTAssertTrue(evaluator.evaluate([bucket], source: .zai, now: now.addingTimeInterval(5 * 60)).isActive)
    }

    func testResetCardStopsAfterMute() {
        let evaluator = ReminderEvaluator(configuration: configuration())
        let now = Date()
        let bucket = resetCardBucket(id: unique("mute"), expiresInSeconds: 20 * 60, from: now)
        XCTAssertTrue(evaluator.evaluate([bucket], source: .zai, now: now).isActive)
        evaluator.muteCurrent(now: now)
        XCTAssertFalse(evaluator.evaluate([bucket], source: .zai, now: now.addingTimeInterval(6 * 60)).isActive)
    }

    func testResetCardSilencedWhenRemindersDisabled() {
        let evaluator = ReminderEvaluator(configuration: configuration(isEnabled: false))
        let now = Date()
        let bucket = resetCardBucket(id: unique("off"), expiresInSeconds: 20 * 60, from: now)
        XCTAssertFalse(evaluator.evaluate([bucket], source: .zai, now: now).isActive)
    }

    func testQuotaBucketStillDeduplicatedByPercent() {
        // 回归：额度桶维持"数字没变不重复打扰"，重置卡的 5 分钟固定间隔不外溢。
        let evaluator = ReminderEvaluator(configuration: configuration())
        let now = Date()
        let bucket = ReminderBucket(
            source: .zai,
            id: unique("quota"),
            title: "ZAI 周额度",
            shortTitle: "周额度",
            remainingPercent: 15,
            resetsAt: nil
        )
        XCTAssertTrue(evaluator.evaluate([bucket], source: .zai, now: now).isActive)
        XCTAssertFalse(evaluator.evaluate([bucket], source: .zai, now: now.addingTimeInterval(6 * 60)).isActive)
    }
}
