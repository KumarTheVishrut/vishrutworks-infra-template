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

[ -d "$WORKSPACE/frontend" ] 
  && echo "  ↳ frontend/ already exists, skipping." 
  || git clone "$FRONTEND_REPO" "$WORKSPACE/frontend"

[ -d "$WORKSPACE/backend" ] 
  && echo "  ↳ backend/ already exists, skipping." 
  || git clone "$BACKEND_REPO" "$WORKSPACE/backend"

[ -d "$WORKSPACE/ai" ] 
  && echo "  ↳ ai/ already exists, skipping." 
  || git clone "$AI_REPO" "$WORKSPACE/ai"

# ── Generate .env files from examples (never overwrite existing) ──────────────
echo ""
echo "⚙️  Generating .env files from examples..."

[ -f "$WORKSPACE/frontend/.env.local" ] 
  || cp "$WORKSPACE/frontend/.env.local.example" "$WORKSPACE/frontend/.env.local"

[ -f "$WORKSPACE/backend/.env" ] 
  || cp "$WORKSPACE/backend/.env.example" "$WORKSPACE/backend/.env"

[ -f "$WORKSPACE/ai/.env" ] 
  || cp "$WORKSPACE/ai/.env.example" "$WORKSPACE/ai/.env"

[ -f ".env.shared" ] 
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
