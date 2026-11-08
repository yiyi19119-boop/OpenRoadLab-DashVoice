import AppKit
import ApplicationServices
import CoreGraphics

/// 逐批键入器：每批键入前经 TargetPolicy 校验；任何"停止"都把剩余文字交给回调方转预览。
/// 全程在 typeQueue 串行执行（DV-021：不占主线程）。
final class Injector {
    static let shared = Injector()
    private let queue = DispatchQueue(label: "com.dashvoice.type", qos: .userInitiated)
    private init() {}

    enum InjectionResult {
        case submitted(characters: Int)     // 已提交输入事件（CGEvent 无接收回执，不称"已写入"）
        case stopped(characters: Int, reason: String)  // 中途停止：已提交 n 字，剩余转预览
    }

    /// 逐批键入。verifier 每批调用一次，返回 .allowed 才继续。
    /// onBatchSubmitted 在每批提交后回调（主线程安全由调用方保证）。
    func injectBatches(_ batches: [String],
                       verifier: @escaping () -> TargetPolicy.Verdict,
                       onBatchSubmitted: @escaping (Int) -> Void,
                       completion: @escaping (InjectionResult) -> Void) {
        queue.async {
            var submitted = 0
            var stopped = false
            for batch in batches {
                // 每批键入前重新校验目标（DV-030/031：覆盖等待期与输入期间的焦点变化）
                switch verifier() {
                case .allowed:
                    self.type(batch)
                    // F06：批次按 Character 计数（与游标/剩余切片同一单位）
                    submitted += batch.count
                    DispatchQueue.main.async { onBatchSubmitted(submitted) }
                case .stopToPreview(let reason):
                    stopped = true
                    DispatchQueue.main.async {
                        completion(.stopped(characters: submitted, reason: reason))
                    }
                    break
                }
                if stopped { return }
            }
            DispatchQueue.main.async {
                completion(.submitted(characters: submitted))
            }
        }
    }

    private func type(_ text: String) {
        for ch in text.unicodeScalars {
            var units = Array(String(ch).utf16)
            guard !units.isEmpty else { continue }
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.post(tap: .cghidEventTap)
            }
            usleep(2500)
        }
    }
}
