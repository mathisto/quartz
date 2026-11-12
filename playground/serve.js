#!/usr/bin/env node
// Quartz Playground Server
//
// Serves the playground UI and provides /api/compile endpoint
// that compiles Quartz source to WASM using the local compiler.
//
// Usage: node playground/serve.js [port]

import { createServer } from 'http';
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { execSync } from 'child_process';
import { join, extname, dirname } from 'path';
import { randomBytes } from 'crypto';

const PORT = parseInt(process.argv[2] || '7878');
const ROOT = new URL('.', import.meta.url).pathname;
const PROJECT_ROOT = join(ROOT, '..');
const SITE_DIST = join(PROJECT_ROOT, 'site', 'dist');
const COMPILER = process.env.QUARTZ_COMPILER || 'self-hosted/bin/quartz';
const HAS_SITE = existsSync(SITE_DIST);

const MIME = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.mjs': 'application/javascript',
  '.css': 'text/css',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
};

function serveStatic(res, filePath) {
  try {
    const data = readFileSync(filePath);
    const ext = extname(filePath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end('Not found');
  }
}

function compile(source) {
  const id = randomBytes(8).toString('hex');
  const srcPath = `/tmp/_qz_play_${id}.qz`;
  const wasmPath = `/tmp/_qz_play_${id}.wasm`;

  try {
    writeFileSync(srcPath, source);
    execSync(`${COMPILER} --backend wasm --no-cache -I . -I std ${srcPath} -o ${wasmPath}`, {
      timeout: 10000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const wasm = readFileSync(wasmPath);
    return { ok: true, wasm };
  } catch (e) {
    const stderr = e.stderr ? e.stderr.toString() : e.message;
    return { ok: false, error: stderr };
  } finally {
    try { unlinkSync(srcPath); } catch {}
    try { unlinkSync(wasmPath); } catch {}
  }
}

const server = createServer((req, res) => {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  // Compile API
  if (req.method === 'POST' && req.url === '/api/compile') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const { source } = JSON.parse(body);
        const result = compile(source);
        if (result.ok) {
          res.writeHead(200, { 'Content-Type': 'application/wasm' });
          res.end(result.wasm);
        } else {
          res.writeHead(400, { 'Content-Type': 'text/plain' });
          res.end(result.error);
        }
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end(e.message);
      }
    });
    return;
  }

  // Route: try Astro site first (if built), then playground files
  const urlPath = req.url.split('?')[0];

  // Playground standalone (legacy path)
  if (urlPath === '/playground.html') {
    return serveStatic(res, join(ROOT, 'index.html'));
  }

  // Astro-built marketing site (serves /playground, /, /docs, etc.)
  if (HAS_SITE) {
    // Try exact file, then .html extension, then /index.html
    const candidates = [
      join(SITE_DIST, urlPath),
      join(SITE_DIST, urlPath + '.html'),
      join(SITE_DIST, urlPath, 'index.html'),
    ];
    for (const candidate of candidates) {
      if (existsSync(candidate) && !candidate.endsWith('/')) {
        try {
          const stat = readFileSync(candidate);
          const ext = extname(candidate);
          res.writeHead(200, { 'Content-Type': MIME[ext] || 'text/html' });
          res.end(stat);
          return;
        } catch {}
      }
    }
  }

  // Fallback: serve playground files directly
  let filePath = urlPath === '/' ? '/index.html' : urlPath;
  serveStatic(res, join(ROOT, filePath));
});

server.listen(PORT, () => {
  console.log(`Quartz Playground: http://localhost:${PORT}`);
  if (HAS_SITE) {
    console.log(`Marketing site: http://localhost:${PORT} (from site/dist/)`);
    console.log(`Playground: http://localhost:${PORT}/playground`);
  }
  console.log(`Compiler: ${COMPILER}`);
});
