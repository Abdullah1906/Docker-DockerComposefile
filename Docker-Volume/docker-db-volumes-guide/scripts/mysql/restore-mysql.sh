#!/usr/bin/env bash
# restore-mysql.sh — mysqldump backup (.sql বা .sql.gz) থেকে restore
#
# ব্যবহার:  ./restore-mysql.sh /backups/mysql/appdb_2026-10-07_02-10.sql.gz
# Environment variable (optional): CONTAINER=mysql-prod  DB_NAME=appdb
#
# ⚠️ Dump এ সাধারণত DROP TABLE + CREATE TABLE থাকে, তাই বিদ্যমান table এর data বদলে যাবে।
# আগে staging এ পরীক্ষা করো।
set -euo pipefail

BACKUP_FILE="${1:-}"
CONTAINER="${CONTAINER:-mysql-prod}"
DB_NAME="${DB_NAME:-appdb}"

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "ব্যবহার: $0 <backup-file.sql|.sql.gz>" >&2
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
  echo "❌ Container '$CONTAINER' চলছে না" >&2
  exit 1
fi

read -r -p "⚠️  '$DB_NAME' (container: $CONTAINER) এর data '$BACKUP_FILE' দিয়ে বদলে যাবে। এগোবে? [y/N] " ans
[ "$ans" = "y" ] || { echo "বাতিল।"; exit 0; }

# .gz হলে decompress করে পাঠাও, নইলে সরাসরি
if [[ "$BACKUP_FILE" == *.gz ]]; then
  READER=(gunzip -c "$BACKUP_FILE")
else
  READER=(cat "$BACKUP_FILE")
fi

# -i দরকার কারণ stdin দিয়ে dump পাঠানো হচ্ছে
"${READER[@]}" | docker exec -i "$CONTAINER" sh -c '
  export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat /run/secrets/mysql_root_password)}"
  mysql -uroot "$1"
' sh "$DB_NAME"

echo "✅ Restore সম্পন্ন"
