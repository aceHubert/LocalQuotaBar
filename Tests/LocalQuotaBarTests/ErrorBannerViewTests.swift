import AppKit
import XCTest
@testable import LocalQuotaBar

final class ErrorBannerViewTests: XCTestCase {
    @MainActor
    func testErrorBannerLayoutSettlesAndSurvivesRepeatedDisplay() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 298, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 298, height: 120))
        window.contentView = host
        let banner = ErrorBannerView()
        host.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            banner.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        let message = "网络连接失败，请稍后重试。当前继续显示上次成功刷新时保存的额度数据。"
        banner.configure(title: "刷新失败，显示 15:20:30 数据", detail: message)
        window.orderFrontRegardless()
        // 走真实显示周期，防止 layout 中重复写换行宽度造成无限约束更新。
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let detail = try XCTUnwrap(descendants(of: banner).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == message })
        XCTAssertGreaterThan(detail.frame.width, 120)
        let wrappingWidth = detail.preferredMaxLayoutWidth
        banner.layout()
        XCTAssertFalse(detail.needsUpdateConstraints)
        XCTAssertEqual(detail.preferredMaxLayoutWidth, wrappingWidth)
        banner.hide()
        banner.configure(title: "刷新失败", detail: "请重试")
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertFalse(banner.isHidden)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
