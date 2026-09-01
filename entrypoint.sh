#!/bin/bash
set -euo pipefail

ZROK_TOKEN="${ZROK_ENABLE_TOKEN:?ZROK_ENABLE_TOKEN is required}"
VNC_PASS="${VNC_PASSWORD:-abc123}"
DURATION="${SESSION_HOURS:-1}"

# The openziti install script names the binary zrok2; the release tarball
# used in the Dockerfile names it zrok. Pick whichever exists.
ZROK="$(command -v zrok2 || command -v zrok)"

# ── Graceful shutdown ─────────────────────────────────────────────
EXIT_CODE=0
cleanup() {
  echo "[*] Shutting down..."
  vncserver -kill :1 2>/dev/null || true
  kill $(jobs -p) 2>/dev/null || true
  # Release the zrok environment so the token can be reused next run
  "$ZROK" disable 2>/dev/null || true
  exit "$EXIT_CODE"
}
trap cleanup SIGTERM SIGINT EXIT

# ── Minimal runtime setup ─────────────────────────────────────────
export XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
# Regenerate if the layer got flattened or the file came through empty.
if [ ! -s /etc/machine-id ]; then
  dbus-uuidgen --ensure=/etc/machine-id
  echo "[*] generated machine-id at runtime"
fi
mkdir -p /run/dbus && dbus-daemon --system --fork 2>/dev/null || true

# KasmVNC's vncserver script shells out to `hostname` (inetutils on Arch).
command -v hostname >/dev/null || { echo "[FATAL] hostname missing"; exit 1; }

# ── Set KasmVNC password ──────────────────────────────────────────
echo -e "${VNC_PASS}\n${VNC_PASS}\n" | kasmvncpasswd -u user -wo
chmod 600 /root/.kasmpasswd

# ── Ensure KasmVNC prerequisite files exist ───────────────────────
mkdir -p /root/.vnc
chmod +x /root/.vnc/xstartup 2>/dev/null || true
touch /root/.vnc/.de-was-selected
touch /root/.Xauthority

# ── Launch KasmVNC ────────────────────────────────────────────────
vncserver :1 \
  -select-de manual \
  -geometry 1920x1080 \
  -depth 24 \
  -websocketPort 6901 \
  -interface 0.0.0.0 \
  -BlacklistThreshold=0 \
  -FreeKeyMappings

echo "[*] KasmVNC started on port 6901"

# Surface the session log - xstartup errors (a desktop that won't launch)
# only appear here, not on stdout.
sleep 3
VNCLOG="$(ls -t /root/.vnc/*.log 2>/dev/null | grep -v xstartup | head -1)"
if [ -n "$VNCLOG" ]; then
  echo "[*] streaming session log: $VNCLOG"
  tail -n +1 -f "$VNCLOG" 2>/dev/null &
else
  echo "[!] no session log found in /root/.vnc/"
fi

# xstartup writes its own log; it may not exist yet, so create it first
touch /root/.vnc/xstartup.log
echo "[*] streaming xstartup log"
tail -n +1 -f /root/.vnc/xstartup.log 2>/dev/null &

echo "[*] processes after startup:"
ps -eo comm= | sort -u | grep -iE 'xfce|xfwm|dbus|xkasm' || echo "  (no desktop processes)"

# ── Launch zrok tunnel ────────────────────────────────────────────
echo "[*] Disabling any stale zrok environment..."
"$ZROK" disable 2>/dev/null || true

echo "[*] Enabling zrok (token: ${ZROK_TOKEN:0:8}...)..."
if ! "$ZROK" enable --headless "$ZROK_TOKEN" 2>&1 | tee /tmp/zrok-enable.log; then
  echo "[FATAL] zrok enable failed:"
  cat /tmp/zrok-enable.log
  EXIT_CODE=1; exit 1
fi
echo "[*] zrok enabled successfully"

echo "[*] Starting zrok share on port 6901..."
"$ZROK" share public --headless 6901 > /tmp/zrok.log 2>&1 &
ZROK_PID=$!

# ── Wait for zrok URL ─────────────────────────────────────────────
ZROK_URL=""
for i in $(seq 1 30); do
  if ! kill -0 "$ZROK_PID" 2>/dev/null; then
    echo "[FATAL] zrok share exited unexpectedly (attempt $i/30)"
    echo "--- zrok share log ---"
    cat /tmp/zrok.log 2>/dev/null
    EXIT_CODE=1; exit 1
  fi
  ZROK_HOST=$(grep -oEm1 '[a-z0-9]+\.shares\.zrok\.io' /tmp/zrok.log 2>/dev/null || true)
  if [ -n "$ZROK_HOST" ]; then
    ZROK_URL="https://${ZROK_HOST}"
    break
  fi
  sleep 1
done

if [ -z "$ZROK_URL" ]; then
  echo "[FATAL] zrok share timed out after 30s"
  echo "--- zrok share log ---"
  cat /tmp/zrok.log 2>/dev/null
  echo "--- zrok enable log ---"
  cat /tmp/zrok-enable.log 2>/dev/null
  EXIT_CODE=1; exit 1
fi

echo ""
echo "============================================"
echo "  ARCH LINUX - BROWSER ACCESS READY"
echo "============================================"
echo ""
echo "  URL:      ${ZROK_URL}"
echo "  User:     user"
echo "  Password: ${VNC_PASS}"
DURATION_MINS=$(awk -v dur="$DURATION" 'BEGIN { printf "%g", dur * 60 }')
echo "  Expires:  ${DURATION_MINS}min"
echo ""
echo "============================================"

SLEEP_SECS=$(awk -v dur="$DURATION" 'BEGIN { printf "%d", dur * 3600 }')
sleep "$SLEEP_SECS" &
wait $!
