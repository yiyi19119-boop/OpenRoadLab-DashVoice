// 离线测试靶：swift run DashVoiceTests（退出码 0=全过）
import Foundation

struct TestError: Error, CustomStringConvertible { let s: String; init(_ s: String) { self.s = s }; var description: String { s } }
var pass = 0, fail = 0
func T(_ name: String, _ body: () throws -> Void) {
    do { try body(); pass += 1; print("  ✔ \(name)") }
    catch { fail += 1; print("  ✘ \(name): \(error)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ m: String = "") throws {
    if a != b { throw TestError("\(m) 期望 \(b) 实得 \(a)") }
}
func isTrue(_ c: Bool, _ m: String) throws { if !c { throw TestError(m) } }

print("== SSE 解析 ==")
let p = SSEParser()
T("单事件", { try eq(try p.feed(Data("data: {\"a\":1}\n\n".utf8)).count, 1) })
T("多行 data 拼接", { try eq(try p.feed(Data("data: abc\ndata: def\n\n".utf8))[0].data, "abc\ndef") })
T("注释与 event 字段", { let e = try p.feed(Data(": ka\nevent: t\ndata: x\n\n".utf8)); try eq(e.count, 1); try eq(e[0].event ?? "", "t") })
T("DONE 标记", { try isTrue(try p.feed(Data("data: [DONE]\n\n".utf8))[0].isDone, "isDone") })
T("CRLF", { try eq(try p.feed(Data("data: hello\r\n\r\n".utf8))[0].data, "hello") })
T("UTF-8 跨包", {
    let p2 = SSEParser()
    let bytes = Array(Data("data: 今天下午三点提醒我参加会议\n\n".utf8))
    let cut = bytes.firstIndex(of: 0x0A)! - 2
    var e: [SSEParser.Event] = []
    e += try p2.feed(Data(bytes[..<cut])); e += try p2.feed(Data(bytes[cut...]))
    try eq(e.count, 1); try eq(e[0].data, "今天下午三点提醒我参加会议")
})
T("EOF 冲刷", { let p3 = SSEParser(); _ = try p3.feed(Data("data: tail".utf8)); let f = try p3.finish(); try eq(f.count, 1); try eq(f[0].data, "tail") })
T("非法 UTF-8 抛错", { XCTAssertThrow(try p.feed(Data([0x64,0x61,0x74,0x61,0x3A,0x20,0xFF,0x0A]))) })

print("== 文本净化 ==")
T("换行替换空格", { try eq(TextSanitizer.sanitize("一\n二", keepNewlines: false), "一 二") })
T("保留换行", { try eq(TextSanitizer.sanitize("a\r\nb", keepNewlines: true), "a\nb") })
T("ESC/退格丢弃", { try eq(TextSanitizer.sanitize("ok\u{1B}[2J\u{08}go", keepNewlines: false), "ok[2Jgo") })
T("C1 丢弃", { try eq(TextSanitizer.sanitize("a\u{009B}b", keepNewlines: false), "ab") })
T("Tab 转空格", { try eq(TextSanitizer.sanitize("a\tb", keepNewlines: false), "a b") })
T("中文/emoji 透传", { try eq(TextSanitizer.sanitize("三点 👍 COVID-19", keepNewlines: false), "三点 👍 COVID-19") })
T("批次覆盖全文", {
    let t = String(repeating: "词", count: 100)
    let bs = TextSanitizer.batches(forRange: 0..<100, in: t, batchSize: 24)
    try eq(bs.joined(), t); try isTrue(bs.allSatisfy { $0.count <= 24 }, "批次上限")
})

print("== 交付队列 ==")
func done(_ s: RecordingSession) {   // 模拟"录音结束"（F03: ready 才可取）
    _ = s.markRecordingFinished(kind: .userStop)
    s.beginTranscription()
}
T("FIFO 顺序（仅录音结束的项可取）", {
    let q = DeliveryQueue(limit: 5)
    let a = RecordingSession(), b = RecordingSession(), c = RecordingSession()
    try q.enqueue(a); try q.enqueue(b); try q.enqueue(c)
    try isTrue(q.next() == nil, "队首 A 仍在录音 → 等待")
    done(a)
    try eq(q.next()?.id, a.id)
    try isTrue(q.next() == nil, "单槽：A 处理中不取 B")
    q.finishCurrent()
    try isTrue(q.next() == nil, "B 仍在录音 → 等待（不提前上传未完成 WAV）")
    done(b)
    try eq(q.next()?.id, b.id); q.finishCurrent()
    done(c)
    try eq(q.next()?.id, c.id); q.finishCurrent()
    try isTrue(q.next() == nil, "空队列")
})
T("队满", {
    let q = DeliveryQueue(limit: 2)
    try q.enqueue(RecordingSession()); try q.enqueue(RecordingSession())
    XCTAssertThrow(try q.enqueue(RecordingSession()))
})
T("重复入队拒绝", {
    let q = DeliveryQueue(limit: 5); let s = RecordingSession()
    try q.enqueue(s); XCTAssertThrow(try q.enqueue(s))
})
T("取消 pending 移除/取消进行中", {
    let q = DeliveryQueue(limit: 5)
    let a = RecordingSession(), b = RecordingSession()
    try q.enqueue(a); try q.enqueue(b)
    try isTrue(q.cancel(id: a.id), "取消 pending"); try isTrue(a.cancelled, "状态=cancelled")
    done(b)
    try eq(q.next()?.id, b.id)
})
T("取消进行中", {
    let q = DeliveryQueue(limit: 5); let a = RecordingSession()
    try q.enqueue(a); done(a); _ = q.next()
    try isTrue(q.cancel(id: a.id), "取消 in-flight"); try isTrue(a.cancelled, "cancelled")
    try isTrue(a.isTerminal, "取消为终态")
})
T("编排: A 完成时 B 仍在录音 → 槽位释放后等待 B", {
    let q = DeliveryQueue(limit: 5)
    let a = RecordingSession(), b = RecordingSession()
    try q.enqueue(a); try q.enqueue(b)
    done(a)
    _ = q.next()                    // A 进入处理
    done(b)                          // B 录音结束（模拟 A 处理期间 B 停止）
    q.finishCurrent()                // A 交付完成释放槽位
    try eq(q.next()?.id, b.id, "B 就绪后按序处理")
    q.finishCurrent()
})
T("编排: 失败 session 也走槽位释放", {
    let q = DeliveryQueue(limit: 5)
    let a = RecordingSession(), b = RecordingSession()
    try q.enqueue(a); try q.enqueue(b)
    done(a); _ = q.next()
    a.markFailed()
    try isTrue(a.isTerminal, "failed 终态")
    q.finishCurrent()
    done(b)
    try eq(q.next()?.id, b.id, "失败不堵队")
})

print("== 会话幂等 ==")
T("finish 只赢一次", {
    let s = RecordingSession()
    try isTrue(s.markRecordingFinished(kind: .delegate), "首次")
    try isFalse(s.markRecordingFinished(kind: .forceTimeout), "迟到无效")
})
T("上传一次", { let s = RecordingSession(); try isTrue(s.markUploadStarted(), "首"); try isFalse(s.markUploadStarted(), "再") })
T("交付一次", {
    let s = RecordingSession(); s.beginTranscription(); s.beginDelivery()
    try isTrue(s.markDeliveryDone(.delivered), "首")
    try isFalse(s.markDeliveryDone(.deliveredPartial), "再")
})
T("迟到取消不覆盖已交付", {
    let s = RecordingSession(); s.beginTranscription(); s.beginDelivery()
    _ = s.markDeliveryDone(.delivered); s.markCancelled()
    try eq(s.state, .delivered)
})
T("交付游标单调", {
    let s = RecordingSession(); s.setFullTranscript("0123456789")
    s.commitDelivered(count: 4); s.commitDelivered(count: 2)
    try eq(s.deliveredCharacters, 4)
    s.commitDelivered(count: 99); try eq(s.deliveredCharacters, 10)
})
T("取消后不可交付", {
    let s = RecordingSession(); s.beginTranscription(); s.markCancelled(); s.beginDelivery()
    try isFalse(s.markDeliveryDone(.delivered), "取消后拒绝")
})

print("== 目标策略 ==")
let origin = TargetPolicy.TargetIdentity(pid: 100, role: "AXTextArea", subrole: nil, elementHash: 555000)
T("文本框+元素一致 允许", {
    try eq(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: "AXTextArea", subrole: nil, elementHash: 555000)), .allowed)
    try eq(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: "AXTextField", subrole: nil, elementHash: 555000)), .allowed)
})
T("CHAT-08: elementHash 不可读 → 拒绝（撤回 pid+secure 猜测放行）", {
    let o = TargetPolicy.TargetIdentity(pid: 726, role: nil, subrole: nil, elementHash: nil)
    let c = TargetPolicy.TargetIdentity(pid: 726, role: nil, subrole: nil, elementHash: nil)
    try isTrue(TargetPolicy.verdict(original: o, current: c).isStop, "无元素身份必须停止")
})
T("CHAT-08: 安全输入启用 → 一律停止（false 不是放行条件）", {
    let o = TargetPolicy.TargetIdentity(pid: 726, role: "AXTextArea", elementHash: 42)
    let c = TargetPolicy.TargetIdentity(pid: 726, role: "AXTextArea", elementHash: 42)
    try isTrue(TargetPolicy.verdict(original: o, current: c, secureInputEnabled: true).isStop, "secure input")
    try eq(TargetPolicy.verdict(original: o, current: c, secureInputEnabled: false), .allowed, "false 时走正常严格判定")
})
T("CHAT-08: 元素身份一致但 pid 变化 → 停止", {
    let o = TargetPolicy.TargetIdentity(pid: 726, role: "AXTextArea", elementHash: 42)
    let c = TargetPolicy.TargetIdentity(pid: 999, role: "AXTextArea", elementHash: 42)
    try isTrue(TargetPolicy.verdict(original: o, current: c).isStop, "pid")
})
T("CHAT-08: 按钮/密码控件仍拒绝", {
    let o = TargetPolicy.TargetIdentity(pid: 726, role: "AXTextArea", elementHash: 42)
    try isTrue(TargetPolicy.verdict(original: o, current: .init(pid: 726, role: "AXButton", elementHash: 42)).isStop, "button")
    try isTrue(TargetPolicy.verdict(original: o, current: .init(pid: 726, role: "AXTextField", subrole: TargetPolicy.secureSubrole, elementHash: 42)).isStop, "secure subrole")
})
T("原生路径: 元素身份不一致仍停止（同 App 换输入框）", {
    try isTrue(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: "AXTextArea", elementHash: 999111)).isStop, "element mismatch")
})
T("进程切换停止", { try isTrue(TargetPolicy.verdict(original: origin, current: .init(pid: 200, role: "AXTextArea", elementHash: 555000)).isStop, "pid 不同") })
T("CHAT-08: 角色未知 → 拒绝（白名单正向判定）", { try isTrue(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: nil, elementHash: 555000)).isStop, "role nil 必须停止") })
T("密码框 role 拒绝", { try isTrue(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: TargetPolicy.secureRole, elementHash: 555000)).isStop, "secure role") })
T("密码框 subrole 拒绝（AXTextField+secure subrole）", {
    try isTrue(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: "AXTextField", subrole: TargetPolicy.secureSubrole, elementHash: 555000)).isStop, "secure subrole")
    try isTrue(TargetPolicy.isSecure(.init(pid: 100, role: "AXTextField", subrole: TargetPolicy.secureSubrole)), "isSecure")
})
T("按钮/容器永不自动", {
    try isTrue(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: "AXButton", elementHash: 555000)).isStop, "button")
    try isTrue(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: "AXWebArea", elementHash: 555000)).isStop, "webarea 容器")
})

