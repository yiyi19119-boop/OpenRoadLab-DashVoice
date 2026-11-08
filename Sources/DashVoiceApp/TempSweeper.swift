import Foundation

/// 临时音频清扫（DV-027）：启动时清理本 App 命名空间内超过 24h 的残留 wav。
/// 只删自己前缀的文件，绝不触碰其他文件。
enum TempSweeper {
    static let prefix = "dashvoice-"
    static let maxAge: TimeInterval = 24 * 3600

    static func sweep(now: Date = Date()) {
        let dir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files where f.lastPathComponent.hasPrefix(prefix) && f.pathExtension == "wav" {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(mtime) > maxAge {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// 会话终态清理：成功/失败/取消统一调用；文件不存在视为已清理
    static func removeSessionFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
