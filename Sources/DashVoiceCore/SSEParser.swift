import Foundation

/// 增量 SSE 解析器（服务器→客户端单向流）。
/// 覆盖：多行 data: 拼接、注释行(:)跳过、event: 字段记录、CRLF/LF、
/// UTF-8 多字节跨 Data 包边界缓冲、[DONE] 终止标记。
/// 只做协议解析，不做业务判断（业务在 ASRProvider）。
public final class SSEParser {
    public struct Event: Equatable {
        public var event: String?      // event: 字段（可空）
        public var data: String        // 多行 data 以 \n 拼接
        public var isDone: Bool        // data == "[DONE]"
    }

    public enum ParseError: Error, Equatable {
        case invalidUTF8
    }

    private var buffer = Data()          // 原始字节缓冲（处理 UTF-8 跨包）
    private var lineBuffer = ""          // 已解码的当前行（\r\n 已剥离）
    private var dataLines: [String] = []
    private var eventName: String?

    public init() {}

    /// 喂入一段字节；返回本次解析出的完整事件（可能 0..n 个）。
    /// - Throws: ParseError.invalidUTF8 当缓冲区出现无法成为合法 UTF-8 前缀的字节
    public func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []

        // 逐行提取：以 \n 或 \r\n 分隔
        while let idx = buffer.firstIndex(where: { $0 == 0x0A }) {   // \n
            var lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if lineData.last == 0x0D { lineData = lineData.dropLast() } // \r
            if let line = try decodeLine(lineData) {
                if let ev = consume(line: line) { events.append(ev) }
            }
        }
        return events
    }

    /// 流结束（EOF）时调用：冲刷残留缓冲。无换行结尾的最后一行也会被处理。
    public func finish() throws -> [Event] {
        var events: [Event] = []
        if !buffer.isEmpty {
            if let line = try decodeLine(buffer) {
                if let ev = consume(line: line) { events.append(ev) }
            }
            buffer.removeAll()
        }
        if !lineBuffer.isEmpty || !dataLines.isEmpty {
            if let ev = flushEvent() { events.append(ev) }
        }
        return events
    }

    // MARK: - 内部

    /// UTF-8 安全解码：校验缓冲是否为合法 UTF-8（含前缀判断）。
    private func decodeLine(_ data: Data) throws -> String? {
        guard !data.isEmpty else { return "" }
        // 完整合法性校验（macOS 13 的 String(decoding:) 不校验，需手动）
        var scanner = data[...]
        while let b = scanner.popFirst() {
            let extra: Int
            switch b {
            case 0x00...0x7F: continue
            case 0xC2...0xDF: extra = 1
            case 0xE0...0xEF: extra = 2
            case 0xF0...0xF4: extra = 3
            default: throw ParseError.invalidUTF8   // 0x80-0xBF 裸续字节 / 0xC0,0xC1,0xF5+
            }
            guard scanner.count >= extra else {
                throw ParseError.invalidUTF8        // 调用方应保证按行喂入，行内不应有截断
            }
            var ok = true
            let cont = scanner.prefix(extra)
            if extra == 2, !(0x80...0xBF).contains(cont.first!) { ok = false }
            if extra == 3, !(0x80...0xBF).contains(cont.first!) { ok = false }
            if extra == 4, !(0x80...0xBF).contains(cont.first!) { ok = false }
            guard ok else { throw ParseError.invalidUTF8 }
            scanner = scanner.dropFirst(extra)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func consume(line: String) -> Event? {
        if line.isEmpty {
            return flushEvent()      // 空行 = 事件分隔
        }
        if line.hasPrefix(":") { return nil }   // 注释
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            dataLines.append(payload)
            return nil
        }
        return nil   // 未知字段忽略（field: value）
    }

    private func flushEvent() -> Event? {
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        let name = eventName
        eventName = nil
        guard !data.isEmpty || name != nil else { return nil }
        return Event(event: name, data: data, isDone: data == "[DONE]")
    }
}
