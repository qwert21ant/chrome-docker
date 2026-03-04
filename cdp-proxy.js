#!/usr/bin/env node
/**
 * cdp-proxy.js — HTTP + WebSocket reverse proxy for Chrome DevTools Protocol.
 *
 * Problems it solves:
 *  1. Chrome >=130 binds DevTools to 127.0.0.1 only — unreachable from outside
 *     the container.  This proxy listens on 0.0.0.0 and forwards to Chrome.
 *
 *  2. Chrome's host-header security check rejects requests whose Host is not
 *     localhost/127.0.0.1.  This proxy always sends Host: localhost:<upstream>
 *     to Chrome regardless of what the client sends.
 *
 *  3. Chrome embeds the Host header value into webSocketDebuggerUrl/webSocketUrl
 *     in its JSON responses.  Because we send Host: localhost:<upstream>, Chrome
 *     returns ws://localhost:<upstream>/..., which is unreachable from other
 *     containers or remote hosts.  This proxy rewrites those URLs in JSON
 *     responses back to the host:port the client used to reach us, so
 *     Puppeteer/Playwright can connect without any client-side URL manipulation.
 *
 * Uses only Node.js built-in modules — no npm install needed.
 */

'use strict';

const http = require('http');
const net  = require('net');

const LISTEN_PORT   = parseInt(process.env.CHROME_REMOTE_DEBUGGING_PORT, 10) || 9111;
const UPSTREAM_HOST = '127.0.0.1';
const UPSTREAM_PORT = LISTEN_PORT + 1; // Chrome's actual internal port

// ── HTTP ──────────────────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  // Preserve the host the client used so we can rewrite Chrome's ws:// URLs.
  const clientHost = req.headers.host || `localhost:${LISTEN_PORT}`;

  const options = {
    hostname: UPSTREAM_HOST,
    port:     UPSTREAM_PORT,
    path:     req.url,
    method:   req.method,
    headers: {
      ...req.headers,
      // Must be localhost so Chrome's host-header check passes.
      host: `localhost:${UPSTREAM_PORT}`,
    },
  };

  const proxy = http.request(options, (upRes) => {
    const isJson = (upRes.headers['content-type'] || '').includes('application/json');
    const outHeaders = { ...upRes.headers };

    // We'll compute a new content-length after rewriting — remove the old one.
    if (isJson) delete outHeaders['content-length'];

    res.writeHead(upRes.statusCode, outHeaders);

    if (isJson) {
      const chunks = [];
      upRes.on('data', c => chunks.push(c));
      upRes.on('end', () => {
        // Chrome embeds `localhost:<UPSTREAM_PORT>` in ws:// URLs.
        // Rewrite to whatever host:port the client used to reach us.
        const body = Buffer.concat(chunks)
          .toString('utf8')
          .replaceAll(`localhost:${UPSTREAM_PORT}`, clientHost);
        res.end(body);
      });
    } else {
      upRes.pipe(res);
    }
  });

  proxy.on('error', err => {
    console.error('[cdp-proxy] upstream HTTP error:', err.message);
    if (!res.headersSent) res.writeHead(502);
    res.end('Bad Gateway');
  });

  req.pipe(proxy);
});

// ── WebSocket / CDP tunnel ────────────────────────────────────────────────────
// HTTP `upgrade` events are not dispatched to the `request` handler, so we
// handle them separately.  We open a raw TCP socket to Chrome and splice the
// streams, rewriting only the Host header in the upgrade handshake.

server.on('upgrade', (req, clientSocket, head) => {
  const tunnel = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    // Rebuild the HTTP/1.1 upgrade request with an overridden Host.
    const headers = Object.entries(req.headers)
      .filter(([k]) => k !== 'host')
      .map(([k, v]) => `${k}: ${v}`)
      .join('\r\n');

    const handshake =
      `${req.method} ${req.url} HTTP/1.1\r\n` +
      `host: localhost:${UPSTREAM_PORT}\r\n` +
      (headers ? headers + '\r\n' : '') +
      '\r\n';

    tunnel.write(handshake);
    if (head && head.length) tunnel.write(head);

    clientSocket.pipe(tunnel);
    tunnel.pipe(clientSocket);
  });

  const cleanup = () => { tunnel.destroy(); clientSocket.destroy(); };
  tunnel.on('error', err => { console.error('[cdp-proxy] tunnel error:', err.message); cleanup(); });
  clientSocket.on('error', cleanup);
  clientSocket.on('close', () => tunnel.destroy());
  tunnel.on('close', () => clientSocket.destroy());
});

// ── Start ─────────────────────────────────────────────────────────────────────

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(`[cdp-proxy] 0.0.0.0:${LISTEN_PORT} → 127.0.0.1:${UPSTREAM_PORT}`);
});
