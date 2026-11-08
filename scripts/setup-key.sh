#!/bin/bash
# DashScope Key 存入钥匙串（路径无关，DV-070）。Key 不落盘、不进参数。
set -euo pipefail
SERVICE="com.dashvoice2.app.credentials"
ACCOUNT="asr.default"
echo "== 大声说 · DashScope API Key 配置 =="
echo "在 https://bailian.console.aliyun.com → API-KEY 管理 创建/复制 Key（建议独立 Key）。"
if security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
  read -rp "已存在 Key，覆盖？[y/N] " yn
  case "$yn" in [Yy]*) ;; *) echo "已取消"; exit 0 ;; esac
fi
# F08: -U = 已存在则更新（Key 轮换路径实测可用），不存在则新建
security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -T /usr/bin/security -U -w
security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w >/dev/null 2>&1 \
  && echo "✅ Key 已存入 App 专属钥匙串 (service=$SERVICE account=$ACCOUNT)。App 首次读取时若弹确认框，选『始终允许』。" \
  || { echo "❌ 写入失败"; exit 1; }
