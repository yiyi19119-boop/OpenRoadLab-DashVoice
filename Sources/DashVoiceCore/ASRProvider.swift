import Foundation

// MARK: - 错误分类（DV-043）

public enum ASRError: Error, Equatable {
    case auth                   // 401/403：不可重试
    case badRequest(String)     // 400：参数错误，不可重试（脱敏后携带摘要）
    case tooLarge               // 413 / 本地超限
    case rateLimited(retryAfter: TimeInterval?)  // 429：可等待重试
    case server                 // 5xx：可重试
    case network(String)        // DNS/TLS/离线/断连：可重试
    case protocolBad(String)    // SSE/JSON 协议错误（本地解析描述，不含服务端正文）
    case serverRefused(code: String, messageLength: Int)  // F07: 服务端拒绝（脱敏：仅类别+正文长度）
    case cancelled
    case invalidConfiguration(String)

    /// Stable diagnostic labels only; associated messages and response bodies stay private.
    public var diagnosticCategory: String {
        switch self {
        case .auth: return "auth"
        case .badRequest: return "bad_request"
        case .tooLarge: return "audio_too_large"
        case .rateLimited: return "rate_limited"
        case .server: return "server"
        case .network: return "network"
        case .protocolBad: return "protocol"
        case .serverRefused: return "server_refused"
        case .cancelled: return "cancelled"
        case .invalidConfiguration: return "invalid_configuration"
        }
    }

    public var retryAfter: TimeInterval? {
        if case .rateLimited(let ra) = self { return ra }
        return nil
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network: return true
        default: return false
        }
    }

    /// 用户可读、不含凭证/音频/原始错误体的行动提示
    public var userHint: String {
        switch self {
        case .auth: return "API Key 无效或无权限，请检查钥匙串中的 DashScope Key"
        case .badRequest(let s): return "请求参数被拒绝：\(s)"
        case .tooLarge: return "音频超过大小限制"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .server: return "识别服务暂时不可用，请稍后再试"
        case .network(let s): return "网络错误：\(s)"
        case .protocolBad(let s): return "服务响应异常：\(s)"
        case .serverRefused(let code, _): return "服务拒绝（\(code)），请检查请求或稍后再试"
        case .cancelled: return "已取消"
        case .invalidConfiguration(let s): return "配置无效：\(s)"
        }
    }
}

// MARK: - 结果与协议（DV-039 / DV-042）

public struct ASRResult {
    public var text: String
    /// false = EOF/中断时已有部分文本但未见 provider 完成标记，结果必须按“部分”呈现
    public var isComplete: Bool
    public var finishReason: String?

    public init(text: String, isComplete: Bool, finishReason: String? = nil) {
        self.text = text
        self.isComplete = isComplete
        self.finishReason = finishReason
    }
}

public protocol ASRProvider {
    /// 流式转写一段 WAV。onDelta 只会收到按序增量；实现内部不得缓存跨 session 状态。
    func transcribeStream(wavURL: URL,
                          request: ASRRequest,
                          onDelta: @escaping (String) -> Void) async throws -> ASRResult
}

public struct ASRRequest {
    public var endpoint: URL
    public var model: String
    public var language: String
    public var enableITN: Bool
    public var apiKey: String
    public var maxSeconds: Double
    /// F07/DV-051: Key 绑定主机（nil=旧配置未登记，跳过校验）
    public var keyHost: String?

    public init(endpoint: URL, model: String, language: String,
                enableITN: Bool, apiKey: String, maxSeconds: Double, keyHost: String? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.enableITN = enableITN
        self.apiKey = apiKey
        self.maxSeconds = maxSeconds
        self.keyHost = keyHost
    }
}

// MARK: - DashScope compatible-mode 实现（DV-040/041/042/043/045/046）