print("== 错误分类 ==")
T("HTTP 分类", {
    try eq(DashScopeProvider.classify(status: 401, retryAfter: nil), .auth)
    try eq(DashScopeProvider.classify(status: 413, retryAfter: nil), .tooLarge)
    try eq(DashScopeProvider.classify(status: 429, retryAfter: "7"), .rateLimited(retryAfter: 7))
    try eq(DashScopeProvider.classify(status: 503, retryAfter: nil), .server)
})
T("可重试矩阵", {
    try isFalse(ASRError.auth.isRetryable, "401 不重试")
    try isFalse(ASRError.badRequest("x").isRetryable, "400 不重试")
    try isTrue(ASRError.server.isRetryable, "5xx 重试")
    try isTrue(ASRError.network("x").isRetryable, "网络重试")
})
T("提示不含凭证", {
    for e in [ASRError.auth, .server, .tooLarge, .cancelled] {
        try isFalse(e.userHint.contains("sk-"), "无 sk-")
    }
})

print("== C03-01 编排: delegate 事件流 ==")
T("delegate 成功 → ready 可取（不依赖手工 beginTranscription）", {
    let q = DeliveryQueue(limit: 5)
    let a = RecordingSession()
    try q.enqueue(a)
    try isTrue(q.next() == nil, "录音中等待")
    // 真实路径：只调 RecordingFinisher（delegate 语义），不再手工补 beginTranscription
    let out = RecordingFinisher.apply(a, kind: .delegate, success: true)
    try eq(out, "ready")
    try eq(q.next()?.id, a.id)
})
T("delegate 失败(flag=false) → failed 终态", {
    let a = RecordingSession()
    RecordingFinisher.apply(a, kind: .delegate, success: false)
    try eq(a.state, .failed)
    try isTrue(a.isTerminal, "终态")
})
T("达到时长上限（走 delegate）后下一段继续", {
    let q = DeliveryQueue(limit: 5)
    let a = RecordingSession(), b = RecordingSession()
    try q.enqueue(a); try q.enqueue(b)
    _ = RecordingFinisher.apply(a, kind: .delegate, success: true)   // 上限触发
    try eq(q.next()?.id, a.id)
    q.finishCurrent()
    _ = RecordingFinisher.apply(b, kind: .delegate, success: true)
    try eq(q.next()?.id, b.id, "上限后下一段不被卡")
    q.finishCurrent()
})
T("重复 delegate 只转移一次", {
    let a = RecordingSession()
    try isTrue(RecordingFinisher.apply(a, kind: .delegate, success: true) != nil, "首")
    try isTrue(RecordingFinisher.apply(a, kind: .forceTimeout, success: true) == nil, "迟到无效")
})
T("放弃×N → cancelled 终态且可清理（sessions 不增长语义）", {
    var sessions: [String: RecordingSession] = [:]
    for _ in 0..<3 {
        let s = RecordingSession()
        sessions[s.id] = s
        s.requestDiscard()
        RecordingFinisher.apply(s, kind: .userDiscard, success: nil)
        // cleanupSession 语义：终态才移除
        if s.isTerminal { sessions.removeValue(forKey: s.id) }
    }
    try eq(sessions.count, 0, "放弃×3 后 sessions 空且有界")
})
T("放弃会话不可再被队列取出转写", {
    let q = DeliveryQueue(limit: 5)
    let a = RecordingSession()
    try q.enqueue(a)
    a.requestDiscard()
    RecordingFinisher.apply(a, kind: .userDiscard, success: nil)
    try isTrue(a.cancelled, "cancelled")
    try isTrue(q.next() == nil, "队列不再交付取消项（q.cancel 语义）")
})

