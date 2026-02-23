# 🚀 Infrastructure Architecture — Docker + Waitlist Automation

> **Repo:** `infra/`  
> **Stack:** Docker Compose · Nginx · Let's Encrypt · Google Apps Script · Clearbit/Hunter.io · Slack Webhooks

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Docker Compose Services](#docker-compose-services)
3. [Nginx Reverse Proxy](#nginx-reverse-proxy)
4. [Environment Management](#environment-management)
5. [Waitlist Automation Pipeline](#waitlist-automation-pipeline)
6. [Lead Enrichment](#lead-enrichment)
7. [Health Checks](#health-checks)
8. [Setup Scripts](#setup-scripts)
9. [Directory Structure](#directory-structure)
10. [Deployment Checklist](#deployment-checklist)

---

## System Overview

The infrastructure layer ties all four services together into a single deployable unit, with automated lead capture and enrichment for the pre-launch waitlist.

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│                    Nginx (Port 80/443)                  │
│                    + SSL (Let's Encrypt)                │
└──────┬────────────────────┬──────────────────┬──────────┘
       │                    │                  │
       ▼                    ▼                  ▼
 :3000 Frontend       :8000 Backend      :8001 AI Service
 (Next.js)            (FastAPI)          (ModelRouter)
       │                    │
       └──────────────┬─────┘
                      ▼
               :5432 PostgreSQL
               :6379 Redis
```

```
Waitlist Flow
    │
    ▼
Google Form submission
    │
    ▼
Google Apps Script trigger
    ├── Write to Google Sheet
    ├── Enrich lead via Clearbit / Hunter.io
    └── POST to Slack/Discord webhook
              │
              ▼
         #leads channel alert
```

---

## Docker Compose Services

### `docker-compose.yaml`

```yaml
version: "3.9"

services:

  frontend:
    build: ./frontend
    ports:
      - "3000:3000"
    environment:
      - NEXT_PUBLIC_API_BASE_URL=http://backend:8000
    depends_on:
      backend:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3

  backend:
    build: ./backend
    ports:
      - "8000:8000"
    env_file: ./backend/.env
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s

  ai:
    build: ./ai
    ports:
      - "8001:8001"
    env_file: ./ai/.env
    volumes:
      - ./ai/weights:/app/weights  # Mount local model weights
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8001/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  db:
    image: postgres:latest
    environment:
      POSTGRES_DB: saas_db
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d saas_db"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:latest
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

  nginx:
    image: nginx:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./infra/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./infra/nginx/certs:/etc/letsencrypt:ro
    depends_on:
      - frontend
      - backend
      - ai

volumes:
  postgres_data:
```

---

## Nginx Reverse Proxy

```nginx
# infra/nginx/nginx.conf

upstream frontend { server frontend:3000; }
upstream backend  { server backend:8000; }
upstream ai       { server ai:8001; }

server {
    listen 80;
    server_name yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    # Frontend
    location / {
        proxy_pass http://frontend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Backend API
    location /api/ {
        proxy_pass http://backend/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # SSE streaming — disable buffering
    location /api/ai/chat {
        proxy_pass http://backend/ai/chat;
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        chunked_transfer_encoding on;
    }

    # Razorpay webhooks
    location /webhooks/ {
        proxy_pass http://backend/webhooks/;
    }
}
```

---

## Environment Management

### Structure

Each service repo has its own `.env` file. Shared secrets live in `infra/.env.shared` and are propagated to sibling repos by `sync-env.sh`.

```
workspace/
│
├── infra/
│   ├── .env.shared           ← Shared secrets (INTERNAL_API_SECRET, etc.) — git-ignored
│   ├── .env.shared.example   ← Committed template with placeholder values
│   └── scripts/sync-env.sh   ← Writes shared keys into sibling .env files
│
├── frontend/
│   └── .env.local            ← Clerk keys, Razorpay public key
│
├── backend/
│   └── .env                  ← DB URL, Clerk JWKS, Razorpay secret + synced shared keys
│
└── ai/
    └── .env                  ← Anthropic/OpenAI/Google API keys + synced shared keys
```

### `sync-env.sh`

```bash
#!/bin/bash
# infra/scripts/sync-env.sh — Propagates shared environment variables to sibling service repos
# Expects WORKSPACE env var to be set (done automatically by setup.sh)
# Can also be run standalone: WORKSPACE=$(cd .. && pwd) bash scripts/sync-env.sh

set -e

WORKSPACE="${WORKSPACE:-$(cd .. && pwd)}"
SHARED_ENV="$(pwd)/.env.shared"

if [ ! -f "$SHARED_ENV" ]; then
  echo "❌ Error: .env.shared not found in $(pwd). Copy .env.shared.example first."
  exit 1
fi

echo "🔄 Syncing shared environment variables from $SHARED_ENV ..."

# Service .env paths — sibling repos relative to workspace
TARGETS=(
  "$WORKSPACE/backend/.env"
  "$WORKSPACE/ai/.env"
)

for TARGET_ENV in "${TARGETS[@]}"; do
  if [ ! -f "$TARGET_ENV" ]; then
    echo "  ⚠️  Skipping $TARGET_ENV — file not found (run setup.sh first)"
    continue
  fi

  # Remove existing lines for shared keys, then append fresh values
  while IFS='=' read -r key _; do
    [[ "$key" =~ ^#|^[[:space:]]*$ ]] && continue
    sed -i "/^${key}=/d" "$TARGET_ENV"
  done < "$SHARED_ENV"

  cat "$SHARED_ENV" >> "$TARGET_ENV"
  echo "  ✅ Synced → $TARGET_ENV"
done

echo "🎉 Environment sync complete."
```

---

## Waitlist Automation Pipeline

```
Step 1: User fills out waitlist Google Form
        ↓
Step 2: Form submission triggers Google Apps Script (onFormSubmit trigger)
        ↓
Step 3: Apps Script extracts email, name, company
        ↓
Step 4: Call Clearbit or Hunter.io API to enrich company data
        ↓
Step 5: Write enriched lead to Google Sheet (append row)
        ↓
Step 6: Evaluate lead score (company size, domain match)
        ↓
Step 7: POST to Slack webhook if lead is high-value (>50 employees)
```

### Google Apps Script

```javascript
// waitlist/Code.gs — deployed as Google Apps Script

const SHEET_NAME = "Waitlist Leads";
const CLEARBIT_API_KEY = PropertiesService.getScriptProperties().getProperty("CLEARBIT_API_KEY");
const SLACK_WEBHOOK_URL = PropertiesService.getScriptProperties().getProperty("SLACK_WEBHOOK_URL");
const HIGH_VALUE_THRESHOLD = 50; // employees

function onFormSubmit(e) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_NAME);
  const { namedValues } = e;

  const name    = namedValues["Full Name"]?.[0]    || "";
  const email   = namedValues["Work Email"]?.[0]   || "";
  const company = namedValues["Company Name"]?.[0] || "";

  // Step 1: Enrich with Clearbit
  const enriched = enrichLead(email);
  const employeeCount = enriched?.company?.metrics?.employees || 0;
  const companyName   = enriched?.company?.name || company;
  const industry      = enriched?.company?.category?.industry || "Unknown";

  // Step 2: Write to Sheet
  sheet.appendRow([
    new Date(),
    name,
    email,
    companyName,
    employeeCount,
    industry,
    employeeCount >= HIGH_VALUE_THRESHOLD ? "HIGH" : "NORMAL",
  ]);

  // Step 3: Notify Slack for high-value leads
  if (employeeCount >= HIGH_VALUE_THRESHOLD) {
    notifySlack({ name, email, companyName, employeeCount, industry });
  }
}

function enrichLead(email) {
  const domain = email.split("@")[1];
  if (!domain || domain.includes("gmail") || domain.includes("yahoo")) return null;

  try {
    const response = UrlFetchApp.fetch(
      `https://company.clearbit.com/v2/companies/find?domain=${domain}`,
      { headers: { Authorization: `Bearer ${CLEARBIT_API_KEY}` } }
    );
    return JSON.parse(response.getContentText());
  } catch (err) {
    Logger.log(`Enrichment failed for ${email}: ${err}`);
    return null;
  }
}

function notifySlack({ name, email, companyName, employeeCount, industry }) {
  const payload = {
    text: `🔥 *High-Value Lead Signed Up!*`,
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `🔥 *New High-Value Waitlist Lead*\n*Name:* ${name}\n*Email:* ${email}\n*Company:* ${companyName}\n*Employees:* ${employeeCount}\n*Industry:* ${industry}`,
        },
      },
    ],
  };

  UrlFetchApp.fetch(SLACK_WEBHOOK_URL, {
    method: "post",
    contentType: "application/json",
    payload: JSON.stringify(payload),
  });
}
```

---

## Lead Enrichment

Two enrichment provider options:

| Provider | API | Best For | Cost |
|---|---|---|---|
| Clearbit | `company.clearbit.com/v2` | Company size, industry, funding | Paid |
| Hunter.io | `api.hunter.io/v2` | Email verification, domain info | Freemium |

Configure via `CLEARBIT_API_KEY` or `HUNTER_API_KEY` in Apps Script properties. The script uses Clearbit by default; swap the `enrichLead()` function to use Hunter.io if preferred.

---

## Health Checks

All compose services include health checks. The startup dependency chain is:

```
db (healthy)
    │
    ├── backend (healthy)
    │       │
    │       └── frontend (healthy)
    │
redis (healthy)
    │
    └── ai (healthy)
```

The backend will **not** attempt to connect to PostgreSQL until `pg_isready` returns success. This prevents SQLAlchemy startup errors in race conditions.

---

## Setup Scripts

### `setup.sh` — Full stack bootstrap

Each service lives in its own repository. `setup.sh` clones all three into a shared workspace folder alongside the infra repo, then wires them together with Docker Compose.

```
workspace/
├── infra/       ← this repo (contains setup.sh, docker-compose.yaml, nginx)
├── frontend/    ← cloned by setup.sh
├── backend/     ← cloned by setup.sh
└── ai/          ← cloned by setup.sh
```

```bash
#!/bin/bash
# infra/scripts/setup.sh — Clone all service repos and launch the full stack
# Run from INSIDE the infra/ directory: bash scripts/setup.sh

set -e

# ── Repo URLs ────────────────────────────────────────────────────────────────
FRONTEND_REPO="https://github.com/your-org/saas-frontend.git"
BACKEND_REPO="https://github.com/your-org/saas-backend.git"
AI_REPO="https://github.com/your-org/saas-ai.git"

# Workspace root is one level above infra/
WORKSPACE="$(cd .. && pwd)"

# ── Clone each service repo (skip if already cloned) ─────────────────────────
echo "📦 Cloning service repositories into $WORKSPACE ..."

[ -d "$WORKSPACE/frontend" ] \
  && echo "  ↳ frontend/ already exists, skipping." \
  || git clone "$FRONTEND_REPO" "$WORKSPACE/frontend"

[ -d "$WORKSPACE/backend" ] \
  && echo "  ↳ backend/ already exists, skipping." \
  || git clone "$BACKEND_REPO" "$WORKSPACE/backend"

[ -d "$WORKSPACE/ai" ] \
  && echo "  ↳ ai/ already exists, skipping." \
  || git clone "$AI_REPO" "$WORKSPACE/ai"

# ── Generate .env files from examples (never overwrite existing) ──────────────
echo ""
echo "⚙️  Generating .env files from examples..."

[ -f "$WORKSPACE/frontend/.env.local" ] \
  || cp "$WORKSPACE/frontend/.env.local.example" "$WORKSPACE/frontend/.env.local"

[ -f "$WORKSPACE/backend/.env" ] \
  || cp "$WORKSPACE/backend/.env.example" "$WORKSPACE/backend/.env"

[ -f "$WORKSPACE/ai/.env" ] \
  || cp "$WORKSPACE/ai/.env.example" "$WORKSPACE/ai/.env"

[ -f ".env.shared" ] \
  || cp ".env.shared.example" ".env.shared"

# ── Prompt operator to fill in credentials ────────────────────────────────────
echo ""
echo "⚠️  Fill in your API keys before continuing:"
echo "    $WORKSPACE/frontend/.env.local  → Clerk publishable key, Razorpay key ID"
echo "    $WORKSPACE/backend/.env         → DB URL, Clerk JWKS URL, Razorpay secret"
echo "    $WORKSPACE/ai/.env              → Anthropic, OpenAI, Google API keys"
echo "    $(pwd)/.env.shared              → INTERNAL_API_SECRET (shared across backend + ai)"
echo ""
read -p "Press ENTER when all credentials are filled in..."

# ── Sync shared secrets to backend and ai ─────────────────────────────────────
echo "🔄 Syncing shared environment variables..."
WORKSPACE="$WORKSPACE" bash scripts/sync-env.sh

# ── Launch ────────────────────────────────────────────────────────────────────
echo "🚀 Building and starting all services..."
docker-compose up -d --build

echo ""
echo "✅ Stack is running!"
echo "   Frontend : http://localhost:3000"
echo "   Backend  : http://localhost:8000"
echo "   AI       : http://localhost:8001"
echo "   Nginx    : http://localhost  (or https:// after SSL setup)"
```

---

## Directory Structure

The four repos are cloned as siblings inside a shared workspace. The `infra/` repo owns `docker-compose.yaml` and references the other three by their sibling paths via build context.

```
workspace/                          ← shared workspace root (not a repo)
│
├── infra/                          ← THIS REPO (git: saas-infra)
│   ├── nginx/
│   │   ├── nginx.conf              # Reverse proxy config
│   │   └── certs/                  # Let's Encrypt certificates (git-ignored)
│   │
│   ├── scripts/
│   │   ├── setup.sh                # Clones all repos + launches stack
│   │   └── sync-env.sh             # Propagates shared secrets
│   │
│   ├── waitlist/
│   │   └── Code.gs                 # Google Apps Script
│   │
│   ├── .env.shared                 # Shared secrets (git-ignored)
│   ├── .env.shared.example         # Template committed to git
│   └── docker-compose.yaml         # References ../frontend, ../backend, ../ai
│
├── frontend/                       ← cloned by setup.sh (git: saas-frontend)
│   ├── .env.local
│   └── ...
│
├── backend/                        ← cloned by setup.sh (git: saas-backend)
│   ├── .env
│   └── ...
│
└── ai/                             ← cloned by setup.sh (git: saas-ai)
    ├── .env
    ├── weights/
    └── ...
```

The `docker-compose.yaml` uses relative `build:` contexts to point at the sibling repos:

```yaml
services:
  frontend:
    build:
      context: ../frontend    # sibling repo
      dockerfile: Dockerfile

  backend:
    build:
      context: ../backend     # sibling repo
      dockerfile: Dockerfile

  ai:
    build:
      context: ../ai          # sibling repo
      dockerfile: Dockerfile
```

---

## Deployment Checklist

- [ ] All `.env` files populated with real credentials
- [ ] `sync-env.sh` executed after any shared secret change
- [ ] SSL certificates provisioned (`certbot certonly --nginx -d yourdomain.com`)
- [ ] `docker-compose up -d` successful with all services healthy
- [ ] Nginx responds on port 443 with valid SSL
- [ ] Backend `/health` endpoint returns 200
- [ ] Apps Script deployed with `onFormSubmit` trigger configured
- [ ] Slack webhook URL set in Apps Script properties
- [ ] Clearbit or Hunter.io API key set in Apps Script properties
- [ ] High-value lead threshold configured (`HIGH_VALUE_THRESHOLD`)
- [ ] Google Sheet created with column headers matching `appendRow()` order

---

> **Related Docs:** [Frontend ARCHITECTURE.md](../frontend/ARCHITECTURE.md) · [Backend ARCHITECTURE.md](../backend/ARCHITECTURE.md) · [AI ARCHITECTURE.md](../ai/ARCHITECTURE.md)
