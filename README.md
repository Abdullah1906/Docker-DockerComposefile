BPS (.NET 8 Backend + Angular 20 Frontend) ধরে practical CI/CD + Docker Compose workflow
```text
1. Final Architecture
                    DEVELOPER
                        │
                        │ git push
                        ▼
                  ┌───────────┐
                  │  GitHub   │
                  └─────┬─────┘
                        │
                        ▼
               ┌─────────────────┐
               │ GitHub Actions  │
               │                 │
               │ 1. Test         │
               │ 2. Build API    │
               │ 3. Build Angular│
               │ 4. Docker Build │
               │ 5. Docker Push  │
               └────────┬────────┘
                        │
                        ▼
                 ┌─────────────┐
                 │ Docker Hub  │
                 │             │
                 │ bps-api     │
                 │ bps-frontend│
                 └──────┬──────┘
                        │
                        │ SSH Deploy
                        ▼
                 ┌─────────────┐
                 │   AWS EC2   │
                 │             │
                 │ docker      │
                 │ compose     │
                 └──────┬──────┘
                        │
             docker compose pull
                        │
                        ▼
          ┌──────────────────────────┐
          │      BPS Containers      │
          │                          │
          │ Angular/Nginx            │
          │ .NET API                 │
          │ Redis                    │
          │ RabbitMQ                 │
          │ SQL Server               │
          └──────────────────────────┘
```
2. Project Structure

GitHub repository এমন :
```text
BPS/
│
├── Backend/
│   ├── BPS.API/
│   ├── BPS.Application/
│   ├── BPS.Domain/
│   ├── BPS.Infrastructure/
│   └── BPS.sln
│
├── Frontend/
│   ├── src/
│   ├── package.json
│   ├── angular.json
│   └── nginx.conf
│
├── docker-compose.yml
│
└── .github/
    └── workflows/
        └── deploy.yml
```
3. Backend Dockerfile

Backend/Dockerfile

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

WORKDIR /src

COPY . .

RUN dotnet restore "BPS.API/BPS.API.csproj"

RUN dotnet publish "BPS.API/BPS.API.csproj" \
    -c Release \
    -o /app/publish \
    --no-restore


FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final

WORKDIR /app

EXPOSE 8080

COPY --from=build /app/publish .

ENTRYPOINT ["dotnet", "BPS.API.dll"]
4. Angular Dockerfile

Frontend/Dockerfile

FROM node:22 AS build

WORKDIR /app

COPY package*.json ./

RUN npm ci

COPY . .

RUN npm run build -- --configuration production


FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf

COPY --from=build /app/dist/bps/browser /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

dist/bps/browser - actual Angular build output অনুযায়ী পরিবর্তন করবে।

5. Angular Nginx

Frontend/nginx.conf

server {

    listen 80;

    server_name _;

    root /usr/share/nginx/html;

    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

}

এটার কারণে Angular routing কাজ করবে।

যেমন:

/login
/dashboard
/admin/buses
/admin/routes
/admin/trips
6. Docker Compose

Root-এর:

docker-compose.yml
services:

  api:
    image: yourusername/bps-api:${IMAGE_TAG:-latest}
    container_name: bps-api
    restart: unless-stopped

    ports:
      - "8080:8080"

    environment:
      ASPNETCORE_ENVIRONMENT: Production
      ASPNETCORE_URLS: http://+:8080

      ConnectionStrings__DefaultConnection: ${DB_CONNECTION_STRING}

      Redis__ConnectionString: redis:6379

      RabbitMQ__Host: rabbitmq
      RabbitMQ__Username: ${RABBITMQ_USER}
      RabbitMQ__Password: ${RABBITMQ_PASSWORD}

    depends_on:
      - redis
      - rabbitmq


  frontend:
    image: yourusername/bps-frontend:${IMAGE_TAG:-latest}
    container_name: bps-frontend
    restart: unless-stopped

    ports:
      - "80:80"

    depends_on:
      - api


  redis:
    image: redis:7-alpine
    container_name: bps-redis
    restart: unless-stopped

    volumes:
      - redis_data:/data


  rabbitmq:
    image: rabbitmq:3-management
    container_name: bps-rabbitmq
    restart: unless-stopped

    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}

    ports:
      - "5672:5672"
      - "15672:15672"

    volumes:
      - rabbitmq_data:/var/lib/rabbitmq


  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: bps-sqlserver
    restart: unless-stopped

    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: ${MSSQL_SA_PASSWORD}

    ports:
      - "1433:1433"

    volumes:
      - sqlserver_data:/var/opt/mssql


