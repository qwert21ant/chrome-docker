# chrome-docker

Docker image running Google Chrome with **Xvfb** (virtual framebuffer) and optional **x11vnc**, based on Debian Bookworm slim. Inspired by [browserless/chrome](https://github.com/browserless/chrome).

## Features

- Chrome runs in a real X display via **Xvfb** — not `--headless`, behaves like a real browser
- **Chrome DevTools Protocol (CDP)** reachable from outside the container on port **9111**
- Optional **VNC** server on port **5900** (x11vnc, controlled by `ENABLE_VNC`)
- Mountable Chrome **user-data directory** at `/data/chrome-profile` for profile persistence
- Configurable screen resolution, extra Chrome flags, and more via environment variables
- Runs as non-root `chrome` user

## How it works

Chrome 130+ ignores `--remote-debugging-address` and always binds DevTools to `127.0.0.1`.
To make it reachable from outside the container, the entrypoint starts a **socat** TCP forwarder:

```
Host → 0.0.0.0:9111 (socat) → 127.0.0.1:9112 (Chrome)
```

Chrome listens on `CHROME_REMOTE_DEBUGGING_PORT + 1` internally; socat exposes it on `CHROME_REMOTE_DEBUGGING_PORT`.

## Quick Start

```bash
# Build
docker build -t chrome-docker .

# Run (CDP only)
docker run -d --name chrome \
  --shm-size=2g \
  -p 9111:9111 \
  chrome-docker

# Run with VNC
docker run -d --name chrome \
  --shm-size=2g \
  -p 9111:9111 \
  -p 5900:5900 \
  -e ENABLE_VNC=true \
  -e VNC_PASSWORD=secret \
  chrome-docker
```

Or with **docker compose**:

```bash
docker compose up -d
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SCREEN_WIDTH` | `1920` | Xvfb screen width (pixels) |
| `SCREEN_HEIGHT` | `1080` | Xvfb screen height (pixels) |
| `SCREEN_DEPTH` | `24` | Xvfb color depth (bits) |
| `ENABLE_VNC` | `false` | Start x11vnc — accepts `true`, `1` |
| `VNC_PORT` | `5900` | VNC listen port |
| `VNC_PASSWORD` | *(empty)* | VNC password; no authentication if empty |
| `CHROME_REMOTE_DEBUGGING_PORT` | `9111` | Externally exposed CDP port (socat listener) |
| `CHROME_FLAGS` | *(empty)* | Extra flags appended to the Chrome command line |
| `CHROME_USER_DATA_DIR` | `/data/chrome-profile` | Chrome user data / profile directory |

> The actual Chrome process listens on `CHROME_REMOTE_DEBUGGING_PORT + 1` internally (e.g. `9112`). Do not expose that port — use the socat port instead.

## Mounting a Chrome Profile

Persisting the profile allows cookies, extensions, localStorage, and other state to survive container restarts.

```bash
# Host directory
docker run -d --shm-size=2g \
  -v /path/on/host:/data/chrome-profile \
  -p 9111:9111 \
  chrome-docker

# Named volume
docker run -d --shm-size=2g \
  -v chrome-data:/data/chrome-profile \
  -p 9111:9111 \
  chrome-docker
```

## Connecting

### Chrome DevTools Protocol

```bash
# List open pages
curl http://localhost:9111/json

# Version info
curl http://localhost:9111/json/version
```

Use the returned `webSocketDebuggerUrl` to connect with Puppeteer, Playwright, or any CDP client:

```js
// Puppeteer example
const browser = await puppeteer.connect({
  browserURL: 'http://localhost:9111',
});
```

### VNC

When `ENABLE_VNC=true`, connect any VNC client to `localhost:5900`.
If `VNC_PASSWORD` is set, the client will be prompted for it; otherwise no authentication is required.

## Opening a URL on Launch

Pass a URL as an extra argument — it is forwarded to Chrome:

```bash
docker run --rm --shm-size=2g -p 9111:9111 chrome-docker https://example.com
```

## Notes

- Always pass `--shm-size=2g` (or set `shm_size` in compose). Docker's default `/dev/shm` is 64 MB which causes Chrome renderer crashes.
- The D-Bus connection errors visible in logs are cosmetic — Chrome operates normally without a system bus inside Docker.
- `--no-sandbox` and `--disable-setuid-sandbox` are required because the container already provides isolation.
