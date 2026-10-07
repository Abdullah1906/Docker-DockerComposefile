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
- [Logging & Monitoring](#logging--monitoring)
- [Metrics Monitoring (Prometheus, cAdvisor, Grafana)](#metrics-monitoring-prometheus-cadvisor-grafana)
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
├── monitoring/
│   ├── prometheus.yml
│   └── grafana/
│       └── provisioning/
│           └── datasources/
│               └── prometheus.yml
├── .env
└── docker-compose.prod.yml
```

---

## Configuration

প্রোডাকশনের সেন্সিটিভ তথ্য কখনো কোডে হার্ডকোড করা যাবে না। রুট ফোল্ডারে `.env` ফাইল তৈরি করুন:

```env
SQL_PASSWORD=YourSuperSecretPassword_2026!
ASPNETCORE_ENVIRONMENT=Production
# Seq admin password hash (generate: see "Logging & Monitoring"; every $ must be written as $$)
SEQ_ADMIN_PASSWORD_HASH=
# Grafana admin password
GRAFANA_ADMIN_PASSWORD=ChangeMe_Grafana_2026!
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
    # Access/error logs go to stdout/stderr so Docker can collect them
    log_format main '$remote_addr [$time_local] "$request" $status $body_bytes_sent '
                    'rid=$request_id upstream=$upstream_addr rt=$request_time urt=$upstream_response_time';
    access_log /dev/stdout main;
    error_log  /dev/stderr warn;

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
            proxy_set_header X-Request-ID $request_id;   # request tracing across Nginx → API
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
# Shared log rotation: prevents container logs from filling the disk
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

services:
  # 1. SQL Server (SSMS-compatible)
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: prod_sql_db
    restart: always
    logging: *default-logging
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
    logging: *default-logging
    environment:
      - ConnectionStrings__DefaultConnection=Server=sqlserver,1433;Database=ProdDb;User Id=sa;Password=${SQL_PASSWORD};TrustServerCertificate=True
      - ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT}
      - Seq__ServerUrl=http://seq:5341
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
    logging: *default-logging
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
    logging: *default-logging
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

  # 5. Seq — centralized log server (all backend replicas ship logs here)
  seq:
    image: datalust/seq:latest
    container_name: prod_seq
    restart: always
    logging: *default-logging
    environment:
      - ACCEPT_EULA=Y
      - SEQ_FIRSTRUN_ADMINPASSWORDHASH=${SEQ_ADMIN_PASSWORD_HASH}
    ports:
      - "127.0.0.1:5341:80"   # UI শুধু লোকাল/SSH tunnel থেকে
    volumes:
      - seq_data:/data
    deploy:
      resources:
        limits:
          memory: 1G
    networks:
      - prod-net

  # 6. cAdvisor — per-container CPU / memory / network / disk metrics
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: prod_cadvisor
    restart: always
    logging: *default-logging
    privileged: true
    devices:
      - /dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    deploy:
      resources:
        limits:
          memory: 256M
    networks:
      - prod-net

  # 7. Prometheus — metrics collection & storage
  prometheus:
    image: prom/prometheus:v2.53.0
    container_name: prod_prometheus
    restart: always
    logging: *default-logging
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
    ports:
      - "127.0.0.1:9090:9090"   # শুধু লোকাল/SSH tunnel থেকে
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    depends_on:
      - cadvisor
    networks:
      - prod-net

  # 8. Grafana — dashboards & alerts
  grafana:
    image: grafana/grafana:11.1.0
    container_name: prod_grafana
    restart: always
    logging: *default-logging
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    ports:
      - "127.0.0.1:3000:3000"   # শুধু লোকাল/SSH tunnel থেকে
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
    depends_on:
      - prometheus
    networks:
      - prod-net

volumes:
  mssql_prod_data:
    driver: local
  seq_data:
    driver: local
  prometheus_data:
    driver: local
  grafana_data:
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

## Logging & Monitoring

৩টি ব্যাকএন্ড রেপ্লিকার লগ আলাদা আলাদা কন্টেইনারে ছড়িয়ে থাকলে ডিবাগ করা কঠিন। তাই সব লগ **Seq**-এ কেন্দ্রীভূত করা হয়েছে (structured logging + search + alerting)।

```
Backend replicas (Serilog) ──▶ Seq :5341 ◀── Browse / Search / Alert
Nginx, Frontend, SQL Server ──▶ Docker json-file (rotated) ──▶ docker compose logs
```

### 1. Setup: Seq admin password

পাসওয়ার্ড হ্যাশ তৈরি করুন এবং `.env`-এ `SEQ_ADMIN_PASSWORD_HASH`-এ বসান:

```bash
echo 'YourSeqPassword' | docker run --rm -i datalust/seq config hash
```

> Compose `$` চিহ্নকে variable ধরে, তাই হ্যাশের প্রতিটি `$` লিখতে হবে `$$` হিসেবে।

### 2. .NET Backend: Serilog

প্যাকেজ ইনস্টল:

```bash
dotnet add package Serilog.AspNetCore
dotnet add package Serilog.Sinks.Seq
dotnet add package Serilog.Enrichers.Environment
```

`Program.cs`:

```csharp
using Serilog;

builder.Host.UseSerilog((ctx, lc) => lc
    .ReadFrom.Configuration(ctx.Configuration)
    .Enrich.FromLogContext()
    .Enrich.WithMachineName()                         // কোন রেপ্লিকা থেকে লগ এসেছে (container ID)
    .Enrich.WithProperty("Application", "MyBackend")
    .WriteTo.Console()
    .WriteTo.Seq(ctx.Configuration["Seq:ServerUrl"] ?? "http://seq:5341"));

builder.Services.AddHealthChecks();

var app = builder.Build();

app.UseSerilogRequestLogging();                       // প্রতিটি HTTP request-এর summary log
app.MapHealthChecks("/health");
```

`Seq__ServerUrl` Compose environment variable থেকে স্বয়ংক্রিয়ভাবে `Seq:ServerUrl` কনফিগারেশনে ম্যাপ হয়।

### 3. Seq UI অ্যাক্সেস

Seq UI পাবলিকলি এক্সপোজ করা হয়নি। রিমোট সার্ভারে SSH tunnel ব্যবহার করুন:

```bash
ssh -L 5341:127.0.0.1:5341 user@your-server-ip
# তারপর ব্রাউজারে: http://localhost:5341
```

কাজে লাগার মতো কিছু Seq query:

```
@Level = 'Error'
Application = 'MyBackend' and @Level in ['Error', 'Fatal']
Elapsed > 1000                       -- ধীর রিকোয়েস্ট (ms)
MachineName = 'a1b2c3d4e5f6'         -- নির্দিষ্ট রেপ্লিকার লগ
```

### 4. Log Retention

ডিস্ক ভরে যাওয়া ঠেকাতে Seq UI → **Settings → Retention**-এ একটি পলিসি দিন (যেমন ৩০ দিন)।

### 5. Alerting

Seq UI → **Settings → Apps** থেকে Email/Slack অ্যাপ ইনস্টল করে একটি **Signal** ও **Alert** তৈরি করুন। যেমন: গত ৫ মিনিটে `@Level = 'Error'` ১০টির বেশি হলে নোটিফিকেশন।

### 6. Quick CLI Commands

```bash
# সব সার্ভিসের লাইভ লগ
docker compose -f docker-compose.prod.yml logs -f --tail=100

# শুধু Nginx load balancer (upstream ও response time সহ)
docker compose -f docker-compose.prod.yml logs -f loadbalancer

# শুধু error লাইনগুলো
docker compose -f docker-compose.prod.yml logs backend | grep -i "error"

# কন্টেইনারের CPU/Memory ব্যবহার
docker stats
```

> Seq লগ ও ইভেন্ট দেখায়। CPU/memory-র মতো সময়ের সাথে metric ট্রেন্ডের জন্য পরের section দেখুন।

---

## Metrics Monitoring (Prometheus, cAdvisor, Grafana)

লগ বলে *কী ঘটেছে*, আর metrics বলে *সিস্টেম কেমন চলছে* (CPU, memory, request rate, latency)। এই স্ট্যাকে তিনটি টুল একসাথে কাজ করে:

```
cAdvisor ──────────────┐
Backend /metrics (x3) ─┼──▶ Prometheus :9090 ──▶ Grafana :3000 (Dashboards + Alerts)
Prometheus itself ─────┘
```

| Tool | কাজ |
|---|---|
| **cAdvisor** | প্রতিটি কন্টেইনারের CPU, memory, network, disk metrics সংগ্রহ করে |
| **Prometheus** | নির্দিষ্ট বিরতিতে সব টার্গেট থেকে metrics টেনে এনে সংরক্ষণ করে (১৫ দিন) |
| **Grafana** | Prometheus-এর ডাটা থেকে ড্যাশবোর্ড ও alert তৈরি করে |

### 1. Prometheus config — `monitoring/prometheus.yml`

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: cadvisor
    static_configs:
      - targets: ['cadvisor:8080']

  # সব backend replica স্বয়ংক্রিয়ভাবে খুঁজে নেয় (Docker DNS)
  - job_name: backend
    metrics_path: /metrics
    dns_sd_configs:
      - names: ['backend']
        type: A
        port: 8080
```

`dns_sd_configs` ব্যবহার করায় `--scale backend=5` করলে নতুন রেপ্লিকাগুলো কিছুক্ষণের মধ্যে (ডিফল্ট ৩০ সেকেন্ড) নিজে থেকেই scrape তালিকায় আসে। আলাদা করে কিছু বদলাতে হয় না।

### 2. Grafana datasource — `monitoring/grafana/provisioning/datasources/prometheus.yml`

Grafana চালু হওয়ার সাথে সাথে Prometheus সংযুক্ত হয়ে যাবে, হাতে সেটআপ লাগবে না:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

### 3. .NET Backend metrics (`prometheus-net`)

```bash
dotnet add package prometheus-net.AspNetCore
```

`Program.cs`:

```csharp
using Prometheus;

app.UseRouting();
app.UseHttpMetrics();   // request count, duration, in-progress
app.MapMetrics();       // exposes /metrics
```

> `/metrics` শুধু Docker নেটওয়ার্কের ভেতরে `backend:8080`-এ পৌঁছানো যায়। Nginx শুধু `/api/` ফরোয়ার্ড করে, তাই এই endpoint পাবলিকলি খোলা নয়। তবু প্রোডাকশনে `/metrics`-এ অতিরিক্ত সুরক্ষা (যেমন নেটওয়ার্ক-লেভেল সীমাবদ্ধতা) রাখা ভালো।

### 4. চালু করা

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

Prometheus টার্গেট ঠিক আছে কিনা দেখুন (`http://localhost:9090/targets`), সব টার্গেট **UP** হওয়া উচিত।

### 5. Dashboard অ্যাক্সেস (SSH tunnel)

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 user@your-server-ip
```

- Grafana: `http://localhost:3000` (user: `admin`, password: `.env`-এর `GRAFANA_ADMIN_PASSWORD`)
- Prometheus: `http://localhost:9090`

Grafana → **Dashboards → New → Import** থেকে ready-made ড্যাশবোর্ড ইমপোর্ট করা যায়। [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards/)-এ "cAdvisor" ও "prometheus-net" সার্চ করুন (যেমন cAdvisor exporter ড্যাশবোর্ড ID `14282`)।

### 6. Useful PromQL queries

```promql
# সার্ভিস অনুযায়ী CPU ব্যবহার (%)
sum by (container_label_com_docker_compose_service) (
  rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_service!=""}[1m])
) * 100

# সার্ভিস অনুযায়ী memory ব্যবহার (bytes)
sum by (container_label_com_docker_compose_service) (
  container_memory_working_set_bytes{container_label_com_docker_compose_service!=""}
)

# Backend request rate (req/sec)
sum(rate(http_requests_received_total[1m]))

# Backend 5xx error rate
sum(rate(http_requests_received_total{code=~"5.."}[5m]))

# Backend p95 response time (seconds)
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))

# চালু থাকা backend replica সংখ্যা (৩-এর কম হলে সমস্যা)
count(up{job="backend"} == 1)
```

### 7. Alerting

Grafana → **Alerting → Alert rules** থেকে এই ধরনের rule তৈরি করুন এবং **Contact points**-এ Email/Slack/Telegram সংযুক্ত করুন:

| Alert | শর্ত |
|---|---|
| Backend replica down | `count(up{job="backend"} == 1) < 3` — ২ মিনিট ধরে |
| High CPU | কোনো সার্ভিসের CPU ৮০%-এর বেশি — ৫ মিনিট ধরে |
| High memory | কন্টেইনারের memory লিমিটের ৯০%-এর বেশি |
| High error rate | ৫xx রেট গত ৫ মিনিটে নির্ধারিত সীমার বেশি |

> **Note:** cAdvisor পূর্ণ metrics দেয় **Linux সার্ভারে**। Windows/macOS-এর Docker Desktop-এ লোকাল টেস্ট করলে কিছু metrics (বিশেষ করে per-container label) অসম্পূর্ণ আসতে পারে।

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
- [ ] Docker log rotation (`max-size` / `max-file`) সব সার্ভিসে সেট করা হয়েছে
- [ ] Serilog + Seq দিয়ে ব্যাকএন্ড লগ কেন্দ্রীভূত করা হয়েছে
- [ ] Seq retention পলিসি ও error alert কনফিগার করা হয়েছে
- [ ] Seq UI পাবলিকলি এক্সপোজ করা নেই
- [ ] `/health` endpoint যোগ করা হয়েছে (ভবিষ্যতে uptime monitor সংযোগের জন্য)
- [ ] Prometheus টার্গেটগুলো (cadvisor, backend) **UP** দেখাচ্ছে
- [ ] Grafana ড্যাশবোর্ড ও alert rule (replica down, CPU, memory, 5xx) কনফিগার করা হয়েছে
- [ ] Grafana ও Prometheus পাবলিকলি এক্সপোজ করা নেই এবং শক্তিশালী `GRAFANA_ADMIN_PASSWORD` সেট করা হয়েছে
- [ ] Angular SPA রাউটিংয়ের জন্য ফ্রন্টএন্ড Nginx-এ `try_files $uri /index.html;` যোগ করা হয়েছে
- [ ] সত্যিকারের মাল্টি-নোড HA দরকার হলে Docker Swarm বা Kubernetes-এ মাইগ্রেট করার পরিকল্পনা আছে

---
