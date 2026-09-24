import XCTest
@testable import LocalQuotaBar

/// 真实登录态探针：仅在 LOCALQUOTABAR_DEEPSEEK_LIVE=1 时运行（本机已登录 Chrome 前提）。
/// 输出脱敏结构信息用于核对解析口径；token 永不打印。
final class DeepSeekLiveProbeTests: XCTestCase {
    func testLiveFetchAndDumpStructure() async throws {
        guard ProcessInfo.processInfo.environment["LOCALQUOTABAR_DEEPSEEK_LIVE"] == "1" else {
            throw XCTSkip("需要显式开启 live 探针")
        }

        let candidates = DeepSeekTokenImporter.importCandidates()
        print("[probe] candidates:", candidates.map(\.profileID))
        guard case .success(let selected) = DeepSeekTokenImporter.selectProfile(
            candidates: candidates, preferredProfileID: nil) else {
            XCTFail("未找到 userToken 候选")
            return
        }
        print("[probe] selected profile:", selected.profileID)

        let snapshot = try await DeepSeekClient().fetchSnapshot(
            token: selected.token, profileID: selected.profileID, profileName: selected.profileName)
        print("[probe] profile:", snapshot.profileName)
        print("[probe] wallets:", snapshot.wallets)
        print("[probe] totalCosts:", snapshot.totalCosts)
        print("[probe] usage currency:", snapshot.usage.currency)
        print("[probe] usage totalAmount:", snapshot.usage.totalAmount)
        print("[probe] usage totalTokens:", snapshot.usage.totalTokens)
        let nonZero = snapshot.usage.days.filter { $0.amount > 0 || $0.tokens > 0 }
        print("[probe] non-zero days count:", nonZero.count)
        for day in nonZero.suffix(5) {
            print("[probe] day:", day)
        }
    }
}
