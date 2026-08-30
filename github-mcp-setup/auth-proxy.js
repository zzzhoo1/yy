#!/usr/bin/env node
/**
 * auth-proxy.js - 认证转换反向代理
 *
 * 把 `Authorization: Bearer <key>` 转换成 `X-API-Key: <key>` 转发给
 * 后端的 mcp-proxy (8080)。这样 Perplexity 用 `authorization` 字段
 * (发送 Authorization: Bearer) 也能通过认证。
 *
 * 同时兼容直接传 `X-API-Key` 头的情况。
 *
 * 用法:
 *   AUTH_PROXY_PORT=8081 node auth-proxy.js
 *   AUTH_PROXY_UPSTREAM=http://127.0.0.1:8080 node auth-proxy.js
 */
const http = require('http');

const PORT = parseInt(process.env.AUTH_PROXY_PORT || '8081', 10);
const UPSTREAM = process.env.AUTH_PROXY_UPSTREAM || 'http://127.0.0.1:8080';
const API_KEY_FILE = '/root/.mcp-api-key';

const fs = require('fs');
function getApiKey() {
  try { return fs.readFileSync(API_KEY_FILE, 'utf8').trim(); } catch (e) { return ''; }
}

const upstreamUrl = new URL(UPSTREAM);

const server = http.createServer((req, res) => {
  // 收集请求体
  let body = [];
  req.on('data', (c) => body.push(c));
  req.on('end', () => {
    const bodyBuf = Buffer.concat(body);

    // 构造转发请求头
    const headers = { ...req.headers };

    // 认证转换：如果只有 Authorization: Bearer，转成 X-API-Key
    const auth = headers['authorization'] || '';
    const xapi = headers['x-api-key'];
    if (!xapi && auth.startsWith('Bearer ')) {
      headers['x-api-key'] = auth.slice('Bearer '.length).trim();
    }

    // 转发到 upstream
    const proxyReq = http.request({
      host: upstreamUrl.hostname,
      port: upstreamUrl.port || 80,
      path: req.url,
      method: req.method,
      headers: headers,
    }, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    });

    proxyReq.on('error', (err) => {
      res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end('proxy error: ' + err.message);
    });

    proxyReq.end(bodyBuf);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`auth-proxy listening on :${PORT} -> ${UPSTREAM}`);
});
