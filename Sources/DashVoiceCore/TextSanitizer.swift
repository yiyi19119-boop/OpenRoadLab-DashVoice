import Foundation

/// 转写文本净化（DV-035）：杜绝回车/控制字符/快捷键触发。
/// 原则：只删不加；换行按策略替换；不影响中文/emoji/合法空格。
public enum TextSanitizer {
    /// keepNewlines=false 时 \r\n/\r/\n 全部替换为单个空格（默认，防误触发送）；
    /// keepNewlines=true 保留 \n（仍剥其余控制字符）。
    public static func sanitize(_ text: String, keepNewlines: Bool) -> String {
        // 先归一化换行：\r\n 与孤 \r 统一为 \n
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var out = String()
        out.reserveCapacity(normalized.count)
        var lastWasSpace = true
        for scalar in normalized.unicodeScalars {
            switch scalar.value {
            case 0x0A:                              // \n
                if keepNewlines {
                    out.unicodeScalars.append("\n")
                    lastWasSpace = true
                } else if !lastWasSpace {
                    out.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F:   // C0（除\n\t）+ DEL
                continue                            // 丢弃：ESC/退格等可触发快捷操作
            case 0x80...0x9F:                       // C1 控制符
                continue
            case 0x09:                              // Tab → 空格
                if !lastWasSpace { out.unicodeScalars.append(" "); lastWasSpace = true }
            default:
                out.unicodeScalars.append(scalar)
                lastWasSpace = (scalar == " ")
            }
        }
        var result = String(out)
        if !keepNewlines { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把全文中"尚未交付"的区间切成键入批次。
    /// 单位约定（F06）：range 与返回批次一律按 **Character（grapheme cluster）** 计数，
    /// 与 RecordingSession.deliveredCharacters、Injector 批次计数同一单位；
    /// 组合 emoji / 肤色修饰 / 重音字符作为整体切片，不再按 scalar 截断。
    public static func batches(forRange range: Range<Int>, in text: String, batchSize: Int = 24) -> [String] {
        guard range.lowerBound < range.upperBound else { return [] }
        let chars = Array(text)
        guard range.upperBound <= chars.count else { return [] }
        let slice = chars[range.lowerBound..<range.upperBound]
        var out: [String] = []
        var current = ""
        var count = 0
        for ch in slice {
            current.append(ch)
            count += 1
            if count >= batchSize { out.append(current); current = ""; count = 0 }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 剩余未交付部分（Character 语义），用于"中途停止→剩余转剪贴板"
    public static func remaining(from delivered: Int, in text: String) -> String {
        let chars = Array(text)
        guard delivered < chars.count else { return "" }
        return String(chars[delivered...])
    }
}
