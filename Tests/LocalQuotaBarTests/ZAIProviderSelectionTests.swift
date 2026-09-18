import XCTest
@testable import LocalQuotaBar

final class ZAIProviderSelectionTests: XCTestCase {
    private func selection(_ object: [String: Any]) -> ZAIProviderSelection? {
        ZAISettings.resolveProviderSelection(object: object)
    }

    func testConnectionSelectionWinsOverFrozenLegacyKey() throws {
        // ZCode 3.12.3 真实落盘形态：连接选择已切到 start-plan，selectedKey 仍是冻结的 coding-plan。
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "providerFamilyConnectionSelections": ["zai": ["kind": "start-plan"]],
            "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-coding-plan"]
        ]))
        XCTAssertEqual(resolved.kind, .startPlan)
        XCTAssertEqual(resolved.connectionKind, "start-plan")
    }

    func testConnectionSelectionKinds() throws {
        for (raw, expected) in [
            ("individual-coding-plan", ZAIPlanKind.codingPlan),
            ("team-coding-plan", ZAIPlanKind.codingPlan)
        ] {
            let resolved = try XCTUnwrap(selection([
                "providerFamilyDomain": "bigmodel",
                "providerFamilyConnectionSelections": ["bigmodel": ["kind": raw]]
            ]))
            XCTAssertEqual(resolved.kind, expected, "连接类型 \(raw)")
            XCTAssertEqual(resolved.connectionKind, raw)
            XCTAssertNil(resolved.selectedKey)
        }
    }

    func testLegacySelectedKeyUsedWhenConnectionSelectionMissing() throws {
        // api-key 模式不写连接选择，仍由 modelProviderFamilySelectedKeys 表达。
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "modelProviderFamilySelectedKeys": ["zai": "api-key:builtin:zai"]
        ]))
        XCTAssertEqual(resolved.kind, .apiKey)
        XCTAssertNil(resolved.connectionKind)

        let startPlan = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-start-plan"]
        ]))
        XCTAssertEqual(startPlan.kind, .startPlan)
    }

    func testUnknownConnectionKindFallsBackToLegacyKey() throws {
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "providerFamilyConnectionSelections": ["zai": ["kind": "future-plan"]],
            "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-coding-plan"]
        ]))
        XCTAssertEqual(resolved.kind, .codingPlan)
        XCTAssertNil(resolved.connectionKind)
    }

    func testMalformedConnectionSelectionFallsBackToLegacy() throws {
        for broken in [["kind": ""], ["unexpected": 1], "not-a-dict"] as [Any] {
            let resolved = try XCTUnwrap(selection([
                "providerFamilyDomain": "zai",
                "providerFamilyConnectionSelections": ["zai": broken],
                "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-coding-plan"]
            ]))
            XCTAssertEqual(resolved.kind, .codingPlan)
            XCTAssertNil(resolved.connectionKind)
        }
    }

    func testUnsupportedDomainYieldsNil() {
        XCTAssertNil(selection(["providerFamilyDomain": "openai"]))
        XCTAssertNil(selection([:]))
    }
}
