import AppKit
@testable import LocalQuotaBar

extension QuotaViewController {
    /// 测试专用 UserDefaults suite：tab 选择持久化不再写 `UserDefaults.standard`，
    /// 避免用例之间（以及本机残留值）互相污染 active tab。
    static let testTabStorageSuiteName = "LocalQuotaBarTests.panelTab"

    /// 测试专用构造入口。
    /// - Parameter clearStoredTab: 是否清空已持久化的 tab 选择；恢复场景传 false。
    @MainActor
    static func makeForTesting(clearStoredTab: Bool = true) -> QuotaViewController {
        let defaults = UserDefaults(suiteName: testTabStorageSuiteName) ?? .standard
        if clearStoredTab {
            defaults.removeObject(forKey: activeTabStorageKey)
        }
        let controller = QuotaViewController()
        controller.tabStorage = defaults
        return controller
    }
}
