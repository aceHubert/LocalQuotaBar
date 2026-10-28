import Foundation
import XCTest
@testable import LocalQuotaBar

final class RefreshPhasePlannerTests: XCTestCase {
    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    func testZeroOffsetAtAnchorFiresAfterFullInterval() {
        let delay = RefreshPhasePlanner.nextDelay(
            offset: 0, interval: 300, anchor: date(0), now: date(0))
        XCTAssertEqual(delay, 300, accuracy: 0.001)
    }

    func testOffsetLandsWithinFirstCycle() {
        let delay = RefreshPhasePlanner.nextDelay(
            offset: 45, interval: 300, anchor: date(0), now: date(0))
        XCTAssertEqual(delay, 45, accuracy: 0.001)
    }

    func testRebuildMidCyclePreservesPhase() {
        // 启动 310s 后改档位重建：下一次触发仍落在 anchor + k*300 + 45 的相位格点上
        let delay = RefreshPhasePlanner.nextDelay(
            offset: 45, interval: 300, anchor: date(0), now: date(310))
        XCTAssertEqual(delay, 35, accuracy: 0.001)  // anchor+345 触发
    }

    func testJustAfterPhaseSlotRollsToNextCycle() {
        let delay = RefreshPhasePlanner.nextDelay(
            offset: 45, interval: 300, anchor: date(0), now: date(346))
        XCTAssertEqual(delay, 299, accuracy: 0.001)  // anchor+645 触发
    }

    func testShortIntervalScalesOffsetProportionally() {
        // 60s 档位下 180s 偏移等比缩小为 36s
        let delay = RefreshPhasePlanner.nextDelay(
            offset: 180, interval: 60, anchor: date(0), now: date(0))
        XCTAssertEqual(delay, 36, accuracy: 0.001)
    }

    func testDelayAlwaysWithinHalfOpenIntervalWindow() {
        for now in stride(from: 0.0, through: 900.0, by: 37.0) {
            for offset in [0.0, 45.0, 90.0, 135.0, 180.0] {
                let delay = RefreshPhasePlanner.nextDelay(
                    offset: offset, interval: 300, anchor: date(0), now: date(now))
                XCTAssertGreaterThan(delay, 0)
                XCTAssertLessThanOrEqual(delay, 300.0001)
            }
        }
    }

    func testToleranceCappedAtTenSeconds() {
        XCTAssertEqual(RefreshPhasePlanner.tolerance(for: 300), 10)
        XCTAssertEqual(RefreshPhasePlanner.tolerance(for: 60), 6)
        XCTAssertEqual(RefreshPhasePlanner.tolerance(for: 30), 3)
    }
}
