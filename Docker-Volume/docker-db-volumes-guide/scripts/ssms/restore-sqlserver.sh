#!/usr/bin/env bash
# restore-sqlserver.sh — .bak file থেকে SQL Server database restore
#
# ব্যবহার:  ./restore-sqlserver.sh /backups/sqlserver/appdb_2026-10-07_02-30.bak
# Environment variable (optional): CONTAINER=sql-prod  DB_NAME=appdb
#
# ⚠️ WITH REPLACE দেওয়ায় একই নামের বিদ্যমান database overwrite হবে।
# ⚠️ Database এ অন্য connection খোলা থাকলে restore fail করতে পারে; আগে app বন্ধ করো।
set -euo pipefail

BACKUP_FILE="${1:-}"
CONTAINER="${CONTAINER:-sql-prod}"
DB_NAME="${DB_NAME:-appdb}"
REMOTE="/var/opt/mssql/backup/restore_$$.bak"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "ব্যবহার: $0 <backup.bak>" >&2
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
  echo "❌ Container '$CONTAINER' চলছে না" >&2
  exit 1
fi

read -r -p "⚠️  '$DB_NAME' (container: $CONTAINER) '$BACKUP_FILE' দিয়ে overwrite হবে। এগোবে? [y/N] " ans
[ "$ans" = "y" ] || { echo "বাতিল।"; exit 0; }

# যেভাবেই শেষ হোক, container এর অস্থায়ী file মুছে দাও
trap 'docker exec -u 0 "$CONTAINER" rm -f "$REMOTE" >/dev/null 2>&1 || true' EXIT

docker exec "$CONTAINER" mkdir -p /var/opt/mssql/backup
docker cp "$BACKUP_FILE" "$CONTAINER:$REMOTE"

# docker cp করা file এর মালিক root হয়; SQL Server (mssql user) যেন পড়তে পারে
docker exec -u 0 "$CONTAINER" chmod 644 "$REMOTE"

QUERY="RESTORE DATABASE [${DB_NAME}] FROM DISK = N'${REMOTE}' WITH REPLACE, RECOVERY"
docker exec "$CONTAINER" sh -c "$SQLCMD"' -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -Q "$1"' sh "$QUERY"

echo "✅ Restore সম্পন্ন"
