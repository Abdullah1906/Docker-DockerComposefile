#!/usr/bin/env bash
# backup-sqlserver.sh — SQL Server এর native backup (.bak, compressed)
#
# ব্যবহার:  ./backup-sqlserver.sh
# Environment variable (সব optional):
#   CONTAINER=sql-prod  DB_NAME=appdb
#   BACKUP_DIR=/backups/sqlserver  RETENTION_DAYS=14
#
# SA password container এর MSSQL_SA_PASSWORD env থেকে পড়া হয় (host এ লাগে না)।
# ⚠️ DB_NAME নামে database আগে থেকে থাকতে হবে।
#
# cron (প্রতিদিন রাত ২:৩০):
#   30 2 * * * /opt/scripts/backup-sqlserver.sh >> /var/log/sql-backup.log 2>&1
set -euo pipefail

CONTAINER="${CONTAINER:-sql-prod}"
DB_NAME="${DB_NAME:-appdb}"
BACKUP_DIR="${BACKUP_DIR:-/backups/sqlserver}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date +%F_%H-%M)"
FILE="${DB_NAME}_${STAMP}.bak"
REMOTE="/var/opt/mssql/backup/$FILE"      # container এর ভেতরের অস্থায়ী path
OUT="$BACKUP_DIR/$FILE"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

mkdir -p "$BACKUP_DIR"

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
  echo "❌ Container '$CONTAINER' চলছে না" >&2
  exit 1
fi

docker exec "$CONTAINER" mkdir -p /var/opt/mssql/backup

# COMPRESSION : আকার ছোট করে
# INIT        : একই নামের পুরোনো backup set overwrite
# CHECKSUM    : backup এর integrity যাচাই
QUERY="BACKUP DATABASE [${DB_NAME}] TO DISK = N'${REMOTE}' WITH COMPRESSION, INIT, CHECKSUM"

# -C : self-signed certificate trust করো (production এ proper cert ভালো)
# -b : error হলে non-zero exit code (নইলে script বুঝতেই পারবে না fail হয়েছে)
docker exec "$CONTAINER" sh -c "$SQLCMD"' -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -Q "$1"' sh "$QUERY"

# Host এ কপি করে container এর অস্থায়ী file মুছে দাও (volume ভরে যাওয়া ঠেকায়)
docker cp "$CONTAINER:$REMOTE" "$OUT"
docker exec "$CONTAINER" rm -f "$REMOTE"

if [ ! -s "$OUT" ]; then
  echo "❌ Backup খালি" >&2
  rm -f "$OUT"
  exit 1
fi

find "$BACKUP_DIR" -name "${DB_NAME}_*.bak" -mtime +"$RETENTION_DAYS" -delete

echo "✅ Backup সম্পন্ন: $OUT ($(du -h "$OUT" | cut -f1))"
