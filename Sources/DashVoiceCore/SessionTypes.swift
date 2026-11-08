import Foundation

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

/// 一次「录音→转写→交付」的完整会话。所有终态转换幂等：重复调用无副作用，
/// 迟到回调（delegate/超时/用户取消竞态）不会把同一 session 交付两次。
public final class RecordingSession {
    /// B02: 可变状态的串行隔离锁（跨线程读写：主线程 UI/取消、后台 ASR 回调、键入队列）
    private let lock = NSLock()
    public enum State: String, CustomStringConvertible {
        case recording, transcribing, delivering
        case delivered, deliveredPartial   // 已提交输入事件（partial=中途转预览/取消）
        case preview                       // 转预览/复制兜底（未自动键入）
        case cancelled, failed
        public var description: String { rawValue }
    }

    public enum FinishKind { case none, delegate, forceTimeout, userDiscard, userStop }

    public let id: String
    public let startedAt: Date
    public private(set) var state: State
    public private(set) var finishKind: FinishKind?

    // 生命周期幂等闸门：每种动作至多一次
    private(set) var uploadStarted = false
    private(set) var deliveryFinished = false
    private(set) var cleanedUp = false
    /// F03: 编排槽位释放闸门（ASR+交付全完成后由 AppState 释放一次）
    public var slotReleased = false

    private var _transcript = ""                     // 全文（部分结果也保留）
    private var _deliveredCharacters = 0
    private var _discardRequested = false
    private var _cancelled = false
    /// B02: 锁内读快照（跨线程安全）
    public var transcript: String { lock.withLock { _transcript } }
    public var deliveredCharacters: Int { lock.withLock { _deliveredCharacters } }
    public var discardRequested: Bool { lock.withLock { _discardRequested } }
    public var cancelled: Bool { lock.withLock { _cancelled } }

    /// 录音开始时的目标身份（进程 + AX 角色），供每批键入校验
    public var target: TargetPolicy.TargetIdentity?
    /// C03-02: 会话配置快照（录音时冻结；转写/交付读快照而非全局）
    public var configSnapshot: VoiceConfig?
    /// CHAT-08 §5: 热键触发时的前台目标 pid（Electron 兼容补读只针对它）；
    /// 兜底路径（自绘应用）也用它作为前台锚点
    public var frontPid: pid_t?
    /// CHAT-06: Key 主线程预读快照（钥匙串弹窗必须主线程语境才能呈现；
    /// 后台读会静默 -67671——11:46 六次失败的直接死因）
    public var keySnapshot: String?

    /// 音频临时文件位置；cleanedUp 后由清理方删除
    public var wavURL: URL?

    public init(id: String = UUID().uuidString, startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        self.state = .recording
    }

    // MARK: - 状态迁移（主线程调用）

    public func beginTranscription() {
        guard state == .recording else { return }
        state = .transcribing
    }

    /// 幂等：只有第一次调用生效（delegate 与强制超时竞争时只赢一方）
    @discardableResult
    public func markRecordingFinished(kind: FinishKind) -> Bool {
        guard finishKind == nil else { return false }
        finishKind = kind
        return true
    }

    public func beginDelivery() {
        guard state == .transcribing else { return }
        state = .delivering
    }

    /// 幂等上传闸门：同一 session 的音频至多发送一次
    @discardableResult
    public func markUploadStarted() -> Bool {
        guard !uploadStarted else { return false }
        uploadStarted = true
        return true
    }

    public func requestDiscard() {
        lock.withLock { _discardRequested = true }
    }

    /// 交付前以净化全文覆盖原始流文本；交付游标归零
    public func setFullTranscript(_ s: String) {
        lock.withLock { _transcript = s; _deliveredCharacters = 0 }
    }

    /// 幂等：整段交付动作只允许一次；返回是否本次是首次
    @discardableResult
    public func markDeliveryDone(_ finalState: State) -> Bool {
        guard !deliveryFinished, !cancelled else { return false }
        deliveryFinished = true
        state = finalState
        return true
    }

    public func markPreview(reason: String) {
        guard !deliveryFinished, !cancelled else { return }
        deliveryFinished = true
        state = .preview
    }

    public func markCancelled() {
        var proceed = false
        lock.withLock {
            guard !_cancelled, !deliveryFinished else { return }   // 终态不被迟到取消覆盖
            _cancelled = true
            proceed = true
        }
        guard proceed else { return }
        deliveryFinished = true
        state = .cancelled
    }

    public func markFailed() {
        deliveryFinished = true
        state = .failed
    }

    // MARK: - 内容

    public func appendTranscript(_ chunk: String) {
        lock.withLock { _transcript += chunk }
    }

    /// 记录已提交输入事件的累计字符数（单调递增，锁内）
    public func commitDelivered(count: Int) {
        lock.withLock {
            _deliveredCharacters = max(_deliveredCharacters, min(count, _transcript.count))
        }
    }

    public var isTerminal: Bool {
        switch state {
        case .delivered, .deliveredPartial, .preview, .cancelled, .failed: return true
        default: return false
        }
    }
}


/// C03-01: 录音结束事件的统一转移策略（幂等）。
/// 用户停止 / delegate 成功 / delegate 失败 / 达到时长上限（走 delegate） / 用户放弃
/// 全部经此函数：只转移一次，状态机保证队列可取或取消终态。
public enum RecordingFinisher {
    /// - Parameters:
    ///   - success: true=成功采音 false=采音失败 nil=不区分（放弃）
    /// - Returns: 实际执行的转移描述（已转移过则返回 nil）
    @discardableResult
    public static func apply(_ session: RecordingSession,
                             kind: RecordingSession.FinishKind,
                             success: Bool?) -> String? {
        guard session.markRecordingFinished(kind: kind) else { return nil }
        if session.discardRequested || kind == .userDiscard {
            session.markCancelled()                       // 放弃 → 取消终态（可清理）
            return "cancelled"
        }
        if success == false {
            session.markFailed()                          // delegate 失败 → 失败终态
            return "failed"
        }
        session.beginTranscription()                      // 成功/上限 → 变为可处理
        return "ready"
    }
}


/// CHAT-08 A: 启动序列的代次保护（纯逻辑，可离线测试）。
/// 用途：录音开始前在后台捕获原输入元素；任何过期/取消的捕获回调
/// 都不得启动录音或绑定新目标。
public final class StartSequenceGate {
    private let lock = NSLock()
    private var generation = 0
    private var pending = false
    private var cancelledCount = 0

    public init() {}

    /// 开始一次捕获；返回本次代次。若已有 pending，返回 nil（拒绝并发启动）。
    public func begin() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return nil }
        pending = true
        generation += 1
        return generation
    }

    /// 用户取消/再次触发：递增代次并清除 pending。
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        pending = false
        cancelledCount += 1
    }

    public enum Outcome: Equatable {
        case accept(generation: Int)   // 可启动录音（target 已冻结或为 nil）
        case stale(generation: Int)    // 过期回调：不启动
        case notPending
    }

    /// 捕获完成回调：仅当代次匹配且仍在 pending 时接受。
    public func complete(generation g: Int) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        guard pending else { return .notPending }
        guard g == generation else { return .stale(generation: g) }
        pending = false
        return .accept(generation: g)
    }

    public var isPending: Bool { lock.lock(); defer { lock.unlock() }; return pending }
    public var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
}
