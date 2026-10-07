# Chapter 2: Named Volumes (Recommended Approach)

> 📁 **Ready-to-run example:** [`examples/postgres/docker-compose.yml`](../examples/postgres/docker-compose.yml) · [MySQL](../examples/mysql/) · [MongoDB](../examples/mongodb/) · [SQL Server](../examples/sqlserver/) · Backup script: [`scripts/backup-postgres.sh`](../scripts/backup-postgres.sh)

## 2.1 Named Volume কী?

Named Volume হলো Docker এর নিজস্ব persistent storage unit, যার একটা **নাম** আছে। তুমি শুধু নাম দাও, কোথায় ও কীভাবে data রাখা হবে তা Docker ঠিক করে।

**Linux এ কোথায় থাকে:**

```
/var/lib/docker/volumes/
└── pgdata/                  ← volume এর নাম
    └── _data/               ← আসল data এখানে
```

```bash
# Volume এর বিস্তারিত দেখো
docker volume inspect pgdata
```

```json
[
    {
        "CreatedAt": "2026-10-07T09:00:00+06:00",
        "Driver": "local",
        "Labels": {},
        "Mountpoint": "/var/lib/docker/volumes/pgdata/_data",
        "Name": "pgdata",
        "Options": null,
        "Scope": "local"
    }
]
```

> 📝 **Docker Desktop (Windows/macOS) এ:** Docker একটা ছোট Linux VM এর ভেতরে চলে, তাই `/var/lib/docker/volumes/` তোমার নিজের PC এর filesystem এ নেই, VM এর ভেতরে। সরাসরি ওই path এ গিয়ে file edit করার চেষ্টা করো না, দরকার হলে helper container দিয়ে access করো।

> 🚫 **কখনো `/var/lib/docker/volumes/` এর ভেতরের file সরাসরি edit/delete করো না।** সবসময় Docker CLI বা container এর মাধ্যমে access করো।

### Named Volume এর বিশেষ আচরণ (Copy-up)
কোনো **খালি named volume** প্রথমবার container এ mount হলে, mount point এ image এর যে content আগে থেকে ছিল তা volume এ **copy হয়ে যায়**। Bind mount এ এটা হয় না, বরং bind mount container এর ওই directory এর original content ঢেকে (shadow করে) দেয়।

---

## 2.2 Step-by-Step: Docker CLI দিয়ে

### Step 1: Volume তৈরি করো

```bash
# একটা named volume বানাও (না বানালেও -v দিলে Docker নিজে বানিয়ে নেয়)
docker volume create pgdata
```

### Step 2: Volume সহ Database চালাও

```bash
docker run -d \
  --name pg-prod \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=ChangeMe_Strong#123 \
  -e POSTGRES_DB=appdb \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v pgdata:/var/lib/postgresql/data \
  -p 5432:5432 \
  --restart unless-stopped \
  postgres:17

# ── Parameter ব্যাখ্যা ──────────────────────────────────────────────
# -d                  : Background (detached) mode এ চালাও
# --name pg-prod      : Container এর নাম
# -e POSTGRES_USER    : Superuser এর নাম (default: postgres)
# -e POSTGRES_PASSWORD: Superuser এর password (প্রথমবার initialize এর সময় সেট হয়)
# -e POSTGRES_DB      : প্রথমবার যে database auto-create হবে
# -e PGDATA           : Data কোন subdirectory তে থাকবে (নিচের নোট দেখো)
# -v pgdata:/var/...  : <volume-name>:<container-path> — এটাই মূল persistence
# -p 5432:5432        : <host-port>:<container-port>
# --restart           : Host/Docker restart হলে container আবার চালু হবে
```

> 💡 **কেন `PGDATA` একটা subdirectory তে?** কিছু storage (যেমন ext4 এর mount point) এর root এ `lost+found` folder থাকে। Postgres `initdb` খালি directory আশা করে, তাই `lost+found` থাকলে fail করে। Subdirectory ব্যবহার করলে এই সমস্যা এড়ানো যায়।

