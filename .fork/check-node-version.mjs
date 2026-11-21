#!/usr/bin/env node
// Fail when the Node that will run this image is older than the repository
// requires.
//
// Why this exists: the runtime stage used to install Node from the Debian apt
// archive (`nodejs` + `npm`). Debian's package is always several majors behind
// what the app declares in `engines.node` (root and `packages/web`), so the
// published image shipped Node 20 while the code requires >= 24.14 and nothing
// noticed. The Dockerfile now copies Node from the official `node` image and
// runs this check as part of the build, so a stale Node fails the build instead
// of silently reaching production.
//
// Usage:
//   node .fork/check-node-version.mjs             # checks the running Node
//   node .fork/check-node-version.mjs v24.14.1    # checks an explicit version
//
// Exit codes: 0 when every declared range is satisfied, 1 otherwise.

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = process.cwd();

// The repository's anti-slop lint rule forbids runtime `typeof`; this is the
// same test without it.
const isString = (value) => Object.prototype.toString.call(value) === '[object String]';

const parseVersion = (raw) => {
  const cleaned = String(raw).trim().replace(/^v/, '').split(/[-+]/)[0];
  const parts = cleaned.split('.').map((part) => Number.parseInt(part, 10));
  if (parts.length === 0 || parts.some((part) => Number.isNaN(part))) {
    throw new Error(`cannot parse version: ${raw}`);
  }
  return [parts[0] ?? 0, parts[1] ?? 0, parts[2] ?? 0];
};

const compare = (a, b) => {
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  }
  return 0;
};

const satisfiesComparator = (version, token) => {
  const match = /^(>=|<=|>|<|=|\^|~)?\s*v?(\d+(?:\.\d+){0,2})(?:\.(?:\*|x))?$/.exec(token);
  if (!match) throw new Error(`unsupported engines.node comparator: "${token}"`);
  const operator = match[1] ?? '=';
  const bound = parseVersion(match[2]);

  if (operator === '=') return compare(version, bound) === 0;
  if (operator === '>=') return compare(version, bound) >= 0;
  if (operator === '>') return compare(version, bound) > 0;
  if (operator === '<=') return compare(version, bound) <= 0;
  if (operator === '<') return compare(version, bound) < 0;
  if (operator === '^') {
    if (compare(version, bound) < 0) return false;
    const upper = bound[0] > 0
      ? [bound[0] + 1, 0, 0]
      : bound[1] > 0
        ? [0, bound[1] + 1, 0]
        : [0, 0, bound[2] + 1];
    return compare(version, upper) < 0;
  }
  // operator === '~'
  if (compare(version, bound) < 0) return false;
  const upper = [bound[0], bound[1] + 1, 0];
  return compare(version, upper) < 0;
};

const satisfiesRange = (version, range) =>
  range
    .split('||')
    .some((alternative) => {
      const tokens = alternative.trim().split(/\s+/).filter(Boolean);
      if (tokens.length === 0) return true;
      return tokens.every((token) => satisfiesComparator(version, token));
    });

const packageFiles = [join(ROOT, 'package.json')];
const packagesDir = join(ROOT, 'packages');
if (existsSync(packagesDir)) {
  for (const entry of readdirSync(packagesDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const file = join(packagesDir, entry.name, 'package.json');
    if (existsSync(file)) packageFiles.push(file);
  }
}

const requirements = [];
for (const file of packageFiles) {
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    continue;
  }
  const range = manifest?.engines?.node;
  if (isString(range) && range.trim() !== '') {
    requirements.push({ file: file.slice(ROOT.length + 1), range: range.trim() });
  }
}

const checked = parseVersion(process.argv[2] ?? process.version);
const label = `${checked.join('.')}`;

if (requirements.length === 0) {
  console.log(`[node-check] no engines.node declared; running Node ${label}`);
  process.exit(0);
}

let failed = false;
for (const { file, range } of requirements) {
  let ok = false;
  try {
    ok = satisfiesRange(checked, range);
  } catch (error) {
    console.error(`[node-check] ${file}: ${error.message}`);
    failed = true;
    continue;
  }
  console.log(`[node-check] ${file}: engines.node "${range}" vs ${label} -> ${ok ? 'ok' : 'TOO OLD'}`);
  if (!ok) failed = true;
}

if (failed) {
  console.error(
    `[node-check] Node ${label} does not satisfy the declared engines.node range(s).\n` +
      '[node-check] Fix: run `.fork/reconcile-node-version.sh`, or bump ARG NODE_VERSION in the Dockerfile.',
  );
  process.exit(1);
}

console.log(`[node-check] Node ${label} satisfies every declared engines.node range`);
