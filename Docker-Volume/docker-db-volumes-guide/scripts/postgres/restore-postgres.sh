#!/usr/bin/env bash
# restore-postgres.sh — pg_dump (-Fc) backup থেকে restore
#
# ব্যবহার:  ./restore-postgres.sh /backups/postgres/appdb_2026-10-07_02-00.dump
# Environment variable (optional): CONTAINER=pg-prod  DB_USER=appuser  DB_NAME=appdb
#
# ⚠️ --clean দেওয়ায় বিদ্যমান object গুলো drop হয়ে backup এর data দিয়ে বদলে যাবে।
# আগে staging এ পরীক্ষা করো।
set -euo pipefail

BACKUP_FILE="${1:-}"
CONTAINER="${CONTAINER:-pg-prod}"
DB_USER="${DB_USER:-appuser}"
DB_NAME="${DB_NAME:-appdb}"

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "ব্যবহার: $0 <backup-file.dump>" >&2
  exit 1
fi

read -r -p "⚠️  '$DB_NAME' (container: $CONTAINER) এর data '$BACKUP_FILE' দিয়ে বদলে যাবে। এগোবে? [y/N] " ans
[ "$ans" = "y" ] || { echo "বাতিল।"; exit 0; }

# -i দরকার কারণ stdin দিয়ে file পাঠানো হচ্ছে
docker exec -i "$CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists < "$BACKUP_FILE"

echo "✅ Restore সম্পন্ন"
