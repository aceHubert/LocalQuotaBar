import AppKit
import XCTest
@testable import LocalQuotaBar

final class ZAIResetIntegrationTests: XCTestCase {
    func testAccountScopeSurvivesTokenRefreshAndSeparatesAccountsAndChannels() throws {
        let selection = ZAIProviderSelection(domain: "zai", kind: .codingPlan, selectedKey: nil)
        let first = try context(selection, zcode: "owner", platform: "account", expiry: 1)
        let refreshed = try context(selection, zcode: "owner", platform: "account", expiry: 2)
        XCTAssertEqual(first.scopeID, refreshed.scopeID)
        XCTAssertNotEqual(first.jwt, refreshed.jwt)
        XCTAssertEqual(first.scopeID.count, 64)
        XCTAssertNotEqual(first.scopeID, try context(selection, zcode: "other", platform: "account").scopeID)
        XCTAssertNotEqual(first.scopeID, try context(selection, zcode: "owner", platform: "other").scopeID)
        XCTAssertNotEqual(first.scopeID, try context(
            .init(domain: "bigmodel", kind: .codingPlan, selectedKey: nil), zcode: "owner", platform: "account"
        ).scopeID)
    }

    func testRejectsUnsupportedPlanAndMissingStableIdentity() throws {
        for kind: ZAIPlanKind in [.apiKey, .startPlan] {
            XCTAssertThrowsError(try context(.init(domain: "zai", kind: kind, selectedKey: nil)))
        }
        // legacy selectedKey 认出的团队连接缺少组织/项目时不能发请求。
        XCTAssertThrowsError(try context(.init(domain: "zai", kind: .codingPlan, selectedKey: "team:project")))
        // ZCode 3.12.3+ 团队连接必须有完整团队作用域。
        XCTAssertThrowsError(try ZAIResetContextResolver.makeContext(
            selection: .init(domain: "zai", kind: .codingPlan, selectedKey: nil,
                             connectionKind: "team-coding-plan"),
            jwt: token(["sub": "owner", "exp": 1]), oauthToken: token(["sub": "account", "exp": 1]), userInfo: nil
        ))
        // 个人 coding-plan 的连接选择必须放行。
        XCTAssertNoThrow(try ZAIResetContextResolver.makeContext(
            selection: .init(domain: "zai", kind: .codingPlan, selectedKey: nil,
                             connectionKind: "individual-coding-plan"),
            jwt: token(["sub": "owner", "exp": 1]), oauthToken: token(["sub": "account", "exp": 1]), userInfo: nil
        ))
        // 完整团队作用域必须放行，并进入团队重置链路。
        let teamContext = ZAITeamContext(productId: "product-a", organizationId: "org-a", projectId: "project-a")
        let team = try ZAIResetContextResolver.makeContext(
            selection: .init(domain: "bigmodel", kind: .codingPlan, selectedKey: nil,
                             connectionKind: "team-coding-plan", teamContext: teamContext),
            jwt: token(["sub": "owner", "exp": 1]), oauthToken: token(["sub": "account", "exp": 1]), userInfo: nil
        )
        XCTAssertEqual(team.teamContext, teamContext)
        XCTAssertNotEqual(team.scopeID, try ZAIResetContextResolver.makeContext(
            selection: .init(domain: "bigmodel", kind: .codingPlan, selectedKey: nil,
                             connectionKind: "team-coding-plan",
                             teamContext: .init(productId: nil, organizationId: "org-b", projectId: "project-a")),
            jwt: token(["sub": "owner", "exp": 1]), oauthToken: token(["sub": "account", "exp": 1]), userInfo: nil
        ).scopeID)
        XCTAssertThrowsError(try ZAIResetContextResolver.makeContext(
            selection: .init(domain: "zai", kind: .codingPlan, selectedKey: nil),
            jwt: token(["exp": 123]), oauthToken: "opaque", userInfo: nil
        ))
    }

