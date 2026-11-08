#!/bin/bash
# 纯构建：编译打包到 build/DashVoice.app（DV-009/010/011/012）
# 不签名、不生成证书、不动钥匙串、不安装、不联网、不发请求。
set -euo pipefail
cd "$(dirname "$0")/.."                       # DashVoice 根（任意路径/含空格均安全，DV-070）
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1"; echo "用法: scripts/build.sh [--quiet]"; exit 2 ;;
  esac
  shift
done

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Info.plist)  # 单一来源（DV-011）
APP=build/DashVoice.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tests

[ "$QUIET" = 0 ] && echo "[build] swiftc 编译（Core+App）..."
swiftc -O \
  Sources/DashVoiceCore/*.swift \
  Sources/DashVoiceApp/*.swift \
  -o "$APP/Contents/MacOS/DashVoice" \
  -framework AppKit -framework AVFoundation -framework ApplicationServices \
  -framework Carbon -framework CoreGraphics -framework UserNotifications -framework Security

cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/DashVoice.icns Support/DashVoiceMenuBar.png "$APP/Contents/Resources/"
BUILT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[ "$BUILT_ID" = "$BUNDLE_ID" ] || { echo "❌ 构建后 ID 不一致: $BUILT_ID != $BUNDLE_ID"; exit 1; }

# 冒烟验证：可执行文件存在且可运行 --version 无此功能，改验 bundle 完整
[ -x "$APP/Contents/MacOS/DashVoice" ] || { echo "❌ 可执行文件缺失"; exit 1; }
if [ "$QUIET" = 0 ]; then
  echo "✅ 构建完成: $APP (bundle=$BUNDLE_ID, 未签名——签名用 scripts/sign.sh)"
fi
exit 0
