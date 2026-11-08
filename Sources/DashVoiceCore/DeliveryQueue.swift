import Foundation

/// 有界 FIFO 交付队列：按录音开始顺序整段交付 session，禁止跨 session 交错。
/// 首版策略（计划 §6.1）：ASR 也按此队列串行执行——上一段转写完成后才开始下一段
/// 的 ASR；录音不受限（可边录下一段边等待上一段交付）。
public final class DeliveryQueue {
    public enum QueueError: Error, Equatable {
        case queueFull(limit: Int)
        case duplicateSession
    }

    public let limit: Int
    private var pending: [RecordingSession] = []   // 等待 ASR/交付，按序
    private var inFlight: RecordingSession?        // 当前串行处理中的 session
    /// B01: next() 丢弃 cancelled 头部时回调编排层（App 据此清文件/删会话）
    public var onAutoDiscard: ((RecordingSession) -> Void)?

    public init(limit: Int = 3) {
        precondition(limit >= 1)
        self.limit = limit
    }

    /// 入队。队满抛 queueFull（调用方向用户反馈，不静默丢弃）。
    public func enqueue(_ session: RecordingSession) throws {
        if pending.contains(where: { $0.id == session.id }) || inFlight?.id == session.id {
            throw QueueError.duplicateSession
        }
        guard pending.count < limit else { throw QueueError.queueFull(limit: limit) }
        pending.append(session)
    }

    /// 按序取出下一个**录音已结束**的 session；无则 nil。
    /// F03：队首仍在录音（state==.recording）时**阻塞等待**，不跳过不提前上传
    /// 未完成的 WAV；顺序严格 FIFO。
    public func next() -> RecordingSession? {
        guard inFlight == nil else { return nil }
        // B01: 移除已取消头部并**回调编排层清理**（不让取消项静默消失）
        while let head = pending.first, head.cancelled {
            pending.removeFirst()
            onAutoDiscard?(head)
        }
        guard let head = pending.first else { return nil }
        // F03: 录音中等待；B01: failed 终态不取出上传（交回调清理）
        if head.state == .failed {
            pending.removeFirst()
            onAutoDiscard?(head)
            return next()   // 继续找下一个可处理项
        }
        guard head.state != .recording, head.finishKind != nil else { return nil }  // 仍在录音
        pending.removeFirst()
        inFlight = head
        return head
    }

    /// 当前 session 处理完成，释放串行槽位。
    public func finishCurrent() {
        inFlight = nil
    }

    public var currentSessionID: String? { inFlight?.id }

    public var count: Int { pending.count + (inFlight != nil ? 1 : 0) }
    public var pendingCount: Int { pending.count }
    public var isBusy: Bool { inFlight != nil }

    /// 取消：pending 直接移除（不再转写/交付）；inFlight 标记取消——
    /// 调用方负责停止网络与键入（已发出的网络费用不可撤销，如实保留已产生文本）。
    @discardableResult
    public func cancel(id: String) -> Bool {
        if let idx = pending.firstIndex(where: { $0.id == id }) {
            pending[idx].markCancelled()
            pending.remove(at: idx)
            return true
        }
        if let cur = inFlight, cur.id == id {
            cur.markCancelled()
            return true
        }
        return false
    }

    /// 取消所有 pending（应用退出时用）；inFlight 不在此处理。
    public func cancelAllPending() {
        for s in pending { s.markCancelled() }
        pending.removeAll()
    }
}
