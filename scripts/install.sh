#!/bin/bash
# 显式安装（DV-017/018）：校验来源 → 退出旧实例 → 备份 → 替换 → 失败回滚。
# 空格路径安全；绝不静默删除用户数据/Key。
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="/Applications/DashVoice.app"
SRC="build/DashVoice.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { echo "--target 需要一个路径参数"; exit 2; }
      TARGET="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1"; echo "用法: scripts/install.sh [--target /Applications/DashVoice.app]"; exit 2 ;;
  esac
done
[ -d "$SRC" ] || { echo "❌ 未找到 $SRC，先运行 scripts/build.sh"; exit 1; }
# Use codesign status directly; grep -q can terminate the pipe early under pipefail.
if codesign -dv "$SRC" >/dev/null 2>&1; then
  codesign --verify --strict "$SRC" 2>&1 || { echo "❌ 来源签名校验失败"; exit 1; }
  echo "✔ 来源签名校验通过"
else
  echo "⚠️ 来源未签名（开发构建）——建议先 scripts/sign.sh --mode local"
fi
# C03-05: staging 复制 → 原子交换 → 失败精确回滚（不嵌套、不按 ls 挑备份）
BAK_DIR="$HOME/Library/Application Support/DashVoice/backups"
mkdir -p "$BAK_DIR"
BAK="$BAK_DIR/DashVoice.app.bak-$(date +%Y%m%d-%H%M%S)"
STAGING="${TARGET}.staging-$$"
cleanup_staging() { rm -rf "$STAGING" 2>/dev/null || true; }
trap cleanup_staging EXIT

# 1) staging 复制（失败不触碰目标）
if ! ditto "$SRC" "$STAGING"; then
  echo "❌ 复制到 staging 失败（目标未动）"; exit 1
fi
[ -f "$STAGING/Contents/MacOS/DashVoice" ] || { echo "❌ staging 内容不完整（目标未动）"; exit 1; }

# 2) 停旧实例（精确匹配**目标路径**的二进制；自定义 target 不影响无关 App）
pkill -f "$TARGET/Contents/MacOS/DashVoice" 2>/dev/null || true
sleep 1

# 3) 原子交换：target→bak；staging→target
if [ -d "$TARGET" ]; then
  mv "$TARGET" "$BAK" || { echo "❌ 备份旧版失败（目标未动）"; exit 1; }
fi
if ! mv "$STAGING" "$TARGET"; then
  echo "❌ 安装失败，精确回滚..."
  rm -rf "$TARGET" 2>/dev/null || true        # 此时 target 至多是空壳/半成品，先移除
  if [ -d "$BAK" ]; then
    mv "$BAK" "$TARGET" && echo "✔ 旧版已恢复到原路径" || echo "❌ 回滚也失败！备份仍在: $BAK"
  fi
  exit 1
fi
trap - EXIT
# 备份压缩为 tar.gz（避免 Spotlight 索引到可执行副本），只留 2 份
if [ -d "$BAK" ]; then
  tar -czf "$BAK.tar.gz" -C "$BAK_DIR" "$(basename "$BAK")" 2>/dev/null && rm -rf "$BAK"
  BAK="$BAK.tar.gz"
fi
touch "$BAK_DIR/.metadata_never_index" 2>/dev/null || true
# 备份压缩为 tar.gz（避免 Spotlight 索引到可执行副本）
if [ -d "$BAK" ]; then
  tar -czf "$BAK.tar.gz" -C "$BAK_DIR" "$(basename "$BAK")" 2>/dev/null && rm -rf "$BAK"
  BAK="$BAK.tar.gz"
fi
touch "$BAK_DIR/.metadata_never_index" 2>/dev/null || true

# CHAT-08 B2: 清理只保留最近 2 份。
# - 无备份是正常情况，不能让清理失败影响已成功的安装
# - 用 here-doc 逐行读取（路径含空格安全），不用 ls|xargs 拆词
# - 只处理本 App 备份目录中明确前缀的 .tar.gz
prune_backups() {
  [ -d "$BAK_DIR" ] || return 0
  local list
  list=$(ls -1t "$BAK_DIR"/DashVoice.app.bak-*.tar.gz 2>/dev/null || true)
  [ -n "$list" ] || return 0
  local i=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    if [ "$i" -gt 2 ]; then
      rm -f -- "$f" || true
    fi
  done <<PRUNE_EOF
$list
PRUNE_EOF
  return 0
}
prune_backups || true
# 钥匙串：不在安装期改写 ACL（DV-049：Key 不得经命令行参数）。
# 稳定签名 DR 下，App 首次读取 Key 时弹一次确认，选『始终允许』即跨构建保持。
# Brace variables before non-ASCII punctuation for older Bash compatibility.
printf '%s\n' \
  "（旧版备份: ${BAK}）" \
  "✅ 已安装: ${TARGET}（首次运行请由用户本人从 Spotlight/Finder 启动；麦克风/辅助功能授权各一次；读 Key 弹窗选『始终允许』）"
