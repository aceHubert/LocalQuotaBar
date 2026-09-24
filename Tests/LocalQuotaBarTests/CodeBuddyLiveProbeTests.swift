import XCTest
@testable import LocalQuotaBar

/// CodeBuddy 真实登录态探针：LOCALQUOTABAR_CODEBUDDY_LIVE=1 时运行。
/// 首次运行可能触发 Keychain 授权弹窗（Chrome Safe Storage），需在手动刷新路径完成。
/// 默认探测国际版（www.codebuddy.ai）；设 LOCALQUOTABAR_CODEBUDDY_LIVE_HOST=www.codebuddy.cn
/// 可复核国内版链路（Cookie 导入、请求契约与响应结构两站一致，仅 host/Referer/region 不同）。
/// 本探针不打印 Cookie 或完整响应体。
final class CodeBuddyLiveProbeTests: XCTestCase {
    func testLiveFetchAndDumpStructure() async throws {
        guard ProcessInfo.processInfo.environment["LOCALQUOTABAR_CODEBUDDY_LIVE"] == "1" else {
            throw XCTSkip("需要显式开启 live 探针")
        }

        let host = ProcessInfo.processInfo.environment["LOCALQUOTABAR_CODEBUDDY_LIVE_HOST"]
            ?? "www.codebuddy.ai"
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        print("[probe] host:", host)

        let imported = CodeBuddyCookieImporter.importCandidates(domain: domain, allowKeychainUI: true)
        guard case .success(let candidates) = imported else {
            if case .failure(let error) = imported {
                print("[probe] import failed:", error.localizedDescription)
            }
            XCTFail("Cookie 导入失败")
            return
        }
        print("[probe] candidates:", candidates.map(\.profileID))
        guard let selected = candidates.first else { return XCTFail("无候选") }
        let cookieNames = selected.cookieHeader
            .split(separator: ";")
            .compactMap { $0.split(separator: "=", maxSplits: 1).first }
            .map(String.init)
        print("[probe] cookie names:", cookieNames, "count:", cookieNames.count)

        let snapshot = try await CodeBuddyClient(endpoints: .init(host: host)).fetchSnapshot(
            cookieHeader: selected.cookieHeader,
            profileID: selected.profileID,
            profileName: selected.profileName
        )
        print("[probe] region:", snapshot.region)
        print("[probe] planName:", snapshot.planName ?? "nil")
        print("[probe] planPackage:", snapshot.planPackage ?? "nil")
        print("[probe] paid:", snapshot.paidPackages)
        print("[probe] free:", snapshot.freePackages)
        print("[probe] other:", snapshot.otherPackages)
    }
}
