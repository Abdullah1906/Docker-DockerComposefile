# 🐳 Docker Volume Mounting Methods for Databases

> PostgreSQL, MySQL, MongoDB, SQL Server ও Redis এর জন্য Docker Storage এর **production-ready** গাইড (বাংলা)। Named Volume, Bind Mount ও tmpfs, কোনটা কখন, কীভাবে, আর কী কী ভুল এড়াতে হবে।

---

## 📚 Chapters

| # | Chapter | কী শিখবে |
|---|---|---|
| 1 | [Docker Storage ও Database Persistence](docs/01-introduction.md) | কেন container এ data হারায়, তিন ধরনের mount এর তুলনা |
| 2 | [Named Volumes](docs/02-named-volumes.md) ⭐ | Production এ recommended পদ্ধতি, driver options, backup/restore |
| 3 | [Bind Mounts](docs/03-bind-mounts.md) | Development, config/seed inject, permission ও security সতর্কতা |
| 4 | [tmpfs Mounts](docs/04-tmpfs-mounts.md) | In-memory test database, cache, data loss এর ঝুঁকি |
| 5 | [Production Best Practices](docs/05-production-best-practices.md) | UID/GID, backup/migration, performance tuning, checklist |
| 6 | [Troubleshooting](docs/06-troubleshooting.md) | সাধারণ error ও সমাধান, anti-pattern |
| A | [Cheat Sheet](docs/07-cheatsheet.md) | এক নজরে syntax ও command |

---

## ⚡ দ্রুত শুরু (Quick Start)

**Prerequisites:** Docker Engine 24+ (বা Docker Desktop) ও Docker Compose v2 (`docker compose`)।

```bash
# ১. Repo clone করো
git clone https://github.com/<your-username>/docker-db-volumes-guide.git
cd docker-db-volumes-guide/examples/postgres

# ২. Password secret বানাও (Git এ যাবে না)
printf 'YourStrongPassword' > secrets/db_password.txt
chmod 600 secrets/db_password.txt

# ৩. Production-style (Named Volume) চালাও
docker compose up -d
docker compose ps                  # health "healthy" হওয়া পর্যন্ত অপেক্ষা করো

# ৪. Data persist হচ্ছে কিনা পরীক্ষা করো
docker exec pg-prod psql -U appuser -d appdb -c "SELECT * FROM products;"
docker compose down                # ⚠️ '-v' দিও না, দিলে volume ও মুছে যাবে
docker compose up -d               # data আগের মতোই থাকবে ✅
```

---

## 🧭 কোনটা কখন?

| পরিস্থিতি | বেছে নাও | Example |
|---|---|---|
| **Production database** | **Named Volume** | [`examples/postgres/docker-compose.yml`](examples/postgres/docker-compose.yml) |
| **Local development** | Named Volume (data) + Bind Mount (config/seed) | [`docker-compose.dev.yml`](examples/postgres/docker-compose.dev.yml) |
| **CI / Test database** | **tmpfs** | [`docker-compose.test.yml`](examples/postgres/docker-compose.test.yml) |
| **Windows/macOS এ DB data** | Named Volume (bind mount নয়) | — |

---

## 📁 Repository Structure

```
docker-db-volumes-guide/
├── README.md                          ← এই file
├── docs/                              ← Chapter গুলো
│   ├── 01-introduction.md
│   ├── 02-named-volumes.md
│   ├── 03-bind-mounts.md
│   ├── 04-tmpfs-mounts.md
│   ├── 05-production-best-practices.md
│   ├── 06-troubleshooting.md
│   └── 07-cheatsheet.md
├── examples/                          ← চালানোর মতো আসল compose file
│   ├── postgres/   (prod, dev, test + config + initdb)
│   ├── mysql/
│   ├── mongodb/
│   └── sqlserver/
├── scripts/                           ← Backup / restore / migrate
│   ├── backup-postgres.sh
│   ├── restore-postgres.sh
│   └── migrate-volume.sh
├── .gitignore                         ← data, backup, secret Git এ যাবে না
└── LICENSE
```

---

## 🛠️ Scripts

```bash
chmod +x scripts/*.sh                                   # প্রথমবার executable করো

./scripts/backup-postgres.sh                            # logical backup নাও
./scripts/restore-postgres.sh backups/appdb_xxx.dump    # restore করো
./scripts/migrate-volume.sh pgdata pgdata_v2 pg-prod    # volume migrate করো
```

প্রতিটি script এর উপরে ব্যবহারবিধি ও environment variable লেখা আছে।

---

## ⚠️ গুরুত্বপূর্ণ নোট

- Example গুলো শুরুর ধাপ হিসেবে দেওয়া। নিজের hardware, workload ও security নীতি অনুযায়ী বদলে নাও।
- Image এর behavior version অনুযায়ী বদলায় (যেমন **PostgreSQL 18+** এ data mount path `/var/lib/postgresql`)। Production এ তোলার আগে [official image docs](https://hub.docker.com/_/postgres) মিলিয়ে নাও।
- `docker compose down -v` ও `docker volume prune -a` **data মুছে ফেলে**। ব্যবহারের আগে দুইবার ভাবো।
- **Backup restore করে পরীক্ষা না করলে সেটা backup নয়।**

---

## 🤝 Contributing

Pull Request ও Issue স্বাগত। ভুল বা পুরোনো তথ্য পেলে জানিও।

## 📄 License

[MIT](LICENSE)
