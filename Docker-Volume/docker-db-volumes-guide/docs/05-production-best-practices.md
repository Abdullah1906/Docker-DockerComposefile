# Chapter 5: Advanced Configurations ও Production Best Practices

> 📁 **Ready-to-use scripts:** [`backup-postgres.sh`](../scripts/backup-postgres.sh) · [`restore-postgres.sh`](../scripts/restore-postgres.sh) · [`migrate-volume.sh`](../scripts/migrate-volume.sh)

## 5.1 Data Security ও File Ownership (UID/GID Mismatch)

### সমস্যাটা কী?

Linux kernel file এর owner চেনে **সংখ্যা (UID/GID)** দিয়ে, নাম দিয়ে নয়। Container ও host এ একই UID এর নাম আলাদা হতে পারে, আবার একই নামের UID আলাদা হতে পারে।

```
Host:        UID 1000 = abdullah       UID 999 = (অন্য কিছু বা কেউ না)
Container:   UID 1000 = (কেউ না)       UID 999 = postgres

→ Host এ "abdullah" এর file container এর "postgres" পড়তে পারে না।
```

### নির্ণয় (Diagnosis)

```bash
# Container কোন UID তে চলছে?
docker exec pg-prod id
# uid=999(postgres) gid=999(postgres) groups=999(postgres)

# Image এর default user কী?
docker run --rm postgres:17 id postgres

# Volume/bind folder এর ownership দেখো (সংখ্যায়)
ls -ldn /mnt/nvme/pgdata
# drwx------ 2 999 999 4096 Oct  7 09:00 /mnt/nvme/pgdata
```

### সমাধানের কৌশল

#### ১. Host directory এর ownership মেলাও (Bind mount / driver_opts এর জন্য)

```bash
sudo chown -R 999:999 /mnt/nvme/pgdata     # Postgres / MySQL / Mongo / Redis (Debian)
sudo chown -R 10001:0 /mnt/ssd/mssql       # SQL Server (mssql user = 10001)
sudo chmod 700 /mnt/nvme/pgdata            # Postgres এ বাধ্যতামূলক
```

#### ২. একটা one-shot "init" container দিয়ে ownership ঠিক করা

Host এ `sudo` ছাড়া বা automation এ সুবিধাজনক:

```yaml
services:
  fix-permissions:
    image: alpine
    command: chown -R 999:999 /data       # Postgres এর UID:GID
    volumes:
      - pgdata:/data
    restart: "no"                         # একবার চালিয়ে বন্ধ হবে

  postgres:
    image: postgres:17
    depends_on:
      fix-permissions:
        condition: service_completed_successfully   # আগে permission ঠিক হবে
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

#### ৩. `user:` directive দিয়ে নির্দিষ্ট UID তে চালানো

```yaml
services:
  postgres:
    image: postgres:17
    user: "999:999"          # স্পষ্টভাবে নির্দিষ্ট করা (volume এর owner এর সাথে মিলিয়ে)
```

#### ৪. Rootless Docker / User Namespace Remap

Rootless mode বা `userns-remap` চালু থাকলে container এর UID 999 host এ আসলে একটা বড় সংখ্যা (যেমন 100999) হয়ে যায়।

```bash
# Rootless Docker এ container UID ↔ host UID mapping দেখো
cat /etc/subuid
# abdullah:100000:65536   → container UID 0 = host 100000, UID 999 = host 100999

# তাই host এ ownership দিতে হবে:
sudo chown -R 100999:100999 ./data
# অথবা সহজ উপায়:
podman unshare chown -R 999:999 ./data     # (Podman এ)
```

### 🔒 Security Hardening Checklist (Container Level)

```yaml
services:
  postgres:
    image: postgres:17
    read_only: true                       # Root filesystem read-only
    tmpfs:
      - /tmp                              # যেখানে লেখা লাগে শুধু সেখানে tmpfs
      - /run/postgresql
    volumes:
      - pgdata:/var/lib/postgresql/data   # শুধু data volume writable
    security_opt:
      - no-new-privileges:true            # Privilege escalation ঠেকায়
    cap_drop:
      - ALL                               # সব Linux capability বাদ
    cap_add:                              # শুধু প্রয়োজনীয়গুলো ফেরত দাও
      - CHOWN
      - SETUID
      - SETGID
      - FOWNER
      - DAC_OVERRIDE
```

> ⚠️ `cap_drop: ALL` ও `read_only: true` image ভেদে ভিন্ন আচরণ করতে পারে। Production এ তোলার আগে staging এ ভালোভাবে পরীক্ষা করো।

### Secret Management

```yaml
# ❌ খারাপ: password সরাসরি environment এ (docker inspect এ দেখা যায়, Git এ চলে যেতে পারে)
environment:
  POSTGRES_PASSWORD: MyPassword123

