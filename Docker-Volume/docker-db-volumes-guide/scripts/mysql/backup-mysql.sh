#!/usr/bin/env bash
# backup-mysql.sh — MySQL এর logical backup (mysqldump, gzip করা)
#
# ব্যবহার:  ./backup-mysql.sh
# Environment variable (সব optional):
#   CONTAINER=mysql-prod  DB_NAME=appdb
#   BACKUP_DIR=/backups/mysql  RETENTION_DAYS=14
#
# Root password container এর ভেতর থেকেই পড়া হয়:
#   MYSQL_ROOT_PASSWORD env থাকলে সেটা, না থাকলে /run/secrets/mysql_root_password (Docker secret)।
# তাই host এ password লাগে না, command line এও password দেখা যায় না।
#
# cron (প্রতিদিন রাত ২:১০):
#   10 2 * * * /opt/scripts/backup-mysql.sh >> /var/log/mysql-backup.log 2>&1
set -euo pipefail

CONTAINER="${CONTAINER:-mysql-prod}"
DB_NAME="${DB_NAME:-appdb}"
BACKUP_DIR="${BACKUP_DIR:-/backups/mysql}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date +%F_%H-%M)"
OUT="$BACKUP_DIR/${DB_NAME}_${STAMP}.sql.gz"
TMP="$OUT.tmp"

mkdir -p "$BACKUP_DIR"
trap 'rm -f "$TMP"' EXIT          # মাঝপথে fail করলে আধখানা file মুছে যাবে

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
  echo "❌ Container '$CONTAINER' চলছে না" >&2
  exit 1
fi

# --single-transaction : InnoDB এ table lock ছাড়াই consistent snapshot
# --routines --triggers: stored procedure ও trigger ও backup এ থাকবে
# MYSQL_PWD            : password কে process list এ দেখানো থেকে বাঁচায়
docker exec "$CONTAINER" sh -c '
  export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat /run/secrets/mysql_root_password)}"
  mysqldump -uroot --single-transaction --routines --triggers "$1"
' sh "$DB_NAME" | gzip > "$TMP"

# gzip করা খালি input ও কিছু bytes হয়, তাই মাপ দেখে যাচাই করা যথেষ্ট নয়;
# decompress করে আসল content আছে কিনা দেখো
if ! gunzip -c "$TMP" | head -c 1 | grep -q .; then
  echo "❌ Backup খালি" >&2
  exit 1
fi

mv "$TMP" "$OUT"
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +"$RETENTION_DAYS" -delete

echo "✅ Backup সম্পন্ন: $OUT ($(du -h "$OUT" | cut -f1))"
