# 🤖 Infrastructure Agent Instructions — Docker + Waitlist Automation

> **Repo:** `infra/`  
> **Purpose:** Directives and execution logic for AI coding agents working on infrastructure tasks.  
> **Last Updated:** 2026-02-23

---

## ⚠️ Global Constraints

| Constraint | Rule |
|---|---|
| Secret Management | All secrets come from `.env` files. Never hardcode in compose or scripts. |
| Health Checks | Every service in `docker-compose.yaml` **must** have a `healthcheck:` block |
| Startup Order | Backend must depend on `db: condition: service_healthy` — not just `depends_on: db` |
| SSL | Never terminate SSL inside app containers — Nginx handles all TLS |
| Env Sync | After adding any shared secret, run `sync-env.sh`. Never duplicate secrets manually. |
| Webhook Privacy | Never log raw webhook payloads — they may contain PII |

---

## Global State Reference

```
Infrastructure State
├── Running Services (docker-compose)
│   ├── frontend   :3000   (Next.js)
│   ├── backend    :8000   (FastAPI)
│   ├── ai         :8001   (ModelRouter)
│   ├── db         :5432   (PostgreSQL)
│   ├── redis      :6379   (Redis)
│   └── nginx      :80/:443 (Reverse proxy + SSL)
│
├── Shared Secrets (infra/.env.shared)
│   └── INTERNAL_API_SECRET
│
├── Volumes
│   └── postgres_data  → persistent DB storage
│
└── Waitlist Pipeline
    ├── Google Form → Apps Script trigger
    ├── Clearbit enrichment
    ├── Google Sheet append
    └── Slack webhook notification
```

---

## Step-by-Step Execution Logic

### Task 1 — Add a New Service to Docker Compose

```
1. Add service block to docker-compose.yaml
2. Set build context to ../new-service (sibling repo path)
3. Define build context or image
4. Add healthcheck: block with appropriate test command
5. Add to depends_on of any services that need it
6. Expose port only if needed externally (prefer internal docker network)
7. Add any service-specific env vars to ../new-service/.env
8. If service uses INTERNAL_API_SECRET: add it to .env.shared, add ../new-service/.env
   to TARGETS in sync-env.sh, then run sync-env.sh
9. Test: docker-compose up -d <service> then docker-compose ps
```

### Task 2 — Add a Shared Environment Variable

```
1. Add variable to infra/.env.shared
2. Add variable to infra/.env.shared.example (with placeholder value)
3. Run: WORKSPACE=$(cd .. && pwd) bash scripts/sync-env.sh
4. Verify the variable appears in ../backend/.env and ../ai/.env
5. Restart affected services: docker-compose restart <service>
```

### Task 3 — Modify Nginx Routing

```
1. Edit infra/nginx/nginx.conf
2. Test config BEFORE applying: docker-compose exec nginx nginx -t
3. Reload (no downtime): docker-compose exec nginx nginx -s reload
4. For SSE endpoints: ensure proxy_buffering off and chunked_transfer_encoding on
5. For webhook endpoints: ensure proxy_read_timeout is set (webhooks can be slow)
```

### Task 4 — Update Waitlist Apps Script

```
1. Edit infra/waitlist/Code.gs
2. In Google Apps Script editor: Deploy → Manage deployments
3. Update Apps Script properties for new API keys (never commit to git)
4. Test with: Run → onFormSubmit (with test event object)
5. Check execution log for errors before going live
```

---

## Directive: Health Check Patterns

Every service must have a working health check. Use these exact patterns:

```yaml
# Web service (FastAPI, Next.js)
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:<PORT>/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 20s   # Allow time for startup migrations

# PostgreSQL
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
  interval: 10s
  timeout: 5s
  retries: 5

# Redis
healthcheck:
  test: ["CMD", "redis-cli", "ping"]
  interval: 10s
  timeout: 5s
  retries: 3
```

The `start_period` is critical for the backend — it runs Alembic migrations on startup which takes time.

---

## Directive: Service Dependency Chain

```yaml
# ✅ CORRECT — waits for healthy status, not just started
depends_on:
  db:
    condition: service_healthy
  redis:
    condition: service_healthy

# ❌ WRONG — db container may be starting but not yet accepting connections
depends_on:
  - db
  - redis
```