### Step 3: Data persist হচ্ছে কিনা পরীক্ষা করো

```bash
# 1. Data লেখো
docker exec pg-prod psql -U appuser -d appdb \
  -c "CREATE TABLE users(id serial PRIMARY KEY, name text);" \
  -c "INSERT INTO users(name) VALUES ('Abdullah');"

# 2. Container সম্পূর্ণ মুছে ফেলো
docker rm -f pg-prod

# 3. একই volume দিয়ে নতুন container চালাও
docker run -d --name pg-prod \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=ChangeMe_Strong#123 \
  -e POSTGRES_DB=appdb \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v pgdata:/var/lib/postgresql/data \
  -p 5432:5432 \
  postgres:17

# 4. Data আছে কিনা দেখো
docker exec pg-prod psql -U appuser -d appdb -c "SELECT * FROM users;"
#  id |   name
# ----+----------
#   1 | Abdullah
```

### অন্যান্য Database এর CLI Example

```bash
# ───────── MySQL ─────────
docker run -d --name mysql-prod \
  -e MYSQL_ROOT_PASSWORD=RootPass#123 \
  -e MYSQL_DATABASE=appdb \
  -v mysqldata:/var/lib/mysql \
  -p 3306:3306 \
  mysql:8.4

# ───────── MongoDB ─────────
docker run -d --name mongo-prod \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=MongoPass#123 \
  -v mongodata:/data/db \
  -v mongoconfig:/data/configdb \
  -p 27017:27017 \
  mongo:7

# ───────── SQL Server ─────────
docker run -d --name sql-prod \
  -e ACCEPT_EULA=Y \
  -e MSSQL_SA_PASSWORD='YourStrong@Pass123' \
  -v sqldata:/var/opt/mssql \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

# ───────── Redis (AOF persistence সহ) ─────────
docker run -d --name redis-prod \
  -v redisdata:/data \
  -p 6379:6379 \
  redis:7 redis-server --appendonly yes
  # --appendonly yes : প্রতিটি write disk এ log হবে, তাই restart এ data থাকবে
```

### `--mount` syntax (আরও explicit ও readable)

`-v` ও `--mount` একই কাজ করে। তবে `--mount` বেশি স্পষ্ট এবং ভুল হলে error দেয় (silently কিছু বানিয়ে ফেলে না)।

```bash
docker run -d --name pg-prod \
  -e POSTGRES_PASSWORD=ChangeMe_Strong#123 \
  --mount type=volume,source=pgdata,target=/var/lib/postgresql/data \
  postgres:17

# type=volume   : mount এর ধরন (volume | bind | tmpfs)
# source=pgdata : volume এর নাম
# target=...    : container এর ভেতরের path
# readonly      : (optional) শুধু read-only করতে শেষে ",readonly" যোগ করো
```

---

## 2.3 Production-Ready Docker Compose (Named Volume + Driver Options)

### ক) Standard Production Configuration

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:17.2              # ⚠️ 'latest' নয়, নির্দিষ্ট version pin করো
    container_name: pg-prod
    restart: unless-stopped           # Host reboot এর পর আবার চালু হবে
    environment:
      POSTGRES_USER: appuser
      POSTGRES_DB: appdb
      # Password সরাসরি না লিখে Docker secret file থেকে পড়ো (নিচের secrets section দেখো)
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      PGDATA: /var/lib/postgresql/data/pgdata   # lost+found সমস্যা এড়াতে subdirectory
    secrets:
      - db_password
    volumes:
      - pgdata:/var/lib/postgresql/data          # ① Named volume (আসল data)
      - ./config/postgresql.conf:/etc/postgresql/postgresql.conf:ro   # ② Config (read-only bind)
      - ./initdb:/docker-entrypoint-initdb.d:ro  # ③ Init script (শুধু প্রথমবার চলে)
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    ports:
      - "127.0.0.1:5432:5432"         # শুধু localhost এ expose; পুরো internet এ নয়!
    shm_size: 256mb                   # Postgres এর shared memory (default 64MB কম)
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U appuser -d appdb"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s
    stop_grace_period: 60s            # Database কে নিরাপদে shutdown করার সময় দাও
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
    logging:
      driver: json-file
      options:
        max-size: "10m"               # Log file বড় হয়ে disk ভরে ফেলা ঠেকায়
        max-file: "5"
    networks:
      - backend

