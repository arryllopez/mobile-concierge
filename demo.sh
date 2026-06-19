#!/usr/bin/env bash
#
# One-shot demo launcher (Option B: remote demo over a public tunnel).
#
#   ./demo.sh
#
# Starts Postgres, the backend, a cloudflared tunnel, then launches Expo with
# the tunnel URL injected so a manager can scan the QR from any network using
# Expo Go. Ctrl-C tears everything down.
set -euo pipefail
cd "$(dirname "$0")"

CF_BIN="./.tools/cloudflared"
CF_LOG="$(mktemp)"
BACKEND_PID=""
TUNNEL_PID=""

cleanup() {
  echo
  echo "Shutting down demo..."
  [ -n "$TUNNEL_PID" ]  && kill "$TUNNEL_PID"  2>/dev/null || true
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true
  # Leave Postgres running (cheap, reused next time). `docker compose down` to stop.
  rm -f "$CF_LOG"
}
trap cleanup EXIT INT TERM

# --- cloudflared (download once to a stable path; /tmp gets wiped) -----------
if [ ! -x "$CF_BIN" ]; then
  echo "Downloading cloudflared (one-time)..."
  mkdir -p .tools
  curl -sL -o "$CF_BIN" \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$CF_BIN"
fi

# --- 1. database ------------------------------------------------------------
echo "[1/4] Starting Postgres..."
docker compose up -d

# --- 2. backend -------------------------------------------------------------
echo "[2/4] Seeding + starting backend on :4000..."
# Free port 4000 if a previous run left something behind.
STALE=$(lsof -ti:4000 || true)
[ -n "$STALE" ] && { echo "  freeing stale :4000 (pid $STALE)"; kill $STALE 2>/dev/null || true; sleep 1; }
( cd server && npm run seed >/dev/null 2>&1 )   # idempotent (ON CONFLICT upserts)
# Run tsx directly (not via `npm run`) so BACKEND_PID is the actual server
# process — killing npm would orphan its tsx child and leave :4000 held.
( cd server && PORT=4000 exec npx tsx src/index.ts ) &
BACKEND_PID=$!

# wait until the API answers
for i in $(seq 1 30); do
  if curl -sf http://localhost:4000/health >/dev/null 2>&1 \
     || curl -sf http://localhost:4000/ >/dev/null 2>&1; then break; fi
  sleep 1
done

# --- 3. tunnel --------------------------------------------------------------
echo "[3/4] Opening public tunnel..."
"$CF_BIN" tunnel --url http://localhost:4000 >"$CF_LOG" 2>&1 &
TUNNEL_PID=$!

PUBLIC_URL=""
for i in $(seq 1 30); do
  PUBLIC_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" | head -1 || true)
  [ -n "$PUBLIC_URL" ] && break
  sleep 1
done

if [ -z "$PUBLIC_URL" ]; then
  echo "ERROR: tunnel URL not found. Tunnel log:"; cat "$CF_LOG"; exit 1
fi

# sanity-check the public URL actually reaches the API (tunnel needs a moment
# to propagate after it prints the URL, so retry a few times).
tunnel_ok=""
for i in $(seq 1 25); do   # trycloudflare quick-tunnels can take ~40s to propagate
  if curl -sf -m 5 -X POST "$PUBLIC_URL/auth/login" \
        -H 'Content-Type: application/json' \
        -d '{"email":"admin@concierge.dev","password":"admin123"}' >/dev/null; then
    tunnel_ok=1; break
  fi
  sleep 2
done
[ -z "$tunnel_ok" ] && echo "WARNING: login through tunnel not confirmed yet — it usually comes up within a minute; the printed URL is still valid."

echo
echo "============================================================"
echo " Public API:  $PUBLIC_URL"
echo " Demo logins: admin@concierge.dev / admin123"
echo "              guest@concierge.dev / guest123"
echo " Event QR code: WELCOME1"
echo "============================================================"
echo

# --- 4. expo ----------------------------------------------------------------
echo "[4/4] Starting Expo (scan the QR with Expo Go)..."
cd apps/mobile
EXPO_PUBLIC_API_URL="$PUBLIC_URL" npx expo start --tunnel