    func testOpaqueOAuthUsesPairedAccountIdentityAndBearerPrefixIsAccepted() throws {
        let selection = ZAIProviderSelection(domain: "zai", kind: .codingPlan, selectedKey: nil)
        let jwt = try token(["sub": "owner"])
        let first = try ZAIResetContextResolver.makeContext(
            selection: selection, jwt: "bearer \(jwt)", oauthToken: "opaque-one",
            userInfo: ["user": ["id": "account"]]
        )
        let second = try ZAIResetContextResolver.makeContext(
            selection: selection, jwt: jwt, oauthToken: "opaque-two", userInfo: ["user": ["id": "account"]]
        )
        XCTAssertEqual(first.scopeID, second.scopeID)
    }

    @MainActor
    func testProviderResetStateKeepsActionsIndependentFromExpansionAndQuotaRefresh() async throws {
        _ = NSApplication.shared
        let panel = ZAIPanelSection(resolveSelection: {
            .init(domain: "zai", kind: .codingPlan, selectedKey: nil)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 298, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 298, height: 600))
        window.contentView = host
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        let cards: [ZAIResetCreditCard] = [
            .init(kind: .fiveHour, expiresAt: Date().addingTimeInterval(8100)),
            .init(kind: .week, expiresAt: Date().addingTimeInterval(86400 * 10))
        ]
        panel.apply(snapshot: .init(kind: .codingPlan, resetCreditCards: cards), account: nil,
                    isRefreshing: false, error: nil, titleOverride: nil)
        panel.applyResetState([:], canUseCards: true, canRetry: true, unavailableReason: nil)
        host.layoutSubtreeIfNeeded()
        let fiveHour = try action("zai.fiveHour", in: panel)
        let week = try action("zai.week", in: panel)
        var requests: [ZAIResetCreditCard.Kind] = []
        panel.onUseResetCard = { requests.append($0) }
        fiveHour.performClick(nil)
        XCTAssertEqual(requests, [.fiveHour])

        panel.applyResetState([.fiveHour: .submitting], canUseCards: true, canRetry: true, unavailableReason: nil)
        XCTAssertTrue(try action("zai.fiveHour", in: panel) === fiveHour)
        XCTAssertFalse(fiveHour.isEnabled)
        XCTAssertFalse(week.isEnabled)
        XCTAssertFalse(panel.canRequestRefresh)
        week.performClick(nil)
        XCTAssertEqual(requests.count, 1)

        panel.applyResetState([.fiveHour: .failed("网络结果不明确")], canUseCards: false, canRetry: true, unavailableReason: nil)
        XCTAssertEqual(fiveHour.title, "重试")
        XCTAssertTrue(fiveHour.isEnabled)
        XCTAssertFalse(week.isEnabled)
        XCTAssertTrue(panel.canRequestRefresh)
        fiveHour.performClick(nil)
        XCTAssertEqual(requests, [.fiveHour, .fiveHour])

        panel.apply(snapshot: .init(kind: .codingPlan, resetCreditCards: []), account: nil,
                    isRefreshing: false, error: nil, titleOverride: nil)
        XCTAssertTrue(try action("zai.fiveHour", in: panel).isEnabled,
                      "未确认请求不能随可用卡列表变化而失去原 key 的重试入口")
        panel.applyResetState([.fiveHour: .succeeded], canUseCards: false, canRetry: true, unavailableReason: nil)
        XCTAssertFalse(try action("zai.fiveHour", in: panel).isEnabled)
        XCTAssertEqual(try action("zai.fiveHour", in: panel).title, "已重置")
        panel.applyResetState([:], canUseCards: true, canRetry: true, unavailableReason: nil)
        XCTAssertFalse(descendants(panel).contains { $0.identifier?.rawValue == "reset-use.zai.fiveHour" })
    }

    private func context(_ selection: ZAIProviderSelection, zcode: String = "owner", platform: String = "account", expiry: Int = 1) throws -> ZAIResetContext {
        try ZAIResetContextResolver.makeContext(selection: selection,
            jwt: token(["sub": zcode, "exp": expiry]), oauthToken: token(["sub": platform, "exp": expiry]), userInfo: nil)
    }

    private func token(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "test.\(payload).signature"
    }

    @MainActor
    private func action(_ id: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "reset-use.\(id)" })
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
