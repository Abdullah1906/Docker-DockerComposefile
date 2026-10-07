# Production-Grade Full-Stack Deployment Guide

**Angular · .NET 8 Web API · SQL Server · Nginx · Docker Compose**

একটি Production-Grade ফুল-স্ট্যাক সিস্টেমে শুধু লোকাল Docker Compose যথেষ্ট নয়। প্রোডাকশনে **High Availability**, **Security**, **Persistent Storage** এবং **Load Balancing** নিশ্চিত করতে হয়। এই গাইডে Angular Frontend, scaled .NET Backend এবং SQL Server (SSMS-compatible) একসঙ্গে ডিপ্লয় করার সম্পূর্ণ পদ্ধতি দেওয়া হয়েছে।

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Dockerfiles](#dockerfiles)
- [Nginx Load Balancer](#nginx-load-balancer)
- [Docker Compose](#docker-compose)
- [Deployment & Scaling](#deployment--scaling)
- [Connecting with SSMS](#connecting-with-ssms)
- [Production Checklist](#production-checklist)

---

## Architecture Overview

```
                    ┌──────────────────────────┐
   Internet ──────▶ │  Nginx (Load Balancer)   │  :80 / :443
                    └────────────┬─────────────┘
                 ┌───────────────┴────────────────┐
                 ▼                                ▼
      ┌─────────────────────┐          ┌──────────────────────┐
      │ Frontend (x2)       │          │ Backend .NET API (x3)│
      │ Angular + Nginx     │          │ :8080                │
      └─────────────────────┘          └──────────┬───────────┘
                                                  ▼
                                       ┌──────────────────────┐
                                       │ SQL Server 2022      │
                                       │ Persistent Volume    │
                                       └──────────────────────┘
```

| Layer | Technology | Replicas | Role |
|---|---|---|---|
| Reverse Proxy / LB | Nginx | 1 | পাবলিক ট্রাফিক রিসিভ ও ফরোয়ার্ড |
| Frontend | Angular + Nginx | 2 | Static file serving (HA) |
| Backend | .NET 8 Web API | 3 | Business logic, লোড ভাগ হয় রেপ্লিকাদের মধ্যে |
| Database | SQL Server 2022 | 1 | Persistent volume + secured credentials |

---

## Prerequisites

- Docker Engine 24+ এবং Docker Compose v2
- Git
- (Optional) SQL Server Management Studio (SSMS)

---

## Project Structure

```
production-app/
├── backend/
│   └── Dockerfile
├── frontend/
│   └── Dockerfile
├── nginx/
│   └── default.conf
├── .env
└── docker-compose.prod.yml
```

---

## Configuration

প্রোডাকশনের সেন্সিটিভ তথ্য কখনো কোডে হার্ডকোড করা যাবে না। রুট ফোল্ডারে `.env` ফাইল তৈরি করুন:

```env
SQL_PASSWORD=YourSuperSecretPassword_2026!
ASPNETCORE_ENVIRONMENT=Production
```

> **Warning:** `.env` ফাইল অবশ্যই `.gitignore`-এ যোগ করুন। GitHub-এ কখনো কমিট করবেন না।
> SQL Server-এর পাসওয়ার্ড কমপক্ষে ৮ অক্ষরের হতে হবে এবং বড় হাতের অক্ষর, ছোট হাতের অক্ষর, সংখ্যা ও সিম্বলের মধ্যে ৩টি ক্যাটাগরি থাকতে হবে।

---

## Dockerfiles

### Backend — `backend/Dockerfile`

Multi-stage build ব্যবহার করে ইমেজ সাইজ ছোট ও দ্রুত রাখা হয়েছে।

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["MyBackend.csproj", "./"]
RUN dotnet restore "MyBackend.csproj"
COPY . .
RUN dotnet publish -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish .
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "MyBackend.dll"]
```

### Frontend — `frontend/Dockerfile`

```dockerfile
FROM node:18-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build -- --configuration production

FROM nginx:alpine-slim
COPY --from=build /app/dist/my-frontend/browser /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

> **Note:** `my-frontend` এর জায়গায় আপনার Angular প্রজেক্টের আসল নাম (`angular.json` অনুযায়ী) দিন। একইভাবে `MyBackend` আপনার `.csproj` নাম অনুযায়ী পরিবর্তন করুন।

---

## Nginx Load Balancer

`nginx/default.conf` ফ্রন্টএন্ড ও ব্যাকএন্ড উভয়ের ট্রাফিক রাউট করে। Docker-এর internal DNS ব্যবহার হওয়ায় `backend` সার্ভিস নামটি সব রেপ্লিকার IP-তে resolve হয় এবং রাউন্ড-রবিন পদ্ধতিতে ট্রাফিক ভাগ হয়।

```nginx
events { worker_connections 1024; }

http {
    upstream backend_cluster {
        # 'backend' = Compose service name; Docker DNS distributes across replicas
        server backend:8080;
    }

    server {
        listen 80;

        # 1. Frontend routing
        location / {
            proxy_pass http://frontend:80;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # 2. Backend API routing
        location /api/ {
            proxy_pass http://backend_cluster/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}
```

> **Important:** Nginx upstream hostname শুধু **স্টার্টআপের সময়** resolve করে। রানটাইমে রেপ্লিকা সংখ্যা বদলালে (scale up/down) নতুন IP চিনতে Nginx reload করতে হবে:
> ```bash
> docker compose -f docker-compose.prod.yml exec loadbalancer nginx -s reload
> ```

---

## Docker Compose

`docker-compose.prod.yml` — এখানে `restart: always`, resource limits এবং healthcheck যুক্ত আছে।

```yaml
services:
  # 1. SQL Server (SSMS-compatible)
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: prod_sql_db
    restart: always
    environment:
      - ACCEPT_EULA=Y
      - MSSQL_SA_PASSWORD=${SQL_PASSWORD}
    ports:
      - "127.0.0.1:1433:1433"   # শুধু লোকাল/SSH tunnel থেকে অ্যাক্সেস
    volumes:
      - mssql_prod_data:/var/opt/mssql
    networks:
      - prod-net
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -Q 'SELECT 1' || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 30s

  # 2. .NET Backend (scaled)
  backend:
    build: ./backend
    restart: always
    environment:
      - ConnectionStrings__DefaultConnection=Server=sqlserver,1433;Database=ProdDb;User Id=sa;Password=${SQL_PASSWORD};TrustServerCertificate=True
      - ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT}
    depends_on:
      sqlserver:
        condition: service_healthy
    deploy:
      replicas: 3
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
    networks:
      - prod-net

  # 3. Frontend (scaled)
  frontend:
    build: ./frontend
    restart: always
    deploy:
      replicas: 2
      resources:
        limits:
          cpus: '0.25'
          memory: 256M
    networks:
      - prod-net

  # 4. Reverse proxy & load balancer
  loadbalancer:
    image: nginx:alpine
    container_name: prod_load_balancer
    restart: always
    volumes:
      - ./nginx/default.conf:/etc/nginx/nginx.conf:ro
    ports:
      - "80:80"
      - "443:443"   # ভবিষ্যতে SSL সার্টিফিকেটের জন্য
    depends_on:
      - backend
      - frontend
    networks:
      - prod-net

volumes:
  mssql_prod_data:
    driver: local

networks:
  prod-net:
    driver: bridge
```

---

## Deployment & Scaling

**1. বিল্ড ও রান (production mode):**

```bash
docker compose -f docker-compose.prod.yml up --build -d
```

**2. কন্টেইনার স্ট্যাটাস ও রেপ্লিকা কাউন্ট চেক:**

```bash
docker compose -f docker-compose.prod.yml ps
```

**3. রানটাইমে স্কেল করা (যেমন backend ৫টি):**

```bash
docker compose -f docker-compose.prod.yml up --scale backend=5 -d
docker compose -f docker-compose.prod.yml exec loadbalancer nginx -s reload
```

**4. লগ দেখা:**

```bash
docker compose -f docker-compose.prod.yml logs -f backend
```

**5. বন্ধ করা:**

```bash
docker compose -f docker-compose.prod.yml down
```

---

## Connecting with SSMS

| Field | Value |
|---|---|
| Server name | `localhost,1433` (অথবা সার্ভারের IP, `,` দিয়ে পোর্ট) |
| Authentication | SQL Server Authentication |
| Login | `sa` |
| Password | `.env`-এ দেওয়া `SQL_PASSWORD` |

> রিমোট সার্ভারে কানেক্ট করতে চাইলে পোর্ট ১৪৩৩ পাবলিকলি খোলার পরিবর্তে **SSH tunnel** বা VPN ব্যবহার করুন:
> ```bash
> ssh -L 1433:127.0.0.1:1433 user@your-server-ip
> ```

---

## Production Checklist

- [ ] `.env` গিট থেকে বাদ দেওয়া হয়েছে (`.gitignore`)
- [ ] শক্তিশালী `SQL_PASSWORD` সেট করা হয়েছে
- [ ] পোর্ট ১৪৩৩ পাবলিকলি এক্সপোজ করা নেই
- [ ] HTTPS/SSL (Let's Encrypt) কনফিগার করা হয়েছে
- [ ] `sa` এর বদলে সীমিত অনুমতিসহ আলাদা DB ইউজার ব্যবহার করা হয়েছে
- [ ] ডাটাবেজ ব্যাকআপ (volume snapshot / `BACKUP DATABASE`) নির্ধারিত আছে

---