volumes:
  pgdata:                             # Named volume declaration
    name: myapp_pgdata                # নির্দিষ্ট নাম (project prefix ছাড়া)
    labels:
      app: myapp
      backup: "daily"

networks:
  backend:

secrets:
  db_password:
    file: ./secrets/db_password.txt   # ⚠️ এই file কখনো Git এ commit করো না (.gitignore এ দাও)
```

```bash
# Secret file বানাও (permission সহ)
mkdir -p secrets && printf 'ChangeMe_Strong#123' > secrets/db_password.txt
chmod 600 secrets/db_password.txt
echo "secrets/" >> .gitignore

# চালু করো
docker compose up -d

# Status ও health দেখো
docker compose ps
docker compose logs -f postgres
```

### খ) Driver Options সহ Named Volume (নির্দিষ্ট Disk এ রাখা)

Production এ প্রায়ই database এর জন্য আলাদা **SSD/NVMe disk** থাকে (যেমন `/mnt/nvme/pgdata`)। `local` driver এর `driver_opts` দিয়ে Docker-managed volume কে সেই path এ বসানো যায়।

```yaml
volumes:
  pgdata:
    driver: local
    driver_opts:
      type: none                      # কোনো নির্দিষ্ট filesystem type নয়
      o: bind                         # আসলে একটা bind হিসেবে কাজ করবে
      device: /mnt/nvme/pgdata        # ⚠️ এই directory আগে থেকে তৈরি থাকতে হবে!
```

```bash
# চালানোর আগে directory ও ownership ঠিক করো
sudo mkdir -p /mnt/nvme/pgdata
sudo chown 999:999 /mnt/nvme/pgdata   # Postgres container user এর UID:GID
sudo chmod 700 /mnt/nvme/pgdata       # Postgres এই permission ছাড়া start হবে না
```

> ⚠️ এই পদ্ধতিতে volume টা দেখতে named volume হলেও আসলে host path এর উপর নির্ভরশীল, তাই Chapter 3 এর permission সতর্কতাগুলো এখানেও প্রযোজ্য।

### গ) NFS / Remote Storage সহ Volume (⚠️ Database এর জন্য সতর্কতার সাথে)

```yaml
volumes:
  shared_backups:
    driver: local
    driver_opts:
      type: nfs
      o: "addr=10.0.0.5,rw,nfsvers=4,hard"   # NFS server এর address ও mount option
      device: ":/exports/backups"            # NFS server এর export path
```

> 🚫 **Live database data directory NFS এ রাখা উচিত নয়।** NFS এর locking ও `fsync` এর semantics এ সমস্যা থাকতে পারে, যা data corruption ঘটাতে পারে। NFS শুধু **backup/dump রাখার জন্য** ব্যবহার করো। Database data এর জন্য block storage (EBS, local NVMe, iSCSI) বেছে নাও।

### ঘ) Pre-created (External) Volume ব্যবহার

গুরুত্বপূর্ণ data এর volume কে Compose এর lifecycle থেকে আলাদা রাখতে `external: true` ব্যবহার করো। এতে `docker compose down -v` ভুল করে চালালেও ওই volume মুছবে না।

```bash
docker volume create myapp_pgdata   # আগে manually বানাও
```

```yaml
volumes:
  pgdata:
    external: true                    # Compose এটাকে create/delete করবে না
    name: myapp_pgdata
