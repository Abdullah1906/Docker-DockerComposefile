# Chapter 3: Bind Mounts (Development ও Host Integration)

> 📁 **Ready-to-run example:** [`examples/postgres/docker-compose.dev.yml`](../examples/postgres/docker-compose.dev.yml)

## 3.1 Bind Mount কী?

Bind Mount এ host machine এর একটা **নির্দিষ্ট file বা directory** সরাসরি container এর ভেতরে map করা হয়। Host ও container **একই file দেখে**, একদিকে পরিবর্তন করলে অন্যদিকে সঙ্গে সঙ্গে দেখা যায়।

```
Host                                 Container
/home/abdullah/project/initdb/  ───▶  /docker-entrypoint-initdb.d/
/home/abdullah/project/pg.conf  ───▶  /etc/postgresql/postgresql.conf
```

### Named Volume থেকে মূল পার্থক্য

| বিষয় | Named Volume | Bind Mount |
|---|---|---|
| Path কে ঠিক করে | Docker | **তুমি** |
| Host path না থাকলে | Docker তৈরি করে | `-v` দিলে **root-owned** folder বানায়, `--mount` দিলে error |
| Container এর original content | Copy-up হয় (খালি volume এ) | **Shadow হয়ে যায়** (ঢাকা পড়ে) |
| Docker CLI দিয়ে manage | ✅ | ❌ |

---

## 3.2 Use Cases

| Use Case | উদাহরণ |
|---|---|
| **Local development** | Host এ edit করা config সঙ্গে সঙ্গে container এ প্রয়োগ |
| **Seed/Init data inject** | `./initdb/*.sql` কে `/docker-entrypoint-initdb.d/` এ mount |
| **Config file** | `postgresql.conf`, `my.cnf`, `redis.conf` version control এ রেখে mount |
| **Log sharing** | Container এর log host এ লিখে সহজে দেখা বা collect করা |
| **Backup directory** | Container এর dump file সরাসরি host এ পাওয়া |
| **Source code** | (App container এর জন্য) live reload |

---

## 3.3 Step-by-Step: Docker CLI

### প্রস্তুতি

```bash
# Project structure বানাও
mkdir -p ~/dbproject/{data,initdb,backups,config}
cd ~/dbproject

# একটা init script লেখো
cat > initdb/01-init.sql <<'EOF'
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    price NUMERIC(10,2)
);
INSERT INTO products (name, price) VALUES ('Laptop', 999.99), ('Mouse', 19.99);
EOF
```

### `-v` দিয়ে চালানো

```bash
docker run -d --name pg-dev \
  -e POSTGRES_PASSWORD=devpass \
  -e POSTGRES_DB=devdb \
  -v "$(pwd)/data":/var/lib/postgresql/data \
  -v "$(pwd)/initdb":/docker-entrypoint-initdb.d:ro \
  -v "$(pwd)/backups":/backups \
  -p 5432:5432 \
  postgres:17

# -v "$(pwd)/data":/var/lib/postgresql/data
#     └─ <host-ABSOLUTE-path>:<container-path>
#        ⚠️ Host path অবশ্যই absolute হতে হবে। $(pwd) সেটাই দেয়।
#        ⚠️ নাম (যেমন "data") দিলে সেটা named volume ধরা হবে, path নয়!
#
# -v "$(pwd)/initdb":/docker-entrypoint-initdb.d:ro
#     └─ ":ro" = read-only। Container এই folder এ কিছু লিখতে/মুছতে পারবে না।
```

### `--mount` দিয়ে চালানো (✅ আরও নিরাপদ)

```bash
docker run -d --name pg-dev \
  -e POSTGRES_PASSWORD=devpass \
  --mount type=bind,source="$(pwd)/data",target=/var/lib/postgresql/data \
  --mount type=bind,source="$(pwd)/initdb",target=/docker-entrypoint-initdb.d,readonly \
  -p 5432:5432 \
  postgres:17

# type=bind : bind mount বোঝায়
# source    : host এর absolute path (না থাকলে Docker ERROR দেবে — এটাই ভালো,
#             কারণ ভুল path এ silent ভাবে root-owned খালি folder তৈরি হয় না)
# target    : container এর ভেতরের path
# readonly  : read-only mount
```

