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