volumes:

  redis_data:

  rabbitmq_data:

  sqlserver_data:
7. AWS .env

AWS server-এ:

/opt/bps/.env
IMAGE_TAG=latest

MSSQL_SA_PASSWORD=YourStrongPassword

DB_CONNECTION_STRING=Server=sqlserver,1433;Database=BPS;User Id=sa;Password=YourStrongPassword;TrustServerCertificate=True;

RABBITMQ_USER=bpsuser
RABBITMQ_PASSWORD=StrongRabbitPassword

এই .env GitHub-এ push করবে না।

.gitignore:

.env
8. GitHub Secrets

GitHub:

Repository
   ↓
Settings
   ↓
Secrets and variables
   ↓
Actions

এই secrets রাখবে:

DOCKER_USERNAME
DOCKER_PASSWORD

AWS_HOST
AWS_USERNAME
AWS_SSH_KEY
9. GitHub Actions Workflow

.github/workflows/deploy.yml

এবার proper production workflow:

name: BPS CI/CD

on:

  push:
    branches:
      - main

  workflow_dispatch:


env:

  API_IMAGE: ${{ secrets.DOCKER_USERNAME }}/bps-api

  FRONTEND_IMAGE: ${{ secrets.DOCKER_USERNAME }}/bps-frontend


jobs:

  # ==========================================
  # CI
  # ==========================================

  build:

    name: Build & Test

    runs-on: ubuntu-latest

    steps:

      - name: Checkout source
        uses: actions/checkout@v4


      # ============================
      # Backend
      # ============================

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: 8.0.x


      - name: Restore Backend
        run: |
          dotnet restore Backend/BPS.sln


      - name: Build Backend
        run: |
          dotnet build Backend/BPS.sln \
            --configuration Release \
            --no-restore


      # ============================
      # Frontend
      # ============================

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: Frontend/package-lock.json


      - name: Install Angular Dependencies
        working-directory: Frontend
        run: npm ci


      - name: Build Angular
        working-directory: Frontend
        run: npm run build -- --configuration production


  # ==========================================
  # Docker
  # ==========================================

  docker:

    name: Build & Push Docker Images

    needs: build

    runs-on: ubuntu-latest

    steps:

      - name: Checkout source
        uses: actions/checkout@v4


      - name: Login Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}


      # ============================
      # Generate image tag
      # ============================

      - name: Set Image Tag
        run: |
          echo "IMAGE_TAG=${GITHUB_SHA::7}" >> $GITHUB_ENV


      # ============================
      # API
      # ============================

      - name: Build API Image
        run: |
          docker build \
            -t $API_IMAGE:$IMAGE_TAG \
            -t $API_IMAGE:latest \
            ./Backend


      - name: Push API Image
        run: |
          docker push $API_IMAGE:$IMAGE_TAG
          docker push $API_IMAGE:latest


      # ============================
      # Frontend
      # ============================

      - name: Build Frontend Image
        run: |
          docker build \
            -t $FRONTEND_IMAGE:$IMAGE_TAG \
            -t $FRONTEND_IMAGE:latest \
            ./Frontend


      - name: Push Frontend Image
        run: |
          docker push $FRONTEND_IMAGE:$IMAGE_TAG
          docker push $FRONTEND_IMAGE:latest


  # ==========================================
  # CD
  # ==========================================

  deploy:

    name: Deploy to AWS

    needs: docker

    runs-on: ubuntu-latest

    steps:

      - name: Deploy
        uses: appleboy/ssh-action@v1.2.0

        with:

          host: ${{ secrets.AWS_HOST }}

          username: ${{ secrets.AWS_USERNAME }}

          key: ${{ secrets.AWS_SSH_KEY }}

          script: |

            cd /opt/bps

            echo "Pulling latest images..."

            docker compose pull

            echo "Starting containers..."

            docker compose up -d

            echo "Removing unused images..."

            docker image prune -f

            echo "Deployment completed."

            docker compose ps

            