### পরীক্ষা

```bash
# Init script চলেছে কিনা দেখো
docker exec pg-dev psql -U postgres -d devdb -c "SELECT * FROM products;"

# Host এ data files সরাসরি দেখা যাচ্ছে
ls -la ./data
```

---

## 3.4 Docker Compose এ Bind Mount

```yaml
# docker-compose.dev.yml  — শুধু DEVELOPMENT এর জন্য
services:
  postgres:
    image: postgres:17
    container_name: pg-dev
    environment:
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: devpass
      POSTGRES_DB: devdb
    ports:
      - "5432:5432"
    volumes:
      # ① Short syntax — ছোট ও পরিচিত
      - ./initdb:/docker-entrypoint-initdb.d:ro       # Seed SQL (read-only)
      - ./config/postgresql.conf:/etc/postgresql/postgresql.conf:ro   # একটা single file mount
      - ./backups:/backups                            # Backup folder (read-write)

      # ② Long syntax — বেশি control ও স্পষ্টতা
      - type: bind
        source: ./data                                # Host path (compose file এর relative)
        target: /var/lib/postgresql/data              # Container path
        bind:
          create_host_path: true                      # Host folder না থাকলে বানাবে
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
```

```bash
docker compose -f docker-compose.dev.yml up -d
```

### Hybrid Pattern (✅ Development এর জন্য সেরা)

Data কে named volume এ রাখো (নিরাপদ ও দ্রুত), আর শুধু config/seed কে bind mount করো।

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_PASSWORD: devpass
    volumes:
      - pgdata:/var/lib/postgresql/data               # Data → Named volume (নিরাপদ)
      - ./initdb:/docker-entrypoint-initdb.d:ro       # Seed → Bind mount (সহজে edit)
      - ./config/pg.conf:/etc/postgresql/postgresql.conf:ro  # Config → Bind mount

volumes:
  pgdata:
```

---

## 3.5 ⚠️ গুরুত্বপূর্ণ সতর্কতা

### 🔴 ১. File Permission ও Ownership (সবচেয়ে সাধারণ সমস্যা)

Container এর ভেতরের user (যেমন `postgres` = UID 999) এবং host এর folder এর owner (যেমন তোমার user = UID 1000) আলাদা হলে `Permission denied` error হয়।

```bash
# সমস্যা: Host folder এর owner তুমি (1000), কিন্তু Postgres চালায় UID 999
ls -ld ./data
# drwxr-xr-x 2 abdullah abdullah ... ./data      ← UID 1000

# Container log এ error:
# initdb: error: could not change permissions of directory
# "/var/lib/postgresql/data": Operation not permitted
```

**সমাধান:**

```bash
# পদ্ধতি ১: Folder এর owner container user এর সাথে মেলাও
sudo chown -R 999:999 ./data
sudo chmod 700 ./data              # Postgres এর জন্য বাধ্যতামূলক (0700 বা 0750)

# পদ্ধতি ২: Container কে তোমার UID দিয়ে চালাও (সব image এ কাজ নাও করতে পারে)
docker run --user "$(id -u):$(id -g)" ...
```

```yaml
# Compose এ
services:
  postgres:
    user: "1000:1000"
```

### 🔴 ২. SELinux (RHEL, CentOS, Fedora, Rocky Linux)

SELinux enforcing থাকলে bind mount এ `Permission denied` আসতে পারে (UID ঠিক থাকলেও)। `:z` বা `:Z` suffix দাও।

```bash
# :z = shared label (একাধিক container এ share হলে)
# :Z = private label (শুধু এই container এর জন্য)
docker run -v "$(pwd)/data":/var/lib/postgresql/data:Z postgres:17
```

```yaml
volumes:
  - ./data:/var/lib/postgresql/data:Z
