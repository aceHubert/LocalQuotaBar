import AppKit
import XCTest
@testable import LocalQuotaBar

final class PanelFooterViewTests: XCTestCase {
    @MainActor
    func testFirstConfigurationKeepsRestoreButtonInItsManagedStack() async throws {
        _ = NSApplication.shared
        let footer = PanelFooterView()

        // 首次状态同步曾对空容器设置显隐优先级，直接触发 AppKit 异常。
        footer.configure(reminder: .default, canRestore: false)

        let restoreButton = try restoreButton(in: footer)
        let reminderSwitch = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? PanelReminderSwitch }.first)
        let reminderLine = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? NSStackView }
            .first { $0.views.contains { $0 === restoreButton } })
        XCTAssertTrue(restoreButton.isHidden)
        XCTAssertEqual(reminderLine.visibilityPriority(for: restoreButton), .notVisible)
        XCTAssertEqual(reminderSwitch.state, .on)
    }

    @MainActor
    func testRestoreVisibilityAndReminderSwitchFollowConfigurationChanges() async throws {
        _ = NSApplication.shared
        let footer = PanelFooterView()
        let restoreButton = try restoreButton(in: footer)
        let reminderSwitch = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? PanelReminderSwitch }.first)

        for (enabled, canRestore) in [(true, false), (false, true), (true, false)] {
            var configuration = ReminderConfiguration.default
            configuration.isEnabled = enabled
            footer.configure(reminder: configuration, canRestore: canRestore)
            XCTAssertEqual(restoreButton.isHidden, !canRestore)
            XCTAssertEqual(reminderSwitch.state, enabled ? .on : .off)
            let reminderLine = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? NSStackView }
                .first { $0.views.contains { $0 === restoreButton } })
            XCTAssertEqual(reminderLine.visibilityPriority(for: restoreButton), canRestore ? .init(999) : .notVisible)
        }
    }

    @MainActor
    func testLegendFollowsConfiguredThresholdsAndDisabledResetReminder() async throws {
        _ = NSApplication.shared
        let footer = PanelFooterView()
        var configuration = ReminderConfiguration.default
        configuration.warningRemainingPercent = 35
        configuration.criticalRemainingPercent = 8
        configuration.resetSoonMinutes = 60
        footer.configure(reminder: configuration, canRestore: false)

        let labels = descendants(of: footer).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "预警 ≤35%" })
        XCTAssertTrue(labels.contains { $0.stringValue == "严重 ≤8%" })
        XCTAssertTrue(labels.contains { $0.stringValue == "即将重置 ≤60分" })

        configuration.resetSoonMinutes = 0
        footer.configure(reminder: configuration, canRestore: false)
        XCTAssertTrue(labels.contains { $0.stringValue == "重置提醒关闭" })
        XCTAssertFalse(labels.contains { $0.stringValue.hasPrefix("即将重置") })
    }

    @MainActor
    func testQuotaControllerLoadsAndAcceptsReminderUpdates() async throws {
        _ = NSApplication.shared
        let controller = QuotaViewController()

        // 模拟菜单栏首次打开前的状态同步，以及加载面板后的后续更新。
        controller.setUnmuteButtonVisible(false)
        controller.applyReminderConfiguration(.default)
        _ = controller.view
        let footer = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? PanelFooterView }.first)
        let restoreButton = try restoreButton(in: footer)

        controller.setUnmuteButtonVisible(true)
        XCTAssertFalse(restoreButton.isHidden)
        controller.setUnmuteButtonVisible(false)
        XCTAssertTrue(restoreButton.isHidden)

        var configuration = ReminderConfiguration.default
        configuration.isEnabled = false
        controller.applyReminderConfiguration(configuration)
        let reminderSwitch = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? PanelReminderSwitch }.first)
        XCTAssertEqual(reminderSwitch.state, .off)
        XCTAssertGreaterThan(controller.preferredContentSize.width, 0)
        XCTAssertGreaterThan(controller.preferredContentSize.height, 0)
    }

    @MainActor
    private func restoreButton(in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }.first { $0.title == "恢复提醒" })
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        // 隐藏的排列视图可能已脱离 subviews，仍需从 stack 管理的 views 查找。
        let children = (view as? NSStackView)?.views ?? view.subviews
        return children.flatMap { [$0] + descendants(of: $0) }
    }
}
