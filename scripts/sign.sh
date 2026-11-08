#!/bin/bash
# 签名（CHAT-08 §4.1）：固定证书指纹选择，禁止静默降级到 adhoc/无签名。
# 用法: scripts/sign.sh [--mode local|development|developer-id] [--bootstrap]
#   local        使用本机固定自签证书（必须已存在，--bootstrap 才生成一次）
#   development   Apple Development 证书
#   developer-id  Developer ID Application + runtime + timestamp + audio-input entitlement
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="local"; BOOTSTRAP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) [ $# -ge 2 ] || { echo "--mode 需要参数"; exit 2; }; MODE="$2"; shift 2 ;;
    --bootstrap) BOOTSTRAP=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1"; echo "用法: scripts/sign.sh [--mode local|development|developer-id] [--bootstrap]"; exit 2 ;;
  esac
done
APP=build/DashVoice.app
[ -d "$APP" ] || { echo "❌ 未找到 $APP，先运行 scripts/build.sh"; exit 1; }
if [ "$BOOTSTRAP" = 1 ] && [ -n "${PINNED_FP:-}" ]; then
  echo "ℹ️ 本机已固定签名身份（$PINNED_FP），--bootstrap 被忽略（不生成新证书）"
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Info.plist)

# CHAT-08 B1: 本机签名身份 pin（不硬编码某个人的证书指纹）
# 读取顺序：环境变量 > 本地 pin 文件 > 无（须 --bootstrap 或显式指定）
PIN_FILE="$HOME/Library/Application Support/DashVoice/signing-identity.txt"
if [ -n "${DASHVOICE_CERT_SHA1:-}" ]; then
  PINNED_FP="$DASHVOICE_CERT_SHA1"
elif [ -f "$PIN_FILE" ]; then
  PINNED_FP=$(head -1 "$PIN_FILE" | tr -d '[:space:]')
else
  PINNED_FP=""
fi

find_identity_by_fp() {  # 输出 "SHA1 CN" 行；按完整指纹精确匹配（不靠 CN）
  /usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)"/\1 \2/p' \
    | grep -i "^${PINNED_FP} " || true
}

# --bootstrap：仅当本机完全没有该指纹的证书时生成一次（之后不再生成）
if ! find_identity_by_fp | grep -q .; then
  if [ -n "$PINNED_FP" ] && [ "$BOOTSTRAP" = 1 ]; then
    echo "❌ 已有固定 pin ($PINNED_FP)，--bootstrap 不再生成新证书"
    echo "   如需更换身份：先人工确认并删除 $PIN_FILE"
    exit 3
  fi
  if [ "$MODE" = local ] && [ "$BOOTSTRAP" = 1 ]; then
    TMPD=$(mktemp -d)
    cat > "$TMPD/cnf" <<EOC
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = DashVoice Dev
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOC
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$TMPD/k.pem" -out "$TMPD/c.crt" -config "$TMPD/cnf" 2>/dev/null
    security import "$TMPD/k.pem" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign >/dev/null
    security import "$TMPD/c.crt" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign >/dev/null
    rm -rf "$TMPD"
    # CHAT-08 B1: 取得**新证书真实指纹**（不按旧 pin 检索——此前必空导致 exit3）
    NEW_FP=$(security find-identity -p codesigning -v 2>/dev/null \
      | sed -n 's/^[[:space:]]*[0-9]*) \([0-9A-F]\{40\}\) "DashVoice Dev"/\1/p' | head -1)
    [ -n "$NEW_FP" ] || { echo "❌ 生成后仍找不到 DashVoice Dev 证书"; exit 3; }
    mkdir -p "$(dirname "$PIN_FILE")"
    printf '%s\n' "$NEW_FP" > "$PIN_FILE"
    echo "✔ 已生成并固定本机签名身份：$NEW_FP（写入 $PIN_FILE）"
    PINNED_FP="$NEW_FP"
  elif [ -z "$PINNED_FP" ]; then
    echo "❌ 本机无签名身份（无 pin、无 DASHVOICE_CERT_SHA1）"
    echo "   首次生成：scripts/sign.sh --mode local --bootstrap（仅一次）"
    exit 3
  else
    echo "❌ 未找到指纹为 $PINNED_FP 的签名证书（不降级到 adhoc/无签名）"
    echo "   如需首次生成：scripts/sign.sh --mode local --bootstrap（仅一次）"
    exit 3
  fi
fi

CERT_CN=$(find_identity_by_fp | cut -d" " -f2-)

# 签名前记录
echo "== 签名前 =="
/usr/bin/codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" || echo "(未签名)"

EXTRA=(--timestamp=none)
if [ "$MODE" = "developer-id" ]; then
  mkdir -p build
  cat > build/entitlements.plist <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
  EXTRA=(--timestamp -o runtime --entitlements build/entitlements.plist)
fi

# 用完整指纹签名（codesign 支持 SHA1 识别证书）
/usr/bin/codesign --force --sign "$PINNED_FP" --identifier "$BUNDLE_ID" "${EXTRA[@]}" "$APP"

# 签名后严格验证：DR、证书叶指纹、严格校验
echo "== 签名后 =="
/usr/bin/codesign --verify --strict --verbose=2 "$APP" || { echo "❌ 严格校验失败"; exit 1; }
DR=$(/usr/bin/codesign -d -r- "$APP" 2>/dev/null | sed 's/^designated => //')
echo "DR: $DR"
echo "$DR" | grep -q "certificate leaf = H\"$(echo "$PINNED_FP" | tr 'A-Z' 'a-z')\"" \
  || echo "$DR" | grep -qi "certificate leaf = H\"$(echo "$PINNED_FP" | tr 'A-Z' 'a-z')\"" \
  || { echo "❌ DR 中的证书叶与固定指纹不一致（可能存在同名多证书）"; exit 1; }
echo "✅ 已签名: identity=$CERT_CN (fp=$PINNED_FP) bundle=$BUNDLE_ID mode=$MODE"
