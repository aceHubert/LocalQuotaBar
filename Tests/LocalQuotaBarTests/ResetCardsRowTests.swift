import AppKit
import XCTest
@testable import LocalQuotaBar

final class ResetCardsRowTests: XCTestCase {
    @MainActor
    func testExpandingShowsEveryCardAndCollapsingRestoresHeight() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        let expiry = Date().addingTimeInterval(3 * 86_400)
        row.configure(chips: [makeChip(id: "codex", expiries: [expiry, nil])])
        layout(window)
        let collapsedHeight = row.fittingSize.height
        let chip = try chipButton("codex", in: row)
        let expand = try XCTUnwrap(descendants(of: row).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "codex" && $0 !== chip })
        XCTAssertEqual(chip.frame.height, expand.frame.height, accuracy: 0.5)
        XCTAssertEqual(chip.frame.midY, expand.frame.midY, accuracy: 0.5)
        XCTAssertEqual(chip.layer?.cornerRadius, expand.layer?.cornerRadius)
        var heightChanges = 0
        row.onContentHeightChange = { heightChanges += 1 }

        try clickChip("codex", in: row)
        layout(window)

        XCTAssertGreaterThan(row.fittingSize.height, collapsedHeight + 35)
        XCTAssertEqual(heightChanges, 1)
        for text in ["#1", "#2", PanelTheme.formatCardExpiry(expiry), "--"] {
            let label = try XCTUnwrap(labels(in: row).first { $0.stringValue == text })
            XCTAssertGreaterThan(label.frame.width, 0, text)
            XCTAssertGreaterThan(label.frame.height, 0, text)
            XCTAssertFalse(label.isHiddenOrHasHiddenAncestor, text)
            let frame = label.convert(label.bounds, to: row)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, text)
            XCTAssertLessThanOrEqual(frame.maxX, row.bounds.width + 0.5, text)
        }

        try clickChip("codex", in: row)
        layout(window)
        XCTAssertEqual(row.fittingSize.height, collapsedHeight, accuracy: 0.5)
        XCTAssertTrue(visibleCardNumbers(in: row).isEmpty)
        XCTAssertEqual(heightChanges, 2)
    }

    @MainActor
    func testRepeatedExpansionReusesButtonsAndDetailViews() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        row.configure(chips: [makeChip(id: "five-hour", expiries: [nil, nil])])
        layout(window)
        let collapsedHeight = row.fittingSize.height
        let originalButton = try chipButton("five-hour", in: row)
        var originalLabels: [NSTextField] = []

        for iteration in 0..<3 {
            originalButton.performClick(nil)
            layout(window)
            XCTAssertTrue(try chipButton("five-hour", in: row) === originalButton)
            let visibleNumbers = visibleCardNumbers(in: row)
            XCTAssertEqual(visibleNumbers.map(\.stringValue), ["#1", "#2"])
            XCTAssertGreaterThan(row.fittingSize.height, collapsedHeight + 35)
            if iteration == 0 {
                originalLabels = visibleNumbers
            } else {
                XCTAssertEqual(visibleNumbers.map(ObjectIdentifier.init), originalLabels.map(ObjectIdentifier.init))
            }

            originalButton.performClick(nil)
            layout(window)
            XCTAssertTrue(try chipButton("five-hour", in: row) === originalButton)
            XCTAssertTrue(visibleCardNumbers(in: row).isEmpty)
            XCTAssertEqual(row.fittingSize.height, collapsedHeight, accuracy: 0.5)
        }
    }

    @MainActor
    func testTogglingOneChipPreservesOtherExpandedDetails() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        row.configure(chips: [
            makeChip(id: "five-hour", expiries: [nil, nil]),
            makeChip(id: "weekly", expiries: [nil])
        ])
        try clickChip("five-hour", in: row)
        layout(window)
        let firstDetails = visibleCardNumbers(in: row)
        let firstExpandedHeight = row.fittingSize.height
        try clickChip("weekly", in: row)
        layout(window)
        XCTAssertEqual(visibleCardNumbers(in: row).count, 3)
        XCTAssertGreaterThan(row.fittingSize.height, firstExpandedHeight)
        try clickChip("weekly", in: row)
        layout(window)
        XCTAssertEqual(visibleCardNumbers(in: row).map(ObjectIdentifier.init), firstDetails.map(ObjectIdentifier.init))
        XCTAssertEqual(row.fittingSize.height, firstExpandedHeight, accuracy: 0.5)
    }

    @MainActor
    func testConfigurePreservesExistingExpansionAndDropsRemovedIDs() async throws {
        let (window, row) = makeHostedRow()
        defer { window.close() }
        let chip = makeChip(id: "five-hour", expiries: [nil])
        row.configure(chips: [chip])
        try clickChip("five-hour", in: row)
        row.configure(chips: [makeChip(id: "five-hour", expiries: [nil, nil])])
        layout(window)
        XCTAssertEqual(visibleCardNumbers(in: row).map(\.stringValue), ["#1", "#2"])

        row.configure(chips: [])
        row.configure(chips: [chip])
        layout(window)
        XCTAssertTrue(visibleCardNumbers(in: row).isEmpty)
    }

    @MainActor
    private func makeHostedRow() -> (NSWindow, ResetCardsRow) {
        _ = NSApplication.shared
        // 使用与实际面板一致的内容宽度，确保跨视图约束和真实布局均被执行。
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
    private func makeChip(id: String, expiries: [Date?]) -> ResetCardsRow.Chip {
        .init(
            id: id, title: "重置卡 ×\(expiries.count)", soon: false,
            cards: expiries.map { .init(kindTitle: "5小时", expiresAt: $0) }
        )
    }

    @MainActor
    private func clickChip(_ id: String, in row: ResetCardsRow) throws {
        try chipButton(id, in: row).performClick(nil)
    }

    @MainActor
    private func chipButton(_ id: String, in row: ResetCardsRow) throws -> NSButton {
        try XCTUnwrap(descendants(of: row).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == id && $0.title.hasPrefix("重置卡") })
    }

    @MainActor
    private func visibleCardNumbers(in row: ResetCardsRow) -> [NSTextField] {
        labels(in: row).filter { $0.stringValue.hasPrefix("#") && !$0.isHiddenOrHasHiddenAncestor }
    }

    @MainActor
    private func layout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func labels(in view: NSView) -> [NSTextField] {
        descendants(of: view).compactMap { $0 as? NSTextField }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
