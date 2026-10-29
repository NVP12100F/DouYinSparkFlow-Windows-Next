#!/usr/bin/env bash
#
# DouYin SparkFlow Windows-Next - remote one-click installer
# Run in ONE line (uses gh-proxy to accelerate GitHub clone, Huawei Cloud for the image):
#
#   bash <(curl -fsSL https://v4.gh-proxy.com/https://raw.githubusercontent.com/NVP12100F/DouYinSparkFlow-Windows-Next/main/install-remote.sh)
#
# Options:
#   --direct        use GitHub directly (no gh-proxy) and the official Playwright image
#   any other args  are passed through to install-linux.sh
#
set -euo pipefail

REPO_URL="https://github.com/NVP12100F/DouYinSparkFlow-Windows-Next.git"
PROXY_PREFIX="https://v4.gh-proxy.com/"
INSTALL_DIR="${INSTALL_DIR:-$HOME/douyin-sparkflow}"

USE_ACCEL=1
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --direct) USE_ACCEL=0 ;;
    *) EXTRA_ARGS+=("$arg") ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "[x] docker not found. Install Docker first: https://docs.docker.com/engine/install/"; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "[x] git not found. Install git first: apt install -y git"; exit 1; }

mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "[+] Found existing install at $INSTALL_DIR, pulling latest code..."
  git -C "$INSTALL_DIR" pull --ff-only || true
else
  echo "[+] Cloning repository ..."
  if [ "$USE_ACCEL" = "1" ]; then
    git clone "${PROXY_PREFIX}${REPO_URL}" "$INSTALL_DIR"
  else
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
fi

cd "$INSTALL_DIR"
chmod +x install-linux.sh
if [ "$USE_ACCEL" = "1" ]; then
  exec ./install-linux.sh "${EXTRA_ARGS[@]}"
else
  exec ./install-linux.sh --direct "${EXTRA_ARGS[@]}"
fi