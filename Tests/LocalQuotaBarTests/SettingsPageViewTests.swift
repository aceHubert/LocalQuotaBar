import AppKit
import XCTest
@testable import LocalQuotaBar

final class SettingsPageViewTests: XCTestCase {
    @MainActor
    func testMenuActionsSelectValueAndNotifyExactlyOnce() async throws {
        _ = NSApplication.shared
        let popup = DarkPopUpButton()
        var selections: [Int] = []
        popup.configure(options: [("30 分钟", 30), ("关闭", 0), ("10 分钟", 10)]) { value in
            selections.append(value)
            XCTAssertEqual(popup.selectedItem?.tag, value)
        }
        let menu = try XCTUnwrap(popup.menu)
        menu.update()

        // 通过实际菜单项派发动作，不能只调用按钮 action 或手动写选中索引。
        for index in [1, 2, 0] {
            let item = try XCTUnwrap(menu.item(at: index))
            XCTAssertTrue(item.isEnabled)
            XCTAssertNotNil(item.action)
            menu.performActionForItem(at: index)
            XCTAssertTrue(popup.selectedItem === item)
        }
        XCTAssertEqual(selections, [0, 10, 30])
    }

    @MainActor
    func testProgrammaticConfigurationAndSelectionStaySilent() async throws {
        _ = NSApplication.shared
        let popup = DarkPopUpButton()
        var selections: [Int] = []
        popup.configure(options: [("50%", 50), ("20%", 20), ("10%", 10)]) {
            selections.append($0)
        }
        popup.select(value: 20)
        XCTAssertEqual(popup.selectedItem?.tag, 20)
        popup.select(nearest: 12)
        XCTAssertEqual(popup.selectedItem?.tag, 10)
        popup.select(value: 99)
        XCTAssertEqual(popup.selectedItem?.tag, 10)
        XCTAssertTrue(selections.isEmpty)

        popup.configure(options: [("5 分钟", 5), ("60 分钟", 60)]) {
            selections.append($0)
        }
        XCTAssertEqual(popup.itemTitles, ["5 分钟", "60 分钟"])
        XCTAssertTrue(selections.isEmpty)
        popup.menu?.performActionForItem(at: 1)
        XCTAssertEqual(selections, [60])
    }

    @MainActor
    func testSettingsPageRoutesAllFourMenuChoicesAndSynchronizesSilently() async throws {
        _ = NSApplication.shared
        let page = SettingsPageView()
        var changes: [String] = []
        page.onRefreshIntervalChange = { changes.append("refresh:\($0)") }
        page.onWarningPercentChange = { changes.append("warning:\($0)") }
        page.onResetSoonChange = { changes.append("reset:\($0)") }
        page.onCooldownChange = { changes.append("cooldown:\($0)") }
        page.configure(reminder: .default, refreshMinutes: 5, canRestore: false)
        XCTAssertTrue(changes.isEmpty)

        let popups = descendants(of: page).compactMap { $0 as? DarkPopUpButton }
        let refresh = try XCTUnwrap(popups.first { $0.itemTitles.first == "1 分钟" })
        let warning = try XCTUnwrap(popups.first { $0.itemTitles.first == "50%" })
        let reset = try XCTUnwrap(popups.first { $0.itemTitles.contains("关闭") })
        let cooldown = try XCTUnwrap(popups.first { $0.itemTitles.first == "5 分钟" })
        XCTAssertEqual(popups.count, 4)

        refresh.menu?.performActionForItem(at: refresh.indexOfItem(withTitle: "15 分钟"))
        warning.menu?.performActionForItem(at: warning.indexOfItem(withTitle: "40%"))
        reset.menu?.performActionForItem(at: reset.indexOfItem(withTitle: "关闭"))
        cooldown.menu?.performActionForItem(at: cooldown.indexOfItem(withTitle: "60 分钟"))
        XCTAssertEqual(changes, ["refresh:15", "warning:40", "reset:0", "cooldown:60"])

        var configuration = ReminderConfiguration.default
        configuration.warningRemainingPercent = 40
        configuration.resetSoonMinutes = 0
        configuration.cooldown = 60 * 60
        page.configure(reminder: configuration, refreshMinutes: 15, canRestore: false)
        XCTAssertEqual([refresh, warning, reset, cooldown].map { $0.selectedItem?.tag }, [15, 40, 0, 60])
        XCTAssertEqual(changes.count, 4)
    }

    @MainActor
    func testReminderChangeSurvivesStateRefreshAndNextSetting() async throws {
        _ = NSApplication.shared
        let controller = QuotaViewController.makeForTesting()
        var initial = ReminderConfiguration.default
        initial.warningRemainingPercent = 30
        controller.applyReminderConfiguration(initial)
        _ = controller.view
        var saved = initial
        controller.onReminderConfigurationChange = { saved = $0 }
        let popups = descendants(of: controller.view).compactMap { $0 as? DarkPopUpButton }
        let warning = try XCTUnwrap(popups.first { $0.itemTitles.first == "50%" })
        let cooldown = try XCTUnwrap(popups.first { $0.itemTitles.first == "5 分钟" })
        warning.menu?.performActionForItem(at: warning.indexOfItem(withTitle: "20%"))
        // 模拟刷新额度后同步静音状态，不能用旧的30%覆盖刚选的20%。
        controller.setUnmuteButtonVisible(false)
        XCTAssertEqual(warning.titleOfSelectedItem, "20%")
        XCTAssertEqual(saved.warningRemainingPercent, 20)
        cooldown.menu?.performActionForItem(at: cooldown.indexOfItem(withTitle: "15 分钟"))
        XCTAssertEqual(saved.warningRemainingPercent, 20)
        XCTAssertEqual(saved.cooldown, 900)
    }

