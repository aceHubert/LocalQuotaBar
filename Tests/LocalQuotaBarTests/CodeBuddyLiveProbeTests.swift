import XCTest
@testable import LocalQuotaBar

/// CodeBuddy 真实登录态探针：LOCALQUOTABAR_CODEBUDDY_LIVE=1 时运行。
/// 首次运行可能触发 Keychain 授权弹窗（Chrome Safe Storage），需在手动刷新路径完成。
/// 已知问题（2026-09-22 实测）：Chrome 全量 Cookie + 浏览器同款请求头仍被 APISIX
/// 网关 401 拒绝——待用户在 Chrome 确认 codebuddy.ai 登录态后复核（见执行计划验证记录）。
final class CodeBuddyLiveProbeTests: XCTestCase {
    func testLiveFetchAndDumpStructure() async throws {
        guard ProcessInfo.processInfo.environment["LOCALQUOTABAR_CODEBUDDY_LIVE"] == "1" else {
            throw XCTSkip("需要显式开启 live 探针")
        }

        let imported = CodeBuddyCookieImporter.importCandidates(allowKeychainUI: true)
        guard case .success(let candidates) = imported else {
            if case .failure(let error) = imported {
                print("[probe] import failed:", error.localizedDescription)
            }
            XCTFail("Cookie 导入失败")
            return
        }
        print("[probe] candidates:", candidates.map(\.profileID))
        guard let selected = candidates.first else { return XCTFail("无候选") }

        let snapshot = try await CodeBuddyClient().fetchSnapshot(
            cookieHeader: selected.cookieHeader,
            profileID: selected.profileID,
            profileName: selected.profileName
        )
        print("[probe] planName:", snapshot.planName ?? "nil")
        print("[probe] planPackage:", snapshot.planPackage ?? "nil")
        print("[probe] paid:", snapshot.paidPackages)
        print("[probe] free:", snapshot.freePackages)
    }
}