```

### ঙ) MySQL ও MongoDB এর Production Compose (সংক্ষিপ্ত)

```yaml
services:
  mysql:
    image: mysql:8.4
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/mysql_root_password
      MYSQL_DATABASE: appdb
    secrets: [mysql_root_password]
    volumes:
      - mysqldata:/var/lib/mysql                 # Data
      - ./config/my.cnf:/etc/mysql/conf.d/custom.cnf:ro   # Custom config
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      retries: 5

  mongo:
    image: mongo:7
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: admin
      MONGO_INITDB_ROOT_PASSWORD_FILE: /run/secrets/mongo_root_password
    secrets: [mongo_root_password]
    volumes:
      - mongodata:/data/db                       # Database files
      - mongoconfig:/data/configdb               # Config database (এটাও আলাদা volume)

volumes:
  mysqldata:
  mongodata:
  mongoconfig:

secrets:
  mysql_root_password:
    file: ./secrets/mysql_root_password.txt
  mongo_root_password:
    file: ./secrets/mongo_root_password.txt
```

---

## 2.4 Named Volume এর সুবিধা ও অসুবিধা

| ✅ সুবিধা (Pros) | ❌ অসুবিধা (Cons) |
|---|---|
| Docker দ্বারা fully managed | Host থেকে সরাসরি file browse করা কঠিন |
| Container lifecycle থেকে স্বাধীন | `docker compose down -v` বা `docker volume prune -a` এ মুছে যেতে পারে |
| Linux/Windows/macOS সব জায়গায় একই আচরণ | Docker Desktop এ data VM এর ভেতরে থাকে |
| Permission সমস্যা তুলনামূলক কম | Default `local` driver এ multi-host share করা যায় না |
| Volume driver plugin (NFS, cloud) সমর্থন | Disk usage নজরে রাখতে আলাদা command লাগে (`docker system df -v`) |
| Backup/restore ও migration সহজ | Docker এর data-root সরালে volume এর location ও বদলায় |
| Copy-up: image এর initial content পায় | — |

---

## 2.5 Backup ও Restore Strategy

> ⚠️ **গুরুত্বপূর্ণ নীতি:** চলমান database এর data file (`tar` দিয়ে) copy করলে **inconsistent backup** হতে পারে (লেখার মাঝপথে copy)। Production এ প্রথম পছন্দ হওয়া উচিত **logical backup** (database এর নিজস্ব dump tool), আর physical backup শুধু container বন্ধ থাকলে, অথবা snapshot/WAL-based tool দিয়ে।

### পদ্ধতি ১: Logical Backup (✅ Recommended)

#### PostgreSQL

```bash
# ── Backup ──
# -Fc = custom compressed format (pg_restore দিয়ে selective restore করা যায়)
docker exec pg-prod pg_dump -U appuser -d appdb -Fc > backup_$(date +%F).dump

# সব database + roles একসাথে (plain SQL)
docker exec pg-prod pg_dumpall -U appuser > full_backup_$(date +%F).sql

# ── Restore ──
# -i দরকার কারণ stdin দিয়ে file পাঠানো হচ্ছে
docker exec -i pg-prod pg_restore -U appuser -d appdb --clean --if-exists < backup_2026-10-07.dump
# --clean --if-exists : আগের object drop করে নতুন করে বানাবে
```

#### MySQL

```bash
# ── Backup ──
# --single-transaction : InnoDB এর জন্য table lock ছাড়াই consistent snapshot
docker exec mysql-prod sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers appdb' > backup_$(date +%F).sql

# ── Restore ──
docker exec -i mysql-prod sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" appdb' < backup_2026-10-07.sql
```

#### MongoDB

```bash
# ── Backup ──
docker exec mongo-prod mongodump \
  --username admin --password 'MongoPass#123' --authenticationDatabase admin \
  --archive --gzip > mongo_backup_$(date +%F).gz

