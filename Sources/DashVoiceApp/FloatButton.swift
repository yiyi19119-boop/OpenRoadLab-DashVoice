import AppKit

/// 悬浮麦克风按钮（DV-066 评估后落地，非激活面板：点击不抢焦点）
final class FloatMicButtonView: NSView {
    private let icon = NSImageView()

    enum Look { case idle, recording, transcribing, failed }

    init(onClick: @escaping () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        wantsLayer = true
        layer?.cornerRadius = 28
        icon.frame = bounds.insetBy(dx: 14, dy: 14)
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        self.onClick = onClick
        set(look: .idle)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var onClick: () -> Void = {}
    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    /// 非激活窗口的首次点击也要响应
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, let w = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !didDrag && hypot(dx, dy) > 3 { didDrag = true }
        guard didDrag else { return }
        // 跟随光标移动（保持按下点与窗口的相对位置）
        w.setFrameOrigin(NSPoint(x: now.x - bounds.width / 2, y: now.y - bounds.height / 2))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil; didDrag = false }
        guard !didDrag else {
            (window?.delegate as? FloatMicPanel)?.onMoved?()   // 拖动结束保存位置
            return
        }
        AppLog.write("float button clicked")
        onClick()
    }

    func set(look: Look) {
        let symbol = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        switch look {
        case .idle:
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
            icon.image = NSImage(systemSymbolName: "mic.fill",
                                 accessibilityDescription: "大声说")?.withSymbolConfiguration(symbol)
            icon.contentTintColor = .white
        case .recording:
            layer?.backgroundColor = NSColor.systemRed.cgColor
            icon.image = NSImage(systemSymbolName: "mic.fill",
                                 accessibilityDescription: "录音中")?.withSymbolConfiguration(symbol)
            icon.contentTintColor = .white
        case .transcribing:
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            icon.image = NSImage(systemSymbolName: "waveform",
                                 accessibilityDescription: "识别中")?.withSymbolConfiguration(symbol)
            icon.contentTintColor = .white
        case .failed:
            layer?.backgroundColor = NSColor.systemOrange.cgColor
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                 accessibilityDescription: "出错")?.withSymbolConfiguration(symbol)
            icon.contentTintColor = .white
        }
    }
}

final class FloatMicPanel: NSPanel, NSWindowDelegate {
    var onMoved: (() -> Void)?
    init(at point: NSPoint, content: FloatMicButtonView) {
        super.init(contentRect: NSRect(origin: point, size: NSSize(width: 56, height: 56)),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        delegate = self
        contentView = content
    }
    func windowDidMove(_ notification: Notification) { onMoved?() }
}
