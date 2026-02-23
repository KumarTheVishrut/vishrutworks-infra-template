# saas-infra

> Docker Compose orchestration, Nginx reverse proxy, and waitlist automation for a B2B AI SaaS.

![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)
![Nginx](https://img.shields.io/badge/Proxy-Nginx-009639?logo=nginx)
![PostgreSQL](https://img.shields.io/badge/DB-PostgreSQL-336791?logo=postgresql)
![Redis](https://img.shields.io/badge/Cache-Redis-red?logo=redis)

---

## What this is

`saas-infra` is the deployment hub for the entire stack. It owns:

- **`docker-compose.yaml`** — wires all four service repos into a single running stack
- **Nginx config** — SSL termination and reverse proxy for frontend, backend, and AI service
- **`setup.sh`** — one-command bootstrap that clones all three service repos and launches everything
- **`sync-env.sh`** — propagates shared secrets (like `INTERNAL_API_SECRET`) across sibling repos
- **Waitlist automation** — Google Apps Script that enriches leads via Clearbit and pings Slack for high-value signups

---

## Workspace layout

This repo is designed to sit alongside the three service repos in a shared workspace:

```
workspace/
├── infra/       ← this repo
├── frontend/    ← cloned by setup.sh
├── backend/     ← cloned by setup.sh
└── ai/          ← cloned by setup.sh
```

`docker-compose.yaml` references the sibling repos via relative `build: context: ../` paths.

---

## Prerequisites

- Docker + Docker Compose
- Git
- A domain name with DNS pointing to your server (for SSL)
- `certbot` for Let's Encrypt SSL (or bring your own certs)

---

## Getting started (full stack)

```bash
# 1. Clone this repo
git clone https://github.com/your-org/saas-infra.git infra
cd infra

# 2. Run setup — clones all service repos, generates .env files, launches stack
bash scripts/setup.sh
```

`setup.sh` will:
1. Clone `saas-frontend`, `saas-backend`, and `saas-ai` into sibling directories
2. Copy `.env.example` → `.env` for each service (won't overwrite existing files)
3. Pause and ask you to fill in credentials
4. Run `sync-env.sh` to propagate shared secrets
5. Run `docker-compose up -d --build`

---

## Manual startup (if repos already cloned)

```bash
# From inside infra/
WORKSPACE=$(cd .. && pwd) bash scripts/sync-env.sh
docker-compose up -d --build
```

---

## Environment variables

### Shared secrets — `infra/.env.shared`

```bash
# Propagated to backend and ai by sync-env.sh
INTERNAL_API_SECRET=...   # Random secret shared between backend and AI service
```

```bash
cp .env.shared.example .env.shared
# Fill in, then run sync-env.sh
```

Each service repo has its own `.env` / `.env.local` — see their individual READMEs for the full variable list.

---

## Services

| Service | Port | Description |
|---|---|---|
| `nginx` | 80, 443 | Reverse proxy + SSL termination |
| `frontend` | 3000 (internal) | Next.js dashboard |
| `backend` | 8000 (internal) | FastAPI API |
| `ai` | 8001 (internal) | Multi-LLM model router (internal only, not proxied publicly) |
| `db` | 5432 (internal) | PostgreSQL |
| `redis` | 6379 (internal) | Redis cache |

Only ports 80 and 443 are exposed publicly. All inter-service communication happens on the internal Docker network.

---

## Startup dependency chain

```
db (healthy)
    ├── backend (healthy)
    │       └── frontend
    │
redis (healthy)
    └── ai
```

All `depends_on` conditions use `service_healthy` — services wait for health checks to pass, not just for containers to start.

---

## SSL setup

```bash
# Provision Let's Encrypt certificate (run on your server)
certbot certonly --nginx -d yourdomain.com -d www.yourdomain.com

# Certs land in /etc/letsencrypt/live/yourdomain.com/
# nginx.conf mounts this path — no further config needed
```

---

## Syncing shared secrets

Whenever you change `INTERNAL_API_SECRET` or add a new shared variable:

```bash
# From inside infra/
WORKSPACE=$(cd .. && pwd) bash scripts/sync-env.sh

# Then restart affected services
docker-compose restart backend ai
```

---

## Project structure

```
infra/
├── nginx/
│   ├── nginx.conf              # Reverse proxy, SSL, SSE streaming config
│   └── certs/                  # Let's Encrypt certs (git-ignored)
│
├── scripts/
│   ├── setup.sh                # Full stack bootstrap (clone + configure + launch)
│   └── sync-env.sh             # Propagates .env.shared to sibling repos
│
├── waitlist/
│   └── Code.gs                 # Google Apps Script for waitlist automation
│
├── .env.shared                 # Shared secrets (git-ignored)
├── .env.shared.example         # Template — committed to git
└── docker-compose.yaml
```

---

## Waitlist automation

A Google Apps Script (`waitlist/Code.gs`) connects to your waitlist Google Form and runs on every submission:

1. Extracts email, name, company from the form response
2. Calls **Clearbit** (or Hunter.io) to enrich the lead with company size and industry
3. Appends the enriched lead to a **Google Sheet**
4. If the company has 50+ employees → posts a rich alert to **Slack**

### Setup

1. Open [Google Apps Script](https://script.google.com) and create a new project linked to your waitlist Google Sheet
2. Paste the contents of `waitlist/Code.gs`
3. Set Script Properties:
   - `CLEARBIT_API_KEY` — from [clearbit.com](https://clearbit.com)
   - `SLACK_WEBHOOK_URL` — from your Slack app's Incoming Webhooks config
4. Add a trigger: **From spreadsheet → On form submit → `onFormSubmit`**

---

## Useful commands

```bash
# Start all services
docker-compose up -d

# View logs for a specific service
docker-compose logs -f backend

# Restart a single service
docker-compose restart ai

# Stop everything
docker-compose down

# Stop and remove volumes (⚠️ deletes DB data)
docker-compose down -v

# Rebuild a single service after code changes
docker-compose up -d --build backend

# Check health of all services
docker-compose ps
```

---

## Deployment checklist

- [ ] All `.env` files populated with real credentials
- [ ] `sync-env.sh` run after filling in `INTERNAL_API_SECRET`
- [ ] SSL certificate provisioned and paths correct in `nginx.conf`
- [ ] `docker-compose up -d` — all services show as `healthy`
- [ ] `https://yourdomain.com` loads the frontend
- [ ] `https://yourdomain.com/api/health` returns `200`
- [ ] Apps Script deployed with `onFormSubmit` trigger active
- [ ] Clearbit or Hunter.io API key set in Script Properties
- [ ] Slack webhook URL set in Script Properties
- [ ] Test form submission end-to-end — check Sheet and Slack

---

## Related repos

| Repo | Role |
|---|---|
| [saas-frontend](../frontend) | Next.js dashboard |
| [saas-backend](../backend) | FastAPI API |
| [saas-ai](../ai) | Multi-LLM inference service |

---

## Docs

- [ARCHITECTURE.md](./ARCHITECTURE.md) — full compose stack, Nginx config, env structure, Apps Script pipeline
- [INSTRUCTION.md](./INSTRUCTION.md) — agent directives, health check patterns, SSE config, anti-patterns
