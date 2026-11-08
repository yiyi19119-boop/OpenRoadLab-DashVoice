# 贡献

- 构建：`scripts/build.sh`（仅 CLT，无需 Xcode）；测试：`swiftc -O Sources/DashVoiceCore/*.swift Sources/DashVoiceTests/main.swift -o /tmp/dv-tests && /tmp/dv-tests`
- 无签名也能跑源码构建；签名与权限见 [权限与签名](PERMISSIONS.md)
- PR 要求：离线测试全绿；不引入运行时第三方依赖；不动默认计费行为；日志不新增敏感内容
- 兼容底线：macOS 12+；不使用私有 API
