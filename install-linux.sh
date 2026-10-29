#!/usr/bin/env bash
#
# DouYin SparkFlow - Linux Docker one-click installer
# Usage:  ./install-linux.sh [--name douyin-sparkflow]
#   DATA_DIR env overrides the host data folder (default: ~/douyin-sparkflow-data)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/DouYinSparkFlow"
IMAGE_NAME="${IMAGE_NAME:-douyin-sparkflow:local}"
CONTAINER_NAME="${CONTAINER_NAME:-douyin-sparkflow}"
DATA_DIR="${DATA_DIR:-$HOME/douyin-sparkflow-data}"
WEB_PORT="${WEB_PORT:-8787}"
LOGIN_PORT="${LOGIN_PORT:-18090}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
say()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die()  { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

# ---------- 0. checks ----------
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker first: https://docs.docker.com/engine/install/"
if ! docker info >/dev/null 2>&1; then
  warn "Cannot talk to the Docker daemon (maybe needs sudo or the docker group)."
  warn "Try:  sudo usermod -aG docker $USER && newgrp docker   (then re-run)"
  die "Docker daemon unavailable."
fi
[ -d "$APP_DIR" ] || die "Application folder not found: $APP_DIR (run this script from the repo root)"

# ---------- 1. build ----------
say "Building image $IMAGE_NAME (playwright chromium + dependencies, may take a few minutes)..."
docker build -f "$APP_DIR/Dockerfile.headless" -t "$IMAGE_NAME" "$APP_DIR"

# ---------- 2. host data dir + container-friendly config ----------
say "Preparing data directory $DATA_DIR ..."
mkdir -p "$DATA_DIR/state/browser-profiles" "$DATA_DIR/state/cron" "$DATA_DIR/state/login-profile" "$DATA_DIR/logs"

if [ ! -f "$DATA_DIR/config.json" ]; then
  cat > "$DATA_DIR/config.json" <<'JSON'
{
  "multiTask": true,
  "taskCount": 1,
  "proxyAddress": "",
  "messageTemplate": "🤩今日火花+1",
  "saveDebugArtifacts": false,
  "useProtocolSender": false,
  "protocolDryRun": false,
  "browserSenderAccounts": [],
  "sendStrategy": {
    "shuffleTargets": true,
    "accountStartDelaySecondsMin": 15,
    "accountStartDelaySecondsMax": 60,
    "messageIntervalSecondsMin": 25,
    "messageIntervalSecondsMax": 70,
    "messageVariants": [
      "🤩今日火花+1",
      "今天来补个火花",
      "给你续一下今天的火花",
      "路过给你加个小火花"
    ]
  },
  "dailySendWindow": {
    "enabled": true,
    "startHour": 10,
    "endHour": 18,
    "scheduleIntervalMinutes": 20
  },
  "hitokotoTypes": ["文学", "影视", "诗词", "哲学"],
  "happyNewYear": { "enabled": false, "messageTemplate": "\r\n" },
  "friendListScan": {
    "maxScanSeconds": 300,
    "idleScanSeconds": 120,
    "scrollStepPx": 400,
    "scrollDelaySeconds": 0.8
  },
  "persistentBrowserProfiles": {
    "enabled": true,
    "root": "/app/state/browser-profiles",
    "seedCookiesWhenEmpty": true,
    "syncStoredCookiesBeforeRun": true,
    "refreshStoredCookiesAfterLogin": true
  }
}
JSON
  say "Wrote container-friendly config.json (browser profiles -> /app/state/browser-profiles)"
fi

# valid empty account store (never ship real usersData.json into the image)
[ -f "$DATA_DIR/usersData.json" ] || echo "[]" > "$DATA_DIR/usersData.json"

# ---------- 3. run ----------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  warn "Removing existing container '$CONTAINER_NAME' (data is preserved in $DATA_DIR)..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

say "Starting container $CONTAINER_NAME ..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart=always \
  -p "$WEB_PORT:8787" \
  -p "$LOGIN_PORT:18090" \
  -e TZ=Asia/Shanghai \
  -e LOGIN_DESKTOP_BIND_ADDRESS=0.0.0.0 \
  -v "$DATA_DIR/config.json:/app/config.json" \
  -v "$DATA_DIR/state:/app/state" \
  -v "$DATA_DIR/logs:/app/logs" \
  -v "$DATA_DIR/usersData.json:/app/usersData.json" \
  "$IMAGE_NAME"

# ---------- 4. health check ----------
say "Waiting for services to come up..."
for i in $(seq 1 12); do
  sleep 3
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ] \
     && curl -sf -o /dev/null "http://127.0.0.1:$WEB_PORT/"; then
    break
  fi
done

echo
say "=========================================================="
say " DouYin SparkFlow is running"
say "   Web UI      : http://<server-ip>:$WEB_PORT   (admin init on first visit)"
say "   Login page  : http://<server-ip>:$LOGIN_PORT (scan QR to add accounts)"
say "   Data folder : $DATA_DIR   (kept on the host)"
say "   Logs        : docker logs -f $CONTAINER_NAME"
say "   Restart     : docker restart $CONTAINER_NAME"
say "   Stop        : docker stop $CONTAINER_NAME"
say "   Auto-start  : enabled (--restart=always, boots with Docker)"
say "=========================================================="
if ! curl -sf -o /dev/null "http://127.0.0.1:$WEB_PORT/"; then
  warn "Web UI not responding yet - check: docker logs $CONTAINER_NAME"
fi