    @MainActor
    func testReminderSwitchesUseSameAppearanceAndConfiguration() async {
        _ = NSApplication.shared
        let controller = QuotaViewController.makeForTesting()
        _ = controller.view
        var configuration = ReminderConfiguration.default
        configuration.isEnabled = false
        controller.applyReminderConfiguration(configuration)
        let switches = descendants(of: controller.view).compactMap { $0 as? PanelReminderSwitch }
        XCTAssertEqual(switches.count, 2)
        for control in switches {
            XCTAssertEqual(control.appearance?.name, .darkAqua)
            XCTAssertEqual(control.state, .off)
        }
    }

    @MainActor
    func testReminderClicksSynchronizeFooterAndSettingsExactlyOnce() async throws {
        _ = NSApplication.shared
        let controller = QuotaViewController.makeForTesting()
        controller.applyReminderConfiguration(.default)
        _ = controller.view
        var changes: [Bool] = []
        controller.onReminderConfigurationChange = { changes.append($0.isEnabled) }
        let footer = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? PanelFooterView }.first)
        let settings = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? SettingsPageView }.first)
        let footerSwitch = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? PanelReminderSwitch }.first)
        let settingsSwitch = try XCTUnwrap(descendants(of: settings).compactMap { $0 as? PanelReminderSwitch }.first)

        footerSwitch.performClick(nil)
        XCTAssertEqual(changes, [false])
        XCTAssertEqual(footerSwitch.state, .off)
        XCTAssertEqual(settingsSwitch.state, .off)
        settingsSwitch.performClick(nil)
        XCTAssertEqual(changes, [false, true])
        XCTAssertEqual(footerSwitch.state, .on)
        XCTAssertEqual(settingsSwitch.state, .on)

        controller.applyReminderConfiguration(.default)
        controller.setUnmuteButtonVisible(false)
        XCTAssertEqual(changes, [false, true])
        XCTAssertEqual(footerSwitch.state, .on)
        XCTAssertEqual(settingsSwitch.state, .on)
    }

    @MainActor
    func testReminderSwitchRendersGreenOnAndGrayOffInWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 100, height: 50),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        window.contentView = host
        let control = PanelReminderSwitch()
        PanelTheme.configureReminderSwitch(control)
        host.addSubview(control)
        let reference = ReminderSwitchColorReferenceView(frame: NSRect(x: 5, y: 17, width: 26, height: 15))
        reference.appearance = control.appearance
        host.addSubview(reference)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(control))
        XCTAssertTrue(control.acceptsFirstResponder)
        XCTAssertEqual(control.accessibilityLabel(), "低量提醒")
        XCTAssertEqual(control.accessibilityRole(), .checkBox)
        XCTAssertEqual(control.bounds.width, 26, accuracy: 0.5)
        XCTAssertEqual(control.bounds.height, 15, accuracy: 0.5)

        for (state, expected, sampleX, filename) in [
            (NSControl.StateValue.on, PanelTheme.green, CGFloat(6), "reminder-switch.png"),
            (NSControl.StateValue.off, PanelTheme.tertiaryText, CGFloat(20), "reminder-switch-off.png")
        ] {
            control.state = state
            reference.color = expected
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(control.bitmapImageRepForCachingDisplay(in: control.bounds))
            control.cacheDisplay(in: control.bounds, to: bitmap)
            // 在轨道内部、远离白色滑块和抗锯齿边缘的位置采样真实渲染像素。
            let x = Int(sampleX / control.bounds.width * CGFloat(bitmap.pixelsWide))
            let y = bitmap.pixelsHigh / 2
            let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            // 基准色也经同一窗口的绘制和缓存管线，避免把设备缓存像素与原始 sRGB 数值混比。
            let referenceBitmap = try XCTUnwrap(reference.bitmapImageRepForCachingDisplay(in: reference.bounds))
            reference.cacheDisplay(in: reference.bounds, to: referenceBitmap)
            let color = try XCTUnwrap(referenceBitmap.colorAt(
                x: referenceBitmap.pixelsWide / 2, y: referenceBitmap.pixelsHigh / 2
            )?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, color.redComponent, accuracy: 0.01)
            XCTAssertEqual(actual.greenComponent, color.greenComponent, accuracy: 0.01)
            XCTAssertEqual(actual.blueComponent, color.blueComponent, accuracy: 0.01)
            XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.01)

            if let directory = ProcessInfo.processInfo.environment["LOCALQUOTABAR_RENDER_DIR"], !directory.isEmpty {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: destination.appendingPathComponent(filename))
            }
        }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        let children = (view as? NSStackView)?.views ?? view.subviews
        return children.flatMap { [$0] + descendants(of: $0) }
    }
}

/// 像素基准与被测控件使用同一 AppKit 绘制路径，保留屏幕色彩管理的影响。
private final class ReminderSwitchColorReferenceView: NSView {
    var color = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
