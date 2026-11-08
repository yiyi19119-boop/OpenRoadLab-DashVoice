import Foundation

/// 用户配置（DV-052/053）：版本化、缺字段兼容、非法不覆盖、无强制解包。
public struct VoiceConfig: Codable, Equatable {
    /// B04: 允许自动迁移绑定的官方主机白名单
    public static let knownBindingHosts: Set<String> = [
        "dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com"
    ]
    public static let currentVersion = 2

    public var version: Int = VoiceConfig.currentVersion
    public var endpoint: String = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    public var model: String = "qwen3-asr-flash"
    public var language: String = "zh"
    public var enable_itn: Bool = true
    public var context: String = ""            // 保留字段：compatible-mode 当前不接受文本输入
    public var hotkey_keycode: UInt32 = 49     // kVK_Space
    public var hotkey_modifiers: UInt32 = 2048 // Carbon optionKey → ⌥Space
    public var max_seconds: Double = 60
    public var keep_newlines: Bool = false
    public var delivery_mode: String = "auto"  // auto | preview | copy
    public var queue_limit: Int = 3            // 有界处理队列（DV-028）
    public var warmup_asr: Bool = false        // DV-047：默认不发付费静音请求
    public var key_host: String? = nil         // F07/DV-051：Key 绑定主机（保存 Key 时登记）
    public var float_button: Bool? = true
    public var float_x: Double? = nil
    public var float_y: Double? = nil

    enum CodingKeys: String, CodingKey {
        case version, endpoint, model, language, enable_itn, context
        case hotkey_keycode, hotkey_modifiers, max_seconds, keep_newlines
        case delivery_mode, queue_limit, warmup_asr, key_host
        case float_button, float_x, float_y
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? VoiceConfig.currentVersion
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? VoiceConfig().endpoint
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? VoiceConfig().model
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? VoiceConfig().language
        enable_itn = try c.decodeIfPresent(Bool.self, forKey: .enable_itn) ?? true
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        hotkey_keycode = try c.decodeIfPresent(UInt32.self, forKey: .hotkey_keycode) ?? 49
        hotkey_modifiers = try c.decodeIfPresent(UInt32.self, forKey: .hotkey_modifiers) ?? 2048
        max_seconds = try c.decodeIfPresent(Double.self, forKey: .max_seconds) ?? 60
        keep_newlines = try c.decodeIfPresent(Bool.self, forKey: .keep_newlines) ?? false
        delivery_mode = try c.decodeIfPresent(String.self, forKey: .delivery_mode) ?? "auto"
        queue_limit = try c.decodeIfPresent(Int.self, forKey: .queue_limit) ?? 3
        warmup_asr = try c.decodeIfPresent(Bool.self, forKey: .warmup_asr) ?? false
        key_host = try c.decodeIfPresent(String.self, forKey: .key_host)
        float_button = try c.decodeIfPresent(Bool.self, forKey: .float_button) ?? true
        float_x = try c.decodeIfPresent(Double.self, forKey: .float_x)
        float_y = try c.decodeIfPresent(Double.self, forKey: .float_y)
    }

    /// 校验+钳制（DV-052）：非法值就地修正并返回警告列表，不抛错不崩溃
    @discardableResult
    public mutating func validate() -> [String] {
        var warnings: [String] = []
        if let url = URL(string: endpoint), let scheme = url.scheme?.lowercased() {
            if scheme != "https" {
                endpoint = VoiceConfig().endpoint
                warnings.append("endpoint 非 HTTPS，已回退默认端点")
            }
        } else {
            endpoint = VoiceConfig().endpoint
            warnings.append("endpoint 非法，已回退默认端点")
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            model = VoiceConfig().model; warnings.append("model 为空，已回退默认")
        }
        if language.trimmingCharacters(in: .whitespaces).isEmpty {
            language = "zh"; warnings.append("language 为空，已回退 zh")
        }
        max_seconds = min(max(max_seconds, 5), 300)     // API 上限 300s
        queue_limit = min(max(queue_limit, 1), 10)
        if !["auto", "preview", "copy"].contains(delivery_mode) {
            delivery_mode = "auto"; warnings.append("delivery_mode 非法，已回退 auto")
        }
        return warnings
    }
}

/// 配置读写（含坏文件备份与不覆盖语义）
public final class ConfigLoader {
    public let fileURL: URL
    private let backupURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.backupURL = fileURL.deletingPathExtension().appendingPathExtension("json.bad")
    }

    /// 读取；解析失败时把原文件移为 .json.bad 再返回默认（不静默覆盖丢失原件）
    public func load() -> (config: VoiceConfig, warnings: [String]) {
        var warnings: [String] = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            var cfg = VoiceConfig()
            cfg.key_host = URL(string: cfg.endpoint)?.host   // B04: 默认官方端点一次可用
            save(cfg)
            return (cfg, warnings)
        }
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(VoiceConfig.self, from: data) {
            var mutable = cfg
            warnings += mutable.validate()
            // B04: 迁移仅限**已知官方 DashScope 主机**；未知/自定义主机不自动绑定
            //（不自动给任意新主机授权旧 Key——需用户显式确认，如设置窗保存 Key 或手写 key_host）
            if (mutable.key_host ?? "").isEmpty, let host = URL(string: mutable.endpoint)?.host,
               VoiceConfig.knownBindingHosts.contains(host) {
                mutable.key_host = host
                warnings.append("已迁移登记 key_host=\(host)（官方主机；换主机需显式更新绑定）")
            }
            save(mutable)
            return (mutable, warnings)
        }
        // 坏 JSON：备份原件，不覆盖语义（原件移走，新默认写入）
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        let cfg = VoiceConfig()
        save(cfg)
        warnings.append("配置文件解析失败，原件已备份为 \(backupURL.lastPathComponent)，已载入默认配置")
        return (cfg, warnings)
    }

    public func save(_ config: VoiceConfig) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
