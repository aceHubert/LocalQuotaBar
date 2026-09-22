// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalQuotaBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LocalQuotaBar", targets: ["LocalQuotaBar"])
    ],
    dependencies: [
        // 真正的灵动岛 API：DynamicNotchKit（MIT 协议，作者 MrKai77）。
        // .floating 风格自动处理非刘海屏，.notch 风格贴合刘海。
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0"),
        // 浏览器凭证读取：Chromium Cookie 解密（Chrome Safe Storage）与 localStorage LevelDB 解析。
        // DeepSeek userToken 与 CodeBuddy 会话 Cookie 均来自本机已登录 Chrome。
        .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.5.3")
    ],
    targets: [
        .executableTarget(
            name: "LocalQuotaBar",
            dependencies: ["DynamicNotchKit", "SweetCookieKit"],
            path: "Sources/LocalQuotaBar",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "LocalQuotaBarTests",
            dependencies: ["LocalQuotaBar"],
            path: "Tests/LocalQuotaBarTests"
        )
    ]
)
