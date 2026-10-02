import XCTest
@testable import LocalQuotaBar

/// 真实登录态探针（赠送有效期）：仅在 LOCALQUOTABAR_DEEPSEEK_LIVE=1 时运行。
/// dump get_all_invoice 原始结构与快照 activeBonusGrants，用于核对解析口径；token 永不打印。
final class DeepSeekRawBonusProbeTests: XCTestCase {
    func testDumpRawBonusOrdersAndActiveGrants() async throws {
        guard ProcessInfo.processInfo.environment["LOCALQUOTABAR_DEEPSEEK_LIVE"] == "1" else {
            throw XCTSkip("需要显式开启 live 探针")
        }

        let candidates = DeepSeekTokenImporter.importCandidates()
        guard case .success(let selected) = DeepSeekTokenImporter.selectProfile(
            candidates: candidates, preferredProfileID: nil) else {
            XCTFail("未找到 userToken 候选")
            return
        }

        let url = URL(string: "https://platform.deepseek.com/auth-api/v0/users/get_all_invoice")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(selected.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        print("[probe] HTTP", (response as? HTTPURLResponse)?.statusCode ?? 0)
        if let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let invoices = (((body["data"] as? [String: Any])?["biz_data"] as? [String: Any])?["invoices"]) as? [String: Any] {
            for entry in (invoices["bonus_orders"] as? [[String: Any]]) ?? [] {
                print("[probe] bonus_order:", entry)
            }
        }

        // 端到端：完整快照里的生效明细（过期 / 耗尽已在快照口径过滤）
        let snapshot = try await DeepSeekClient().fetchSnapshot(
            token: selected.token, profileID: selected.profileID, profileName: selected.profileName)
        print("[probe] bonus balance:", snapshot.balance(kind: .bonus, currency: snapshot.primaryBalance?.currency ?? "CNY"))
        for grant in snapshot.activeBonusGrants {
            print("[probe] active grant:", grant.currency, grant.amount,
                  "effective:", grant.effectiveAt as Any, "expires:", grant.expiresAt as Any)
        }
    }
}