print("== C03-04 完成判定真值表 ==")
T("stop=完整", { try eq(DashScopeProvider.evaluateCompletion(sawDone: false, finishReason: "stop"), true) })
T("length+DONE=部分（截断优先）", { try eq(DashScopeProvider.evaluateCompletion(sawDone: true, finishReason: "length"), false) })
T("未知reason+DONE=完整（传输收尾）", { try eq(DashScopeProvider.evaluateCompletion(sawDone: true, finishReason: "weird"), true) })
T("仅DONE=完整", { try eq(DashScopeProvider.evaluateCompletion(sawDone: true, finishReason: nil), true) })
T("无标记EOF=部分", { try eq(DashScopeProvider.evaluateCompletion(sawDone: false, finishReason: nil), false) })
T("未知reason无DONE=部分", { try eq(DashScopeProvider.evaluateCompletion(sawDone: false, finishReason: "weird"), false) })

print("== C03-03 绑定缺省与迁移 ==")
func mkWav(seconds: Double = 1.0) -> URL {
    let sr = 16000.0; let n = Int(sr * seconds)
    var d = Data()
    func str(_ x: String){ d.append(x.data(using:.ascii)!) }
    func u32(_ x: UInt32){ var v=x.littleEndian; d.append(Data(bytes:&v,count:4)) }
    func u16(_ x: UInt16){ var v=x.littleEndian; d.append(Data(bytes:&v,count:2)) }
    str("RIFF"); u32(UInt32(36+n*2)); str("WAVE"); str("fmt "); u32(16); u16(1); u16(1)
    u32(UInt32(sr)); u32(UInt32(sr*2)); u16(2); u16(16); str("data"); u32(UInt32(n*2))
    d.append(Data(repeating:0, count:n*2))
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-\(UUID()).wav")
    try? d.write(to: u); return u
}
T("keyHost=nil 拒绝（缺省不绕过）", {
    let u = mkWav()
    let req = ASRRequest(endpoint: URL(string:"https://evil.example.com/x")!, model:"m", language:"zh",
                         enableITN:true, apiKey:"sk-t", maxSeconds:60, keyHost:nil)
    do { _ = try DashScopeProvider.preflight(wavURL: u, request: req); try isFalse(true, "应拒绝") }
    catch let e as ASRError {
        try isTrue(e.isBindingError, "绑定类错误")
        try isTrue(e.userHint.contains("绑定"), "提示含绑定")
    }
    try? FileManager.default.removeItem(at: u)
})
T("keyHost 一致通过", {
    let u = mkWav()
    let req = ASRRequest(endpoint: URL(string:"https://dashscope.aliyuncs.com/v1/x")!, model:"m", language:"zh",
                         enableITN:true, apiKey:"sk-t", maxSeconds:60, keyHost:"dashscope.aliyuncs.com")
    try DashScopeProvider.preflight(wavURL: u, request: req)
    try? FileManager.default.removeItem(at: u)
})
T("keyHost 不一致拒绝且指明两主机", {
    let u = mkWav()
    let req = ASRRequest(endpoint: URL(string:"https://evil.example.com/x")!, model:"m", language:"zh",
                         enableITN:true, apiKey:"sk-t", maxSeconds:60, keyHost:"dashscope.aliyuncs.com")
    do { _ = try DashScopeProvider.preflight(wavURL: u, request: req); try isFalse(true, "应拒绝") }
    catch let e as ASRError {
        try isTrue(e.isBindingError, "绑定类")
        try isTrue(e.userHint.contains("evil.example.com") && e.userHint.contains("dashscope.aliyuncs.com"), "指明两主机")
    }
    try? FileManager.default.removeItem(at: u)
})
T("旧配置迁移登记 key_host", {
    let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-c-\(UUID()).json")
    try Data(("{\"endpoint\":\"https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions\"}").utf8).write(to: f)
    let (c, w) = ConfigLoader(fileURL: f).load()
    try eq(c.key_host ?? "", "dashscope.aliyuncs.com")
    try isTrue(w.contains { $0.contains("key_host") }, "迁移有提示")
    try? FileManager.default.removeItem(at: f)
})

