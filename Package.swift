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
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalQuotaBar",
            dependencies: ["DynamicNotchKit"],
            path: "Sources/LocalQuotaBar",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
