import AppKit
import AVFoundation
import Carbon.HIToolbox
import UserNotifications

/// 编排器：录音生命周期 → 有界串行队列 → ASR → 交付。
/// 所有 UI 更新在主线程；网络/键入在后台；热键路径无长阻塞（DV-021）。
final class AppState: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu?
    private let hotKey = HotKeyManager()
    private var queue = DeliveryQueue(limit: 3)
    private var sessions: [String: RecordingSession] = [:]
    private var recorder: AVAudioRecorder?
    private var recorderSessionID: String?
    private var lastToggleAt = Date.distantPast
    private var settingsWarningShown = false
    private var provider: ASRProvider = DashScopeProvider(diagnostics: { AppLog.write($0) })

    private var config: VoiceConfig = VoiceConfig()
    private lazy var configLoader = ConfigLoader(fileURL: ConfigLocation.fileURL)
    

    private var lastTranscript: String?
    private var frontPidAtStart: pid_t?   // CHAT-08 §5: 热键触发时的前台目标
    private let startGate = StartSequenceGate()   // CHAT-08 A: 启动代次保护（可测）
    private var activeTask: Task<Void, Never>?   // C03-02: 可取消的 ASR/交付任务
    private var recentResults: [String] = []   // DV-063：最近 5 条，仅内存
    private var settingsWC: SettingsWindowController?
    private var floatPanel: FloatMicPanel?
    private var floatView: FloatMicButtonView?

    private var agentPlistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/com.dashvoice.app.plist" }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bid = Bundle.main.bundleIdentifier ?? "com.dashvoice2.app"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }

        let (cfg, warnings) = configLoader.load()
        config = cfg
        warnings.forEach { AppLog.write("config: \($0)") }
        queue = DeliveryQueue(limit: config.queue_limit)
        wireQueueCallbacks()

        TempSweeper.sweep()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateUI()
        statusItem.button?.toolTip = "大声说 DashVoice（⌥Space 或点击图标）"
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let status = hotKey.register(keyCode: config.hotkey_keycode,
                                     modifiers: config.hotkey_modifiers)
        hotKey.onToggle = { [weak self] in self?.toggleRecording() }
        AppLog.write("launch: hotkey=\(status) id=\(bid) configWarn=\(warnings.count)")
        if status != noErr { notify(title: "大声说", body: "全局热键注册失败，请用菜单栏图标操作。") }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 悬浮按钮（默认开）
        if config.float_button ?? true { showFloatButton() }

        // 连接预热（非计费 HEAD）；付费 ASR 预热默认关闭（DV-047）
        if config.warmup_asr, let key = try? try KeychainStore.read() {
            _ = try? DashScopeProvider().transcribeStream  // 占位：真预热在 online-smoke 中显式执行
            AppLog.write("warmup_asr=true（付费预热已启用）")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.warmUpConnection() }
        // CHAT-08: AX 预热放后台且带 1s 超时（主线程零 AX 调用）
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            _ = AXFocus.readTarget()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("terminate: 清理 pending=\(queue.pendingCount) recording=\(recorder != nil)")
        if let sid = recorderSessionID { queue.cancel(id: sid) }
        queue.cancelAllPending()
        recorder?.stop()
        // F04: 统一终态清理——取消全部活动会话并删除各自临时音频
        for (_, session) in sessions {
            if !session.isTerminal { session.markCancelled() }
            TempSweeper.removeSessionFile(session.wavURL)
            session.wavURL = nil
        }
        sessions.removeAll()
    }

    private func warmUpConnection() {
        var req = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com")!)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: 触发

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggleRecording() }
    }

    @objc func toggleRecording() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) >= 0.25 else {
            AppLog.write("toggle debounced (burst)")
            return
        }
        lastToggleAt = now

        if startGate.isPending {
            // CHAT-08 A.3: 捕获期间再次触发 → 取消本次启动（迟到结果作废）
            startGate.cancel()
            AppLog.write("pending start cancelled by user (gen=\(startGate.currentGeneration))")
            return
        }
        if let sid = recorderSessionID, recorder != nil {
            guard now.timeIntervalSince(sessions[sid]?.startedAt ?? now) >= 0.7 else {
                AppLog.write("stop ignored (0.7s debounce)")
                return
            }
            finalizeRecording(kind: .userStop, success: true)
        } else {
            beginStartSequence()
        }
    }

    /// CHAT-08 A: 先捕获并冻结原输入元素，再开始录音。
    /// 捕获阶段全在后台（主线程零 AX）；代次保护确保取消/再次触发/前台变化后的
    /// 迟到结果不会启动幽灵录音或绑定新输入框。
    private func beginStartSequence() {
        guard let gen = startGate.begin() else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        frontPidAtStart = pid
        AppLog.write("start sequence gen=\(gen) pid=\(pid ?? 0)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var captured: TargetPolicy.TargetIdentity?
            if let pid, pid > 0 {
                // 先直接读（带 1s 消息超时），role 不可键入则走 compat/树遍历
                let direct = AXFocus.readTarget()
                if let t = direct, t.pid == pid, let r = t.role,
                   TargetPolicy.allowedRoles.contains(r) {
                    captured = t
                } else {
                    captured = AXFocus.readTargetWithElectronCompat(pid: pid)
                }
            }
            DispatchQueue.main.async {
                // 代次与 pending 双校验：任何过期回调都不启动
                switch self.startGate.complete(generation: gen) {
                case .accept:
                    break
                case .stale(let g):
                    AppLog.write("start sequence gen=\(g) stale → ignored")
                    return
                case .notPending:
                    AppLog.write("start sequence gen=\(gen) no longer pending → ignored")
                    return
                }
                if let captured {
                    AppLog.write("target frozen before recording pid=\(captured.pid) role=\(captured.role ?? "nil")")
                } else {
                    AppLog.write("target capture failed → this session will never auto-type")
                }
                self.beginRecording(target: captured, frontPid: pid)
            }
        }
    }

    // MARK: 录音（DV-020/024/025/027/028）

    /// 权限门 + 启动录音（target 已由 beginStartSequence 冻结）
    private func beginRecording(target: TargetPolicy.TargetIdentity?, frontPid: pid_t?) {
        switch MicPermission.current {
        case .granted:
            startRecorder(target: target, frontPid: frontPid)
        case .notDetermined:
            MicPermission.request { [weak self] perm in
                DispatchQueue.main.async {
                    // 权限弹窗期间焦点可能变化，但 target 已在弹窗前冻结（A.6）
                    perm == .granted ? self?.startRecorder(target: target, frontPid: frontPid) : self?.micDenied()
                }
            }
        case .denied, .restricted:
            micDenied()
        }
    }

    private func micDenied() {
        AppLog.write("mic denied/restricted -> settings")
        if !settingsWarningShown {
            notify(title: "无法访问麦克风",
                   body: "请在 系统设置 → 隐私与安全性 → 麦克风 中允许大声说。")
            settingsWarningShown = true
        }
        MicPermission.openSettings()
        updateUI()
    }

    private func startRecorder(target: TargetPolicy.TargetIdentity?, frontPid: pid_t?) {
        // 队满反馈（DV-028）：pending 满则不开新录音
        guard queue.pendingCount < config.queue_limit else {
            AppLog.write("queue full -> refuse recording")
            notify(title: "处理队列已满", body: "已有 \(queue.pendingCount) 段在等待，稍后再录。")
            updateUI()
            return
        }

        let session = RecordingSession()
        session.target = target
        session.configSnapshot = config   // C03-02: 会话配置快照
        session.frontPid = frontPid   // CHAT-08 A: 启动时捕获的前台 pid
        sessions[session.id] = session
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashvoice-\(session.id).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            guard rec.record(forDuration: config.max_seconds) else {
                throw RecordingStartError()
            }
            session.wavURL = url
            recorder = rec
            recorderSessionID = session.id
            try queue.enqueue(session)
            updateUI()
            warmUpConnection()

            NSSound(named: NSSound.Name("Tink"))?.play()
            AppLog.write("recording started session=\(session.id.prefix(8)) target=\(target?.pid ?? 0)")
        } catch {
            AppLog.write("beginRecording FAILED: \(error.localizedDescription)")
            sessions[session.id] = nil
            TempSweeper.removeSessionFile(url)
            finishWithError("录音启动失败：\(error.localizedDescription)")
        }
    }

    struct RecordingStartError: LocalizedError {
        var errorDescription: String? { "无法启动录音" }
    }

    /// C03-01: 幂等结束录音（用户停止/上限 delegate/强制超时/放弃 统一入口）。
    /// RecordingFinisher.apply 只转移一次；随后簿记+推进队列。
    private func finalizeRecording(kind: RecordingSession.FinishKind, success: Bool?) {
        guard let sid = recorderSessionID, let session = sessions[sid] else { return }
        recorder?.stop()
        recorder = nil
        recorderSessionID = nil
        // CHAT-08: 主线程不做任何 AX 读取（AX 内核调用可无限阻塞，实测导致
        // 进程 STAT=UE 且 kill -9 无效）。目标读取全部在 transcribe 后台完成。
        // CHAT-06/K: Key 主线程预读（finalize 在主线程）——钥匙串"允许访问"弹窗
        // 只有主线程语境才能呈现；后台线程读会静默 -67671（11:46 六次失败直接死因）
        if session.keySnapshot == nil, kind != .userDiscard {
            do {
                session.keySnapshot = try KeychainStore.read()
                AppLog.write("keychain pre-read ok at finish (main thread)")
            } catch {
                AppLog.write("keychain pre-read at finish failed: \(error)")
            }
        }
        let outcome = RecordingFinisher.apply(session, kind: kind, success: success)
        AppLog.write("recording finish kind=\(kind) session=\(sid.prefix(8)) outcome=\(outcome ?? "dup")")
        updateUI()
        pump()
    }

    /// C03-01: delegate 结束（含**自动达到时长上限**与设备错误）统一走转移；
    /// flag=false 分类为失败——此前该路径漏 beginTranscription 会卡住队列。
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard let sid = recorderSessionID, self.recorder === recorder else { return }  // 迟到回调无副作用
        DispatchQueue.main.async {
            self.finalizeRecording(kind: .delegate, success: flag)
        }
    }

    /// 放弃当前录音（右键菜单）：标记取消 + 停止；文件在终态统一清理
    @objc private func discardRecording() {
        guard let sid = recorderSessionID, let session = sessions[sid] else { return }
        AppLog.write("discard session=\(sid.prefix(8))")
        session.requestDiscard()
        finalizeRecording(kind: .userDiscard, success: nil)   // → cancelled 终态，可清理
    }

    // MARK: 串行处理泵（DV-033：按序整段处理）

    /// B01: 队列自动丢弃（cancelled/failed 头部）→ 统一清文件+删会话（有界保留）
    private func wireQueueCallbacks() {
        queue.onAutoDiscard = { [weak self] session in
            DispatchQueue.main.async {
                AppLog.write("queue auto-discard session=\(session.id.prefix(8)) state=\(session.state)")
                self?.cleanupSession(session)
                self?.updateUI()
            }
        }
    }

    private func pump() {
        guard !queue.isBusy else { return }
        guard let session = queue.next() else { return }   // F03: 队首录音中则等待
        guard !session.cancelled, !session.discardRequested else {
            TempSweeper.removeSessionFile(session.wavURL)
            releaseSlot(session)
            return
        }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.transcribe(session)   // 内部完成 deliver 调度
            // F03: 槽位不在 transcribe 返回时释放——由 deliver 完成回调统一 releaseSlot
        }
        activeTask = task
    }

    /// C03-02: 用户取消当前处理（菜单入口）——取消任务句柄 + 标记 in-flight session
    @objc private func cancelActiveProcessing() {
        guard let cur = queue.currentSessionID, let session = sessions[cur] else { return }
        AppLog.write("user cancel processing session=\(cur.prefix(8))")
        session.requestDiscard()      // 令 verifier/onDelta 路径停止
        session.markCancelled()
        activeTask?.cancel()
        activeTask = nil
        queue.cancel(id: cur)
        releaseSlot(session)
    }

    /// F03: 该 session 的 ASR+整段交付/预览/取消 **全部结束**后调用（主线程）。
    /// 幂等：同一 session 只释放一次槽位。
    private func releaseSlot(_ session: RecordingSession) {
        guard !session.slotReleased else { return }
        // B01: 只释放属于自己 session 的槽位（迟到回调不得释放他人/新队列槽）
        guard queue.currentSessionID == session.id else {
            AppLog.write("releaseSlot skipped: slot owner=\(queue.currentSessionID ?? "nil") caller=\(session.id.prefix(8))")
            return
        }
        session.slotReleased = true
        queue.finishCurrent()
        cleanupSession(session)
        updateUI()
        pump()   // 串行推进下一段
    }

    /// F04: 终态 session 从字典移除（有界保留：只留最近结果，不留会话对象）
    private func cleanupSession(_ session: RecordingSession) {
        guard session.isTerminal else { return }
        TempSweeper.removeSessionFile(session.wavURL)
        session.wavURL = nil
        sessions.removeValue(forKey: session.id)
    }

    private func transcribe(_ session: RecordingSession) async {
        guard session.markUploadStarted() else { return }   // 只上传一次
        session.beginTranscription()
        let cfg = session.configSnapshot ?? config   // C03-02: session 配置快照（录音时冻结）
        AppLog.write("transcribe session=\(session.id.prefix(8)) model=\(cfg.model) targetPid=\(session.target?.pid ?? 0)")
        // CHAT-08 A: 目标已在 beginStartSequence 中**冻结**（录音开始前捕获）。
        // 此处**禁止**任何重新绑定——录音期间/排队期间的焦点变化不得被当成本段目标。
        if session.target == nil {
            AppLog.write("no frozen target for session=\(session.id.prefix(8)) → clipboard only (never auto-type)")
        }

        // CHAT-06/K: 用主线程预读的快照；缺失时不再后台重读（会 -67671），
        // 而是明确失败+引导（下一次录音的主线程预读会触发可见弹窗）
        guard let key = session.keySnapshot, !key.isEmpty else {
            AppLog.write("keychain error: category=no_snapshot (main-thread pre-read failed at finish)")
            await MainActor.run {
                session.markFailed()
                self.fail(session, "未找到 API Key：请在菜单栏图标右键 → 设置… → 粘贴 DashScope Key → 保存 Key，然后重新录音。")
                self.releaseSlot(session)
            }
            TempSweeper.removeSessionFile(session.wavURL)
            return
        }

        guard let url = session.wavURL else { return }
        let request = ASRRequest(endpoint: URL(string: cfg.endpoint) ?? URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
                                 model: cfg.model, language: cfg.language,
                                 enableITN: cfg.enable_itn, apiKey: key,
                                 maxSeconds: cfg.max_seconds, keyHost: cfg.key_host)

        // B02（Owner 决定）: 首版禁用自动重试（DV-045→DEFERRED 进路线图）。
        // 保留 DV-044 总墙钟 90s watchman；attempt 入口检查取消，取消不再发起新请求。
        func attempt() async throws -> ASRResult {
            try Task.checkCancellation()
            // session 由 AppState.sessions 字典持有，请求期强捕获无循环；
            // （[weak session]+内层 async 捕获在 Swift 5.8 会触发非确定性的并发捕获诊断）
            return try await withTimeout(seconds: 90) {
                try await self.provider.transcribeStream(wavURL: url, request: request) { chunk in
                    // C03-02/B02: 累积写状态切主线程（串行隔离），后台不再直写 session
                    let chunk = chunk
                    DispatchQueue.main.async { session.appendTranscript(chunk) }
                }
            }
        }
        final class ResultBox { var value: ASRResult? }
        let box = ResultBox()
        do {
            do {
                box.value = try await attempt()
            } catch let e as ASRError where e.isRetryable && session.transcript.isEmpty
                     && !session.cancelled && !session.discardRequested {
                // 受控重试：2s 退避后重发一次（请求计数上限 2，无重复计费——首试未收到任何文本）
                AppLog.write("transcribe retry 1/1 session=\(session.id.prefix(8)) after \(e.diagnosticCategory) (no partial text)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try Task.checkCancellation()
                box.value = try await attempt()
            }
            try Task.checkCancellation()
            guard let r = box.value else { throw ASRError.protocolBad("无结果") }
            let result = r
            await MainActor.run { self.deliver(session: session, result: result) }
        } catch is CancellationError {
            AppLog.write("transcribe cancelled session=\(session.id.prefix(8))")
            TempSweeper.removeSessionFile(session.wavURL)
            await MainActor.run { self.releaseSlot(session) }
        } catch let e as ASRError {
            AppLog.write("ASR error session=\(session.id.prefix(8)): category=\(e.diagnosticCategory)")
            TempSweeper.removeSessionFile(session.wavURL)
            await MainActor.run {
                if session.cancelled { self.releaseSlot(session); return }
                // F05: 已有累积文本的中断/协议错误 → 部分结果保留可取回，不伪装完整也不丢弃
                let partial = TextSanitizer.sanitize(session.transcript, keepNewlines: self.config.keep_newlines)
                if !partial.isEmpty {
                    self.preservePartialResult(session, text: partial, error: e.userHint)
                } else {
                    session.markFailed()
                    self.fail(session, e.userHint)
                }
                self.releaseSlot(session)
            }
        } catch {
            AppLog.write("ASR unknown error: \(error.localizedDescription)")
            TempSweeper.removeSessionFile(session.wavURL)
            await MainActor.run {
                if !session.cancelled {
                    session.markFailed()
                    self.fail(session, "识别失败：\(error.localizedDescription)")
                }
                self.releaseSlot(session)
            }
        }
    }

    // MARK: 交付（DV-029/030/031/034/035/036）

    private func deliver(session: RecordingSession, result: ASRResult) {
        TempSweeper.removeSessionFile(session.wavURL)   // 音频用后即删（DV-055）
        guard !session.cancelled, !session.discardRequested else {
            releaseSlot(session)
            return
        }

        // C03-02: 自动键入的安全文本不允许换行（防误发送）；
        // keep_newlines=true 时原文保留在预览/最近结果，自动键入用换行折叠版本。
        let snap = session.configSnapshot ?? config
        let fullOriginal = TextSanitizer.sanitize(result.text, keepNewlines: snap.keep_newlines)
        let fullTyped = TextSanitizer.sanitize(result.text, keepNewlines: false)
        let full = snap.delivery_mode == "auto" ? fullTyped : fullOriginal
        session.setFullTranscript(full)
        lastTranscript = full
        let entry = (result.isComplete ? "" : "【部分】") + full
        recentResults.insert(entry, at: 0)
        if recentResults.count > 5 { recentResults.removeLast() }
        guard !full.isEmpty else {
            session.markFailed()
            fail(session, "未识别到语音内容")
            releaseSlot(session)
            return
        }

        // DV-034：完成语义 = isComplete（协议层）与 delivered（交付层）分开报告
        AppLog.write("asr result session=\(session.id.prefix(8)) chars=\(full.count) complete=\(result.isComplete) finish=\(result.finishReason ?? "nil")")

        let partialMark = result.isComplete ? "" : "【部分】"
        switch snap.delivery_mode {
        case "copy":
            copyToClipboard(full)
            session.markDeliveryDone(.preview)
            notify(title: "大声说 · 已复制\(partialMark)", body: String(full.prefix(120)))
            releaseSlot(session)
        case "preview":
            // C03-02: preview 不改剪贴板——预览=通知展示，取用走"最近结果"菜单复制
            session.markDeliveryDone(.preview)
            notify(title: "大声说 · 预览（未键入，可从菜单复制）\(partialMark)", body: String(full.prefix(160)))
            releaseSlot(session)
        default:   // auto
            session.beginDelivery()
            // B01 收紧: 元素不可读（自绘应用如微信）→ 一律剪贴板，无 pid 猜测放行
            guard let original = session.target else {
                copyToClipboard(full)
                session.markDeliveryDone(.deliveredPartial)
                notify(title: "大声说 · 已转剪贴板", body: "该应用不支持自动键入（无 AX 元素）。\n\(String(full.prefix(100)))")
                releaseSlot(session)
                return
            }
            let batches = TextSanitizer.batches(forRange: session.deliveredCharacters..<full.count,
                                                in: full)
            Injector.shared.injectBatches(
                batches,
                verifier: { [weak self] in
                    guard let self, !session.cancelled, !session.discardRequested else {
                        return .stopToPreview(reason: "已取消")
                    }
                    // 每批校验（DV-030/031）：目标进程一致 + 角色白名单
                    // Q1: 每批实时读安全输入状态（密码框保护）
                    return TargetPolicy.verdict(original: original,
                                                current: AXFocus.readTarget(),
                                                secureInputEnabled: SecureInput.isEnabled)
                },
                onBatchSubmitted: { [weak self] submitted in
                    session.commitDelivered(count: submitted)
                    self?.updateUI()
                },
                completion: { outcome in
                    switch outcome {
                    case .submitted(let n):
                        AppLog.write("delivered session=\(session.id.prefix(8)) chars=\(n) complete=\(result.isComplete)")
                        // F05: 部分结果（无 stop/[DONE]）如实标注，不给完成音
                        if session.markDeliveryDone(result.isComplete ? .delivered : .deliveredPartial) {
                            if result.isComplete {
                                NSSound(named: NSSound.Name("Pop"))?.play()
                            } else {
                                self.notify(title: "大声说 · 部分结果", body: "识别流未正常收尾，以下为部分文字（已键入）：\n\(String(full.prefix(100)))")
                            }
                        }
                    case .stopped(let n, let reason):
                        session.commitDelivered(count: n)
                        AppLog.write("delivery stopped at \(n): \(reason)")
                        if session.cancelled {
                            self.updateUI()
                            self.releaseSlot(session)
                            return   // 用户取消：不复制不打扰
                        }
                        session.markDeliveryDone(.deliveredPartial)
                        let rest = TextSanitizer.remaining(from: session.deliveredCharacters, in: full)
                        self.copyToClipboard(rest.isEmpty ? full : rest)
                        self.notify(title: "大声说 · 已转剪贴板",
                                    body: "自动键入已停止（\(reason)）。剩余文字已复制。\n\(String(full.prefix(100)))")
                    }
                    self.releaseSlot(session)   // F03: 交付真正结束才释放槽位
                }
            )
        }
    }

    /// F05: 部分结果保留（可取回），标记部分，不进入正常交付流程
    private func preservePartialResult(_ session: RecordingSession, text: String, error: String) {
        lastTranscript = text
        recentResults.insert("【部分】" + text, at: 0)
        if recentResults.count > 5 { recentResults.removeLast() }
        copyToClipboard(text)
        session.markDeliveryDone(.deliveredPartial)
        notify(title: "大声说 · 部分结果已保留",
               body: "识别中断，已收到部分文字（已复制到剪贴板）：\(error)\n\(String(text.prefix(100)))")
        updateUI()
    }

    private func fail(_ session: RecordingSession, _ message: String) {
        NSSound(named: NSSound.Name("Basso"))?.play()
        notify(title: "大声说", body: message)
        updateUI()
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(text.data(using: .utf8), forType: .string)
    }

    // MARK: 菜单与状态

    private func showMenu() {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "大声说 DashVoice — \(stateLabel)", action: nil, keyEquivalent: ""))
        m.addItem(.separator())
        let t = NSMenuItem(title: recorder != nil ? "停止录音" : "开始录音（点击图标即可）",
                           action: #selector(toggleRecording), keyEquivalent: "")
        t.target = self
        m.addItem(t)
        if recorder != nil {
            let d = NSMenuItem(title: "放弃本次录音（不转写）", action: #selector(discardRecording), keyEquivalent: "")
            d.target = self
            m.addItem(d)
        } else if queue.isBusy {
            let c = NSMenuItem(title: "取消当前处理", action: #selector(cancelActiveProcessing), keyEquivalent: "")
            c.target = self
            m.addItem(c)
        }
        let c = NSMenuItem(title: "复制上次转写结果", action: #selector(copyLast), keyEquivalent: "")
        c.target = self
        c.isEnabled = (lastTranscript != nil)
        m.addItem(c)
        if !recentResults.isEmpty {   // DV-063：最近结果面板（点击复制，不自动回放）
            let sub = NSMenu()
            for t in recentResults {
                let it = NSMenuItem(title: String(t.prefix(28)), action: #selector(copyRecent(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = t
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: "最近结果（点击复制）", action: nil, keyEquivalent: "")
            parent.submenu = sub
            m.addItem(parent)
        }
        m.addItem(.separator())
        let agent = NSMenuItem(title: "开机自启", action: #selector(toggleAgent), keyEquivalent: "")
        agent.target = self
        agent.state = agentRegistered() ? .on : .off   // C03-06: 显示实际注册结果
        m.addItem(agent)
        let fb = NSMenuItem(title: "悬浮麦克风按钮", action: #selector(toggleFloatButton), keyEquivalent: "")
        fb.target = self
        fb.state = (floatPanel != nil) ? .on : .off
        m.addItem(fb)
        let oc = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        oc.target = self
        m.addItem(oc)
        let cf = NSMenuItem(title: "打开配置文件", action: #selector(openConfig), keyEquivalent: "")
        cf.target = self
        m.addItem(cf)
        if !recentResults.isEmpty {
            let clr = NSMenuItem(title: "清除最近结果", action: #selector(clearRecent), keyEquivalent: "")
            clr.target = self
            m.addItem(clr)
            // B03: 自动"重试交付"入口禁用（Beta 收敛：绕过队列/快照的安全路径不复用）
            // 受控重试将随结果面板在路线图中回归
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "退出大声说", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu = m
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController(config: config, configLoader: configLoader) { [weak self] in
                DispatchQueue.main.async { self?.reloadConfigAndReregisterHotkey() }
            }
        }
        // CHAT-08: 顺序很重要——先激活应用，再让窗口成为 key，最后聚焦 Key 输入框
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        settingsWC?.window?.makeKey()
        if let wc = settingsWC { wc.window?.makeFirstResponder(wc.keyField) }
    }

    /// DV-063: 清除最近结果（内存与剪贴板不主动动）
    @objc private func clearRecent() {
        recentResults.removeAll()
        lastTranscript = nil
        updateUI()
    }

    // CHAT-08 §5.7/B03: 受控重试交付入口已禁用（主线程 AX 读取 + 绕过队列），
    // 方法随之移除，避免任何主线程 AX 调用。受控重试随结果面板在路线图回归。

    @objc private func copyRecent(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? String { copyToClipboard(t) }
    }

    @objc private func copyLast() {
        guard let t = lastTranscript else { return }
        copyToClipboard(t)
    }

    @objc private func openConfig() {
        // CHAT-08: NSWorkspace.open(file) 会用 .json 的系统关联程序打开；
        // 本机 .json 被关联到 ChimeraX → 每次点"打开配置文件"都弹出分子软件。
        // 显式指定 TextEdit（系统自带，永不关联错误）。
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([configLoader.fileURL],
                                withApplicationAt: textEdit,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// DV-062/C03-02: 配置重载 + 热键重注册（冲突时恢复默认并提示）
    private func reloadConfigAndReregisterHotkey() {
        let (cfg, warnings) = configLoader.load()
        config = cfg
        warnings.forEach { AppLog.write("config reload: \($0)") }
        hotKey.onToggle = nil
        let st = hotKey.register(keyCode: config.hotkey_keycode, modifiers: config.hotkey_modifiers)
        if st != noErr {
            AppLog.write("hotkey re-register failed st=\(st) -> fallback default")
            config.hotkey_keycode = 49; config.hotkey_modifiers = 2048
            _ = hotKey.register(keyCode: 49, modifiers: 2048)
            notify(title: "大声说", body: "自定义热键注册失败（可能冲突），已恢复 ⌥Space")
            configLoader.save(config)
        }
        hotKey.onToggle = { [weak self] in self?.toggleRecording() }
        // B01: 忙时禁止替换队列（丢任务风险）——空闲才应用 queue_limit 变更
        if queue.isBusy || queue.pendingCount > 0 || recorder != nil {
            AppLog.write("queue busy -> queue_limit change deferred until idle")
        } else {
            queue = DeliveryQueue(limit: config.queue_limit)
            wireQueueCallbacks()
        }
    }

    @objc private func toggleAgent() {
        let installed = agentRegistered()   // F10: 用实际注册状态而非 plist 存在
        setAgent(!installed)
    }

    private func agentRegistered() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/com.dashvoice.app"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @objc private func toggleFloatButton() {
        AppLog.write("toggleFloatButton: current=\(floatPanel != nil) config=\(config.float_button ?? true)")
        if floatPanel != nil {
            floatPanel?.orderOut(nil); floatPanel = nil; floatView = nil
            config.float_button = false
        } else {
            showFloatButton()
            config.float_button = true
        }
        configLoader.save(config)
    }

    private func setAgent(_ enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in   // C03-06: 簿记离开主线程
            self?.setAgentSync(enabled)
            DispatchQueue.main.async { self?.updateUI() }
        }
    }

    private func setAgentSync(_ enabled: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["unload", agentPlistPath]
        try? p.run(); p.waitUntilExit()
        if enabled, let exe = Bundle.main.executableURL?.path {
            let logs = NSHomeDirectory() + "/Library/Logs"
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.dashvoice.app</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><false/>
              <key>ProcessType</key><string>Interactive</string>
              <key>StandardErrorPath</key><string>\(logs)/dashvoice.log</string>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(atPath: (agentPlistPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? xml.write(toFile: agentPlistPath, atomically: true, encoding: .utf8)
            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p2.arguments = ["load", agentPlistPath]
            let errPipe = Pipe(); p2.standardError = errPipe
            do { try p2.run() } catch {
                notify(title: "大声说", body: "自启注册失败：\(error.localizedDescription)")
                updateUI()
                return
            }
            p2.waitUntilExit()
            if p2.terminationStatus != 0 {
                let err = (try? errPipe.fileHandleForReading.readDataToEndOfFile())
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                notify(title: "大声说", body: "自启注册失败：\(err.prefix(120))")
            }
        } else {
            try? FileManager.default.removeItem(atPath: agentPlistPath)
        }
    }

    private var stateLabel: String {
        if recorder != nil { return "录音中…" }
        if isProcessing { return "识别/交付中…（队列 \(queue.pendingCount)）" }
        return "空闲"
    }

    private var isProcessing: Bool { queue.isBusy || queue.pendingCount > 0 }

    // MARK: UI 同步

    private func showFloatButton() {
        guard floatPanel == nil else { return }
        let cfg = config
        var origin: NSPoint
        if let f = NSScreen.main?.frame { origin = NSPoint(x: f.maxX - 96, y: f.minY + 120) } else { origin = NSPoint(x: 1580, y: 120) }
        if let x = cfg.float_x, let y = cfg.float_y { origin = NSPoint(x: x, y: y) }
        if let s = NSScreen.main?.frame {
            origin.x = min(max(origin.x, s.minX + 4), s.maxX - 60)
            origin.y = min(max(origin.y, s.minY + 4), s.maxY - 60)
        }
        let view = FloatMicButtonView { [weak self] in self?.toggleRecording() }
        let panel = FloatMicPanel(at: origin, content: view)
        panel.onMoved = { [weak self] in
            guard let self, let f = self.floatPanel?.frame else { return }
            self.config.float_x = f.origin.x
            self.config.float_y = f.origin.y
            self.configLoader.save(self.config)
        }
        panel.orderFrontRegardless()
        floatPanel = panel
        floatView = view
        floatView?.set(look: currentLook)
        // 诊断：确认 panel 真实可见
        AppLog.write("float panel created: frame=\(panel.frame) visible=\(panel.isVisible) level=\(panel.level.rawValue) alpha=\(panel.alphaValue) screens=\(NSScreen.screens.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let p = self?.floatPanel else { return }
            AppLog.write("float panel after 1s: visible=\(p.isVisible) frame=\(p.frame)")
        }
    }

    private var currentLook: FloatMicButtonView.Look {
        if recorder != nil { return .recording }
        if isProcessing { return .transcribing }
        return .idle
    }

    private func updateUI() {
        guard let button = statusItem.button else { return }
        // CHAT-08: 自绘图标（不依赖 SF Symbol —— 菜单栏占位/异常渲染的实测修复）
        if recorder != nil {
            button.image = StatusIcon.make(.recording)
            button.contentTintColor = nil
        } else if isProcessing {
            button.image = StatusIcon.make(.processing)
            button.contentTintColor = nil
        } else {
            button.image = StatusIcon.make(.idle)
            button.contentTintColor = nil
        }
        floatView?.set(look: currentLook)
    }

    private func finishWithError(_ msg: String) {
        AppLog.write("ERROR: \(msg)")
        NSSound(named: NSSound.Name("Basso"))?.play()
        notify(title: "大声说", body: msg)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "出错")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        }
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            if self?.recorder == nil { self?.updateUI() }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
