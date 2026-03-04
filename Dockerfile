FROM debian:bookworm-slim

LABEL maintainer="chrome-docker"
LABEL description="Chrome with Xvfb and optional x11vnc"

# Environment defaults
ENV DISPLAY=:99 \
    SCREEN_WIDTH=1920 \
    SCREEN_HEIGHT=1080 \
    SCREEN_DEPTH=24 \
    ENABLE_VNC=false \
    VNC_PORT=5900 \
    VNC_PASSWORD="" \
    CHROME_REMOTE_DEBUGGING_PORT=9111 \
    CHROME_FLAGS="" \
    CHROME_USER_DATA_DIR=/data/chrome-profile \
    CONNECTION_TIMEOUT=60000 \
    DBUS_SESSION_BUS_ADDRESS=/dev/null

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    curl \
    wget \
    gnupg2 \
    ca-certificates \
    procps \
    dbus \
    dbus-x11 \
    # Xvfb and X11
    xvfb \
    x11vnc \
    x11-utils \
    x11-xserver-utils \
    # Fonts
    fonts-liberation \
    fonts-noto-color-emoji \
    fonts-noto-cjk \
    fontconfig \
    # Audio (PulseAudio stub)
    pulseaudio \
    # Shared libs for Chrome
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    libasound2 \
    libpango-1.0-0 \
    libcairo2 \
    libxshmfence1 \
    libvulkan1 \
    xdg-utils \
    # nodejs for the cdp-proxy.js DevTools reverse proxy
    nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome Stable
RUN wget -q -O /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
    && apt install -y /tmp/chrome.deb \
    && rm /tmp/chrome.deb

# Prepare directories
RUN mkdir -p /data/chrome-profile /tmp/.X11-unix

# Copy entrypoint and CDP proxy
COPY entrypoint.sh /entrypoint.sh
COPY cdp-proxy.js  /cdp-proxy.js
RUN chmod +x /entrypoint.sh

# Expose ports: 9222 = Chrome DevTools, 5900 = VNC
EXPOSE ${CHROME_REMOTE_DEBUGGING_PORT} 5900

# Mount point for Chrome user data
VOLUME ["/data/chrome-profile"]

WORKDIR /root

ENTRYPOINT ["/entrypoint.sh"]
