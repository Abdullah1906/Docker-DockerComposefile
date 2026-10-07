# Appendix A: Quick Cheat Sheet

## Mount Syntax এক নজরে

```bash
# ── Named Volume ──
-v myvol:/var/lib/postgresql/data
--mount type=volume,source=myvol,target=/var/lib/postgresql/data

# ── Bind Mount ──
-v /abs/host/path:/container/path
-v /abs/host/path:/container/path:ro                # read-only
-v /abs/host/path:/container/path:Z                 # SELinux
--mount type=bind,source=/abs/host/path,target=/container/path,readonly

# ── tmpfs ──
--tmpfs /container/path:rw,size=512m
--mount type=tmpfs,destination=/container/path,tmpfs-size=536870912
```

## Compose এ তিনটি পদ্ধতি এক জায়গায়

```yaml
services:
  db:
    image: postgres:17
    volumes:
      - pgdata:/var/lib/postgresql/data           # ① Named Volume
      - ./initdb:/docker-entrypoint-initdb.d:ro   # ② Bind Mount (read-only)
    tmpfs:
      - /tmp                                      # ③ tmpfs

volumes:
  pgdata:                                          # Named volume declaration (bind/tmpfs এ লাগে না)
```

## Volume Commands

```bash
docker volume create <name>             # তৈরি
docker volume ls                        # তালিকা
docker volume inspect <name>            # বিস্তারিত
docker volume rm <name>                 # মুছো (কোনো container ব্যবহার না করলে)
docker volume prune                     # অব্যবহৃত anonymous volume মুছো
docker volume prune -a                  # ⚠️ সব অব্যবহৃত volume মুছো
docker system df -v                     # disk usage
```

## কোনটা কখন (এক লাইনে)

| পরিস্থিতি | বেছে নাও |
|---|---|
| Production database | **Named Volume** |
| Dev এ config/seed file | **Bind Mount (`:ro`)** |
| CI test database | **tmpfs** |
| Windows/macOS এ DB data | **Named Volume** (bind নয়) |
| Backup রাখা | **Bind Mount** বা NFS Volume |

---

⬅️ [আগের: Chapter 6](06-troubleshooting.md) | 🏠 [সূচিপত্র](../README.md)