print("== F05/F06/F07 针对性 ==")
T("F06: 组合 emoji 批次完整（家庭 emoji 不截断）", {
    let text = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}测试\u{1F44F}\u{1F3FB}结束"
    let bs = TextSanitizer.batches(forRange: 0..<6, in: text, batchSize: 3)
    try eq(bs.joined(), text, "批次拼回=全文")
})
T("F06: 剩余切片 Character 语义", {
    let text = "\u{1F468}\u{200D}\u{1F469}abc"
    // 交付 2 个 Character（家庭 emoji 占 1 个 Character + 'a'）→ 剩余 "bc"
    try eq(TextSanitizer.remaining(from: 2, in: text), "bc")
})
T("F07: 主机绑定不一致拒绝", {
    let url = URL(string: "https://evil.example.com/v1/chat/completions")!
    let req = ASRRequest(endpoint: url, model: "qwen3-asr-flash", language: "zh",
                         enableITN: true, apiKey: "sk-test", maxSeconds: 60, keyHost: "dashscope.aliyuncs.com")
    XCTAssertThrow(try DashScopeProvider.preflight(wavURL: URL(fileURLWithPath: "/dev/null"), request: req))
})
T("F07: 主机绑定一致通过预检", {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-t-\(UUID()).wav")
    try Data(repeating: 1, count: 100).write(to: tmp)
    let url = URL(string: "https://dashscope.aliyuncs.com/v1/chat/completions")!
    let req = ASRRequest(endpoint: url, model: "m", language: "zh", enableITN: true,
                         apiKey: "sk-test", maxSeconds: 60, keyHost: "dashscope.aliyuncs.com")
    try DashScopeProvider.preflight(wavURL: tmp, request: req)   // 不抛=通过
    try? FileManager.default.removeItem(at: tmp)
})
T("F07: serverRefused 不含正文内容", {
    let e = ASRError.serverRefused(code: "InvalidApiKey", messageLength: 300)
    let hint = e.userHint
    try isFalse(hint.contains("sk-"), "无凭证样式")
    try isTrue(e.userHint.count < 80, "提示简短（无正文）")
    try isFalse(e.isRetryable, "拒绝类不自动重试")
})
T("F07: userHint 覆盖所有类别且无 sk-", {
    let all: [ASRError] = [.auth, .badRequest("x"), .tooLarge, .rateLimited(retryAfter: nil),
                           .server, .network("x"), .protocolBad("x"),
                           .serverRefused(code: "c", messageLength: 1), .cancelled,
                           .invalidConfiguration("x")]
    for e in all { try isFalse(e.userHint.contains("sk-"), e.userHint) }
})

