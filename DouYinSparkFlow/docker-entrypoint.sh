#!/usr/bin/env bash
set -euo pipefail
cd /app

mkdir -p state/cron state/login-profile state/browser-profiles logs

# Generate the cron schedule file if missing (drives the daily send window)
if [ ! -f state/cron/root ]; then
  python - <<'PY' || true
import sys
from webui.ops import sync_daily_schedule_from_config
r = sync_daily_schedule_from_config()
sys.exit(0 if getattr(r, "returncode", 0) == 0 else 1)
PY
fi

# Scheduler (every 20 min within the send window, reads state/cron/root)
python scripts/cron_runner.py /app/state/cron/root &
SCHED_PID=$!
echo "[entry] scheduler pid=$SCHED_PID"

# Desktop login service (bind via LOGIN_DESKTOP_BIND_ADDRESS, default 0.0.0.0 in container)
python login_desktop_server.py &
LOGIN_PID=$!
echo "[entry] login service pid=$LOGIN_PID"

# Web admin UI (foreground, keeps the container alive)
echo "[entry] starting web ui on http://0.0.0.0:8787"
exec python main.py --web --host 0.0.0.0 --port 8787