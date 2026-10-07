#!/usr/bin/env bash
# backup-postgres.sh — PostgreSQL এর logical backup (pg_dump, custom format)
#
# ব্যবহার:  ./backup-postgres.sh
# Environment variable দিয়ে বদলানো যায় (সব optional):
#   CONTAINER=pg-prod  DB_USER=appuser  DB_NAME=appdb
#   BACKUP_DIR=/backups/postgres  RETENTION_DAYS=14
#
# cron (প্রতিদিন রাত ২:০০):
#   0 2 * * * /opt/scripts/backup-postgres.sh >> /var/log/pg-backup.log 2>&1
set -euo pipefail

CONTAINER="${CONTAINER:-pg-prod}"
DB_USER="${DB_USER:-appuser}"
DB_NAME="${DB_NAME:-appdb}"
BACKUP_DIR="${BACKUP_DIR:-/backups/postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date +%F_%H-%M)"
OUT="$BACKUP_DIR/${DB_NAME}_${STAMP}.dump"

mkdir -p "$BACKUP_DIR"

# Container চলছে কিনা যাচাই
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
  echo "❌ Container '$CONTAINER' চলছে না" >&2
  exit 1
fi

# -Fc = custom compressed format (pg_restore দিয়ে selective restore করা যায়)
docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$OUT"

# খালি backup হলে fail
if [ ! -s "$OUT" ]; then
  echo "❌ Backup খালি: $OUT" >&2
  rm -f "$OUT"
  exit 1
fi

# পুরোনো backup মুছে ফেলো
find "$BACKUP_DIR" -name "${DB_NAME}_*.dump" -mtime +"$RETENTION_DAYS" -delete

echo "✅ Backup সম্পন্ন: $OUT ($(du -h "$OUT" | cut -f1))"
