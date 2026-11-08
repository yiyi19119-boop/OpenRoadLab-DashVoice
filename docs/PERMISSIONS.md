# 权限与签名说明

## 运行所需系统权限
| 权限 | 用途 | 授予时机 |
|---|---|---|
| 麦克风 | 录音 | 首次录音弹窗；拒绝后可在 系统设置→隐私与安全性→麦克风 恢复 |
| 辅助功能 | 把转写文字键入目标应用 | 系统设置→隐私与安全性→辅助功能 手动添加 |

## 签名身份（重要）
TCC 用代码签名的 designated requirement 记忆授权。本仓库 scripts/build.sh 产出**未签名**包；
scripts/sign.sh --mode local 用本机自签证书（DashVoice Dev，可 --bootstrap 生成）签名——
同一证书+同一 bundle ID 的重编译会保留已授予的权限；换证书/换 bundle ID 需重新授权。
当前提供源码 Beta。本地自签仅用于自己构建和安装。

## 钥匙串
DashScope Key 存于登录钥匙串（service=com.dashvoice2.app.credentials），不落盘、不进日志。
首次读取会弹确认框，选**始终允许**（稳定签名下此授权跨构建保持）。
可在应用设置中保存或删除专用条目。
