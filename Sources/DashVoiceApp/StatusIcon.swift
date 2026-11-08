import AppKit

/// 待机使用品牌图标，录音和处理保留彩色状态提示。
enum StatusIcon {
    enum Kind { case idle, recording, processing }

    static func make(_ kind: Kind) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if kind == .idle,
           let url = Bundle.main.url(forResource: "DashVoiceMenuBar", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = size
            icon.isTemplate = true
            return icon
        }

        let img = NSImage(size: size, flipped: false) { rect in
            let color: NSColor
            switch kind {
            case .idle: color = .labelColor
            case .recording: color = .systemRed
            case .processing: color = .controlAccentColor
            }
            color.setStroke(); color.setFill()

            // 麦克风主体：圆头 + 支架
            let capsule = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 7.5, width: 5, height: 8),
                                       xRadius: 2.5, yRadius: 2.5)
            capsule.fill()
            // 底座弧
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 8), radius: 5,
                          startAngle: 200, endAngle: 340, clockwise: false)
            arc.lineWidth = 1.6
            arc.stroke()
            // 竖杆 + 底脚
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 9, y: 3))
            stem.line(to: NSPoint(x: 9, y: 1.6))
            stem.lineWidth = 1.6
            stem.stroke()
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 6.4, y: 1.6))
            base.line(to: NSPoint(x: 11.6, y: 1.6))
            base.lineWidth = 1.6
            base.stroke()

            // 录音态：右上角红点；处理态：右下角小方块
            if kind == .recording {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 12.5, width: 4.5, height: 4.5)).fill()
            } else if kind == .processing {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 1.5, width: 4, height: 4)).fill()
            }
            _ = rect
            return true
        }
        img.isTemplate = false
        return img
    }
}
