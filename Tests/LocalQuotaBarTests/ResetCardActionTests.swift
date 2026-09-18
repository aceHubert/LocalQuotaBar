import AppKit
import XCTest
@testable import LocalQuotaBar

final class ResetCardActionTests: XCTestCase {
    @MainActor
    func testEachResetButtonDispatchesItsOwnCardTypeWithoutExpanding() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        row.configure(chips: [makeChip("five-hour"), makeChip("weekly")])
        var received: [String] = []
        row.onReset = { received.append($0) }

        try button("reset-use.five-hour", in: row).performClick(nil)
        try button("reset-use.weekly", in: row).performClick(nil)

        XCTAssertEqual(received, ["five-hour", "weekly"])
        XCTAssertTrue(visibleCardNumbers(in: row).isEmpty)
    }

    @MainActor
    func testDisabledAndStaleButtonsRejectDirectActionDispatch() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        row.configure(chips: [makeChip("five-hour", enabled: false)])
        var calls = 0
        row.onReset = { _ in calls += 1 }
        let disabled = try button("reset-use.five-hour", in: row)
        disabled.performClick(nil)
        try sendDirectAction(disabled)
        // 即使外部修改控件状态，也不能绕过保存的操作状态。
        disabled.isEnabled = true
        try sendDirectAction(disabled)
        XCTAssertEqual(calls, 0)

        row.configure(chips: [makeChip("five-hour")])
        let removed = try button("reset-use.five-hour", in: row)
        row.configure(chips: [makeChip("weekly")])
        try sendDirectAction(removed)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testActionUpdatesReuseViewsAndPreserveExpandedDetails() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        row.configure(chips: [makeChip("five-hour"), makeChip("weekly")])
        let reset = try button("reset-use.five-hour", in: row)
        let chip = try button("five-hour", in: row)
        chip.performClick(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let originalNumbers = visibleCardNumbers(in: row).map(ObjectIdentifier.init)
        let originalViews = descendants(of: row).map(ObjectIdentifier.init)
        var heightChanges = 0
        row.onContentHeightChange = { heightChanges += 1 }
        var calls = 0
        row.onReset = { _ in calls += 1 }

        row.updateResetActions([
            "five-hour": .init(title: "重置中", isEnabled: false, toolTip: "正在重置5小时额度")
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(try button("reset-use.five-hour", in: row) === reset)
        XCTAssertEqual(descendants(of: row).map(ObjectIdentifier.init), originalViews)
        XCTAssertEqual(visibleCardNumbers(in: row).map(ObjectIdentifier.init), originalNumbers)
        XCTAssertEqual(heightChanges, 0)
        XCTAssertEqual(reset.title, "重置中")
        XCTAssertEqual(reset.toolTip, "正在重置5小时额度")
        XCTAssertFalse(reset.isEnabled)
        XCTAssertNotEqual(reset.layer?.backgroundColor, PanelTheme.green.cgColor)
        try sendDirectAction(reset)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try button("reset-use.weekly", in: row).isEnabled)

        row.updateResetActions(["five-hour": .init(title: "重试", isEnabled: true)])
        XCTAssertEqual(reset.title, "重试")
        XCTAssertNil(reset.toolTip)
        XCTAssertTrue(reset.isEnabled)
        XCTAssertEqual(reset.layer?.backgroundColor, PanelTheme.green.cgColor)
        XCTAssertEqual(reset.contentTintColor, PanelTheme.panelBackground)
        reset.performClick(nil)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(visibleCardNumbers(in: row).map(ObjectIdentifier.init), originalNumbers)
    }

    @MainActor
    func testResetGroupsFitPanelWidthAndAlignActionsToTrailingEdge() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        row.configure(chips: [makeChip("five-hour"), makeChip("weekly")])
        window.contentView?.layoutSubtreeIfNeeded()
        let first = try button("reset-use.five-hour", in: row)
        let second = try button("reset-use.weekly", in: row)
        let firstFrame = first.convert(first.bounds, to: row)
        let secondFrame = second.convert(second.bounds, to: row)
        XCTAssertGreaterThan(abs(firstFrame.midY - secondFrame.midY), 18)
        XCTAssertEqual(firstFrame.maxX, 298, accuracy: 0.5)
        XCTAssertEqual(secondFrame.maxX, 298, accuracy: 0.5)

        for control in descendants(of: row).compactMap({ $0 as? NSButton }) {
            let frame = control.convert(control.bounds, to: row)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
            XCTAssertLessThanOrEqual(frame.maxX, 298.5)
            XCTAssertEqual(frame.height, 18, accuracy: 0.5)
            XCTAssertEqual(control.layer?.cornerRadius, 6)
        }
        row.updateResetActions(["five-hour": .init(title: "重置中", isEnabled: false)])
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.convert(first.bounds, to: row).maxX, 298, accuracy: 0.5)
    }

    @MainActor
    func testCodexChipsKeepHorizontalLayoutWithoutResetButtons() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        row.configure(chips: [
            .init(id: "codex-a", title: "重置卡 ×1", soon: false, cards: []),
            .init(id: "codex-b", title: "重置卡 ×2", soon: false, cards: [])
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        let controls = descendants(of: row).compactMap { $0 as? NSButton }
        XCTAssertEqual(controls.count, 4)
        XCTAssertFalse(controls.contains { $0.identifier?.rawValue.hasPrefix("reset-use.") == true })
        let first = try button("codex-a", in: row)
        let second = try button("codex-b", in: row)
        XCTAssertEqual(first.convert(first.bounds, to: row).midY,
                       second.convert(second.bounds, to: row).midY, accuracy: 0.5)

        row.updateResetActions(["codex-a": .init(title: "重置", isEnabled: true)])
        XCTAssertEqual(descendants(of: row).compactMap { $0 as? NSButton }.count, 4)
    }

    @MainActor
    private func makeChip(_ id: String, enabled: Bool = true) -> ResetCardsRow.Chip {
        .init(
            id: id, title: id == "five-hour" ? "5h 重置 ×2 · 9/15" : "周重置 ×1 · 10/1",
            soon: id == "five-hour", cards: [.init(kindTitle: "5小时额度", expiresAt: nil)],
            resetAction: .init(title: "重置", isEnabled: enabled)
        )
    }

    @MainActor
    private func makeHostedRow() -> (NSWindow, ResetCardsRow) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 298, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 298, height: 400))
        window.contentView = host
        let row = ResetCardsRow()
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        return (window, row)
    }

    @MainActor
    private func button(_ id: String, in row: ResetCardsRow) throws -> NSButton {
        try XCTUnwrap(descendants(of: row).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == id })
    }

    @MainActor
    private func sendDirectAction(_ button: NSButton) throws {
        let action = try XCTUnwrap(button.action)
        let target = try XCTUnwrap(button.target)
        _ = NSApp.sendAction(action, to: target, from: button)
    }

    @MainActor
    private func visibleCardNumbers(in row: ResetCardsRow) -> [NSTextField] {
        descendants(of: row).compactMap { $0 as? NSTextField }
            .filter { $0.stringValue.hasPrefix("#") && !$0.isHiddenOrHasHiddenAncestor }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
