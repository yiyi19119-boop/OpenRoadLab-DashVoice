import AVFoundation
import AppKit
import ApplicationServices
import Carbon

/// 麦克风权限状态处理（DV-024）：四态一次处理，不循环弹窗/不开设置风暴。
enum MicPermission {
    case notDetermined, granted, denied, restricted

    static var current: MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// 请求授权（仅 notDetermined 时调用一次）
    static func request(_ completion: @escaping (MicPermission) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted ? .granted : .denied)
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

/// AX 焦点读取：role + subrole + 元素身份（CFHash）。
/// elementHash=nil 表示身份不可确认——策略层会因此转预览（F02）。
enum AXFocus {
    /// CHAT-08: AX 消息超时（秒）。对 Electron/Chromium 等应用，AX 查询可能
    /// 长时间等待其建树；不设超时会阻塞调用线程（实测主线程进入不可中断等待）。
    private static let messagingTimeout: Float = 1.0

    private static func timed(_ el: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }

    /// 直接读取系统级焦点元素（原生 App 路径）。
    /// CHAT-08 补充：Firefox/微信等应用，系统焦点返回**容器**（AXGroup/AXWindow），
    /// 输入框挂在容器内部 → 对容器再查 AXFocusedUIElement 向内钻取（AX 标准属性）。
    static func readTarget() -> TargetPolicy.TargetIdentity? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(timed(AXUIElementCreateSystemWide()),
                                                kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let el = value else {
            AppLog.write("AX focus unavailable: trusted=\(AXIsProcessTrusted()) error=\(err.rawValue)")
            return nil
        }
        var element = el as! AXUIElement
        // 容器角色 → 向内钻取（最多 3 层：Group→Group→Input；无变化则跳出防循环）
        for _ in 0..<3 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard let r = role as? String,
                  ["AXGroup", "AXWindow", "AXScrollArea", "AXSplitGroup"].contains(r) else { break }
            var inner: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString,
                                                &inner) == .success, let ie = inner else { break }
            let innerEl = ie as! AXUIElement
            if CFEqual(innerEl, element) { break }
            element = innerEl
        }
        return identity(from: element)
    }

    /// CHAT-08 §5：Electron/Chromium 官方兼容路径。
    /// 对**热键触发时选定的前台 pid**（不扫描、不硬编码应用名）设置
    /// AXManualAccessibility=true，随后有界重读（≤3 次 / ≤1s，非主线程）。
    /// - Parameter pid: 热键触发时捕获的前台目标 pid
    /// - Returns: 仅当取得的元素 pid 仍等于该目标时返回；否则 nil（焦点已变，放弃）
    static func readTargetWithElectronCompat(pid: pid_t, deadline: TimeInterval = 1.0) -> TargetPolicy.TargetIdentity? {
        // ① 先走正常路径——但 role 必须可键入：
        //    Firefox 实测：系统焦点返回 AXWindow（pid 匹配但非输入控件），
        //    若此处直接返回，后续 verdict 必拒且树遍历永不触发。
        if let t = readTarget(), t.pid == pid,
           let r = t.role, TargetPolicy.allowedRoles.contains(r) {
            return t
        }
        guard AXIsProcessTrusted() else {
            AppLog.write("electron compat skipped: AX not trusted")
            return nil
        }
        // ② 兼容接口：按目标类型尝试
        //   - Electron/Chromium 系：AXManualAccessibility（Electron 官方）
        //   - Chrome / Safari 等：AXEnhancedUserInterface（Chromium 启用完整 AX 树的开关）
        //   仅对已选定 pid 设置一次，逐个记录返回码
        let axApp = timed(AXUIElementCreateApplication(pid))
        var anyAccepted = false
        for attr in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let r = AXUIElementSetAttributeValue(axApp, attr as CFString, kCFBooleanTrue)
            AppLog.write("AX compat \(attr) pid=\(pid) result=\(r.rawValue)")
            if r == .success { anyAccepted = true }
        }
        guard anyAccepted else { return nil }
        // ③ 有界重读（Electron 建树异步；非阻塞主线程——调用点保证在后台）
        let start = Date()
        for attempt in 1...3 {
            if Date().timeIntervalSince(start) > deadline { break }
            usleep(300_000)
            if let t = readTarget(), t.pid == pid {
                AppLog.write("ax compat ok pid=\(pid) attempt=\(attempt) role=\(t.role ?? "nil")")
                return t
            }
            // 焦点若已变化立即放弃（不把新焦点当旧目标）
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                AppLog.write("ax compat aborted: frontmost changed")
                return nil
            }
        }
        // ④ CHAT-08 补充：部分应用（如微信/Firefox）不把输入框挂到系统焦点链上，
        //    遍历其 AX 树（优先 focused window，失败则 app 全树），只接受可编辑角色
        if let t = findFocusedEditableInWindow(pid: pid) {
            AppLog.write("ax tree walk ok pid=\(pid) role=\(t.role ?? "nil")")
            return t
        }
        AppLog.write("ax compat failed: element not exposed (system focus + tree walk)")
        return nil
    }

    /// 在目标应用的 focused window 内遍历 AX 树，找 AXFocused=true 的可编辑元素。
    /// 有界：最大深度 10、最多访问 500 个节点；只接受白名单角色。
    private static func findFocusedEditableInWindow(pid: pid_t) -> TargetPolicy.TargetIdentity? {
        let axApp = timed(AXUIElementCreateApplication(pid))
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return nil }
        var visited = 0
        var result: AXUIElement?
        func search(_ el: AXUIElement, _ depth: Int) {
            guard result == nil, depth <= 10, visited < 500 else { return }
            visited += 1
            _ = timed(el)
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            let roleStr = role as? String
            if let r = roleStr, TargetPolicy.allowedRoles.contains(r) {
                var focusedRef: CFTypeRef?
                let okF = AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &focusedRef) == .success
                let isFocused = (focusedRef as? Bool) ?? false
                if okF && isFocused { result = el; return }
            }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                  let arr = kids as? [AXUIElement] else { return }
            for k in arr { search(k, depth + 1) }
        }
        search(win as! AXUIElement, 0)
        guard let found = result else { return nil }
        return identity(from: found)
    }

    private static func identity(from element: AXUIElement) -> TargetPolicy.TargetIdentity? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        _ = timed(element)
        var role: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return TargetPolicy.TargetIdentity(
            pid: pid,
            role: r1 == .success ? (role as? String) : nil,
            subrole: r2 == .success ? (subrole as? String) : nil,
            elementHash: Int(CFHash(element)))
    }
}

/// macOS 标准安全输入检测（作为额外拒绝信号，不作为放行条件）
enum SecureInput {
    static var isEnabled: Bool { IsSecureEventInputEnabled() }
}
