#!/usr/bin/env bash
# restore-mongodb.sh — mongodump archive থেকে restore
#
# ব্যবহার:  ./restore-mongodb.sh /backups/mongodb/mongo_2026-10-07_02-20.archive.gz
# Environment variable (optional): CONTAINER=mongo-prod  MONGO_USER=admin
#
# ⚠️ --drop দেওয়ায় archive এর collection গুলো আগে মুছে তারপর restore হয়,
# অর্থাৎ ওই collection এর বর্তমান data বদলে যাবে। আগে staging এ পরীক্ষা করো।
set -euo pipefail

BACKUP_FILE="${1:-}"
CONTAINER="${CONTAINER:-mongo-prod}"
MONGO_USER="${MONGO_USER:-admin}"

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "ব্যবহার: $0 <backup.archive.gz>" >&2
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
  echo "❌ Container '$CONTAINER' চলছে না" >&2
  exit 1
fi

read -r -p "⚠️  '$CONTAINER' এর collection গুলো '$BACKUP_FILE' দিয়ে বদলে যাবে। এগোবে? [y/N] " ans
[ "$ans" = "y" ] || { echo "বাতিল।"; exit 0; }

# -i দরকার কারণ stdin দিয়ে archive পাঠানো হচ্ছে
docker exec -i "$CONTAINER" sh -c '
  PASS="${MONGO_INITDB_ROOT_PASSWORD:-$(cat /run/secrets/mongo_root_password)}"
  mongorestore --username "$1" --password "$PASS" --authenticationDatabase admin --archive --gzip --drop
' sh "$MONGO_USER" < "$BACKUP_FILE"

echo "✅ Restore সম্পন্ন"