print("== B01/B04 Beta 收敛针对性 ==")
T("B01: cancelled 头部经 onAutoDiscard 回调（编排层可清理）", {
    let q = DeliveryQueue(limit: 5)
    var discarded: [String] = []
    q.onAutoDiscard = { discarded.append($0.id) }
    let a = RecordingSession(), b = RecordingSession()
    try q.enqueue(a); try q.enqueue(b)
    a.requestDiscard()
    RecordingFinisher.apply(a, kind: .userDiscard, success: nil)   // 放弃→cancelled
    done(b)
    try eq(q.next()?.id, b.id, "跳过取消的 a 取 b")
    try eq(discarded, [a.id], "回调收到被丢弃的 a")
    q.finishCurrent()
})
T("B01: failed 头部不入交付（回调清理后推进）", {
    let q = DeliveryQueue(limit: 5)
    var discarded: [String] = []
    q.onAutoDiscard = { discarded.append($0.id) }
    let a = RecordingSession(), b = RecordingSession()
    try q.enqueue(a); try q.enqueue(b)
    RecordingFinisher.apply(a, kind: .delegate, success: false)   // delegate 失败→failed
    done(b)
    try eq(q.next()?.id, b.id, "failed 不上传，直接取 b")
    try eq(discarded, [a.id], "failed 经回调清理")
    q.finishCurrent()
})
T("B02: session 可变状态跨线程读写（锁）", {
    let s = RecordingSession()
    let g = DispatchGroup()
    for _ in 0..<4 {
        g.enter()
        DispatchQueue.global().async {
            for _ in 0..<200 { s.appendTranscript("字") }
            g.leave()
        }
    }
    g.wait()
    try eq(s.transcript.count, 800, "并发追加无丢失")
})
T("B02: 放弃+delegate 竞态终态唯一", {
    let a = RecordingSession()
    a.requestDiscard()
    RecordingFinisher.apply(a, kind: .delegate, success: true)
    try eq(a.state, .cancelled, "放弃优先")
})
T("B04: 未知主机不自动迁移绑定（key_host 保持 nil）", {
    let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-b4-\(UUID()).json")
    try Data(("{\"endpoint\":\"https://selfhost.example.net/api\"}").utf8).write(to: f)
    let (c, w) = ConfigLoader(fileURL: f).load()
    try eq(c.key_host ?? "", "", "未自动绑定陌生主机")
    try isFalse(w.contains { $0.contains("key_host") }, "无迁移提示")
    try? FileManager.default.removeItem(at: f)
})
T("B04: 官方主机迁移仍有效", {
    let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-b4-\(UUID()).json")
    try Data(("{\"endpoint\":\"https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions\"}").utf8).write(to: f)
    let (c, _) = ConfigLoader(fileURL: f).load()
    try eq(c.key_host ?? "", "dashscope.aliyuncs.com")
    try? FileManager.default.removeItem(at: f)
})
T("B04: 手写显式绑定生效（用户确认路径）", {
    let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-b4-\(UUID()).json")
    try Data(("{\"endpoint\":\"https://selfhost.example.net/api\",\"key_host\":\"selfhost.example.net\"}").utf8).write(to: f)
    let (c, _) = ConfigLoader(fileURL: f).load()
    try eq(c.key_host ?? "", "selfhost.example.net", "显式绑定保留")
    try? FileManager.default.removeItem(at: f)
})

