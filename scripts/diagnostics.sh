#!/bin/bash
# 只读权限与身份诊断（DV-015）：不改任何状态。
APP="/Applications/DashVoice.app"
echo "== 1. 安装与身份 =="
[ -d "$APP" ] && /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" || echo "未安装: $APP"
codesign -dvvv "$APP" 2>&1 | grep -E "Identifier=|Authority|TeamIdentifier|CDHash" || echo "（无签名）"
codesign -d -r- "$APP" 2>&1 | tail -1
codesign --verify --strict "$APP" 2>&1 && echo "verify: OK" || echo "verify: FAIL"
echo "== 2. Gatekeeper 评估 =="
spctl -a -vv "$APP" 2>&1 || true
echo "== 3. LaunchAgent =="
PLIST="$HOME/Library/LaunchAgents/com.dashvoice.app.plist"
[ -f "$PLIST" ] && { echo "存在: $PLIST"; /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST"; } || echo "未安装自启"
echo "== 4. 运行中进程 =="
pgrep -fl "DashVoice.app" || echo "未运行"
echo "== 5. 应用日志尾部（无 Key/转写内容） =="
tail -15 "$HOME/Library/Logs/dashvoice.log" 2>/dev/null || echo "无日志"
echo "== 6. TCC 数据库（需要终端完全磁盘访问权限；只读） =="
sqlite3 -readonly -header -column "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, auth_value, datetime(last_modified,'unixepoch','localtime') m FROM access WHERE service='kTCCServiceMicrophone' AND client LIKE '%dashvoice%';" 2>&1 | head -5
echo "== 7. tccd 请求日志（需 sudo，按需手动运行） =="
echo "   sudo log show --last 10m --style compact --predicate 'subsystem == \"com.apple.TCC\"' | grep -iE 'dashvoice|AUTHREQ|prompt' | tail -30"
