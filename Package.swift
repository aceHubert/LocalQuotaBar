// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexTouchBarQuota",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "CodexTouchBarQuota", targets: ["CodexTouchBarQuota"])
    ],
    targets: [
        .executableTarget(
            name: "CodexTouchBarQuota",
            path: "Sources/CodexTouchBarQuota",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