# ✅ ভালো: _FILE variant + Docker secret
environment:
  POSTGRES_PASSWORD_FILE: /run/secrets/db_password
secrets:
  - db_password
```

| Database | Secret এর জন্য `_FILE` variable |
|---|---|
| PostgreSQL | `POSTGRES_PASSWORD_FILE` |
| MySQL / MariaDB | `MYSQL_ROOT_PASSWORD_FILE`, `MYSQL_PASSWORD_FILE` |
| MongoDB | `MONGO_INITDB_ROOT_PASSWORD_FILE` |

---

## 5.2 Volume Backup, Restoration ও Migration

### ক) Backup Strategy: 3-2-1 Rule

> **৩** টি copy রাখো, **২** টি আলাদা ধরনের storage এ, এবং **১** টি offsite (অন্য জায়গায়/cloud এ)।

| স্তর | পদ্ধতি | উদাহরণ |
|---|---|---|
| **Logical dump** | `pg_dump`, `mysqldump`, `mongodump` | রাতে scheduled |
| **Physical/Snapshot** | LVM/ZFS/Btrfs snapshot, cloud disk snapshot (EBS) | ঘণ্টায়/দিনে |
| **Continuous (WAL/binlog)** | `pgBackRest`, `WAL-G`, MySQL binlog | Point-in-Time Recovery (PITR) এর জন্য |
| **Offsite** | S3, GCS, Azure Blob, অন্য datacenter | `rclone`, `aws s3 sync` |

```bash
# Backup S3 তে পাঠানো
aws s3 cp backup_2026-10-07.dump s3://my-db-backups/postgres/ --storage-class STANDARD_IA

# অথবা rclone দিয়ে (যেকোনো cloud এ)
rclone copy /backups/postgres remote:db-backups/postgres
```

> ⚠️ **যে backup restore করে পরীক্ষা করা হয়নি, সেটা backup নয়, শুধু আশা।** প্রতি মাসে অন্তত একবার একটা আলাদা environment এ restore করে যাচাই করো।

### খ) Volume Migration কৌশল

#### ১. এক Volume থেকে আরেক Volume এ কপি (একই host)

```bash
docker stop pg-prod                       # ① Database বন্ধ করো (consistency এর জন্য)

docker volume create pgdata_v2            # ② নতুন volume

docker run --rm \
  -v pgdata:/from:ro \
  -v pgdata_v2:/to \
  alpine \
  sh -c "cp -a /from/. /to/"              # ③ -a = permission, ownership, timestamp সহ হুবহু কপি

# ④ নতুন volume দিয়ে container চালাও ও যাচাই করো
```

#### ২. এক Host থেকে আরেক Host এ Migration

```bash
# ── পুরোনো Server এ ──
docker stop pg-prod
docker run --rm \
  -v myapp_pgdata:/source:ro \
  -v "$(pwd)":/backup \
  alpine tar czf /backup/pgdata.tar.gz -C /source .

# Archive টা নতুন server এ পাঠাও
scp pgdata.tar.gz user@new-server:/tmp/

# ── নতুন Server এ ──
docker volume create myapp_pgdata
docker run --rm \
  -v myapp_pgdata:/target \
  -v /tmp:/backup:ro \
  alpine sh -c "cd /target && tar xzf /backup/pgdata.tar.gz"

docker compose up -d                      # Compose file ও নতুন server এ নিয়ে এসে চালাও
```

#### ৩. Bind Mount → Named Volume এ Migration

```bash
docker volume create pgdata

docker run --rm \
  -v /home/abdullah/olddata:/from:ro \
  -v pgdata:/to \
  alpine sh -c "cp -a /from/. /to/"
```

#### ৪. Database Version Upgrade (Major Version)

> ⚠️ **Major version upgrade (যেমন Postgres 16 → 17) এর ক্ষেত্রে data directory সরাসরি নতুন image এ mount করলে চলবে না।** Postgres এর binary data format major version এ বদলায়।

```bash
# নিরাপদ পথ: Dump → নতুন version এ Restore
docker exec pg-old pg_dumpall -U postgres > upgrade_dump.sql

# নতুন version এর নতুন (খালি) volume দিয়ে চালাও
docker run -d --name pg-new -e POSTGRES_PASSWORD=secret \
  -v pgdata_17:/var/lib/postgresql/data postgres:17

