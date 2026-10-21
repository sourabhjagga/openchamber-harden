#!/usr/bin/env bun
// Deploy watcher: publishes a new image to the running OpenChamber.
//
// Why this exists: the CircleCI build pushes the image to DockerHub, but
// Coolify's API port is not reachable from the public internet, so the CI job
// cannot trigger a deployment itself. This watcher runs beside the app in the
// same compose, reaches Coolify over the host's docker network, and asks it to
// deploy whenever the watched image tag gets a new digest.
//
// What it does on a new digest:
//   1. remembers the commit of the last deployment that finished, as the
//      rollback target
//   2. asks Coolify to deploy the application (POST /applications/{uuid}/start,
//      a full deployment: re-clone the repo, re-import the compose, pull the
//      image, recreate the container)
//   3. waits for that deployment to finish
//   4. if it failed, asks Coolify to roll back to the last good commit
//      (POST /applications/{uuid}/rollback), so the previously deployed image
//      keeps serving traffic
//
// Coolify has its own safety net for the common case: the compose service
// defines a healthcheck, so a container that starts but never becomes healthy
// is rolled back by Coolify itself. This watcher covers the case where the
// deployment fails before the container ever comes up.
//
// The Coolify API token is read from a file mounted read-only, so it never
// reaches the OpenChamber container or the repository.

const COOLIFY_URL = (process.env.COOLIFY_URL || "http://host.docker.internal:8000").replace(/\/$/, "");
const APP_UUID = process.env.COOLIFY_APPLICATION_UUID || "";
const WATCH_IMAGE = process.env.WATCH_IMAGE || "sourabhjagga/openchamber-harden:main";
const TOKEN_FILE = process.env.COOLIFY_TOKEN_FILE || "/run/secrets/coolify_api_token";
const STATE_DIR = process.env.STATE_DIR || "/run/deploy";
const INTERVAL = Number(process.env.WATCH_INTERVAL || 60) * 1000;
const DIGEST_TIMEOUT = Number(process.env.DIGEST_TIMEOUT || 120) * 1000;
const DEPLOY_TIMEOUT = Number(process.env.DEPLOY_TIMEOUT || 900) * 1000;

const STATE_FILE = `${STATE_DIR}/state.json`;

const log = (msg) => console.log(`[deploy-watcher] ${new Date().toISOString()} ${msg}`);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let token = null;

async function readToken() {
  if (token) return token;
  try {
    token = (await Bun.file(TOKEN_FILE).text()).trim();
  } catch {
    token = null;
  }
  if (!token) throw new Error(`no Coolify token at ${TOKEN_FILE}`);
  return token;
}

async function coolify(path, init = {}) {
  const auth = await readToken();
  const res = await fetch(`${COOLIFY_URL}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${auth}`,
      Accept: "application/json",
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  let body = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  if (!res.ok) {
    throw new Error(`Coolify ${path} -> ${res.status}: ${text.slice(0, 200)}`);
  }
  return body;
}

/** Digest the registry currently serves for the watched tag. */
async function publishedDigest() {
  const [repo, tag] = WATCH_IMAGE.split(":");
  const res = await fetch(
    `https://hub.docker.com/v2/repositories/${repo}/tags/${encodeURIComponent(tag)}`,
  );
  if (!res.ok) return null;
  const json = await res.json();
  return json.digest || null;
}

async function readState() {
  try {
    return JSON.parse(await Bun.file(STATE_FILE).text());
  } catch {
    return { digest: null, lastGoodCommit: null };
  }
}

async function writeState(state) {
  await Bun.write(STATE_FILE, JSON.stringify(state, null, 2));
}

async function deployments() {
  const body = await coolify(`/api/v1/deployments/applications/${APP_UUID}`);
  return body.deployments || [];
}

/** Commit of the newest deployment that finished, used as the rollback target. */
async function lastGoodCommit() {
  const list = await deployments();
  const good = list.find((d) => d.status === "finished" && d.commit);
  return good ? good.commit : null;
}

async function deploymentInProgress() {
  const list = await deployments();
  return list.some((d) => ["queued", "pending", "in_progress"].includes(d.status));
}

async function deploy() {
  const state = await readState();
  const rollbackCommit = state.lastGoodCommit || (await lastGoodCommit());
  if (rollbackCommit) state.lastGoodCommit = rollbackCommit;

  if (await deploymentInProgress()) {
    log("a deployment is already running, skipping");
    return;
  }

  log(`triggering deploy of ${APP_UUID} (rollback target ${rollbackCommit || "none"})`);
  const res = await coolify(`/api/v1/applications/${APP_UUID}/start`, { method: "POST" });
  const uuid = res.deployment_uuid;
  if (!uuid) {
    log(`deploy not queued: ${JSON.stringify(res).slice(0, 200)}`);
    return;
  }
  log(`deployment queued: ${uuid}`);

  const deadline = Date.now() + DEPLOY_TIMEOUT;
  while (Date.now() < deadline) {
    await sleep(15000);
    let dep;
    try {
      dep = await coolify(`/api/v1/deployments/${uuid}`);
    } catch (err) {
      log(`poll failed: ${err.message}`);
      continue;
    }
    if (dep.status === "finished") {
      state.lastGoodCommit = dep.commit || state.lastGoodCommit;
      await writeState(state);
      log(`deployment ${uuid} finished (${dep.commit || "?"})`);
      return;
    }
    if (dep.status === "failed" || dep.status === "cancelled") {
      log(`deployment ${uuid} ${dep.status}, rolling back to ${rollbackCommit || "none"}`);
      if (rollbackCommit) {
        try {
          const rb = await coolify(`/api/v1/applications/${APP_UUID}/rollback`, {
            method: "POST",
            body: JSON.stringify({ commit: rollbackCommit }),
          });
          log(`rollback queued: ${JSON.stringify(rb).slice(0, 160)}`);
        } catch (err) {
          log(`rollback failed: ${err.message}`);
        }
      }
      return;
    }
    log(`deployment ${uuid} is ${dep.status}`);
  }
  log(`deployment ${uuid} still running after ${DEPLOY_TIMEOUT}ms, leaving it alone`);
}

async function main() {
  await Bun.$`mkdir -p ${STATE_DIR}`.quiet();
  log(`watching ${WATCH_IMAGE} via ${COOLIFY_URL} (app ${APP_UUID})`);
  let first = true;
  for (;;) {
    try {
      const digest = await publishedDigest();
      const state = await readState();
      if (digest && digest !== state.digest) {
        if (first) {
          // First sighting after a restart: record it, do not deploy.
          log(`initial digest ${digest}, recorded without deploying`);
        } else {
          log(`new digest ${digest} (was ${state.digest})`);
          await deploy();
        }
        state.digest = digest;
        if (!state.lastGoodCommit) state.lastGoodCommit = await lastGoodCommit().catch(() => null);
        await writeState(state);
      }
      first = false;
    } catch (err) {
      log(`error: ${err.message}`);
    }
    await sleep(INTERVAL);
  }
}

await main();