Always use `condition: service_healthy`. Without this, the backend will crash on first startup because SQLAlchemy tries to connect before PostgreSQL is ready.

---

## Directive: setup.sh Requirements

The setup script must:

1. `git clone` the repository
2. Copy `.env.example` → `.env` for each service (never overwrite existing `.env` if present)
3. Prompt the user to fill in credentials before launching
4. Run `sync-env.sh` automatically
5. Run `docker-compose up -d --build`
6. Print service URLs on success

```bash
# ✅ CORRECT — copy only if not exists (safe to re-run)
[ -f "../backend/.env" ] || cp "../backend/.env.example" "../backend/.env"

# ❌ WRONG — overwrites an existing .env that may have real credentials
cp "../backend/.env.example" "../backend/.env"
```

---

## Directive: sync-env.sh Requirements

The sync script must:

1. Read all key=value pairs from `infra/.env.shared`
2. For each target service: remove existing lines for those keys, then append fresh values
3. Skip comment lines and blank lines
4. Be idempotent — running twice produces the same result

```bash
# Test idempotency (run from inside infra/)
WORKSPACE=$(cd .. && pwd) bash scripts/sync-env.sh
WORKSPACE=$(cd .. && pwd) bash scripts/sync-env.sh
diff <(cat ../backend/.env) <(cat ../backend/.env)  # Should show no diff
```

---

## Directive: Apps Script Lead Enrichment

```javascript
// ✅ CORRECT — skip personal email domains for enrichment
function enrichLead(email) {
  const PERSONAL_DOMAINS = ["gmail.com", "yahoo.com", "hotmail.com", "outlook.com"];
  const domain = email.split("@")[1];
  
  if (!domain || PERSONAL_DOMAINS.includes(domain)) {
    return null;  // Skip enrichment for personal emails
  }
  
  // Proceed with Clearbit/Hunter.io call
}

// ✅ CORRECT — always wrap external API calls in try/catch
try {
  const response = UrlFetchApp.fetch(url, options);
  return JSON.parse(response.getContentText());
} catch (err) {
  Logger.log(`Enrichment failed: ${err}`);
  return null;  // Graceful degradation — still write to Sheet without enrichment
}
```

---

## Directive: Nginx SSE Configuration

SSE endpoints (AI streaming) require special Nginx directives to prevent buffering:

```nginx
# ✅ CORRECT — SSE streaming config
location /api/ai/chat {
    proxy_pass http://backend/ai/chat;
    proxy_buffering off;         # Disable response buffering
    proxy_cache off;             # Disable caching for SSE
    proxy_set_header Connection '';
    proxy_http_version 1.1;
    chunked_transfer_encoding on;
    proxy_read_timeout 300s;     # Long timeout for AI responses
}

# ❌ WRONG — default proxy will buffer SSE responses
location /api/ai/chat {
    proxy_pass http://backend/ai/chat;
}
```

---

## Anti-Patterns — Never Do These

```
❌ Never hardcode secrets in docker-compose.yaml — use env_file or environment with ${VAR}
❌ Never skip health checks — services without healthcheck break conditional depends_on
❌ Never use depends_on: [db] without condition: service_healthy
❌ Never terminate SSL in app containers — Nginx only
❌ Never commit .env files — only commit .env.example with placeholder values
❌ Never log raw Google Form submissions — they may contain PII
❌ Never expose the AI service port (8001) publicly — internal only via Nginx
❌ Never run sync-env.sh in CI/CD without verifying infra/.env.shared is populated
```

---

## Checklist Before Marking a Task Complete

- [ ] All new services have `healthcheck:` block
- [ ] Startup dependencies use `condition: service_healthy`
- [ ] No hardcoded secrets in compose or shell scripts
- [ ] New shared secrets added to `infra/.env.shared.example`
- [ ] `sync-env.sh` updated if new services were added as targets
- [ ] Nginx config tested with `nginx -t` before applying
- [ ] SSE endpoints have `proxy_buffering off`
- [ ] Apps Script API calls wrapped in try/catch
- [ ] Setup script is idempotent (safe to run twice)
- [ ] All `.env` files are in `.gitignore`

---

> **See Also:** [ARCHITECTURE.md](./ARCHITECTURE.md) · [Backend INSTRUCTION.md](../backend/INSTRUCTION.md) · [AI INSTRUCTION.md](../ai/INSTRUCTION.md)
