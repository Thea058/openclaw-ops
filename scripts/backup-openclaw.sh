#!/usr/bin/env bash
#
# OpenClaw 每日备份脚本
#
# 设计要点：
#   1. set -euo pipefail —— 任一命令失败立即退出，避免"部分成功"被误认为成功
#   2. --verify —— 归档生成后立即校验，不带校验的备份等于没有备份
#   3. 按时间清理（-mtime +30）而非"保留 N 份" —— 备份失败时不会误删唯一可用的旧备份
#   4. 日志追加而非覆盖 —— 保留历史，便于判断"从哪天开始失败的"
#
# 安装：
#   install -m 700 backup-openclaw.sh ~/bin/backup-openclaw.sh
#   crontab -e
#   17 4 * * * /home/ubuntu/bin/backup-openclaw.sh
#
# 注意：备份包含 DeepSeek API Key、飞书 App Secret、gateway token，
#      安全等级等同服务器本身。禁止上传网盘或提交 Git。

set -euo pipefail

BACKUP_DIR="/home/ubuntu/backups/openclaw"
LOG="$BACKUP_DIR/backup.log"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "[$(date -Iseconds)] backup start" >> "$LOG"
/usr/bin/openclaw backup create --output "$BACKUP_DIR" --verify >> "$LOG" 2>&1
echo "[$(date -Iseconds)] backup done" >> "$LOG"

find "$BACKUP_DIR" -name '*.tar.gz' -mtime +30 -delete
echo "[$(date -Iseconds)] prune done" >> "$LOG"
