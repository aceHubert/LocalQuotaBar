import AppKit
import XCTest
@testable import LocalQuotaBar

/// slim 头部（tabs 版）：只保留状态文字与失败错误文案，不再有 logo / 名称 / tag / 刷新按钮。
final class ProviderHeaderViewTests: XCTestCase {
    @MainActor
    func testCompactAccountLabelKeepsFirstThreeCharactersAndDomain() async {
        let cases = [
            ("username@example.com", "use…@example.com"),
            ("测试用户名@example.com", "测试用…@example.com"),
            ("👩🏽‍💻用户名字@example.com", "👩🏽‍💻用户…@example.com"),
            ("ab@example.com", "ab@example.com"),
            ("abc@example.com", "abc@example.com"),
            ("API Key", "API Key"),
            ("", "")
        ]

        for (account, expected) in cases {
            XCTAssertEqual(ProviderHeaderView.compactAccountLabel(account), expected)
        }
    }

    @MainActor
    func testSlimHeaderShowsStatusTimeWithoutChrome() async throws {
        let (window, header) = makeHostedHeader()
        defer { window.close() }
        header.configure(.init(statusText: "15:22", statusKind: .ok))
        window.contentView?.layoutSubtreeIfNeeded()

        let time = try label("15:22", in: header)
        XCTAssertFalse(time.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(time.toolTip, "15:22")
        // 身份信息已上移 Tab 栏：头部不再有 logo、图标或刷新按钮。
        XCTAssertTrue(descendants(of: header).compactMap { $0 as? NSImageView }.isEmpty)
        XCTAssertTrue(descendants(of: header).compactMap { $0 as? PanelIconButton }.isEmpty)
        // 错误文案默认隐藏。
        XCTAssertNil(descendants(of: header).compactMap { $0 as? NSTextField }
            .first { $0.toolTip?.contains("失败") == true })
    }

    @MainActor
    func testSlimHeaderShowsTruncatedErrorWithFullTooltip() async throws {
        let (window, header) = makeHostedHeader()
        defer { window.close() }
        let error = "macOS Keychain 拒绝访问 Chrome Safe Storage。请在系统设置中授予访问权限，然后点击重新刷新。"
        header.configure(.init(
            statusText: "刷新失败",
            statusKind: .bad,
            errorText: error,
            errorTooltip: "刷新失败，显示 15:20:30 数据 · \(error)"
        ))
        window.contentView?.layoutSubtreeIfNeeded()

        let errorLabel = try XCTUnwrap(descendants(of: header).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == error })
        XCTAssertFalse(errorLabel.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(errorLabel.toolTip, "刷新失败，显示 15:20:30 数据 · \(error)")
        XCTAssertEqual(errorLabel.maximumNumberOfLines, 1)
        let status = try label("刷新失败", in: header)
        XCTAssertFalse(status.isHiddenOrHasHiddenAncestor)

        // 恢复成功后错误文案清除。
        header.configure(.init(statusText: "15:26", statusKind: .ok))
        XCTAssertTrue(errorLabel.isHidden)
    }

    @MainActor
    private func makeHostedHeader() -> (NSWindow, ProviderHeaderView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 298, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 298, height: 40))
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        let header = ProviderHeaderView()
        header.wantsLayer = true
        header.layer?.backgroundColor = PanelTheme.panelBackground.cgColor
        host.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        return (window, header)
    }

    @MainActor
    private func label(_ text: String, in view: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == text })
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
