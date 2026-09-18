import AppKit
import XCTest
@testable import LocalQuotaBar

final class SettingsActionButtonTests: XCTestCase {
    @MainActor
    func testInitialAndDefaultActionsRejectClicksAndDirectDispatch() async throws {
        _ = NSApplication.shared
        let page = SettingsPageView()
        var resets = 0
        var restores = 0
        page.onRestoreDefaults = { resets += 1 }
        page.onUnmuteAll = { restores += 1 }
        let reset = try button(titled: "重置", in: page)
        let restore = try button(titled: "恢复提醒", in: page)

        for refreshMinutes in [1, 5, 15] {
            // 第一轮同时验证 configure 之前的初始状态。
            try assertDisabledAndDispatch(reset)
            try assertDisabledAndDispatch(restore)
            page.configure(reminder: .default, refreshMinutes: refreshMinutes, canRestore: false)
        }
        try assertDisabledAndDispatch(reset)
        try assertDisabledAndDispatch(restore)
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(restores, 0)
    }

    @MainActor
    func testEachNonDefaultFieldEnablesResetWithoutRoundingToDisplayedOption() async throws {
        _ = NSApplication.shared
        let page = SettingsPageView()
        let reset = try button(titled: "重置", in: page)
        let changes: [(String, (inout ReminderConfiguration) -> Void)] = [
            ("提醒开关", { $0.isEnabled = false }),
            ("额度阈值", { $0.warningRemainingPercent = 20.1 }),
            ("严重阈值", { $0.criticalRemainingPercent = 10.1 }),
            ("重置时间", { $0.resetSoonMinutes = 30.1 }),
            ("提醒间隔", { $0.cooldown = 601 })
        ]

        for (name, change) in changes {
            var configuration = ReminderConfiguration.default
            change(&configuration)
            page.configure(reminder: configuration, refreshMinutes: 5, canRestore: false)
            XCTAssertTrue(reset.isEnabled, name)
            assertHighlighted(reset)

            page.configure(reminder: .default, refreshMinutes: 5, canRestore: false)
            XCTAssertFalse(reset.isEnabled, name)
            XCTAssertNotEqual(reset.layer?.backgroundColor, PanelTheme.green.cgColor, name)
            assertButtonGeometry(reset)
        }
    }

    @MainActor
    func testResetAppliesDefaultsOnceAndImmediatelyDisablesItself() async throws {
        _ = NSApplication.shared
        let controller = QuotaViewController()
        var configuration = ReminderConfiguration.default
        configuration.isEnabled = false
        configuration.warningRemainingPercent = 40
        configuration.resetSoonMinutes = 0
        configuration.cooldown = 900
        controller.applyReminderConfiguration(configuration)
        _ = controller.view
        var saved: [ReminderConfiguration] = []
        controller.onReminderConfigurationChange = { saved.append($0) }
        let page = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? SettingsPageView }.first)
        let reset = try button(titled: "重置", in: page)

        XCTAssertTrue(reset.isEnabled)
        reset.performClick(nil)
        XCTAssertEqual(saved, [.default])
        try assertDisabledAndDispatch(reset)
        XCTAssertEqual(saved, [.default])
        XCTAssertTrue(descendants(of: controller.view).compactMap { $0 as? PanelReminderSwitch }
            .allSatisfy { $0.state == .on })
    }

    @MainActor
    func testRestoreAvailabilityFollowsMuteStateRegardlessOfReminderSwitch() async throws {
        _ = NSApplication.shared
        let page = SettingsPageView()
        let restore = try button(titled: "恢复提醒", in: page)
        var restored = 0
        page.onUnmuteAll = { restored += 1 }

        for enabled in [true, false] {
            var configuration = ReminderConfiguration.default
            configuration.isEnabled = enabled
            page.configure(reminder: configuration, refreshMinutes: 5, canRestore: false)
            try assertDisabledAndDispatch(restore)

            page.configure(reminder: configuration, refreshMinutes: 5, canRestore: true)
            XCTAssertTrue(restore.isEnabled)
            XCTAssertFalse(restore.isHidden)
            assertHighlighted(restore)
            restore.performClick(nil)

            page.configure(reminder: configuration, refreshMinutes: 5, canRestore: false)
            try assertDisabledAndDispatch(restore)
            XCTAssertNotEqual(restore.layer?.backgroundColor, PanelTheme.green.cgColor)
            assertButtonGeometry(restore)
        }
        XCTAssertEqual(restored, 2)
    }

    @MainActor
    func testControllerRestoreCallbackSynchronizesAndPreventsSecondAction() async throws {
        _ = NSApplication.shared
        let controller = QuotaViewController()
        _ = controller.view
        controller.setUnmuteButtonVisible(true)
        var restored = 0
        controller.onUnmuteAll = { [weak controller] in
            restored += 1
            controller?.setUnmuteButtonVisible(false)
        }
        let page = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? SettingsPageView }.first)
        let restore = try button(titled: "恢复提醒", in: page)

        XCTAssertTrue(restore.isEnabled)
        restore.performClick(nil)
        XCTAssertEqual(restored, 1)
        try assertDisabledAndDispatch(restore)
        XCTAssertEqual(restored, 1)
    }

    @MainActor
    private func assertDisabledAndDispatch(_ button: NSButton, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(button.isEnabled, file: file, line: line)
        button.performClick(nil)
        // 直接派发会绕过 NSButton 自身的禁用过滤，动作仍须拒绝执行。
        let action = try XCTUnwrap(button.action, file: file, line: line)
        let target = try XCTUnwrap(button.target, file: file, line: line)
        _ = NSApp.sendAction(action, to: target, from: button)
    }

    @MainActor
    private func assertHighlighted(_ button: NSButton, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(button.layer?.backgroundColor, PanelTheme.green.cgColor, file: file, line: line)
        XCTAssertEqual(button.contentTintColor, PanelTheme.panelBackground, file: file, line: line)
        assertButtonGeometry(button, file: file, line: line)
    }

    @MainActor
    private func assertButtonGeometry(_ button: NSButton, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(button.layer?.cornerRadius, 4, file: file, line: line)
        XCTAssertTrue(button.constraints.contains {
            $0.isActive && $0.firstAttribute == .height && $0.relation == .equal && $0.constant == 20
        }, file: file, line: line)
    }

    @MainActor
    private func button(titled title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        let children = (view as? NSStackView)?.views ?? view.subviews
        return children.flatMap { [$0] + descendants(of: $0) }
    }
}