public final class DashScopeProvider: ASRProvider {
    /// C03-04 配套：允许测试注入受控 URLSession（URLProtocol stub 验证完整协议链）
    private let session: URLSession
    private let diagnostics: ((String) -> Void)?
    public init(session: URLSession? = nil, diagnostics: ((String) -> Void)? = nil) {
        if let session {
            self.session = session
        } else {
            // CHAT-06 根因修复：系统 PAC 代理（p.hinpac.com）会把 dashscope 请求
            // 路由到代理进程，代理间歇故障 → 成串 network 错误（10:35-10:53 连败）。
            // DashScope 是国内服务，直连最快且稳定 → 专属 session 显式绕过一切代理。
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [:]
            cfg.waitsForConnectivity = false
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: cfg)
        }
        self.diagnostics = diagnostics
    }

    /// 协议核对记录：2026-11-06 对照
    /// https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference
    /// compatible-mode /v1/chat/completions；input_audio data=data:audio/wav;base64,…
    /// 仅接受纯音频输入（任何文本输入 400）；asr_options{language,enable_itn}；
    /// SSE: choices[].delta.content / finish_reason；终止 data:[DONE]。
    /// 端点地域由 endpoint URL 决定（cn-beijing / intl），Key 与 endpoint 绑定由上层配置校验。

    public func transcribeStream(wavURL: URL, request: ASRRequest,
                                 onDelta: @escaping (String) -> Void) async throws -> ASRResult {
        try Self.preflight(wavURL: wavURL, request: request)

        var req = URLRequest(url: request.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15           // DV-044 首响应档；总墙钟由调用方 90s watchman 兜底
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")

        let audio = try Data(contentsOf: wavURL)   // ≤10MB 已在 preflight 校验
        let body: [String: Any] = [
            "model": request.model,
            "messages": [[
                "role": "user",
                "content": [["type": "input_audio",
                             "input_audio": ["data": "data:audio/wav;base64," + audio.base64EncodedString(),
                                             "format": "wav"] as [String: Any]]]
            ]],
            "stream": true,
            "asr_options": ["language": request.language, "enable_itn": request.enableITN]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let t0 = Date()
        let (bytes, resp) = try await Self.execute(req, session: session)
        let http = resp as? HTTPURLResponse
        guard let http else { throw ASRError.protocolBad("非 HTTP 响应") }
        diagnostics?("ASR HTTP status=\(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            throw Self.classify(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }

        let parser = SSEParser()
        var full = ""
        var finishReason: String?
        var sawDone = false

        func handle(_ payload: String) throws {
            if payload == "[DONE]" { sawDone = true; return }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw ASRError.protocolBad("SSE data 非合法 JSON")
            }
            if let err = obj["error"] as? [String: Any] {
                // F07：服务端错误正文可能含回显内容，不进错误对象/日志——只记类别与代码
                let code = (err["code"] as? String) ?? "unknown"
                let msgLen = ((err["message"] as? String) ?? "").count
                throw ASRError.serverRefused(code: String(code.prefix(60)), messageLength: msgLen)
            }
            guard let choices = obj["choices"] as? [[String: Any]] else { return }
            if let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                full += content
                onDelta(content)
            }
            if let fr = choices.first?["finish_reason"] as? String, !fr.isEmpty {
                finishReason = fr
            }
        }

        func consume(_ events: [SSEParser.Event]) throws {
            for event in events {
                if event.isDone { sawDone = true; break }
                try handle(event.data)
            }
        }

        do {
            // Preserve raw SSE delimiters. Foundation .lines can omit empty lines,
            // while SSEParser needs the blank line to finish each event.
            var packet = Data()
            for try await byte in bytes {
                packet.append(byte)
                if byte == 0x0A || packet.count >= 4096 {
                    try Task.checkCancellation()
                    try consume(parser.feed(packet))
                    packet.removeAll(keepingCapacity: true)
                    if sawDone { break }
                }
            }
            if !sawDone {
                if !packet.isEmpty { try consume(parser.feed(packet)) }
                if !sawDone { try consume(parser.finish()) }
            }
        } catch let e as ASRError { throw e }
        catch is URLError { throw ASRError.network("连接中断") }
        catch { throw ASRError.network("\(error.localizedDescription)") }

        guard full.isEmpty == false else {
            throw ASRError.protocolBad("服务未返回任何文本（HTTP \(http.statusCode)）")
        }
        // C03-04: 传输结束与业务终止分层——length（截断）即使收到 [DONE] 也是部分；
        // stop=完整；仅 [DONE] 无 finish_reason=传输完整收尾（协议上内容已收全）=完整；
        // 无 [DONE] 且无/未知 reason（EOF 断流）=部分。
        let complete = Self.evaluateCompletion(sawDone: sawDone, finishReason: finishReason)
        return ASRResult(text: full, isComplete: complete, finishReason: finishReason)
    }

    /// C03-04: 完成判定纯函数（协议分层，可测）
    /// - finish_reason=="stop" → 完整
    /// - finish_reason=="length" → 部分（语义截断，即便 [DONE]）
    /// - 无 finish_reason 且 sawDone → 完整（流正常收尾）
    /// - 其余（无标记 EOF/未知）→ 部分
    static func evaluateCompletion(sawDone: Bool, finishReason: String?) -> Bool {
        if finishReason == "stop" { return true }
        if finishReason == "length" { return false }
        if sawDone { return true }
        return false
    }

    // MARK: 工具

    static func preflight(wavURL: URL, request: ASRRequest) throws {
        guard request.endpoint.scheme?.lowercased() == "https" else {
            throw ASRError.invalidConfiguration("endpoint 必须为 HTTPS")
        }
        // F07/C03-03: 凭证-主机绑定。**缺省不绕过**：keyHost 未登记（nil/空）时拒绝发送
        // 生产凭证到任意主机；需先完成绑定登记（load 迁移或 setup-key.sh）。
        let host = request.endpoint.host ?? ""
        guard let bound = request.keyHost, !bound.isEmpty else {
            throw ASRError.invalidConfiguration("Key 尚未绑定主机（key_host 未登记）；请重跑 scripts/setup-key.sh 完成绑定后再使用云端识别")
        }
        guard host == bound else {
            throw ASRError.invalidConfiguration("endpoint 主机(\(host))与 Key 绑定主机(\(bound))不一致；请先更新 Key 绑定或换回原端点")
        }
        guard !request.apiKey.isEmpty else {
            throw ASRError.invalidConfiguration("缺少 API Key")
        }
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw ASRError.invalidConfiguration("音频文件不存在")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0
        guard size > 0, size <= 10_000_000 else { throw ASRError.tooLarge }
        // 16k/mono/16bit → 每秒 32KB；给配置上限留 1.15 倍头空间
        let approxSeconds = Double(size) / 32_000.0
        if approxSeconds > request.maxSeconds * 1.15 { throw ASRError.tooLarge }
    }

    static func execute(_ req: URLRequest, session: URLSession = .shared) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do { return try await session.bytes(for: req) }
        catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted:
                throw ASRError.network("无法连接（\(e.code.rawValue)）")
            case .timedOut: throw ASRError.network("连接超时")
            case .cancelled: throw ASRError.cancelled
            default: throw ASRError.network(e.localizedDescription)
            }
        }
    }

    static func classify(status: Int, retryAfter: String?) -> ASRError {
        switch status {
        case 400: return .badRequest("HTTP 400")
        case 401, 403: return .auth
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap(Double.init))
        case 500...599: return .server
        default: return .server
        }
    }
}

private extension Data {
    func appending(_ byte: UInt8) -> Data { var d = self; d.append(byte); return d }
}

// MARK: - DV-044 总墙钟

/// 总墙钟超时：body 超过 seconds 即抛 network 错误（并取消 body 任务）
public func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ASRError.network("总耗时超过 \(Int(seconds))s")
        }
        let r = try await group.next()!
        group.cancelAll()
        return r
    }
}

extension ASRError {
    /// C03-03: 凭证绑定类错误判定（供测试与 UI 区分）
    public var isBindingError: Bool {
        if case .invalidConfiguration(let m) = self { return m.contains("绑定") }
        return false
    }
}
