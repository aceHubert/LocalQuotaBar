import AppKit
import XCTest
@testable import LocalQuotaBar

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
    func testHeaderKeepsRefreshTimeAndStatusDotFullyVisibleAtPanelWidth() async throws {
        let (window, header) = makeHostedHeader(account: "username@example.com")
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()

        let views = descendants(of: header)
        let account = try label("use…@example.com", in: header)
        let time = try label("15:22", in: header)
        let logo = try XCTUnwrap(views.compactMap { $0 as? NSImageView }
            .first { $0.image != nil && !$0.isHiddenOrHasHiddenAncestor })
        let refresh = try XCTUnwrap(views.compactMap { $0 as? PanelIconButton }.first)
        // 徽标状态点必须由头部承载，才能完整覆盖徽标边缘而不受其裁切。
        let dot = try XCTUnwrap(header.subviews.first {
            abs($0.frame.width - 7) < 0.01 && abs($0.frame.height - 7) < 0.01
        })

        XCTAssertEqual(header.bounds.width, 298, accuracy: 0.5)
        XCTAssertEqual(account.toolTip, "username@example.com")
        XCTAssertEqual(time.toolTip, "15:22")
        XCTAssertGreaterThanOrEqual(time.frame.width + 0.5, time.intrinsicContentSize.width)
        for view in [logo, try label("Codex", in: header), account,
                     try label("plus", in: header), time, refresh, dot] {
            assertFullyVisible(view, in: header)
        }

        try renderIfRequested(header)
    }

    @MainActor
    func testLongDomainCompressesAccountInsteadOfRefreshTime() async throws {
        let email = "username@very-long-organization-name.example.com"
        let (window, header) = makeHostedHeader(account: email)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()

        let account = try label("use…@very-long-organization-name.example.com", in: header)
        let time = try label("15:22", in: header)
        XCTAssertEqual(account.toolTip, email)
        XCTAssertLessThan(account.frame.width, account.intrinsicContentSize.width)
        XCTAssertGreaterThanOrEqual(time.frame.width + 0.5, time.intrinsicContentSize.width)
        assertFullyVisible(account, in: header)
        assertFullyVisible(time, in: header)
    }

    @MainActor
    private func makeHostedHeader(account: String) -> (NSWindow, ProviderHeaderView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 298, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 298, height: 80))
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
        header.configure(.init(
            title: "Codex", monogram: "C", logoImage: PanelLogos.codex,
            subtitle: account, tagText: "plus", tagStyle: .plan,
            statusText: "15:22", statusKind: .ok
        ))
        return (window, header)
    }

    @MainActor
    private func assertFullyVisible(
        _ view: NSView, in header: NSView,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let description = "\(type(of: view)): \((view as? NSTextField)?.stringValue ?? view.toolTip ?? "")"
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, description, file: file, line: line)
        XCTAssertGreaterThan(view.bounds.width, 0, description, file: file, line: line)
        XCTAssertGreaterThan(view.bounds.height, 0, description, file: file, line: line)
        let frame = view.convert(view.bounds, to: header)
        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, description, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, -0.5, description, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, header.bounds.width + 0.5, description, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, header.bounds.height + 0.5, description, file: file, line: line)
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

    @MainActor
    private func renderIfRequested(_ header: NSView) throws {
        guard let directory = ProcessInfo.processInfo.environment["LOCALQUOTABAR_RENDER_DIR"],
              !directory.isEmpty else { return }
        // 只渲染测试中的虚构账号，默认测试运行不写入图片。
        let bitmap = try XCTUnwrap(header.bitmapImageRepForCachingDisplay(in: header.bounds))
        header.cacheDisplay(in: header.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appendingPathComponent("provider-header.png"))
    }
}