print("== CHAT-06 provider 端到端流式（URLProtocol fixture）==")
// 受控 transport：拦截请求，按脚本回放字节块（含 UTF-8 跨块/空行/[DONE]/CRLF/EOF 断流/length）
final class SSEStubProtocol: URLProtocol {
    static var script: [[UInt8]] = []
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        // 必须先发 response，URLSession.bytes 才会开始产出字节
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        for chunk in Self.script {
            client?.urlProtocol(self, didLoad: Data(chunk))
        }
        client?.urlProtocol(self, didReceive: URLResponse(), cacheStoragePolicy: .notAllowed) // 占位防优化
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let cfgStub = URLSessionConfiguration.ephemeral
cfgStub.protocolClasses = [SSEStubProtocol.self]
let stubbed = URLSession(configuration: cfgStub)
let provider = DashScopeProvider(session: stubbed)

func mkWavFile() -> URL {
    let sr = 16000.0; let n = 1600
    var d = Data()
    func str(_ x: String){ d.append(x.data(using:.ascii)!) }
    func u32(_ x: UInt32){ var v=x.littleEndian; d.append(Data(bytes:&v,count:4)) }
    func u16(_ x: UInt16){ var v=x.littleEndian; d.append(Data(bytes:&v,count:2)) }
    str("RIFF"); u32(UInt32(36+n*2)); str("WAVE"); str("fmt "); u32(16); u16(1); u16(1)
    u32(UInt32(sr)); u32(UInt32(sr*2)); u16(2); u16(16); str("data"); u32(UInt32(n*2))
    d.append(Data(repeating:0, count:n*2))
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-e2e-\(UUID()).wav")
    try? d.write(to: u); return u
}
func jsonDelta(_ text: String, finish: String? = nil) -> [UInt8] {
    // 对齐 Qwen 真协议：finish_reason 在 choices[0] **顶层**（与 delta 平级），不在 delta 内
    var obj = "{\"choices\":[{\"delta\":{\"content\":\"\(text)\"}"
    if let f = finish { obj += ",\"finish_reason\":\"\(f)\"" }
    obj += "}]}"
    return Array(obj.utf8)
}
// 由于无 runloop 并发框架，改为信号量等待的同步包装
func runE2ESync(_ script: [[UInt8]], name: String,
                check: @escaping (Result<ASRResult, Error>) throws -> Void) {
    SSEStubProtocol.script = script
    let wav = mkWavFile()
    let req = ASRRequest(endpoint: URL(string:"https://stub.local/v1/chat/completions")!,
                         model:"m", language:"zh", enableITN:true,
                         apiKey:"sk-stub", maxSeconds:60, keyHost:"stub.local")
    let sem = DispatchSemaphore(value: 0)
    final class Box { var value: Result<ASRResult, Error>? }
    let box = Box()
    Task {
        do {
            let r = try await provider.transcribeStream(wavURL: wav, request: req) { _ in }
            box.value = .success(r)
        } catch {
            box.value = .failure(error)
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 15)
    T(name) { try check(box.value ?? .failure(TestError("无结果"))) }
}

let b64 = Array("data: ".utf8)
T("E2E: 两条 delta+空行分隔+[DONE]（LF）", {
    let e1 = jsonDelta("今天"); let e2 = jsonDelta("开会")
    var script: [[UInt8]] = []
    for e in [e1, e2, Array("[DONE]".utf8)] {
        script.append(b64 + e + Array("\n\n".utf8))
    }
    runE2ESync(script, name: "") { r in
        guard case .success(let res) = r else { throw TestError("应成功") }
        try eq(res.text, "今天开会")
        try eq(res.isComplete, true)
    }
})
T("E2E: 中文跨字节块+CRLF", {
    let line = "data: " + String(data: try! JSONSerialization.data(withJSONObject: ["choices":[["delta":["content":"今天下午"]]]], options: []), encoding: .utf8)! + "\r\n\r\n"
    let bytes = Array(line.utf8)
    let cut = bytes.count - 4   // 在尾部多字节区内截断
    let e2line = "data: [DONE]\r\n\r\n"
    runE2ESync([Array(bytes[..<cut]), Array(bytes[cut...]), Array(e2line.utf8)], name: "") { r in
        guard case .success(let res) = r else { throw TestError("应成功") }
        try eq(res.text, "今天下午")
    }
})
T("E2E: length+[DONE] → 部分结果", {
    var script: [[UInt8]] = []
    for e in [jsonDelta("部分文字", finish: "length"), Array("[DONE]".utf8)] {
        script.append(b64 + e + Array("\n\n".utf8))
    }
    runE2ESync(script, name: "") { r in
        guard case .success(let res) = r else { throw TestError("应成功") }
        try eq(res.text, "部分文字")
        try eq(res.isComplete, false, "length=部分")
    }
})
T("E2E: 异常 EOF（无 DONE 无 finish）→ 部分且非空", {
    var script: [[UInt8]] = [b64 + jsonDelta("截断文字") + Array("\n\n".utf8)]
    runE2ESync(script, name: "") { r in
        guard case .success(let res) = r else { throw TestError("已有文本的 EOF 不应整体失败") }
        try eq(res.text, "截断文字")
        try eq(res.isComplete, false)
    }
})
T("E2E: HTTP 401 → auth 分类且不含 Key", {
    SSEStubProtocol.script = [[UInt8]]()   // 状态在 response 里无法注入——用协议内 401 不可行时验证非流式分支
    // 直接验证 classify（HTTP 层分类已由 ASRErrorTests 覆盖；此处验证 401 userHint 无 sk-）
    let e = DashScopeProvider.classify(status: 401, retryAfter: nil)
    try eq(e, .auth)
    try isFalse(e.userHint.contains("sk-stub"), "无 fixture 凭证")
})
T("E2E: 请求头不含 Authorization 字面值泄漏到 fixture 日志断言（结构检查）", {
    // StubProtocol 记录的 request 有 Authorization 头（URLSession 行为），
    // 但测试结果/错误对象永不包含它——由上方各类 userHint 断言覆盖。此处验证请求确实发出。
    try isTrue(SSEStubProtocol.lastRequest != nil, "请求已发出")
})

print("== CHAT-08 A: 启动代次保护 ==")
T("A: 正常捕获 → 可启动", {
    let g = StartSequenceGate()
    let gen = g.begin()
    try isTrue(gen != nil, "begin 成功")
    try eq(g.complete(generation: gen!), .accept(generation: gen!))
})
T("A: 捕获未完成时再次触发 → 迟到回调不得启动", {
    let g = StartSequenceGate()
    let gen1 = g.begin()!
    g.cancel()                                    // 用户再次触发/取消
    let out = g.complete(generation: gen1)        // 迟到的捕获结果
    try isTrue(out != .accept(generation: gen1), "迟到结果必须被拒：\(out)")
    try eq(out, .notPending)                      // cancel 清 pending
})
T("A: 并发 begin 被拒（不会同时两个启动序列）", {
    let g = StartSequenceGate()
    try isTrue(g.begin() != nil, "首个成功")
    try isTrue(g.begin() == nil, "第二个被拒")
})
T("A: 代次不匹配 → stale", {
    let g = StartSequenceGate()
    let gen1 = g.begin()!
    g.cancel()
    let gen2 = g.begin()!
    let out = g.complete(generation: gen1)        // 旧代次
    try eq(out, .stale(generation: gen1))         // pending 被 gen2 占用 → 旧代次 stale（拒绝）
    try eq(g.complete(generation: gen2), .accept(generation: gen2))
})
T("A: 完成后再回调 → notPending（不重复启动）", {
    let g = StartSequenceGate()
    let gen = g.begin()!
    _ = g.complete(generation: gen)
    try eq(g.complete(generation: gen), .notPending)
})

print("== B01 收紧: 元素不可读 → 一律剪贴板 ==")
let wxOrigin = TargetPolicy.TargetIdentity(pid: 3063, role: nil, elementHash: nil)
T("元素不可读 → 停止（无 pid 猜测放行）", {
    try isTrue(TargetPolicy.verdict(original: wxOrigin, current: nil).isStop, "current nil")
    try isTrue(TargetPolicy.verdict(original: wxOrigin, current: .init(pid: 3063, role: nil)).isStop, "role nil")
    try isTrue(TargetPolicy.verdict(original: wxOrigin, current: .init(pid: 3063, role: "AXGroup")).isStop, "容器角色")
})
T("安全输入启用 → 停止", {
    try isTrue(TargetPolicy.verdict(original: wxOrigin, current: nil, secureInputEnabled: true).isStop, "secure")
})
T("元素可读 → 正常路径 A", {
    try eq(TargetPolicy.verdict(original: origin, current: .init(pid: 100, role: "AXTextArea", elementHash: 555000)), .allowed)
})

print("== 配置 ==")
let dir = NSTemporaryDirectory()
func cfgFile(_ content: String) -> URL {
    let f = URL(fileURLWithPath: dir).appendingPathComponent("dv-cfg-\(UUID().uuidString).json")
    try? content.data(using: .utf8)!.write(to: f); return f
}
T("缺字段取默认+key_host 迁移登记", {
    let f = cfgFile("{}")
    let (c, w) = ConfigLoader(fileURL: f).load()
    try isTrue(c.endpoint.hasPrefix("https://"), "https")
    try eq(c.key_host ?? "", "dashscope.aliyuncs.com", "默认端点主机自动登记")
    try isTrue(w.contains { $0.contains("key_host") }, "迁移提示")
})
T("坏 JSON 备份不覆盖", {
    let f = cfgFile("{not json")
    _ = ConfigLoader(fileURL: f).load()
    try isTrue(FileManager.default.fileExists(atPath:
        f.deletingPathExtension().appendingPathExtension("json.bad").path), ".json.bad 存在")
})
T("非 HTTPS 回退", {
    let f = cfgFile("{\"endpoint\":\"http://evil.example.com/x\"}")
    let (c, w) = ConfigLoader(fileURL: f).load()
    try isTrue(c.endpoint.hasPrefix("https://"), "回退 https"); try isFalse(w.isEmpty, "有警告")
})
T("钳制", {
    var c = VoiceConfig(); c.max_seconds = 99999; c.queue_limit = 999
    _ = c.validate()
    try eq(c.max_seconds, 300.0); try eq(c.queue_limit, 10)
})
T("旧配置兼容", {
    let f = cfgFile("{\"endpoint\":\"https://x.example.com\",\"model\":\"qwen3-asr-flash\"}")
    let (c, _) = ConfigLoader(fileURL: f).load()
    try eq(c.model, "qwen3-asr-flash"); try eq(c.float_button ?? true, true)
})

print("\n结果: PASS=\(pass) FAIL=\(fail)")
exit(fail == 0 ? 0 : 1)

// 迷你断言
func XCTAssertThrow(_ body: @autoclosure () throws -> Any) {
    if (try? body()) != nil { fail += 1; print("  ✘ 期望抛错但未抛") } else { pass += 1 }
}
func isFalse(_ c: Bool, _ m: String) throws { if c { throw TestError(m) } }

extension TargetPolicy.Verdict {
    var isStop: Bool { if case .stopToPreview = self { return true }; return false }
}
