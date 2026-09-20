import XCTest
@testable import LocalQuotaBar

/// 文件事件过滤决策：文件变更只更新本地参数，绝不触发网络刷新；
/// 额度刷新由周期定时器、手动刷新与套餐视图切换 / 重置驱动。
final class ZAISettingsChangeResolverTests: XCTestCase {
    private let stamp = ZAISettingsFileStamp(
        modifiedAt: Date(timeIntervalSince1970: 1_000), byteCount: 4_096)
    private let rewrittenStamp = ZAISettingsFileStamp(
        modifiedAt: Date(timeIntervalSince1970: 2_000), byteCount: 4_200)

    private func identity(account: String? = "id:user-1",
                          domain: String = "zai") -> ZAISettingsFileIdentity {
        ZAISettingsFileIdentity(
            account: account,
            selection: ZAIProviderSelection(
                domain: domain, kind: .codingPlan,
                selectedKey: "coding-plan:builtin:\(domain)-coding-plan")
        )
    }

    func testIgnoresDirectoryNoiseWhenStampsUnchanged() {
        // tasks-index.sqlite-wal 等目录事件：受监控的两个文件没动。
        XCTAssertEqual(
            ZAISettingsChangeResolver.resolve(
                previousStamps: [stamp], currentStamps: [stamp],
                previousIdentity: identity(), currentIdentity: identity()),
            .ignore)
    }

    func testIgnoresRewriteWhenIdentityUnchanged() {
        // setting.json 因 recentProjects 重写、credentials.json token 轮换：
        // 文件确实变了，但账号与 provider 选择没变。
        XCTAssertEqual(
            ZAISettingsChangeResolver.resolve(
                previousStamps: [stamp], currentStamps: [rewrittenStamp],
                previousIdentity: identity(), currentIdentity: identity()),
            .ignore)
    }

    func testAppliesLocalStateWhenAccountChanges() {
        // 换号也只更新本地参数（清快照 / 账号标签），不发网络请求。
        XCTAssertEqual(
            ZAISettingsChangeResolver.resolve(
                previousStamps: [stamp], currentStamps: [rewrittenStamp],
                previousIdentity: identity(account: "id:user-1"),
                currentIdentity: identity(account: "id:user-2")),
            .applySettingsChange)
    }

    func testAppliesLocalStateWhenSelectionChanges() {
        // zai ↔ bigmodel 切渠道。
        XCTAssertEqual(
            ZAISettingsChangeResolver.resolve(
                previousStamps: [stamp], currentStamps: [rewrittenStamp],
                previousIdentity: identity(domain: "zai"),
                currentIdentity: identity(domain: "bigmodel")),
            .applySettingsChange)
    }

    func testTreatsLogoutAsIdentityChange() {
        // 登出：账号身份从有值变为 nil，即使 selection 字段仍能解析出来也要更新
        // 本地状态（额度查询依赖凭证存在）。
        let loggedOut = ZAISettingsFileIdentity(
            account: nil,
            selection: ZAIProviderSelection(domain: "zai", kind: .codingPlan, selectedKey: nil))
        XCTAssertEqual(
            ZAISettingsChangeResolver.resolve(
                previousStamps: [stamp], currentStamps: [rewrittenStamp],
                previousIdentity: identity(), currentIdentity: loggedOut),
            .applySettingsChange)
    }
}
