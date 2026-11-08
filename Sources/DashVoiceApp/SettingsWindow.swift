import AppKit

/// 设置窗（DV-049/061/062）：图形化 Key 管理 + 参数配置 + 热键重注册。
/// 非模态；保存时校验并热应用。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var onChange: () -> Void
    private let configLoader: ConfigLoader

    let keyField: NSSecureTextField
    private let modelPopup: NSPopUpButton
    private let langField: NSTextField
    private let maxSecField: NSTextField
    private let queueField: NSTextField
    private let keycodeField: NSTextField
    private let modifiersField: NSTextField
    private let modePopup: NSPopUpButton
    private let itnCheck: NSButton
    private let newlinesCheck: NSButton
    private let statusLabel: NSTextField

    init(config: VoiceConfig, configLoader: ConfigLoader,
         onChange: @escaping () -> Void) {
        self.configLoader = configLoader
        self.onChange = onChange

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "大声说 · 设置"
        w.center()

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.spacing = 8
        w.contentView = stack

        func row(_ label: String, _ control: NSControl) {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(l)
            control.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
            stack.addArrangedSubview(control)
        }

        stack.addArrangedSubview(NSTextField(labelWithString: "DashScope API Key（存入钥匙串，不落盘）"))
        keyField = NSSecureTextField(frame: .zero)
        keyField.placeholderString = "粘贴 Key（留空=不修改）"
        row("Key：", keyField)
        let keyButtons = NSStackView(views: [
            { let b = NSButton(title: "保存 Key", target: nil, action: nil); b.bezelStyle = .rounded; return b }(),
            { let b = NSButton(title: "删除 Key", target: nil, action: nil); b.bezelStyle = .rounded; return b }()])
        keyButtons.orientation = .horizontal
        stack.addArrangedSubview(keyButtons)

        stack.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 10)))
        // CHAT-08 后续: 模型下拉（双模型并列即时切换，不重启不重授权）
        modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modelPopup.addItems(withTitles: ["qwen3-asr-flash", "qwen-audio-3.1-asr-flash"])
        if config.model == "qwen-audio-3.1-asr-flash" { modelPopup.selectItem(at: 1) }
        else { modelPopup.selectItem(at: 0) }
        row("识别模型：", modelPopup)
        langField = NSTextField(string: config.language)
        row("识别语言（zh/en/…）：", langField)
        maxSecField = NSTextField(string: String(format: "%.0f", config.max_seconds))
        row("单段最长秒数（5~300）：", maxSecField)
        queueField = NSTextField(string: String(config.queue_limit))
        row("处理队列上限（1~10）：", queueField)
        keycodeField = NSTextField(string: String(config.hotkey_keycode))
        row("热键 keycode（49=Space）：", keycodeField)
        modifiersField = NSTextField(string: String(config.hotkey_modifiers))
        row("热键 modifiers（2048=⌥）：", modifiersField)

        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: ["auto（自动键入）", "preview（只预览）", "copy（只复制）"])
        modePopup.selectItem(at: ["auto", "preview", "copy"].firstIndex(of: config.delivery_mode) ?? 0)
        row("交付模式：", modePopup)

        itnCheck = NSButton(checkboxWithTitle: "口语数字转阿拉伯数字（ITN）", target: nil, action: nil)
        itnCheck.state = config.enable_itn ? .on : .off
        stack.addArrangedSubview(itnCheck)
        newlinesCheck = NSButton(checkboxWithTitle: "保留换行（仅预览/复制模式生效；自动键入始终折叠换行）", target: nil, action: nil)
        newlinesCheck.state = config.keep_newlines ? .on : .off
        stack.addArrangedSubview(newlinesCheck)

        let saveBtn = NSButton(title: "保存并应用", target: nil, action: nil)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        stack.addArrangedSubview(saveBtn)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        super.init(window: w)
        w.delegate = self
        // Key 按钮动作
        (keyButtons.arrangedSubviews[0] as! NSButton).target = self
        (keyButtons.arrangedSubviews[0] as! NSButton).action = #selector(saveKey)
        (keyButtons.arrangedSubviews[1] as! NSButton).target = self
        (keyButtons.arrangedSubviews[1] as! NSButton).action = #selector(deleteKey)
        saveBtn.target = self
        saveBtn.action = #selector(saveSettings)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// CHAT-08: accessory 应用窗口必须显式成为 key window 并聚焦输入框，
    /// 否则 ⌘V 会被系统路由到其他应用（表现为"粘贴不进去"）。
    func focusKeyField() {
        guard let w = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeKey()
        w.makeFirstResponder(keyField)
        AppLog.write("settings focus: keyWindow=\(w.isKeyWindow) firstResponder=\(String(describing: w.firstResponder))")
    }

    @objc private func saveKey() {
        let secret = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            statusLabel.stringValue = "请先粘贴 Key"; return
        }
        do {
            // CHAT-08 §4.2: App 自建专属条目 → Add/Update → 读回校验（save 内部已完成）
            try KeychainStore.save(secret)
            // C03-03: 保存 Key 时同步登记当前端点主机绑定
            var cfg = configLoader.load().config
            if let host = URL(string: cfg.endpoint)?.host {
                cfg.key_host = host
                configLoader.save(cfg)
            }
            keyField.stringValue = ""
            statusLabel.stringValue = "✔ Key 已保存到 App 专属钥匙串（读回校验通过）并绑定当前端点主机"
            onChange()
        } catch {
            statusLabel.stringValue = "保存失败：\(error)"
        }
    }

    @objc private func deleteKey() {
        KeychainStore.deleteOwned()
        statusLabel.stringValue = "Key 已从钥匙串删除"
        onChange()
    }

    @objc private func saveSettings() {
        var cfg = configLoader.load().config
        // CHAT-08 后续: 模型只由下拉决定（自定义框曾以旧值覆盖下拉，导致"切了没反应"——已移除）
        let selected = modelPopup.titleOfSelectedItem ?? "qwen3-asr-flash"
        if selected != cfg.model {
            statusLabel.stringValue = "模型已切换为 \(selected)（下一段录音生效）"
        }
        cfg.model = selected
        cfg.language = langField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.max_seconds = Double(maxSecField.stringValue) ?? cfg.max_seconds
        cfg.queue_limit = Int(queueField.stringValue) ?? cfg.queue_limit
        cfg.hotkey_keycode = UInt32(keycodeField.stringValue) ?? cfg.hotkey_keycode
        cfg.hotkey_modifiers = UInt32(modifiersField.stringValue) ?? cfg.hotkey_modifiers
        cfg.delivery_mode = ["auto", "preview", "copy"][modePopup.indexOfSelectedItem]
        cfg.enable_itn = itnCheck.state == .on
        cfg.keep_newlines = newlinesCheck.state == .on
        let warnings = cfg.validate()
        configLoader.save(cfg)
        statusLabel.stringValue = warnings.isEmpty ? "✔ 已保存并应用" : ("⚠️ " + warnings.joined(separator: "；"))
        onChange()
    }
}
