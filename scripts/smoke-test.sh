#!/bin/sh
# Post-deploy smoke test, run inside the running container.
#
# A deploy that reports success is not a working app: the orchestrator only
# sees the container start, and the failures that matter here happen later and
# quietly. The shared MCP bridge, for example, came up and was then ended by
# the orphan sweep seconds after boot, while the app kept answering on 3000.
# This script checks the pieces that a boot cannot prove.
#
# Every check prints PASS or FAIL and the run ends with a count. Run it right
# after a deploy, from the container:
#
#   sh /home/openchamber/workspaces/openchamber-harden/scripts/smoke-test.sh
#
# Exit code 0 means every check passed.
set -u

HOST="${OPENCHAMBER_SMOKE_HOST:-127.0.0.1}"
APP_PORT="${OPENCHAMBER_SMOKE_PORT:-3000}"
BRIDGE_PORT="${OPENCHAMBER_BRIDGE_PORT:-8910}"
HOME_DIR="${HOME:-/home/openchamber}"
TMP="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
}

section() {
  printf '\n%s\n' "$1"
}

# --- the app answers -------------------------------------------------------
section "app"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${HOST}:${APP_PORT}/" 2>/dev/null || echo 000)"
if [ "$code" = "200" ]; then
  ok "GET / -> 200"
else
  bad "GET / -> $code"
fi

# --- the shared MCP bridge ------------------------------------------------
section "shared MCP bridge"
bridge_reply="$(curl -s --max-time 10 -X POST "http://${HOST}:${BRIDGE_PORT}/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' 2>/dev/null || true)"
case "$bridge_reply" in
  *doppler-api-readonly*) ok "port ${BRIDGE_PORT} answers initialize (doppler-api-readonly)" ;;
  *) bad "port ${BRIDGE_PORT} did not answer initialize" "${bridge_reply:-no response}" ;;
esac

if ps -eo command 2>/dev/null | grep -q 'bin/openchamber-bridge'; then
  ok "bridge process is alive"
else
  bad "bridge process is not running"
fi

# --- the shared MCP servers ------------------------------------------------
# Each launcher prints one JSON-RPC line naming its server. The launchers put
# their install back if the volume was emptied, so this also exercises the
# unpack path.
section "MCP servers"
mcp_probe() {
  name="$1"
  binary="$2"
  pattern="$3"
  if [ ! -x "$binary" ]; then
    bad "$name: launcher missing at $binary"
    return
  fi
  reply="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
    | timeout 60 "$binary" 2>/dev/null | head -c 400)"
  case "$reply" in
    *"$pattern"*) ok "$name answers initialize" ;;
    *) bad "$name did not answer initialize" "${reply:-no response}" ;;
  esac
}

mcp_probe "markitdown" "${HOME_DIR}/.config/opencode/bin/markitdown-mcp" '"name":"markitdown"'
mcp_probe "analytics-mcp" "${HOME_DIR}/.config/opencode/bin/analytics-mcp" 'Google Analytics MCP Server'

# --- the browser -----------------------------------------------------------
# The Server Browser extension starts the browser from PATH without a sandbox
# flag and then drives it over the DevTools protocol. This starts it the same
# way, loads a page that needs no network, and reads the rendered text back.
section "server browser"
cat > "$TMP/browser.mjs" <<'NODE_EOF'
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const require = createRequire('/home/openchamber/packages/web/package.json');
const { WebSocket } = require('ws');

const profile = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'smoke-chrome-'));
const child = spawn('/usr/local/bin/chromium', [
  '--headless=new',
  '--remote-debugging-port=0',
  '--remote-debugging-address=127.0.0.1',
  `--user-data-dir=${profile}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-background-networking',
  '--disable-component-update',
  '--disable-sync',
  '--password-store=basic',
  'about:blank',
], { stdio: 'ignore', detached: true });

const fail = (message) => {
  try { process.kill(-child.pid, 'SIGKILL'); } catch {}
  fs.rmSync(profile, { recursive: true, force: true });
  console.log(`FAIL ${message}`);
  process.exit(1);
};

const portFile = path.join(profile, 'DevToolsActivePort');
let port = '';
for (let i = 0; i < 100; i += 1) {
  try {
    const [line] = (await fs.promises.readFile(portFile, 'utf8')).split('\n');
    if (line.trim()) { port = line.trim(); break; }
  } catch {}
  await new Promise((r) => setTimeout(r, 100));
}
if (!port) fail('browser wrote no DevToolsActivePort');

const target = JSON.parse(await (await fetch(`http://127.0.0.1:${port}/json/version`)).text());
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.once('open', resolve);
  ws.once('error', () => reject(new Error('devtools websocket refused')));
});

let nextId = 0;
const pending = new Map();
ws.on('message', (raw) => {
  const message = JSON.parse(raw.toString());
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  if (message.error) entry.reject(new Error(message.error.message));
  else entry.resolve(message.result);
});
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = (nextId += 1);
  pending.set(id, { resolve, reject });
  ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
});

const url = 'data:text/html,<title>smoke</title><h1>server browser ok</h1>';
const { targetId } = await send('Target.createTarget', { url });
const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });

let text = '';
for (let i = 0; i < 60; i += 1) {
  await new Promise((r) => setTimeout(r, 250));
  try {
    const result = await send('Runtime.evaluate', {
      expression: 'document.body ? document.body.innerText : ""',
      returnByValue: true,
    }, sessionId);
    text = result?.result?.value ?? '';
    if (text.includes('server browser ok')) break;
  } catch {}
}

