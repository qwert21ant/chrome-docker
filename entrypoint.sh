#!/bin/bash
set -euo pipefail

# When docker restarts, this file is still there,
# so we need to kill it just in case
[ -f /tmp/.X99-lock ] && rm -f /tmp/.X99-lock

# ---------- Xvfb ----------
echo "[entrypoint] Starting Xvfb on ${DISPLAY} (${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH})"
Xvfb "${DISPLAY}" \
  -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" \
  -ac \
  -nolisten tcp \
  +extension RANDR \
  &
XVFB_PID=$!

# Wait for Xvfb to be ready
for i in $(seq 1 30); do
  if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if ! xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
  echo "[entrypoint] ERROR: Xvfb failed to start"
  exit 1
fi
echo "[entrypoint] Xvfb is ready"

# ---------- x11vnc (optional) ----------
if [[ "${ENABLE_VNC,,}" == "true" || "${ENABLE_VNC}" == "1" ]]; then
  VNC_ARGS=(-display "${DISPLAY}" -forever -shared -rfbport "${VNC_PORT}" -noxdamage)

  if [[ -n "${VNC_PASSWORD}" ]]; then
    mkdir -p /root/.vnc
    x11vnc -storepasswd "${VNC_PASSWORD}" /root/.vnc/passwd
    VNC_ARGS+=(-rfbauth /root/.vnc/passwd)
  else
    VNC_ARGS+=(-nopw)
  fi

  echo "[entrypoint] Starting x11vnc on port ${VNC_PORT}"
  x11vnc "${VNC_ARGS[@]}" &
  X11VNC_PID=$!
fi

# ---------- D-Bus session (Chrome needs it) ----------
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" || "${DBUS_SESSION_BUS_ADDRESS}" == "/dev/null" ]]; then
  eval "$(dbus-launch --sh-syntax)" 2>/dev/null || true
fi

# ---------- Chrome ----------
# Chrome >=130 ignores --remote-debugging-address and always binds to 127.0.0.1.
# So we run Chrome on an internal port and use socat to expose it on 0.0.0.0.
INTERNAL_DEBUG_PORT=$(( CHROME_REMOTE_DEBUGGING_PORT + 1 ))

CHROME_ARGS=(
  --no-first-run
  --no-default-browser-check
  --disable-background-networking
  --disable-background-timer-throttling
  --disable-backgrounding-occluded-windows
  --disable-breakpad
  --disable-client-side-phishing-detection
  --disable-component-extensions-with-browser-startup
  --disable-default-apps
  --disable-dev-shm-usage
  --disable-extensions
  --disable-hang-monitor
  --disable-ipc-flooding-protection
  --disable-popup-blocking
  --disable-prompt-on-repost
  --disable-renderer-backgrounding
  --disable-sync
  --disable-translate
  --force-color-profile=srgb
  --metrics-recording-only
  --password-store=basic
  --use-mock-keychain
  --force-fieldtrials=*BackgroundTracing/default/
  --export-tagged-pdf
  --no-sandbox
  --disable-setuid-sandbox
  --disable-features=Translate,OptimizationHints,MediaRouter,DialMediaRouteProvider,CalculateNativeWinOcclusion,InterestFeedContentSuggestions,CertificateTransparencyComponentUpdater,AutofillServerCommunication,PrivacySandboxSettings4,AutomationControlled
  --remote-debugging-port=${INTERNAL_DEBUG_PORT}
  --user-data-dir="${CHROME_USER_DATA_DIR}"
  --window-size=${SCREEN_WIDTH},${SCREEN_HEIGHT}  
)

# Append any user-supplied flags
if [[ -n "${CHROME_FLAGS}" ]]; then
  read -ra EXTRA_FLAGS <<< "${CHROME_FLAGS}"
  CHROME_ARGS+=("${EXTRA_FLAGS[@]}")
fi

# If the caller passed extra args on docker run, append them
if [[ $# -gt 0 ]]; then
  CHROME_ARGS+=("$@")
fi

# ---------- CDP proxy for DevTools ----------
# cdp-proxy.js: listens on 0.0.0.0:PORT, forwards to Chrome on 127.0.0.1:PORT+1
# with Host rewriting, and rewrites ws:// URLs in JSON responses so any
# client host gets back correct WebSocket endpoints without client-side hackery.
echo "[entrypoint] Starting cdp-proxy 0.0.0.0:${CHROME_REMOTE_DEBUGGING_PORT} -> 127.0.0.1:${INTERNAL_DEBUG_PORT}"
node /cdp-proxy.js &

echo "[entrypoint] Launching Chrome"
echo "[entrypoint]   user-data-dir = ${CHROME_USER_DATA_DIR}"
echo "[entrypoint]   DevTools at   = http://0.0.0.0:${CHROME_REMOTE_DEBUGGING_PORT} (internal: ${INTERNAL_DEBUG_PORT})"

exec google-chrome-stable "${CHROME_ARGS[@]}"
