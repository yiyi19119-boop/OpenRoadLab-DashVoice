import AppKit
import Carbon.HIToolbox
import Foundation

/// 日志（DV-056）：只记 session、状态、匿名长度、耗时与错误类别；
/// 不记录转写原文、音频、Authorization、完整请求体。
enum AppLog {
    static let maxLogBytes = 1_000_000   // DV-057: 超过 1MB 轮转为 .1.log
    static func write(_ message: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(message)\n"
        let path = NSHomeDirectory() + "/Library/Logs/dashvoice.log"
        rotateIfNeeded(path: path)
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func rotateIfNeeded(path: String) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > maxLogBytes else { return }
        let old = (path as NSString).deletingPathExtension + ".1.log"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
    }
}

/// Carbon 全局热键（无需额外系统权限；事件级探针区分"未达"与"主队列堵"）
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onToggle: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let cb: EventHandlerUPP = { _, _, userData in
            guard let userData = userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            AppLog.write("hotkey event received")
            DispatchQueue.main.async { mgr.onToggle?() }
            return noErr
        }
        let install = InstallEventHandler(GetApplicationEventTarget(), cb, 1, &spec,
                                          Unmanaged.passUnretained(self).toOpaque(),
                                          &handlerRef)
        guard install == noErr else { return install }
        let id = EventHotKeyID(signature: OSType(0x5A564F49), id: 1)
        return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

/// 配置目录（DV-053/055）：唯一落点，文档化于 PRIVACY.md
enum ConfigLocation {
    static var dirURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DashVoice", isDirectory: true)
    }
    static var fileURL: URL { dirURL.appendingPathComponent("config.json") }
}