```

> ⚠️ `:Z` host directory এর SELinux label পরিবর্তন করে। `/home`, `/etc`, `/usr` এর মতো system directory তে কখনো ব্যবহার করো না।

### 🔴 ৩. Security Risks

| ঝুঁকি | ব্যাখ্যা | প্রতিরোধ |
|---|---|---|
| **Host filesystem exposure** | Container এ write access থাকলে host এর file বদলাতে/মুছতে পারে | যতটা সম্ভব `:ro` ব্যবহার করো |
| **Container root = Host file এর মালিক** | Container এ root হলে bind mount করা file এ root হিসেবে লেখে | Non-root user ব্যবহার করো |
| **Sensitive path mount** | `/`, `/etc`, `/var/run/docker.sock` mount করলে host দখলের ঝুঁকি | ❌ কখনো করো না |
| **Secret leak** | `.env`, key file ভুল করে mount | শুধু প্রয়োজনীয় file mount করো |
| **অজান্তে Git এ commit** | `./data` folder এ database file Git এ চলে যায় | `.gitignore` এ `data/` যোগ করো |

```bash
# .gitignore এ অবশ্যই রাখো
data/
backups/
secrets/
*.env
```

### 🔴 ৪. Cross-Platform Performance (Linux vs Windows/macOS)

| Platform | Bind Mount Performance | কারণ |
|---|---|---|
| **Linux (native)** | 🚀 Native speed | Container সরাসরি host kernel ও filesystem ব্যবহার করে |
| **macOS** | ⚠️ ধীর | Docker একটা Linux VM এ চলে; host ফোল্ডার file-sharing layer (VirtioFS/gRPC-FUSE) দিয়ে share হয় |
| **Windows + WSL2 backend** | ⚠️ `/mnt/c/...` path এ অত্যন্ত ধীর | Windows ↔ Linux filesystem boundary পার হতে হয় |
| **Windows + WSL2 (WSL এর ভেতরের path)** | 🚀 দ্রুত | `\\wsl$\Ubuntu\home\user\...` বা `~/project` Linux filesystem এ |

**Windows/macOS এ Database এর জন্য নিয়ম:**

```bash
# ❌ Windows এ ধীর ও সমস্যাজনক (NTFS এর উপর)
docker run -v /mnt/c/Users/me/pgdata:/var/lib/postgresql/data postgres:17

# ✅ WSL2 এর ভেতরের Linux filesystem (ext4) — দ্রুত
cd ~/projects/myapp
docker run -v "$(pwd)/data":/var/lib/postgresql/data postgres:17

# ✅ সবচেয়ে ভালো: Database data কে Named Volume এ রাখো
docker run -v pgdata:/var/lib/postgresql/data postgres:17
```

> 🚫 **Windows (NTFS) বা macOS এর bind mount এ Postgres/MySQL এর data directory রাখলে** `chmod`/`chown` কাজ করে না, `fsync` ধীর ও অনির্ভরযোগ্য হয়, আর file locking এ সমস্যা হয়। ফলে error বা corruption হতে পারে। **এই platform গুলোতে database data এর জন্য সবসময় Named Volume ব্যবহার করো।**

### 🔴 ৫. Container এর Original Content ঢাকা পড়া (Shadowing)

খালি host folder কে image এ আগে থেকে content আছে এমন path এ bind mount করলে container এর original content অদৃশ্য হয়ে যায়।

```bash
# Container এর /etc/mysql/conf.d এ default config ছিল।
# খালি ./conf bind করলে সেই default config আর দেখা যাবে না।
docker run -v "$(pwd)/conf":/etc/mysql/conf.d mysql:8.4
```

**সমাধান:** পুরো directory এর বদলে নির্দিষ্ট file mount করো।

---

⬅️ [আগের: Chapter 2](02-named-volumes.md) | 🏠 [সূচিপত্র](../README.md) | [পরের: Chapter 4](04-tmpfs-mounts.md) ➡️
