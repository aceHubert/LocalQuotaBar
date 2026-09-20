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

    func testSelectedKeyDefaultWinsOverFormConnectionKind() throws {
        // ZCode 3.14.0：连接形态保持 individual；setting.json 的 selectedKey 是默认套餐
        // 选择（切换在会话级模型选择器、不落盘），默认值压过只表达连接形态的 connectionKind。
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "providerFamilyConnectionSelections": ["zai": ["kind": "individual-coding-plan"]],
            "modelProviderFamilySelectedKeys": ["zai": "start-plan:builtin:zai-start-plan"]
        ]))
        XCTAssertEqual(resolved.kind, .startPlan)
        XCTAssertEqual(resolved.connectionKind, "individual-coding-plan")
        XCTAssertNil(resolved.teamContext)

        // 3.12.3 时期的 key 前缀仍带 coding-plan 段，靠 start-plan 后缀识别。
        let legacyKeyForm = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "providerFamilyConnectionSelections": ["zai": ["kind": "individual-coding-plan"]],
            "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-start-plan"]
        ]))
        XCTAssertEqual(legacyKeyForm.kind, .startPlan)
    }

    func testSelectedKeyApiKeyWinsOverStaleConnectionKind() throws {
        // 连接选择残留 oauth 形态、实际已切 api-key 模式（api-key 不写连接选择）。
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "providerFamilyConnectionSelections": ["zai": ["kind": "individual-coding-plan"]],
            "modelProviderFamilySelectedKeys": ["zai": "api-key:builtin:zai"]
        ]))
        XCTAssertEqual(resolved.kind, .apiKey)
        XCTAssertEqual(resolved.connectionKind, "individual-coding-plan")
    }

    func testTeamScopeKeptWhenSelectedKeyDrivesKind() throws {
        // 3.14.0 本机实测形态：bigmodel 连接形态 team + selectedKey coding-plan，
        // 套餐 kind 由 selectedKey 判定，团队 org/project 作用域仍来自连接形态。
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "bigmodel",
            "providerFamilyConnectionSelections": [
                "bigmodel": [
                    "kind": "team-coding-plan",
                    "productId": "product-9cef7c",
                    "organizationId": "org-test",
                    "projectId": "proj_test"
                ]
            ],
            "modelProviderFamilySelectedKeys": ["bigmodel": "coding-plan:builtin:bigmodel-coding-plan"]
        ]))
        XCTAssertEqual(resolved.kind, .codingPlan)
        XCTAssertEqual(resolved.connectionKind, "team-coding-plan")
        XCTAssertEqual(resolved.teamContext?.organizationId, "org-test")
        XCTAssertEqual(resolved.teamContext?.projectId, "proj_test")
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

    func testTeamConnectionParsesScope() throws {
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "bigmodel",
            "providerFamilyConnectionSelections": [
                "bigmodel": [
                    "kind": "team-coding-plan",
                    "productId": "product-9cef7c",
                    "organizationId": "org-test",
                    "projectId": "proj_test"
                ]
            ]
        ]))
        XCTAssertEqual(resolved.teamContext?.productId, "product-9cef7c")
        XCTAssertEqual(resolved.teamContext?.organizationId, "org-test")
        XCTAssertEqual(resolved.teamContext?.projectId, "proj_test")
    }

    func testIncompleteTeamScopeIsUnavailable() throws {
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "bigmodel",
            "providerFamilyConnectionSelections": [
                "bigmodel": ["kind": "team-coding-plan", "organizationId": "org-test"]
            ]
        ]))
        XCTAssertNil(resolved.teamContext)
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

    func testUnknownConnectionKindFallsBackToSelectedKey() throws {
        let resolved = try XCTUnwrap(selection([
            "providerFamilyDomain": "zai",
            "providerFamilyConnectionSelections": ["zai": ["kind": "future-plan"]],
            "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-coding-plan"]
        ]))
        XCTAssertEqual(resolved.kind, .codingPlan)
        XCTAssertNil(resolved.connectionKind)
    }

    func testMalformedConnectionSelectionFallsBackToSelectedKey() throws {
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

    // MARK: - 套餐视图 override（ZCode 3.14.0 会话级切换不落盘，由用户手动指定）

    private func makeDefaults() -> UserDefaults {
        let name = "test.zai.planView.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testPlanViewSettingsRoundtrip() {
        let defaults = makeDefaults()
        // 未设置时为 nil（跟随文件默认套餐）。
        XCTAssertNil(ZAIPlanViewSettings.load(defaults: defaults))
        ZAIPlanViewSettings.save(.teamCodingPlan, defaults: defaults)
        XCTAssertEqual(ZAIPlanViewSettings.load(defaults: defaults), .teamCodingPlan)
        // 未知/旧值回退 nil，不崩溃。
        defaults.set("followFile", forKey: ZAIPlanViewSettings.overrideKey)
        XCTAssertNil(ZAIPlanViewSettings.load(defaults: defaults))
    }

    func testPlanViewSettingsDomainTrackingAndClear() {
        let defaults = makeDefaults()
        ZAIPlanViewSettings.save(.teamCodingPlan, defaults: defaults)
        ZAIPlanViewSettings.saveLastDomain("bigmodel", defaults: defaults)
        XCTAssertEqual(ZAIPlanViewSettings.load(defaults: defaults), .teamCodingPlan)
        XCTAssertEqual(ZAIPlanViewSettings.loadLastDomain(defaults: defaults), "bigmodel")

        ZAIPlanViewSettings.clear(defaults: defaults)
        ZAIPlanViewSettings.saveLastDomain("zai", defaults: defaults)
        XCTAssertNil(ZAIPlanViewSettings.load(defaults: defaults))
        XCTAssertEqual(ZAIPlanViewSettings.loadLastDomain(defaults: defaults), "zai")
    }

    func testPlanViewSettingsIsolateByAccount() {
        let defaults = makeDefaults()
        ZAIPlanViewSettings.save(.teamCodingPlan, accountID: "sub:account-a", defaults: defaults)
        XCTAssertTrue(ZAIPlanViewSettings.isValid(for: "sub:account-a", defaults: defaults))
        XCTAssertFalse(ZAIPlanViewSettings.isValid(for: "sub:account-b", defaults: defaults))

        // 旧数据未绑定账号：能识别当前账号时必须失效，避免跨账号泄漏。
        defaults.set(ZAIPlanViewOverride.startPlan.rawValue, forKey: ZAIPlanViewSettings.overrideKey)
        defaults.removeObject(forKey: ZAIPlanViewSettings.accountKey)
        XCTAssertFalse(ZAIPlanViewSettings.isValid(for: "sub:account-a", defaults: defaults))
        XCTAssertTrue(ZAIPlanViewSettings.isValid(for: nil, defaults: defaults))

        // 同一渠道换号：domain 不变，但 override 不能再沿用。
        ZAIPlanViewSettings.save(.teamCodingPlan, accountID: "sub:account-a", defaults: defaults)
        ZAIPlanViewSettings.saveLastDomain("zai", defaults: defaults)
        XCTAssertEqual(ZAIPlanViewSettings.loadLastDomain(defaults: defaults), "zai")
        XCTAssertEqual(ZAIPlanViewSettings.load(defaults: defaults), .teamCodingPlan)
        XCTAssertFalse(ZAIPlanViewSettings.isValid(for: "sub:account-b", defaults: defaults))

        ZAIPlanViewSettings.clear(defaults: defaults)
        XCTAssertNil(ZAIPlanViewSettings.load(defaults: defaults))
        XCTAssertNil(ZAIPlanViewSettings.loadAccountID(defaults: defaults))
    }

    func testLastAccountIdentityTracksWithoutOverride() {
        let defaults = makeDefaults()
        // 未设置 override 时也必须能记录账号身份，供刷新时判断是否换号。
        XCTAssertNil(ZAIPlanViewSettings.loadLastAccountID(defaults: defaults))
        ZAIPlanViewSettings.saveLastAccountID("sub:account-a", defaults: defaults)
        XCTAssertEqual(ZAIPlanViewSettings.loadLastAccountID(defaults: defaults), "sub:account-a")
        ZAIPlanViewSettings.saveLastAccountID("sub:account-b", defaults: defaults)
        XCTAssertEqual(ZAIPlanViewSettings.loadLastAccountID(defaults: defaults), "sub:account-b")
        XCTAssertNil(ZAIPlanViewSettings.load(defaults: defaults))
    }

    func testAccountIdentityPriorityIDThenUserIDThenEmail() {
        XCTAssertEqual(
            ZAISettings.accountIdentity(from: [
                "id": "id-1", "user_id": "user-2", "email": "mail@example.com",
            ]),
            "id:id-1"
        )
        XCTAssertEqual(
            ZAISettings.accountIdentity(from: [
                "user_id": "user-2", "email": "mail@example.com",
            ]),
            "user_id:user-2"
        )
        XCTAssertEqual(
            ZAISettings.accountIdentity(from: ["email": "Mail@Example.com"]),
            "email:mail@example.com"
        )
        // 顶层优先于嵌套 user。
        XCTAssertEqual(
            ZAISettings.accountIdentity(from: [
                "id": "top", "user": ["id": "nested"],
            ]),
            "id:top"
        )
    }

    private func effective(_ object: [String: Any],
                           override: ZAIPlanViewOverride?,
                           credentials domains: Set<String> = ["zai", "bigmodel"]) -> ZAIProviderSelection? {
        ZAISettings.resolveEffectiveSelection(
            object: object, override: override, hasCredential: credentials(domains)
        )
    }

    private func credentials(_ domains: Set<String>) -> (String) -> Bool {
        { domains.contains($0) }
    }

    private let zaiIndividualFile: [String: Any] = [
        "providerFamilyDomain": "zai",
        "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-coding-plan"],
        "providerFamilyConnectionSelections": ["zai": ["kind": "individual-coding-plan"]],
    ]

    private let bigmodelTeamFile: [String: Any] = [
        "providerFamilyDomain": "zai",
        "modelProviderFamilySelectedKeys": [
            "zai": "coding-plan:builtin:zai-coding-plan",
            "bigmodel": "coding-plan:builtin:bigmodel-coding-plan",
        ],
        "providerFamilyConnectionSelections": [
            "zai": ["kind": "individual-coding-plan"],
            "bigmodel": [
                "kind": "team-coding-plan",
                "organizationId": "org-test",
                "projectId": "proj_test",
            ],
        ],
    ]

    func testEffectiveSelectionNilOverrideFollowsFile() throws {
        let resolved = try XCTUnwrap(effective(zaiIndividualFile, override: nil))
        XCTAssertEqual(resolved.kind, .codingPlan)
        XCTAssertNil(resolved.teamContext)
    }

    func testEffectiveSelectionSwitchesToStartPlan() throws {
        let resolved = try XCTUnwrap(effective(zaiIndividualFile, override: .startPlan))
        XCTAssertEqual(resolved.kind, .startPlan)
        XCTAssertNil(resolved.teamContext)
        // 切回个人订阅。
        let back = try XCTUnwrap(effective(zaiIndividualFile, override: .codingPlan))
        XCTAssertEqual(back.kind, .codingPlan)
        XCTAssertNil(back.teamContext)
    }

    func testEffectiveSelectionTeamOverrideUsesTeamConnection() throws {
        // 文件当前 domain 是 zai 个人，团队 override 切到 bigmodel 团队连接 + org/project。
        let resolved = try XCTUnwrap(effective(bigmodelTeamFile, override: .teamCodingPlan))
        XCTAssertEqual(resolved.kind, .codingPlan)
        XCTAssertEqual(resolved.domain, "bigmodel")
        XCTAssertEqual(resolved.connectionKind, "team-coding-plan")
        XCTAssertEqual(resolved.teamContext?.organizationId, "org-test")
        XCTAssertEqual(resolved.teamContext?.projectId, "proj_test")

        // 再切回个人订阅：必须切到 individual 连接，不能沿用 bigmodel 团队 domain
        // 后只清空作用域，否则请求仍按团队形态发送。
        let personal = try XCTUnwrap(effective(bigmodelTeamFile, override: .codingPlan))
        XCTAssertEqual(personal.domain, "zai")
        XCTAssertEqual(personal.kind, .codingPlan)
        XCTAssertEqual(personal.connectionKind, "individual-coding-plan")
        XCTAssertNil(personal.teamContext)
    }

    func testTeamOverrideInertWithoutTeamConnection() throws {
        // 文件没有团队连接时团队 override 无效，保持文件原样。
        let resolved = try XCTUnwrap(effective(zaiIndividualFile, override: .teamCodingPlan))
        XCTAssertEqual(resolved.kind, .codingPlan)
        XCTAssertEqual(resolved.domain, "zai")
        XCTAssertNil(resolved.teamContext)
    }

    func testEffectiveSelectionInertForAPIKeyMode() throws {
        // api-key 连接不受套餐视图影响（各套餐都是 OAuth 形态）。
        let apiKeyFile: [String: Any] = [
            "providerFamilyDomain": "zai",
            "modelProviderFamilySelectedKeys": ["zai": "api-key:builtin:zai"],
        ]
        for override in ZAIPlanViewOverride.allCases {
            let resolved = try XCTUnwrap(effective(apiKeyFile, override: override))
            XCTAssertEqual(resolved.kind, .apiKey)
        }
    }

    // MARK: - 右键菜单套餐可选项(codex-cliproxy 文件判定法)

    func testPlanMenuOptionsFromConnectionSlots() {
        // zai 个人 + bigmodel 团队：start-plan 永远可选，个人、团队槽位都在。
        let options = ZAISettings.planMenuOptions(
            object: bigmodelTeamFile,
            hasCredential: credentials(["zai", "bigmodel"])
        )
        XCTAssertTrue(options.startPlan)
        XCTAssertTrue(options.personal)
        XCTAssertTrue(options.team)

        // 只有个人连接:无团队槽位。
        let personalOnly = ZAISettings.planMenuOptions(
            object: zaiIndividualFile,
            hasCredential: credentials(["zai"])
        )
        XCTAssertTrue(personalOnly.startPlan)
        XCTAssertTrue(personalOnly.personal)
        XCTAssertFalse(personalOnly.team)

        // 只有团队连接：个人槽位缺失，团队槽位在。
        let teamOnlyFile: [String: Any] = [
            "providerFamilyDomain": "bigmodel",
            "modelProviderFamilySelectedKeys": ["bigmodel": "coding-plan:builtin:bigmodel-coding-plan"],
            "providerFamilyConnectionSelections": [
                "bigmodel": ["kind": "team-coding-plan", "organizationId": "org-test", "projectId": "proj_test"],
            ],
        ]
        let teamOnly = ZAISettings.planMenuOptions(
            object: teamOnlyFile,
            hasCredential: credentials(["bigmodel"])
        )
        XCTAssertTrue(teamOnly.startPlan)
        XCTAssertFalse(teamOnly.personal)
        XCTAssertTrue(teamOnly.team)

        // legacy 文件(无连接选择,默认指向个人 coding-plan):个人槽位经回退存在。
        let legacy = ZAISettings.planMenuOptions(
            object: [
                "providerFamilyDomain": "zai",
                "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-coding-plan"],
            ],
            hasCredential: credentials(["zai"])
        )
        XCTAssertTrue(legacy.startPlan)
        XCTAssertTrue(legacy.personal)
        XCTAssertFalse(legacy.team)

        // 文件缺失:全部不可选。
        let missing = ZAISettings.planMenuOptions(object: nil)
        XCTAssertFalse(missing.startPlan)
        XCTAssertFalse(missing.personal)
        XCTAssertFalse(missing.team)
    }

    func testPlanMenuOptionsTeamIgnoresStaleProviderDisabledFlag() {
        // config.json 的 provider 镜像可能滞后（本机 host 已校验团队项目成功，
        // builtin:bigmodel-coding-plan 却仍是 oauth_provider_inactive）；
        // 团队入口只以 setting.json 的完整团队连接为准。
        let options = ZAISettings.planMenuOptions(
            object: bigmodelTeamFile,
            hasCredential: credentials(["bigmodel"])
        )
        XCTAssertTrue(options.team)
    }

    func testPlanMenuOptionsHidesPlansWithoutCredentials() {
        // 当前账号只有 bigmodel 凭证：zai 个人槽位虽残留，也不能显示个人套餐。
        let options = ZAISettings.planMenuOptions(
            object: bigmodelTeamFile,
            hasCredential: credentials(["bigmodel"])
        )
        XCTAssertTrue(options.startPlan)
        XCTAssertFalse(options.personal)
        XCTAssertTrue(options.team)
    }

    func testPlanMenuOptionsHidesTeamWhenOnlyZaiCredentialExists() {
        // 切到 zai 个人后只剩 oauth:zai：bigmodel 团队槽位仍在 setting.json，
        // 但不能借 zai 凭证显示团队套餐。
        let options = ZAISettings.planMenuOptions(
            object: bigmodelTeamFile,
            hasCredential: credentials(["zai"])
        )
        XCTAssertTrue(options.startPlan)
        XCTAssertTrue(options.personal)
        XCTAssertFalse(options.team)
    }

    func testOAuthCredentialRequiresExactDomain() {
        let onlyZai = ["oauth:zai:access_token": "token"]
        XCTAssertTrue(ZAISettings.hasOAuthCredential(object: onlyZai, domain: "zai"))
        XCTAssertFalse(ZAISettings.hasOAuthCredential(object: onlyZai, domain: "bigmodel"))
    }

    func testEffectiveSelectionPrefersCurrentDomainAfterChannelSwitch() throws {
        // zai 与 bigmodel 同时存在个人连接时，切换到 bigmodel 后必须优先使用
        // bigmodel 的 individual 连接，不能被固定的 zai 优先顺序带回旧渠道。
        let bothIndividual: [String: Any] = [
            "providerFamilyDomain": "bigmodel",
            "modelProviderFamilySelectedKeys": [
                "zai": "coding-plan:builtin:zai-coding-plan",
                "bigmodel": "coding-plan:builtin:bigmodel-coding-plan",
            ],
            "providerFamilyConnectionSelections": [
                "zai": ["kind": "individual-coding-plan"],
                "bigmodel": ["kind": "individual-coding-plan"],
            ],
        ]
        let personal = try XCTUnwrap(effective(bothIndividual, override: .codingPlan))
        XCTAssertEqual(personal.domain, "bigmodel")
        XCTAssertEqual(personal.connectionKind, "individual-coding-plan")
        XCTAssertNil(personal.teamContext)

        // 团队连接同样以当前渠道优先。
        let bothTeam: [String: Any] = [
            "providerFamilyDomain": "bigmodel",
            "providerFamilyConnectionSelections": [
                "zai": [
                    "kind": "team-coding-plan",
                    "organizationId": "org-zai",
                    "projectId": "proj-zai",
                ],
                "bigmodel": [
                    "kind": "team-coding-plan",
                    "organizationId": "org-bigmodel",
                    "projectId": "proj-bigmodel",
                ],
            ],
        ]
        let team = try XCTUnwrap(effective(bothTeam, override: .teamCodingPlan))
        XCTAssertEqual(team.domain, "bigmodel")
        XCTAssertEqual(team.teamContext?.organizationId, "org-bigmodel")
        XCTAssertEqual(team.teamContext?.projectId, "proj-bigmodel")
    }
}
