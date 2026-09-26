import Foundation

// MARK: - ChatGPT.app 内置 codex 可执行文件定位

/// ChatGPT.app 内置 codex 的历史位置：
/// - 旧版：`Contents/Resources/codex`
/// - 2026-09 起新版：`Contents/Resources/codex-cli/bin/codex`（shell 包装脚本，转发到 CodexCLI.app）
/// 按新路径优先、旧路径回退的顺序探测，兼容新旧版本。
enum CodexAppServerLocator {
    static let candidatePaths: [String] = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
    ]

    /// 返回默认路径：第一个可执行的候选路径；都不存在时返回首个候选，
    /// 让调用方的启动检查以当前期望位置报错。
    static func defaultExecutablePath(fileManager: FileManager = .default) -> String {
        firstExecutablePath(in: candidatePaths, fileManager: fileManager) ?? candidatePaths[0]
    }

    static func firstExecutablePath(
        in candidates: [String],
        fileManager: FileManager = .default
    ) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