ws.close();
try { process.kill(-child.pid, 'SIGKILL'); } catch {}
fs.rmSync(profile, { recursive: true, force: true });

const browserVersion = String(target.Browser ?? '');
const version = (browserVersion.match(/Chrome\/([\d.]+)/) || [])[1] ?? 'unknown';
if (!text.includes('server browser ok')) {
  console.log(`FAIL browser ${version} rendered no page text`);
  process.exit(1);
}
console.log(`OK browser ${version} rendered a page over DevTools`);
NODE_EOF

if command -v node >/dev/null 2>&1; then
  browser_out="$(timeout 120 node "$TMP/browser.mjs" 2>&1)"
  case "$browser_out" in
    OK*) ok "${browser_out#OK }" ;;
    *) bad "browser check failed" "$browser_out" ;;
  esac
else
  bad "node is missing, cannot drive the browser"
fi

# --- the modules the server imports at runtime -----------------------------
# The image can carry a pruned node_modules (PRUNE_DEV_DEPS). Every package the
# server loads at runtime has to still resolve, including the ones a workspace
# declares, so this walks the real import graph instead of a hand written list.
#
# Resolution runs under bun, because that is what runs the server: some of these
# packages are ESM-only with an `import` export map, which node's resolver
# rejects even though the image is fine.
section "runtime modules"
cat > "$TMP/specifiers.py" <<'PY_EOF'
import json, os, re

pattern = re.compile(r"""(?:^|[^\w$.])(?:from\s*|import\s*\(\s*|require\s*\(\s*)['"]([^'"\n]{1,80})['"]""")
builtins = {
    'assert', 'buffer', 'child_process', 'cluster', 'console', 'constants', 'crypto', 'dgram',
    'dns', 'domain', 'events', 'fs', 'http', 'http2', 'https', 'module', 'net', 'os', 'path',
    'perf_hooks', 'process', 'punycode', 'querystring', 'readline', 'repl', 'stream',
    'string_decoder', 'timers', 'tls', 'tty', 'url', 'util', 'v8', 'vm', 'worker_threads', 'zlib',
}

found = set()
for base in ('/home/openchamber/packages/web/server', '/home/openchamber/packages/web/bin'):
    for directory, _, files in os.walk(base):
        if '/test' in directory:
            continue
        for name in files:
            if not name.endswith(('.js', '.mjs', '.cjs')) or '.test.' in name or '.spec.' in name:
                continue
            with open(os.path.join(directory, name), encoding='utf-8', errors='ignore') as handle:
                for line in handle:
                    stripped = line.strip()
                    # Comments talk about imports too; only code counts.
                    if stripped.startswith(('*', '//', '/*')):
                        continue
                    for match in pattern.finditer(line):
                        spec = match.group(1)
                        if spec.startswith(('.', '/', '#', 'node:', 'bun:', 'data:')):
                            continue
                        head = '/'.join(spec.split('/')[:2]) if spec.startswith('@') else spec.split('/')[0]
                        if head in builtins:
                            continue
                        if not re.fullmatch(r'@?[a-z0-9][\w.\-]*(/[a-z0-9][\w.\-]*)?', spec, re.I):
                            continue
                        found.add(spec)

print(json.dumps(sorted(found)))
PY_EOF

specs="$(timeout 60 python3 "$TMP/specifiers.py" 2>/dev/null || echo '[]')"
if [ "$specs" = "[]" ] || [ -z "$specs" ]; then
  bad "could not read the server's import graph"
else
  resolve_out="$(cd /home/openchamber/packages/web && SPECS="$specs" timeout 60 bun -e '
const specs = JSON.parse(process.env.SPECS);
const missing = [];
for (const spec of specs) {
  try { import.meta.resolve(spec); } catch { missing.push(spec); }
}
if (missing.length === 0) console.log(`OK ${specs.length} runtime imports resolve`);
else console.log(`FAIL ${missing.length} runtime imports do not resolve: ${missing.join(", ")}`);
' 2>&1)"
  case "$resolve_out" in
    OK*) ok "${resolve_out#OK }" ;;
    *) bad "runtime module resolution" "$resolve_out" ;;
  esac
fi

# --- the installs kept in the volume --------------------------------------
section "vendored installs"
for name in analytics-mcp markitdown supergateway; do
  if [ -f "${HOME_DIR}/.mcp-vendor/${name}.tar.gz" ]; then
    ok "${name} archive present"
  else
    bad "${name} archive missing from ${HOME_DIR}/.mcp-vendor"
  fi
done

# --- process hygiene -------------------------------------------------------
section "processes"
orphans="$(ps -eo pid,ppid,command 2>/dev/null | awk '$2 == 1' | grep -E 'markitdown-mcp|analytics-mcp|supergateway' | grep -v 'openchamber-bridge' | head -5)"
if [ -z "$orphans" ]; then
  ok "no orphaned MCP servers"
else
  bad "orphaned MCP servers are running" "$orphans"
fi

browsers="$(ps -eo command 2>/dev/null | grep -E '^/usr/(lib|bin)/chromium' | head -5)"
if [ -z "$browsers" ]; then
  ok "no leftover browser processes"
else
  bad "browser processes left behind" "$browsers"
fi

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