# ── Restore ──
docker exec -i mongo-prod mongorestore \
  --username admin --password 'MongoPass#123' --authenticationDatabase admin \
  --archive --gzip < mongo_backup_2026-10-07.gz
```

#### SQL Server

```bash
# ── Backup (container এর ভেতরে .bak file তৈরি হয়) ──
docker exec sql-prod /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'YourStrong@Pass123' -C \
  -Q "BACKUP DATABASE [appdb] TO DISK = N'/var/opt/mssql/backup/appdb.bak' WITH COMPRESSION, INIT"

# Host এ কপি করো
docker cp sql-prod:/var/opt/mssql/backup/appdb.bak ./appdb.bak

# ── Restore ──
docker cp ./appdb.bak sql-prod:/var/opt/mssql/backup/appdb.bak
docker exec sql-prod /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'YourStrong@Pass123' -C \
  -Q "RESTORE DATABASE [appdb] FROM DISK = N'/var/opt/mssql/backup/appdb.bak' WITH REPLACE"
# -C : server certificate trust করো (self-signed এর জন্য; production এ proper cert ব্যবহার করো)
```

### পদ্ধতি ২: Physical Backup (Volume এর tar archive)

**শুধুমাত্র database বন্ধ রেখে** নাও, যাতে file consistent থাকে।

```bash
# ── Backup ──
docker stop pg-prod                                    # ① আগে database বন্ধ করো

docker run --rm \
  -v myapp_pgdata:/source:ro \
  -v "$(pwd)":/backup \
  alpine \
  tar czf /backup/pgdata_$(date +%F).tar.gz -C /source .

docker start pg-prod                                   # ② আবার চালু করো

# -v myapp_pgdata:/source:ro : volume কে read-only mount (ভুল করে বদলানো ঠেকায়)
# -v "$(pwd)":/backup        : বর্তমান folder এ archive সংরক্ষণ হবে
# --rm                       : কাজ শেষে helper container নিজে মুছে যাবে
# tar czf ... -C /source .   : /source এর সব কিছু gzip করো
```

```bash
# ── Restore (⚠️ নতুন বা খালি volume এ করো) ──
docker volume create pgdata_restored

docker run --rm \
  -v pgdata_restored:/target \
  -v "$(pwd)":/backup:ro \
  alpine \
  sh -c "cd /target && tar xzf /backup/pgdata_2026-10-07.tar.gz"
```

### Automated Backup (cron + script)

```bash
#!/usr/bin/env bash
# backup-postgres.sh — প্রতিদিন চালানোর জন্য
set -euo pipefail

BACKUP_DIR="/backups/postgres"
RETENTION_DAYS=14
STAMP=$(date +%F_%H-%M)

mkdir -p "$BACKUP_DIR"

# Logical backup নাও
docker exec pg-prod pg_dump -U appuser -d appdb -Fc \
  > "$BACKUP_DIR/appdb_$STAMP.dump"

# Backup ঠিকমতো হয়েছে কিনা যাচাই করো (খালি file হলে fail)
[ -s "$BACKUP_DIR/appdb_$STAMP.dump" ] || { echo "Backup খালি!"; exit 1; }

# পুরোনো backup মুছে ফেলো
find "$BACKUP_DIR" -name "*.dump" -mtime +"$RETENTION_DAYS" -delete

echo "✅ Backup সম্পন্ন: appdb_$STAMP.dump"
```

```bash
# crontab -e  →  প্রতিদিন রাত ২:০০ টায়
0 2 * * * /opt/scripts/backup-postgres.sh >> /var/log/pg-backup.log 2>&1
```

---

⬅️ [আগের: Chapter 1](01-introduction.md) | 🏠 [সূচিপত্র](../README.md) | [পরের: Chapter 3](03-bind-mounts.md) ➡️
