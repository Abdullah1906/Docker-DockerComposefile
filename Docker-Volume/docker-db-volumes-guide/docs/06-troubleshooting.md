# Chapter 6: Troubleshooting ও সাধারণ ভুল (Bonus)

## 6.1 সাধারণ Error ও সমাধান

| Error / লক্ষণ | সম্ভাব্য কারণ | সমাধান |
|---|---|---|
| `initdb: directory "/var/lib/postgresql/data" exists but is not empty` + `lost+found` | Mount point এর root এ `lost+found` | `PGDATA=/var/lib/postgresql/data/pgdata` সেট করো |
| `Permission denied` / `could not change permissions of directory` | UID/GID mismatch | `chown -R 999:999` + `chmod 700`; অথবা `user:` সেট করো |
| `data directory has wrong ownership` / `has group or world access` | Postgres এর কড়া permission নিয়ম | `chmod 700` (বা 750) ও সঠিক owner |
| SELinux এ bind mount এ `Permission denied` | SELinux label | `:z` বা `:Z` যোগ করো |
| Container restart দিলে data নেই | Volume mount হয়নি / ভুল path / tmpfs | `docker inspect <container>` এ `Mounts` section দেখো |
| `docker compose down` এর পর data গেছে | `-v` flag দেওয়া হয়েছিল | `-v` ছাড়া `down` করো; volume কে `external: true` করো |
| Init script চলছে না | Data directory খালি নয় | Volume মুছে নতুন করে শুরু করো (⚠️ data যাবে) |
| `could not resize shared memory segment` | `/dev/shm` ছোট (default 64MB) | `shm_size: 256mb` বা বেশি |
| `No space left on device` (tmpfs) | tmpfs `size` ছোট | `size=` বাড়াও বা RAM বাড়াও |
| Windows এ database অতি ধীর / error | NTFS bind mount | Named Volume বা WSL2 এর ভেতরের path |
| Volume দেখাচ্ছে কিন্তু ভেতরে কিছু নেই | Compose project নাম বদলে নতুন volume বেছে নিয়েছে | `docker volume ls`; `name:` দিয়ে নির্দিষ্ট নাম দাও |
| Postgres 18+ এ পুরোনো mount path এ সমস্যা | Data directory layout বদলেছে | `/var/lib/postgresql` এ mount করো |

## 6.2 Debug কমান্ড

```bash
# Container এ কী কী mount হয়েছে (সবচেয়ে কাজের command)
docker inspect pg-prod --format '{{ json .Mounts }}' | python3 -m json.tool

# Volume এর ভেতরে কী আছে (helper container দিয়ে)
docker run --rm -v myapp_pgdata:/data alpine ls -la /data

# Container এর ভেতরে permission/ownership দেখা
docker exec pg-prod ls -la /var/lib/postgresql/data

# Container log
docker logs --tail 100 -f pg-prod

# Compose এর final resolved configuration
docker compose config
```

## 6.3 ❌ এড়িয়ে চলো (Anti-Patterns)

```bash
# ❌ ১. Volume ছাড়া production database
docker run -d postgres:17

# ❌ ২. 'latest' tag — অপ্রত্যাশিত major upgrade এ data directory incompatible হয়ে যেতে পারে
image: postgres:latest

# ❌ ৩. Compose এ password সরাসরি লিখে Git এ commit
POSTGRES_PASSWORD: admin123

# ❌ ৪. Database কে সবার জন্য expose
ports: ["5432:5432"]          # ভালো: "127.0.0.1:5432:5432"

# ❌ ৫. চলমান database এর data folder সরাসরি cp/tar (inconsistent backup)
cp -r /var/lib/docker/volumes/pgdata/_data /backup/

# ❌ ৬. ভুল করে সব volume মুছে ফেলা
docker volume prune -a
docker compose down -v

# ❌ ৭. Production এ fsync বন্ধ (শুধু test এর জন্য)
-c fsync=off
```

---

⬅️ [আগের: Chapter 5](05-production-best-practices.md) | 🏠 [সূচিপত্র](../README.md) | [পরের: Appendix A](07-cheatsheet.md) ➡️
