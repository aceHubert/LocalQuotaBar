import AppKit
import XCTest
@testable import LocalQuotaBar

final class CodexResetCardRowTests: XCTestCase {
    @MainActor
    func testDetailsFillProviderWidthAndAlignActionsRight() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 298, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 298, height: 400))
        window.contentView = host
        let section = ProviderPanelSection(monogram: "Cx", name: "Codex")
        host.addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            section.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        section.resetCards.configure(chips: [.init(
            id: "codex", title: "重置卡 ×2", soon: false,
            cards: ["a", "b"].map {
                .init(kindTitle: "重置卡", expiresAt: Date().addingTimeInterval(8100), id: $0,
                      resetAction: .init(title: "重置", isEnabled: true))
            }
        )])
        // 只展开合成明细，不点击任何重置动作。
        try XCTUnwrap(button("codex", in: section.resetCards)).performClick(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(section.resetCards.bounds.width, PanelTheme.contentWidth, accuracy: 0.5)
        for id in ["a", "b"] {
            let action = try XCTUnwrap(button("reset-use.card.\(id)", in: section.resetCards))
            let actionFrame = action.convert(action.bounds, to: section.resetCards)
            XCTAssertEqual(actionFrame.maxX, section.resetCards.bounds.width - 9, accuracy: 0.5)
            XCTAssertGreaterThan(actionFrame.width, 0)
            var container = action.superview
            while container != nil && !(container is PanelCardView) { container = container?.superview }
            let card = try XCTUnwrap(container as? PanelCardView)
            XCTAssertEqual(card.bounds.width, PanelTheme.contentWidth, accuracy: 0.5)
        }
    }

    @MainActor
    func testDetailButtonsDispatchCurrentCreditIDAndHonorDisabledState() throws {
        _ = NSApplication.shared
        let row = ResetCardsRow()
        row.configure(chips: [.init(
            id: "codex", title: "重置卡 ×2", soon: false,
            cards: ["credit-a", "credit-b"].map {
                .init(kindTitle: "重置卡", expiresAt: nil, id: $0,
                      resetAction: .init(title: "重置", isEnabled: true))
            }
        )])
        var selected: [String] = []
        row.onReset = { selected.append($0) }
        let first = try XCTUnwrap(button("reset-use.card.credit-a", in: row))
        let second = try XCTUnwrap(button("reset-use.card.credit-b", in: row))
        first.performClick(nil)
        second.performClick(nil)
        XCTAssertEqual(selected, ["credit-a", "credit-b"])

        row.updateCardResetActions([
            "credit-a": .init(title: "重置中", isEnabled: false),
            "credit-b": .init(title: "重置", isEnabled: false)
        ])
        XCTAssertTrue(button("reset-use.card.credit-a", in: row) === first)
        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(second.isEnabled)
        first.performClick(nil)
        second.performClick(nil)
        XCTAssertEqual(selected.count, 2)

        row.updateCardResetActions([
            "credit-a": .init(title: "重试", isEnabled: true, toolTip: "上次请求未确认")
        ])
        XCTAssertEqual(first.title, "重试")
        first.performClick(nil)
        XCTAssertEqual(selected.last, "credit-a")
    }

    @MainActor
    func testRemovedDetailButtonCannotDispatchOldCreditID() throws {
        _ = NSApplication.shared
        let row = ResetCardsRow()
        row.configure(chips: [.init(
            id: "codex", title: "重置卡 ×1", soon: false,
            cards: [.init(kindTitle: "重置卡", expiresAt: nil, id: "old-credit",
                          resetAction: .init(title: "重置", isEnabled: true))]
        )])
        let removed = try XCTUnwrap(button("reset-use.card.old-credit", in: row))
        var count = 0
        row.onReset = { _ in count += 1 }
        row.configure(chips: [])
        NSApp.sendAction(try XCTUnwrap(removed.action), to: removed.target, from: removed)
        XCTAssertEqual(count, 0)
    }

    @MainActor
    private func button(_ id: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
        return view.subviews.lazy.compactMap { self.button(id, in: $0) }.first
    }
}
