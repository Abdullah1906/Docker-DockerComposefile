#!/usr/bin/env bash
# backup-mongodb.sh — MongoDB এর logical backup (mongodump --archive --gzip)
#
# ব্যবহার:  ./backup-mongodb.sh
# Environment variable (সব optional):
#   CONTAINER=mongo-prod  MONGO_USER=admin
#   BACKUP_DIR=/backups/mongodb  RETENTION_DAYS=14
#
# Password container এর ভেতর থেকে পড়া হয়:
#   MONGO_INITDB_ROOT_PASSWORD env থাকলে সেটা, না থাকলে /run/secrets/mongo_root_password।
# ⚠️ mongodump এ password argument হিসেবে যায়, তাই শুধু container এর ভেতরের process list এ
#    ক্ষণিকের জন্য দেখা যায়; host এর history/ps এ নয়।
#
# cron (প্রতিদিন রাত ২:২০):
#   20 2 * * * /opt/scripts/backup-mongodb.sh >> /var/log/mongo-backup.log 2>&1
set -euo pipefail

CONTAINER="${CONTAINER:-mongo-prod}"
MONGO_USER="${MONGO_USER:-admin}"
BACKUP_DIR="${BACKUP_DIR:-/backups/mongodb}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date +%F_%H-%M)"
OUT="$BACKUP_DIR/mongo_${STAMP}.archive.gz"
TMP="$OUT.tmp"

mkdir -p "$BACKUP_DIR"
trap 'rm -f "$TMP"' EXIT

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
  echo "❌ Container '$CONTAINER' চলছে না" >&2
  exit 1
fi

# --archive : একটা মাত্র stream/file এ সব database
# --gzip    : compress করা
docker exec "$CONTAINER" sh -c '
  PASS="${MONGO_INITDB_ROOT_PASSWORD:-$(cat /run/secrets/mongo_root_password)}"
  mongodump --username "$1" --password "$PASS" --authenticationDatabase admin --archive --gzip
' sh "$MONGO_USER" > "$TMP"

if [ ! -s "$TMP" ]; then
  echo "❌ Backup খালি" >&2
  exit 1
fi

mv "$TMP" "$OUT"
find "$BACKUP_DIR" -name "mongo_*.archive.gz" -mtime +"$RETENTION_DAYS" -delete

echo "✅ Backup সম্পন্ন: $OUT ($(du -h "$OUT" | cut -f1))"
