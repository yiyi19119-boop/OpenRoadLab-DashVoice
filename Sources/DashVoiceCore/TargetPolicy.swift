import Foundation

/// 自动键入目标策略（F02 强化）：**元素级身份** + 正向白名单 + 安全输入排除。
/// 原则：
/// - 原可编辑元素身份必须可确认；不可确认（nil）或与当前不一致 → 停止转预览，不按 pid+role 猜测
/// - 同一 App 内换聊天/标签/输入框 → 元素身份变化 → 停止
/// - 密码控件：role=AXSecureTextField 或 subrole=kAXSecureTextFieldSubrole 均拒绝
/// - AXWebArea 是网页容器非可编辑输入 → 不在白名单
public struct TargetPolicy {
    /// 允许自动键入的 AX 角色（正向白名单；未知/读取失败一律不自动键入）
    public static let allowedRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox"
    ]
    /// Apple 文档：kAXSecureTextFieldSubrole
    public static let secureSubrole = "AXSecureTextField"
    public static let secureRole = "AXSecureTextField"

    public struct TargetIdentity: Equatable {
        public var pid: pid_t
        public var role: String?
        public var subrole: String?
        /// 原可编辑元素的稳定标识（AXFocus 层用 CFHash（AXUIElement））；
        /// nil = 身份不可确认（自绘应用如微信不暴露 AX 元素）
        public var elementHash: Int?
        public init(pid: pid_t, role: String?, subrole: String? = nil, elementHash: Int? = nil) {
            self.pid = pid; self.role = role; self.subrole = subrole
            self.elementHash = elementHash
        }
    }

    public enum Verdict: Equatable {
        case allowed
        case stopToPreview(reason: String)
    }

    /// 每批键入前校验（CHAT-08 FINAL AUDIT B01 收紧版）。
    /// 元素身份不可读（自绘应用如微信）→ **一律剪贴板**，无 pid 猜测放行。
    /// 原身份可读时：严格元素比对（拦截同 App 换输入框/标签）+ secure input 额外拒绝。
    public static func verdict(original: TargetIdentity,
                               current: TargetIdentity?,
                               secureInputEnabled: Bool = false) -> Verdict {
        if secureInputEnabled {
            return .stopToPreview(reason: "系统安全输入已启用（密码/敏感输入）")
        }
        // 元素身份不可读 → 剪贴板（无猜测放行；微信等自绘应用不支持自动键入）
        guard let oh = original.elementHash, oh != 0 else {
            return .stopToPreview(reason: "原目标元素身份不可确认（该应用不支持自动键入）")
        }
        guard let current else {
            return .stopToPreview(reason: "焦点元素不可读取")
        }
        guard current.pid == original.pid else {
            return .stopToPreview(reason: "前台应用已切换")
        }
        guard let ch = current.elementHash, ch != 0, ch == oh else {
            return .stopToPreview(reason: "焦点已离开原输入元素（同应用切换输入框）")
        }
        guard let role = current.role, allowedRoles.contains(role) else {
            return .stopToPreview(reason: "焦点控件不可自动键入（role=\(current.role ?? "nil")）")
        }
        if let sub = current.subrole, sub == secureSubrole {
            return .stopToPreview(reason: "密码控件禁止自动键入")
        }
        return .allowed
    }

    /// 便捷判定：该身份是否密码控件（供 UI 展示与测试引用）
    public static func isSecure(_ t: TargetIdentity) -> Bool {
        t.role == secureRole || t.subrole == secureSubrole
    }
}
