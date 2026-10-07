#!/usr/bin/env bash
# migrate-volume.sh — এক Docker volume এর সব data আরেক (নতুন) volume এ কপি
#
# ব্যবহার:  ./migrate-volume.sh <পুরোনো-volume> <নতুন-volume> [container-নাম]
# উদাহরণ:   ./migrate-volume.sh pgdata pgdata_v2 pg-prod
#
# তৃতীয় argument দিলে ওই container কিছুক্ষণ বন্ধ রাখা হয় (consistent কপির জন্য)
# এবং শেষে আবার চালু করা হয়।
set -euo pipefail

OLD="${1:-}"
NEW="${2:-}"
CONTAINER="${3:-}"

if [ -z "$OLD" ] || [ -z "$NEW" ]; then
  echo "ব্যবহার: $0 <পুরোনো-volume> <নতুন-volume> [container]" >&2
  exit 1
fi

docker volume inspect "$OLD" >/dev/null 2>&1 || { echo "❌ Volume '$OLD' নেই" >&2; exit 1; }

# নতুন volume আগে থেকে থাকলে সতর্ক করো (ভুল করে overwrite ঠেকাতে)
if docker volume inspect "$NEW" >/dev/null 2>&1; then
  echo "❌ Volume '$NEW' আগে থেকেই আছে। নতুন নাম দাও বা আগে সেটা সরাও।" >&2
  exit 1
fi

if [ -n "$CONTAINER" ]; then
  echo "⏸  Container '$CONTAINER' বন্ধ করা হচ্ছে..."
  docker stop "$CONTAINER"
fi

docker volume create "$NEW" >/dev/null

# cp -a = permission, ownership, timestamp সহ হুবহু কপি
docker run --rm \
  -v "$OLD":/from:ro \
  -v "$NEW":/to \
  alpine sh -c "cp -a /from/. /to/"

echo "✅ '$OLD' → '$NEW' কপি সম্পন্ন"

if [ -n "$CONTAINER" ]; then
  echo "ℹ️  Container এর compose/run এ volume এর নাম '$NEW' এ বদলে তারপর আবার চালু করো।"
  echo "    (পুরোনো container '$CONTAINER' বন্ধ অবস্থায় আছে; যাচাই শেষে মুছো)"
fi