10. এখন আসল Workflow

এখন developer হিসেবে শুধু এই কাজ করবে:

git add .

তারপর:

git commit -m "Update trip booking"

তারপর:

git push origin main


11. এরপর ভিতরে ভিতরে কী হবে?
Step 1

GitHub code receive করবে।

git push
     ↓
GitHub Repository
Step 2 — CI শুরু

GitHub Actions:

Checkout
   ↓
.NET Restore
   ↓
.NET Build
   ↓
Angular npm ci
   ↓
Angular Production Build

যদি এখানে error হয়:

❌ CI FAILED

তাহলে Docker image build হবে না।

এটা গুরুত্বপূর্ণ।

Code
 ↓
Test/Build
 ↓
❌ Error
 ↓
STOP
12. CI successful হলে Docker build
CI SUCCESS
     ↓
Docker Login
     ↓
Build API
     ↓
Build Angular

commit:

8f31a21

তাহলে:

yourusername/bps-api:8f31a21
yourusername/bps-frontend:8f31a21

Docker Hub-এ যাবে।

সাথে:

yourusername/bps-api:latest
yourusername/bps-frontend:latest

ও update হবে।

13. তারপর CD

Docker push successful হলে:

GitHub Actions
      │
      │ SSH
      ▼
AWS EC2

AWS-এ command চলবে:

cd /opt/bps

তারপর:

docker compose pull

এটা Docker Hub থেকে নতুন image নিয়ে আসবে।

তারপর:

docker compose up -d

Docker Compose নতুন image দিয়ে container recreate করবে।

14. Final deployment flow

পুরো বিষয়টা মনে রাখার জন্য:
```text

                 ┌──────────────┐
                 │  Developer   │
                 └──────┬───────┘
                        │
                     git push
                        │
                        ▼
                 ┌──────────────┐
                 │    GitHub    │
                 └──────┬───────┘
                        │
                        ▼
             ┌─────────────────────┐
             │   GitHub Actions    │
             │                     │
             │       CI            │
             │   ┌─────────────┐   │
             │   │ .NET Build  │   │
             │   │ Angular     │   │
             │   │ Test        │   │
             │   └──────┬──────┘   │
             │          │          │
             │       SUCCESS       │
             │          │          │
             │       Docker        │
             │          │          │
             │   Build API         │
             │   Build Frontend    │
             └──────────┬──────────┘
                        │
                        ▼
                 ┌──────────────┐
                 │ Docker Hub   │
                 │              │
                 │ API:v1       │
                 │ API:latest   │
                 │              │
                 │ UI:v1        │
                 │ UI:latest    │
                 └──────┬───────┘
                        │
                     SSH/CD
                        │
                        ▼
                 ┌──────────────┐
                 │   AWS EC2    │
                 │              │
                 │ docker       │
                 │ compose pull │
                 │      ↓       │
                 │ compose up   │
                 └──────┬───────┘
                        │
                        ▼
              ┌────────────────────┐
              │   BPS Production   │
              │                    │
              │ Angular + Nginx    │
              │ .NET API           │
              │ Redis              │
              │ RabbitMQ           │
              │ SQL Server         │
              └────────────────────┘
```
15. CI আর CD আলাদা করে মনে রাখো

CI = Code ঠিক আছে কিনা যাচাই + image তৈরি/push
```text
GitHub
 ↓
Build
 ↓
Test
 ↓
Docker Build
 ↓
Docker Hub

CD = নতুন image production-এ deploy

Docker Hub
 ↓
AWS
 ↓
docker compose pull
 ↓
docker compose up -d
```
তোমার daily কাজ
git add .
git commit -m "my changes"
git push origin main

এরপর:
```text
GitHub Actions
      ↓
CI
      ↓
Docker Hub
      ↓
CD
      ↓
AWS
      ↓
Docker Compose
      ↓
Production Updated
```