docker exec -i pg-new psql -U postgres < upgrade_dump.sql
```

বড় database এর জন্য `pg_upgrade` (ও `--link` mode) অথবা logical replication ব্যবহার করে downtime কমানো যায়।

### গ) Volume পর্যবেক্ষণ ও রক্ষণাবেক্ষণ

```bash
docker volume ls                          # সব volume
docker volume ls -f dangling=true         # কোনো container এ ব্যবহৃত নয় এমন volume
docker volume inspect myapp_pgdata        # বিস্তারিত (Mountpoint, Driver, Labels)
docker system df -v                       # প্রতিটি volume কত জায়গা নিচ্ছে
docker volume prune                       # অব্যবহৃত anonymous volume মুছে ফেলে
docker volume prune -a                    # ⚠️ সব অব্যবহৃত (named সহ) volume মুছে ফেলে — বিপজ্জনক!
```

> ⚠️ **কোন volume "অব্যবহৃত"?** যে volume কোনো container (এমনকি stopped container) এর সাথে যুক্ত নয়, সেটাই অব্যবহৃত ধরা হয়। তাই database container সাময়িক মুছে ফেলার পর `docker volume prune -a` চালালে data চিরতরে চলে যাবে। Docker এর নতুন version এ default `prune` শুধু anonymous volume মুছে, তবে `-a` flag সব মুছে দেয়।

---

## 5.3 Performance Tuning

### ক) I/O Throttling (Noisy Neighbour সমস্যা)

একটা container যাতে পুরো disk bandwidth দখল করে অন্যদের ধীর না করে দেয়।

```bash
# Block device এর নাম জানো
lsblk                                     # যেমন /dev/nvme0n1

docker run -d --name pg-prod \
  --device-read-bps  /dev/nvme0n1:200mb \
  --device-write-bps /dev/nvme0n1:100mb \
  --device-read-iops  /dev/nvme0n1:5000 \
  --device-write-iops /dev/nvme0n1:2500 \
  -v pgdata:/var/lib/postgresql/data \
  postgres:17

# --device-read-bps   : সর্বোচ্চ read bandwidth (bytes/sec)
# --device-write-bps  : সর্বোচ্চ write bandwidth
# --device-read-iops  : সর্বোচ্চ read operations/sec
# --device-write-iops : সর্বোচ্চ write operations/sec
```

```yaml
# Compose এ (blkio_config)
services:
  postgres:
    image: postgres:17
    blkio_config:
      weight: 500                         # আপেক্ষিক অগ্রাধিকার (10-1000)
      device_read_bps:
        - path: /dev/nvme0n1
          rate: "200mb"
      device_write_bps:
        - path: /dev/nvme0n1
          rate: "100mb"
      device_read_iops:
        - path: /dev/nvme0n1
          rate: 5000
      device_write_iops:
        - path: /dev/nvme0n1
          rate: 2500
```

> ⚠️ Throttling সাধারণত direct I/O ও block device level এ কাজ করে। Production এ চালু করার আগে নিজের workload এ benchmark করে নাও, কারণ খুব কড়া limit database কে ধীর করে দিতে পারে।

### খ) Storage ও Filesystem বেছে নেওয়া

| সিদ্ধান্ত | সুপারিশ |
|---|---|
| **Disk type** | NVMe/SSD, HDD নয় |
| **Filesystem** | **ext4** বা **XFS** (database এর জন্য সবচেয়ে পরীক্ষিত) |
| **Docker storage driver** | `overlay2` (default); Volume কে overlay এর বাইরে রাখাই নিয়ম |
| **Network storage** | NFS/SMB এ live data ❌; Block storage (EBS, iSCSI, local NVMe) ✅ |
| **Windows/macOS** | Bind mount ❌, Named Volume ✅ (Docker Desktop VM এর ভেতরে native speed) |
| **Mount option** | ext4/XFS এ `noatime` যোগ করলে অপ্রয়োজনীয় metadata write কমে |

### গ) Database ও Container Resource Tuning

```yaml
services:
  postgres:
    image: postgres:17
    shm_size: 512mb                       # Postgres shared memory; ছোট হলে "could not resize shared memory" error
    ulimits:
      nofile:                             # বেশি connection/file handle
        soft: 65536
        hard: 65536
    deploy:
      resources:
        limits:
          cpus: "4.0"
          memory: 8G                      # Hard cap
        reservations:
          memory: 4G                      # নিশ্চিত বরাদ্দ
    command: >
      postgres
      -c shared_buffers=2GB               # সাধারণত মোট RAM এর ~25%
      -c effective_cache_size=6GB         # OS cache সহ আনুমানিক cache (~50-75% RAM)
      -c work_mem=16MB
      -c maintenance_work_mem=512MB
      -c max_wal_size=4GB
      -c random_page_cost=1.1             # SSD/NVMe এর জন্য (default 4.0 HDD এর জন্য)
      -c max_connections=200
