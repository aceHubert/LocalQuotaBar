import AppKit
import XCTest
@testable import LocalQuotaBar

final class PanelRenderingTests: XCTestCase {
    @MainActor
    func testQuotaPopoverRendersAcrossRepeatedOpenings() async throws {
        _ = NSApplication.shared
        let controller = QuotaViewController()
        controller.applyReminderConfiguration(.default)
        let snapshot = QuotaSnapshot(
            fiveHour: .init(kind: .fiveHour, usedPercent: 25, windowDurationMins: 300, resetsAt: nil),
            weekly: nil, resetCreditCount: 2,
            resetCreditCards: [
                .init(issuedAt: nil, expiresAt: Date().addingTimeInterval(86_400)),
                .init(issuedAt: nil, expiresAt: nil)
            ],
            creditBalance: nil, planType: "pro", fetchedAt: Date()
        )
        controller.apply(snapshot: snapshot, isRefreshing: false, error: nil, reminder: .inactive)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 300, width: 100, height: 30),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView = anchor
        window.orderFrontRegardless()
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = controller
        popover.behavior = .transient
        controller.onPreferredContentSizeChange = { [weak popover, weak controller] in
            guard let controller else { return }
            if popover?.contentSize != controller.preferredContentSize {
                popover?.contentSize = controller.preferredContentSize
            }
        }
        defer { popover.close() }

        for _ in 0..<3 {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            let collapsedSize = popover.contentSize
            let chip = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "codex" && $0.title.hasPrefix("重置卡") })
            chip.performClick(nil)
            // 覆盖日志中的另一条触发路径：卡片展开后，额度刷新重建卡片列表。
            controller.apply(snapshot: snapshot, isRefreshing: true, error: nil, reminder: .inactive)
            controller.apply(snapshot: snapshot, isRefreshing: false, error: nil, reminder: .inactive)
            for _ in 0..<5 {
                controller.view.window?.displayIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(popover.isShown)
            XCTAssertEqual(popover.contentSize.width, collapsedSize.width)
            XCTAssertGreaterThan(popover.contentSize.height, collapsedSize.height)
            XCTAssertTrue(descendants(of: controller.view).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "#2" && !$0.isHiddenOrHasHiddenAncestor })
            let collapseButton = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "codex" && $0.title.hasPrefix("重置卡") })
            collapseButton.performClick(nil)
            XCTAssertEqual(popover.contentSize, collapsedSize)
            popover.close()
        }
    }

    @MainActor
    func testTopUpdatedLabelFollowsLatestSuccessfulRefreshAcrossProviders() async throws {
        _ = NSApplication.shared
        let controller = QuotaViewController()
        let now = Date()
        let codexSnapshot = QuotaSnapshot(
            fiveHour: nil, weekly: nil, resetCreditCount: nil,
            resetCreditCards: [], creditBalance: nil, planType: nil,
            fetchedAt: now.addingTimeInterval(-150)
        )
        controller.apply(snapshot: codexSnapshot, isRefreshing: false, error: nil, reminder: .inactive)
        XCTAssertEqual(controller.lastUpdatedDisplayText, "2 分钟前")

        // 刷新开始时的旧快照重放不能把顶部时间回退。
        controller.apply(snapshot: codexSnapshot, isRefreshing: true, error: nil, reminder: .inactive)
        XCTAssertEqual(controller.lastUpdatedDisplayText, "2 分钟前")

        // 单独刷新 Z.AI 成功后，顶部时间跟随最新的渠道。
        controller.applyZAI(
            snapshot: ZAIQuotaSnapshot(fetchedAt: now),
            account: nil, isRefreshing: false, error: nil
        )
        XCTAssertEqual(controller.lastUpdatedDisplayText, "刚刚")

        // Codex 之后即使再回放旧快照，也仍以 Z.AI 的刷新时间为准。
        controller.apply(snapshot: codexSnapshot, isRefreshing: false, error: nil, reminder: .inactive)
        XCTAssertEqual(controller.lastUpdatedDisplayText, "刚刚")
    }

    @MainActor
    func testFooterRendersInVisibleWindow() async throws {
        _ = NSApplication.shared
        let footer = PanelFooterView()
        footer.configure(reminder: .default, canRestore: false)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 298, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = footer
        window.orderFrontRegardless()
        // 仅加载视图不会执行系统控件的延迟渲染，必须让真实窗口经历显示周期。
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(window.isVisible)
        let normal = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "正常" })
        let warning = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("预警") })
        let normalItem = try XCTUnwrap(normal.superview)
        let warningItem = try XCTUnwrap(warning.superview)
        let normalFrame = footer.convert(normalItem.bounds, from: normalItem)
        let warningFrame = footer.convert(warningItem.bounds, from: warningItem)
        XCTAssertEqual(warningFrame.minX - normalFrame.maxX, 9, accuracy: 0.5)
        XCTAssertEqual(normal.alignmentRect(forFrame: normal.frame).width, normal.intrinsicContentSize.width, accuracy: 0.5)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
