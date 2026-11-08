#!/bin/bash
# 卸载（DV-072）：精确退出 + 移除自启；App/数据/Key 分项选择，不误删。
set -uo pipefail
PLIST="$HOME/Library/LaunchAgents/com.dashvoice.app.plist"
[ -f "$PLIST" ] && launchctl unload "$PLIST" 2>/dev/null
rm -f "$PLIST"
pkill -f "/Applications/DashVoice.app/Contents/MacOS/DashVoice" 2>/dev/null
echo "✅ 已退出并移除开机自启。"
read -rp "删除 /Applications/DashVoice.app？[y/N] " a
case "$a" in [Yy]*) rm -rf /Applications/DashVoice.app; echo "  已删除 App";; esac
read -rp "删除配置目录 ~/Library/Application Support/DashVoice？[y/N] " b
case "$b" in [Yy]*) rm -rf "$HOME/Library/Application Support/DashVoice"; echo "  已删除配置";; esac
read -rp "删除钥匙串中的 DashVoice API Key？[y/N] " c
case "$c" in [Yy]*) security delete-generic-password -s com.dashvoice2.app.credentials -a asr.default && echo "  已删除 Key";; esac
echo "提示：麦克风/辅助功能授权记录可用 系统设置 手动移除，或 tccutil reset Microphone com.dashvoice2.app（会重置该 App 的对应授权）。"