```

> 💡 উপরের মানগুলো **শুধু উদাহরণ**। তোমার hardware ও workload অনুযায়ী `PGTune` জাতীয় tool দিয়ে হিসাব করে নাও, আর নিজের data দিয়ে benchmark করো।

### ঘ) Bind Mount Consistency Flags (শুধু পুরোনো macOS Docker Desktop এ)

```bash
# পুরোনো macOS এ গতি বাড়াতে ব্যবহৃত হতো
-v "$(pwd)/data":/var/lib/postgresql/data:delegated
# :cached    — host এর view প্রধান, container এ পরে sync (read-heavy এ)
# :delegated — container এর view প্রধান, host এ পরে sync (write-heavy এ)
```

> 📝 বর্তমান Docker Desktop এ VirtioFS ব্যবহার হলে এই flag গুলোর প্রভাব নেই বললেই চলে। সবচেয়ে ভালো সমাধান আসলে Named Volume।

---

## 5.4 ✅ Production Deployment Checklist

### 🗄️ Storage ও Persistence
- [ ] Database data **Named Volume** (বা dedicated block storage) এ আছে, container writable layer এ নয়
- [ ] Volume এর স্পষ্ট নাম আছে, anonymous volume নেই
- [ ] গুরুত্বপূর্ণ volume `external: true` দিয়ে Compose lifecycle থেকে সুরক্ষিত
- [ ] Live data NFS/SMB এ **নেই**
- [ ] Windows/macOS এ data directory এর জন্য bind mount **ব্যবহার করা হয়নি**
- [ ] Postgres 18+ হলে mount path `/var/lib/postgresql` কিনা যাচাই করা হয়েছে
- [ ] Disk space monitoring ও alert আছে (`docker system df -v`, Prometheus node-exporter)

### 💾 Backup ও Recovery
- [ ] স্বয়ংক্রিয় logical backup (cron/CI) চালু আছে
- [ ] 3-2-1 rule মানা হচ্ছে, অন্তত একটা offsite copy আছে
- [ ] Backup এর retention policy নির্ধারিত (যেমন ১৪ দিন)
- [ ] **Restore regularly পরীক্ষা করা হয়** (অন্তত মাসিক)
- [ ] PITR (WAL/binlog archiving) প্রয়োজন হলে কনফিগার করা আছে
- [ ] `docker compose down -v` ও `docker volume prune -a` এর ঝুঁকি টিম জানে

### 🔐 Security
- [ ] Image tag **pinned** (`postgres:17.2`), `latest` নয়
- [ ] Password `_FILE` + Docker secrets দিয়ে, plain `environment` এ নয়
- [ ] Secret file `.gitignore` এ আছে, permission `600`
- [ ] Container non-root user এ চলছে; UID/GID ownership ঠিক আছে
- [ ] Port শুধু প্রয়োজনে expose (`127.0.0.1:5432:5432` বা internal network)
- [ ] Config/init mount `:ro`
- [ ] `no-new-privileges`, প্রয়োজনে `cap_drop: ALL` (staging এ পরীক্ষিত)
- [ ] `/var/run/docker.sock` কোনো database container এ mount করা **নেই**
- [ ] Database কে আলাদা internal Docker network এ রাখা হয়েছে

### ⚙️ Reliability ও Performance
- [ ] `restart: unless-stopped` সেট করা আছে
- [ ] `healthcheck` কনফিগার করা আছে (`pg_isready`, `mysqladmin ping`)
- [ ] `stop_grace_period` যথেষ্ট (≥ 30-60s), যাতে shutdown নিরাপদে হয়
- [ ] CPU ও memory limit দেওয়া আছে
- [ ] `shm_size` (Postgres) ঠিক করা আছে
- [ ] Log rotation (`max-size`, `max-file`) আছে
- [ ] Database config (`shared_buffers` ইত্যাদি) hardware অনুযায়ী tune করা
- [ ] Storage SSD/NVMe, filesystem ext4/XFS

### 🧪 Testing ও Operations
- [ ] Test/CI এ tmpfs ব্যবহার, production এ **কখনো নয়**
- [ ] Major version upgrade এর procedure লেখা ও পরীক্ষিত
- [ ] Monitoring (query performance, connection, disk, replication lag) আছে
- [ ] Runbook/documentation আপডেটেড

---

⬅️ [আগের: Chapter 4](04-tmpfs-mounts.md) | 🏠 [সূচিপত্র](../README.md) | [পরের: Chapter 6](06-troubleshooting.md) ➡️
