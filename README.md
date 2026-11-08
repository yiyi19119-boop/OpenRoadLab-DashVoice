# 大声说 DASHVOICE

[English README](README.en.md)

大声说是一个 macOS 菜单栏语音输入工具。按 `⌥Space` 开始录音，再按一次停止。它会把录音发到阿里云百炼转成文字，并将结果键入原输入框。无法确认输入框时，结果复制到剪贴板。

这是 **MIT 源码 Beta**。开发实测环境为 macOS 13 Ventura / Intel，最低系统版本声明为 macOS 12。Apple Silicon 和其他 macOS 版本尚未验证。

## 首发宣言

> **《大声说 DASHVOICE：对硅基世界的一次物理越权》**
>
> 自图灵时代起，人类就在委屈自己。为了迎合死板的机器，我们发明了汇编、C++，把鲜活的思想压缩成几行干瘪的 Prompt。我们小心翼翼地敲击键盘，生怕多打了一个空格。
>
> 但时代变了。当 Transformer 承载着几千亿参数的暴力算力降临，**机器的阅读理解能力，早已超越了人类的打字速度。**
>
> 「大声说 DASHVOICE」诞生于一台早已落后于时代的 Intel Mac。它拒绝妥协，硬生生凿穿了 Chrome、Firefox 甚至是微信的底层沙箱封锁。它的逻辑极其狂妄：**既然 AI 算力无穷，凭什么还要人类去精简语言？**
>
> 把那些寒暄、前因后果、碎碎念，统统大声说出来。**因为废话，就是喂给 Agent 最顶级的上下文；含糊的指令，才是赛博灾难的源头。**
>
> 这不仅是一个语音输入法，这是人类向机器递交的休战协议：**自然语言即最高指令，让机器去适应人的狂野，而不是人去适应机器的死板。**

上面是品牌宣言。预览版通过 macOS 辅助功能确认输入目标，能确认才自动键入。微信等无法确认目标的场景使用剪贴板。

## 从源码构建

需要 Xcode Command Line Tools 和自己的阿里云百炼 DashScope API Key。

```bash
git clone https://github.com/yiyi19119-boop/OpenRoadLab-DashVoice.git
cd OpenRoadLab-DashVoice
scripts/build.sh
```

构建生成 `build/DashVoice.app`。如需签名并安装到 `/Applications`，可在本机运行：

```bash
scripts/sign.sh --mode local --bootstrap
scripts/install.sh
open /Applications/DashVoice.app
```

首次录音时允许麦克风权限。若要启用自动键入，在系统设置的「隐私与安全性 → 辅助功能」中添加 DashVoice。进入菜单栏「设置」填写你自己的 API Key。应用将它保存到专用钥匙串条目；源码未内置 Key。

## 使用与限制

- 点击菜单栏图标、悬浮按钮或按 `⌥Space` 开始和停止录音。停止后收到的文字可以自动键入、预览或复制。
- 自动键入前逐批核对原输入框。切换焦点、进入安全输入或目标不可读时，停止自动键入。微信等无法读取输入框的应用可用剪贴板。
- 默认模型为 `qwen3-asr-flash`。模型设置保留；`qwen-audio-3.1-asr-flash` 是预留项，当前兼容接口未接通，日常使用请选择默认模型。
- 录音会发送到配置的识别服务；云端费用按你自己的账户计费。见[隐私与数据](docs/PRIVACY.md)和[权限与签名](docs/PERMISSIONS.md)。

## 离线测试

```bash
swiftc -O Sources/DashVoiceCore/*.swift Sources/DashVoiceTests/main.swift -o /tmp/dv-tests
/tmp/dv-tests
```

离线测试不需要真实 API Key。使用问题可查阅[排障指南](docs/TROUBLESHOOTING.md)，安全问题见[报告说明](docs/SECURITY.md)。

## 许可证

[MIT](LICENSE) © OpenRoad Lab。
