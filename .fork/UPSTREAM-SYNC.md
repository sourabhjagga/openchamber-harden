# Upstream sync guide for this fork

This document is for whoever — human or AI agent — has to bring a new
OpenChamber upstream release into this fork. It records **every change this
fork carries over upstream**, **why** it exists, and **how to keep it alive
through a merge**.

Read this whole file before touching the working tree.

- Fork: `sourabhjagga/openchamber-harden` (`origin`)
- Upstream: `openchamber/openchamber` (`upstream`)
- Last synced upstream tag: **v2.5.1** (`3e9ef4db1`)
- Fork commits ahead of that base: **24** (listed in Appendix A), plus the
  merge commit that brought v2.5.1 in

---

## 1. How this fork ships

```
git push origin main
   └─ CircleCI (.circleci/config.yml, arm.medium, machine: true)
        ├─ docker build .
        ├─ docker push 4 tags
        └─ .fork/ci-trigger-deploy.sh   (SSH, restricted key, forced command)
             └─ host: .fork/oc-deploy.sh
                  └─ Coolify API → pull image → recreate container
                       └─ on failure: roll back to the last finished deployment
```

There is **no path filter**: every push to `main` builds, pushes and
redeploys. A docs-only commit still costs a full ~12 minute build and a
container restart (see §11).

Image tags pushed on every build:

| Tag | Source |
|---|---|
| `sourabhjagga/openchamber-harden:latest` | always |
| `sourabhjagga/openchamber-harden:main` | always |
| `sourabhjagga/openchamber-harden:<sha7>` | `CIRCLE_SHA1` first 7 chars |
| `sourabhjagga/openchamber-harden:v<version>` | `"version"` in `package.json` |

`docker-compose.yaml` pins the tag in one place:

```yaml
x-openchamber-image: &openchamber-harden sourabhjagga/openchamber-harden:v2.5.1
```

Coolify reads that compose file from git, so **the version in `package.json`
and the tag in `docker-compose.yaml` must agree** after every upstream release,
or the next deploy pulls the old image.

---

## 2. Inventory of fork changes

Everything below is fork-owned. When merging upstream, each group has a
different rule; the rule column is what actually matters.

| # | Area | Files | Why | Merge rule |
|---|---|---|---|---|
| 1 | Slim runtime dependencies | `Dockerfile` (`prod-deps` stage, runtime `COPY --from=prod-deps`) | Builder tree was 1400 MB; the app needs 654 MB | **Keep ours**, rebase onto upstream's stage layout |
| 2 | Browser flavour switch | `Dockerfile` (`ARG CHROMIUM_FLAVOR` etc.), wrapper at `/usr/local/bin/chromium` | Debian chromium vs Chrome-for-Testing; both land at `/opt/browser/chrome` | **Keep ours**, default stays `debian` |
| 3 | Runtime tooling | `Dockerfile` (uv, engram, Node, cloudflared, browser libs) | `uvx` MCP entries, Engram panel, tunnel, extension permissions | **Keep ours**, bump versions only |
| 4 | Shared MCP vendor | `Dockerfile` (vendor `RUN` + ARGs), `scripts/docker-entrypoint.sh` (`unpack_vendor`, launchers) | One install per container instead of one per project location | **Keep ours**; re-verify against upstream's entrypoint |
| 5 | Shared Doppler bridge | `scripts/docker-entrypoint.sh` (bridge heredoc), `mcp-process-cleanup.js` (marker exemption) | One HTTP MCP server every project shares | **Keep ours**, the two halves must both survive |
| 6 | Orphan process reaping | `packages/web/server/lib/opencode/mcp-process-cleanup.js` (+ `.test.js`), `lifecycle.js`, `index.js`, `shutdown-runtime.js` | Stray `opencode` runs leak 1 GB+ of MCP servers per command | **Re-apply** on top of upstream's lifecycle changes |
| 7 | CI/CD | `.circleci/config.yml`, `.fork/*.sh`, `docker-compose.yaml` | This fork ships an image, not npm/desktop/mobile artifacts | **Keep ours** |
| 8 | Upstream workflows | `.github/workflows/*` | Upstream workflows need upstream's GitHub App, Blacksmith runners, and publish artifacts nobody here consumes | **Take upstream, then run `.fork/sync-upstream-workflows.sh`** |
| 9 | Renovate | `renovate.json` | Dependency PRs for `bun.lock` | **Take upstream**, then re-apply fork additions |

Details for the two groups that need real thought (1–2 and 6) follow.

### 2.1 Image build (`Dockerfile`)

Upstream's Dockerfile is a 3-stage build (`base` → `deps` → `builder` →
`runtime`). The fork adds a fourth stage and a lot of runtime extras.

Stage order (names are stable, line numbers drift):

```
base → deps → builder          upstream
            ↘ prod-deps        fork: production-only install
runtime                        upstream + fork blocks
```

Fork blocks, in the order they appear in `runtime`:

1. `apt-get` baseline (`bash bzip2 ca-certificates curl git less
   openssh-client python3 python3-pip`) — upstream may have its own list;
   union them, do not drop one.
2. `uv` via `astral.sh/uv/install.sh` into `/usr/local/bin` (`UV_INSTALL_DIR`).
3. `ARG CHROMIUM_FLAVOR=debian` + `CHROME_HEADLESS_SHELL_VERSION` +
   `CHROME_HEADLESS_SHELL_SHA256`, then the conditional apt list and the
   `cft-shell` download path. **Default must stay `debian`.** The `debian`
   branch also asserts `test -u /usr/lib/chromium/chrome-sandbox` — keep it.
4. The `/usr/local/bin/chromium` wrapper heredoc. Behaviour:
   `unshare -U true` probe → run with the browser's own sandbox; if the
   process is gone after 2 s → relaunch with `--no-sandbox`. It must **not**
   `exec` on the first attempt (that is what allows the fallback).
5. `ARG ENGRAM_VERSION` / `ENGRAM_SHA256` + verified `curl | tar` into
   `/usr/local/bin`.
6. `ARG NODE_VERSION=24` + NodeSource install.
7. `userdel bun` → `groupadd/useradd -g 1000 openchamber`; volume ownership
   depends on uid 1000.
8. `NPM_CONFIG_PREFIX=/home/openchamber/.npm-global` and
   `npm install -g @opencode/cli@<version>` as the runtime user.
9. Vendor block: `ARG ANALYTICS_MCP_VERSION`, `MARKITDOWN_MCP_VERSION`,
   `SUPERGATEWAY_VERSION`; venvs built **at their final absolute path**
   (`/home/openchamber/.config/opencode/vendor/<name>`) because a venv bakes
   its own path into every shebang; tarred into
   `/home/openchamber/.mcp-vendor/`; then the source dirs are deleted. Every
   version uses `${VAR:?unset}` so an unset ARG fails the build loudly.
10. `cloudflared` copied by digest from `cloudflare/cloudflared@sha256:…`.
11. Runtime `COPY --from=prod-deps` for `/app/node_modules` and
    `/app/packages/web/node_modules`; everything else copies from `builder`.
12. The `chmod -R a+rX …/built-in-extensions` fix. Upstream can ship that
    directory as `0700`, which crashes the server for uid 1000. **Keep it**,
    it is a one-line guard against an upstream regression.

`prod-deps` stage:

```dockerfile
FROM deps AS prod-deps
ARG PRUNE_DEV_DEPS=true
RUN if [ "$PRUNE_DEV_DEPS" = "true" ]; then \
      rm -rf node_modules packages/*/node_modules \
      && bun install --frozen-lockfile --ignore-scripts --production \
      && cd packages/web && bun -e '… import.meta.resolve(…) …' …
```

The prune is a **fresh production install**, not a deletion from the
installed tree: Bun hardlinks the store, so deleting the top level leaves
dangling symlinks. `PRUNE_DEV_DEPS=false` restores the full tree without
reverting the commit — that is the escape hatch if an upstream release starts
importing a dev dependency at runtime.

Measured effect of this stage alone: `node_modules` 1400 MB → 654 MB, image
1646.9 MB → 1446.9 MB compressed.

### 2.2 Orphan reaping (server code)

`mcp-process-cleanup.js` is a new module. It exports:

- `killMcpChildrenOf(pid)` — end the MCP servers a **live** OpenCode pid
  started. Must run before the parent dies, because the parent link is the
  only way to identify them.
- `reapOrphanedMcpServers()` — end MCP servers whose parent is gone
  (reparented to init).
- `reapOrphanedOpencodeServers()` — end OpenCode servers whose owner died.

Two hard-won exceptions live in `isBridgeProcess()`:

- `BRIDGE_MARKER = 'openchamber-bridge'` — the wrapper script name.
- `BRIDGE_TRANSPORT_FLAG = '--outputTransport streamableHttp'` — the same
  bridge after its wrapper was replaced.

Without both, the sweep kills the shared Doppler bridge and every project
loses its MCP server.

Wiring:

- `lifecycle.js` imports all three; kills MCP children before the process
  tree is signalled; reaps at startup; `startOrphanReapMonitoring()` runs
  every `OPENCHAMBER_ORPHAN_REAP_INTERVAL_MS` (default 120000, `unref()`d).
- `index.js` holds `orphanReapInterval`, exposes it through
  `openCodeLifecycleState`, calls `startOrphanReapMonitoring()` after
  bootstrap, and hands the getter/clearer to the graceful-shutdown runtime.
- `shutdown-runtime.js` clears the interval on shutdown.

Upstream rewrites `lifecycle.js` and `index.js` often. Expect conflicts and
**re-derive the wiring instead of resolving the hunk blindly**: find where
upstream starts its health monitoring, put the reap call next to it, and find
where upstream registers its shutdown clears.

---

## 3. Pre-flight (do not skip)

```sh
cd /home/openchamber/workspaces/openchamber-harden
git status                        # must be clean
git fetch upstream --tags

git log --oneline HEAD..upstream/main | wc -l      # how far behind
git tag --sort=-creatordate | head -5              # new release tag
git log --oneline -5 upstream/main                 # what landed
```

Production must be healthy **before** you start:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3005/
```

and the previous smoke test must have passed. If prod is already broken, fix
that first; you will not be able to tell your merge from the pre-existing
breakage.

Also record the current prod state, so a rollback has a target:

```sh
docker compose -f docker-compose.yaml ps
docker inspect --format '{{.Config.Image}} {{.State.StartedAt}}' openchamber
```

---

## 4. Sync steps

**Merge, do not rebase.** 15 of the 24 fork commits touch `Dockerfile`;
rebasing means resolving the same Dockerfile hunks up to 15 times. A merge
resolves them once. (The v2.5.0 sync was replayed linearly, which is why the
merge-base sits exactly on that tag — that style does not scale here.)

```sh
# 1. branch
git switch -c sync/upstream-v2.6.0        # use the real version

# 2. merge the release tag (preferred over main: reproducible point in time)
git merge v2.6.0                          # or: git merge upstream/main

# 3. conflicts — see §5, resolve one file at a time
git status --short

# 4. workflows are upstream-owned files that this fork disables
sh .fork/sync-upstream-workflows.sh

# 5. lockfile: never hand-merge it
git checkout --theirs bun.lock 2>/dev/null || true
bun install                               # regenerates/validates against merged package.json
git diff --stat bun.lock                  # sanity: only expected bumps

# 6. verify locally (see §6)
git add -A
git commit                                # let the default merge message stand,
                                          # then amend a short body listing what you re-applied

# 7. versions (§7), then push
git push origin sync/upstream-v2.6.0      # open a PR; CI runs on main only
```

Fast-forward the branch into `main` with a merge commit (or squash), then
watch CI:

```sh
# pipeline, then workflows
curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
  'https://circleci.com/api/v2/project/gh/sourabhjagga/openchamber-harden/pipeline?branch=main&limit=1'
```

Expected: build ~12 min, deploy step last, job green only when Coolify
finished (the deploy script propagates the host's exit code).

---

## 5. Conflict playbook

The conflict surface is small. At v2.5.0 → v2.5.1 upstream changed 9 files this
fork cares about, of 1928 changed upstream: `Dockerfile`, `package.json`,
`renovate.json`, `AGENTS.md`, and five workflows the fork deletes. The
workflow edits come back as modify/delete conflicts and the `Dockerfile` as a
content conflict; `packages/web/server/index.js`, `lifecycle.js` and the
entrypoint took the merge cleanly. Expect a similar shape.

| File | Resolution |
|---|---|
| `.github/workflows/{nix-eval,nix-hashes,pr-intake,pr-review,stale}.yml` and the other 17 disabled ones | `git checkout --ours .github/workflows` (or `git rm`) then `sh .fork/sync-upstream-workflows.sh`. Never hand-edit these. |
| `.github/workflows/oc-review.yml` | Take **upstream's**, then let the script repoint `blacksmith-4vcpu-ubuntu-2404` → `ubuntu-latest`. |
| `renovate.json` | Take **upstream's**, then re-apply fork additions: `"schedule": ["* 1 1 * *"]` and, if still present upstream, the `ARG NODE_VERSION` custom manager. Verify before dropping either. |
| `docker-compose.yaml` | Take **ours**. It is fork-only in practice (upstream ships a different compose). Check the image tag, `security_opt: seccomp=unconfined`, `shm_size: 1gb`, the volume list, and the `OPENCHAMBER_UI_PASSWORD` guard. |
| `.circleci/config.yml`, `.fork/*` | Take **ours**, wholesale. Upstream has no such pipeline. |
| `Dockerfile` | Mixed — see below. |
| `packages/web/server/index.js` | Take **ours** where the reaping wiring lives; take upstream everywhere else. Re-derive if upstream moved bootstrap/shutdown. |
| `packages/web/server/lib/opencode/lifecycle.js` | Mixed — re-derive (see §2.2). |
| `bun.lock` | `--theirs`, then `bun install`. |
| `package.json` (`@opencode/client`) | Take upstream's version. It must match the CLI pin. |

### Dockerfile, in order

1. Take upstream's stage skeleton first: `base`, `deps` (its `COPY`
   package.jsons, `bun install`), `builder` (its build commands, including
   `bun run --cwd packages/sdk build` and `bun run build:web`).
2. Re-insert `prod-deps` after `deps`, and point the runtime `COPY`s at it.
3. Re-insert the runtime blocks 1–12 from §2.1, in upstream's ordering
   constraints: `USER openchamber` must come before the vendor block, the
   vendor block before the `COPY --from=prod-deps`.
4. Re-check every `ARG` default: `CHROMIUM_FLAVOR=debian`,
   `PRUNE_DEV_DEPS=true`, `NODE_VERSION`, `ENGRAM_VERSION`/`SHA256`,
   `CHROME_HEADLESS_SHELL_*`, `ANALYTICS_MCP_VERSION`,
   `MARKITDOWN_MCP_VERSION`, `SUPERGATEWAY_VERSION`.
5. `@opencode/cli@<version>`: **take upstream's new version** unless there is
   a written reason to hold back. Then set `@opencode/client` in
   `package.json` to the same version — they are a pair.
6. `ENTRYPOINT` must stay
   `["sh", "/home/openchamber/openchamber-entrypoint.sh"]`.

---

## 6. Verification gate

### 6.1 Before pushing (no Docker needed)

```sh
# the two files whose merge is riskiest must at least parse and lint
bun run --cwd packages/web type-check        # or the repo's documented equivalent
bun run lint

# the reaper has its own tests
bun test packages/web/server/lib/opencode/mcp-process-cleanup.test.js
```

If `bun` cannot resolve something locally that Docker could, remember:
`@opencode/client` is **ESM-only**, so `node --input-type=module -e
'import.meta.resolve("@opencode/client")'` via `bun` works while
`require.resolve` does not.

### 6.2 After the deploy

Run the smoke test **inside the running container**:

```sh
sh scripts/smoke-test.sh
```

12 checks, all must pass:

| Section | Check |
|---|---|
| app | `GET /` → 200 |
| bridge | process alive |
| bridge | answers `initialize` as `doppler-api-readonly` |
| MCP | `analytics-mcp` answers `initialize` |
| MCP | `markitdown` answers `initialize` |
| browser | launches, renders `https://example.com` (expect ~917 chars of "Example Domain") |
| imports | server import graph resolves (`bun` resolution from `bin/cli.js` + `server/index.js`) |
| archives | `analytics-mcp.tar.gz`, `markitdown.tar.gz`, `supergateway.tar.gz` present in `/home/openchamber/.mcp-vendor` |
| hygiene | no orphaned MCP servers |
| hygiene | no leftover browser processes |

Manual checks that the smoke test cannot see:

```sh
docker logs openchamber 2>&1 | grep -E 'MCP bridge is up|is in place|starting\.\.\.'
docker exec openchamber ps -eo pid,ppid,args | grep -E '[o]penchamber-bridge|[s]upergateway'
# the bridge must be pid 20-ish with ppid 1, alive for the whole container life
docker exec openchamber /opt/browser/chrome --version
docker exec openchamber sh -c 'du -sh /home/openchamber/node_modules'   # ~654 MB with pruning on
```

Then in the UI: open a project, confirm the chat answers (MCP bridge), and
open Server Browser and load a page (browser + sandbox).

If any of that fails → §8.

---

## 7. Versions to bump (one change, one place)

```sh
# 1. app version — drives the v<version> tag
grep -m1 '"version"' package.json

# 2. compose tag — must match
grep -n 'openchamber-harden:' docker-compose.yaml

# 3. the CLI/client pair — must match each other
grep -o '@opencode/cli@[0-9.]*' Dockerfile
grep -o '"@opencode/client": *"[^"]*"' package.json
```

`ENGRAM_VERSION`, `CHROME_HEADLESS_SHELL_VERSION` (and its sha256) and the
MCP versions are **not** tracked by Renovate — bump them by hand when you
want them, and always store the new sha256 for the browser blob.

---

## 8. Rollback

Every prior image stays on DockerHub under its version tag.

1. `docker-compose.yaml`: set the tag back (e.g. `v2.5.0`).
2. Push to `main` → CI builds that commit. If the code is also broken, revert
   the merge commit instead: `git revert -m 1 <merge-sha>` and push.
3. If CI itself cannot build, deploy by hand: Coolify → application
   `tstvi6x0rrptvet3jonr31ta` → set image tag → redeploy.

`oc-deploy.sh` already rolls back the *commit* when a Coolify deployment
fails, but it does not choose an older image — that is the tag change above.

---

## 9. Fast path: only the OpenCode CLI needs updating

When you do not want to wait for an OpenChamber release:

1. `Dockerfile`: `npm install -g @opencode/cli@<new>`
2. `package.json`: `"@opencode/client": "<same version>"`
3. `bun install` (lock update)
4. commit → push → CI → `sh scripts/smoke-test.sh`

Nothing else is involved: no workflows script, no merge. Verify afterwards
that a chat still answers — a CLI/SDK mismatch shows up there first.

---

## 10. Traps that already cost time

- **`pkill -f <pattern>` kills your own shell** here, because the pattern
  matches the invoking command line. Use
  `ps -eo pid,args | grep '[p]attern'`.
- **Never `exec` the supergateway bridge.** Its command line carries the
  `openchamber-bridge` marker that keeps the reaper from killing it. The
  wrapper must stay as the surviving process.
- **The bridge wrapper is written at start time**, in the entrypoint, with a
  quoted heredoc. A Dockerfile `RUN` would expand its `$HOME`, `$SUPERGATEWAY`
  etc. at build time and the script would look for its token in the wrong
  place.
- **venvs must be built at their final path** (shebangs are absolute).
- **Archives live in `/home/openchamber/.mcp-vendor`**, owned by uid 1000, and
  are *not* a volume — they ship in the image. The unpacked installs live in
  the `openchamber-opencode-config` volume.
- **`chmod -R a+rX …/built-in-extensions`** guards an upstream packaging bug
  (`EACCES … registry.json` at startup). Removing it looks harmless and is not.
- **The compose `x-openchamber-image` anchor is the only place the tag is
  set**; editing the `image:` line alone breaks the next retag.
- **Two `@opencode` versions exist**: the CLI (npm global, Dockerfile) and the
  SDK (`@opencode/client`, `package.json`). They move together.
- **`.github/workflows` is upstream-owned**: after any merge, run
  `.fork/sync-upstream-workflows.sh`. `.fork/sync-upstream-workflows.sh
  --restore` puts upstream's copies back if the script itself drifted.
- **CI has no path filter** (§11), so a documentation-only commit still
  restarts production. Put the fork's doc updates in the merge commit.
- **Run the checks with the Bun version `packageManager` names.** v2.5.1 moved
  to bun@1.4.4 and `type-check` is now `bun check -b`, which 1.4.3 does not
  have. A local 1.4.3 reports a tool error that reads like a broken script.
- **The five workflows upstream edits return as modify/delete conflicts** on
  every sync, because the fork deletes them. Keep them deleted and re-run the
  sync script.
- **A new `packages/sdk/examples/*` workspace needs no `deps` `COPY`.** The
  glob resolves from the lockfile and the install works without those example
  manifests. Prove it without Docker by reproducing the stage: copy
  `package.json`, `bun.lock`, `bun-patches/` and the six named manifests into a
  temp dir, then run `bun install --frozen-lockfile --ignore-scripts`.
- **`git remote -v` prints the token** embedded in `origin`'s URL. Do not run
  it into a transcript. The token itself should be rotated and moved out of
  `.git/config`.

---

## 11. CI behaviour for documentation commits

`.circleci/config.yml` filters on `branches: only: main` and nothing else. A
commit that only adds or edits Markdown **will** trigger the full pipeline:
~12 minute build → 4 tags pushed → `.fork/ci-trigger-deploy.sh` → Coolify
redeploys and restarts the container.

Two consequences:

- The final image is byte-identical for the common case, because the runtime
  stage only copies `scripts/docker-entrypoint.sh` plus `builder`/`prod-deps`
  outputs — a new `.md` file lives only in the throwaway `builder` stage.
- The restart is real. With "one change per deploy" in force, either accept
  one restart for the docs, or batch the docs with the next real change.

If docs-only pushes become frequent, add a guard as its own change (and its
own verification run), for example a first step that halts the job when every
file in the push is `*.md`:

```sh
if [ -z "$(git diff --name-only HEAD~1 HEAD -- ':!*.md' ':!.fork/*.md')" ]; then
  circleci step halt
fi
```

That is a CI change: it must be proven on a throwaway push, because a guard
that wrongly halts a real build silently leaves production on an old image.

---

## Appendix A — fork commits (24)

Ordered oldest → newest, each mapped to the group in §2. The sync merge
commit that lands upstream v2.5.1 sits on top of these and is not counted.

| Commit | Subject | Group |
|---|---|---|
| `0a0b34855` | sync: bring in upstream v2.5.0 (@opencode/cli@2.0.32) | sync |
| `2254836e4` | ci: disable upstream workflows that need upstream-only App credentials | 8 |
| `86bb1dec4` | ci: disable remaining upstream-only workflows, keep PR checks working | 8 |
| `fa25ea85d` | ci: auto-deploy a newly published image, with rollback on failure | 7 |
| `1824157f9` | fix(deploy-watcher): do not let a state-write failure disarm the watcher | 7 |
| `72e988d66` | ci: deploy from the CircleCI job instead of a background watcher | 7 |
| `9ffba8399` | feat(runtime): add uv, pip, chromium and engram to the image | 2, 3 |
| `2c411b2f0` | fix(runtime): drop the root pip cache cleanup from the analytics-mcp step | 3 |
| `324d311f5` | fix(runtime): reclaim MCP servers and give the browser a working sandbox | 2, 6 |
| `f7ba47ede` | fix(runtime): reclaim orphaned servers on a timer, not only at startup | 6 |
| `5203cc5d8` | chore(runtime): pin the OpenCode CLI to 2.1.2 | 3 |
| `afffa0c5a` | feat(runtime): share one Doppler MCP server across every project | 5 |
| `78a142b7e` | fix(runtime): write the bridge wrapper as root and keep its variables | 5 |
| `c15d517ee` | fix(runtime): write the bridge wrapper at start time, not during the build | 5 |
| `43332ca65` | feat(runtime): install the shared MCP servers once, into the volume | 4 |
| `9a8c6178b` | fix(runtime): keep the shared MCP archives in a directory the runtime user owns | 4 |
| `80156e668` | ci: publish the build log so a failed build can be read | 7 |
| `44d2d4395` | ci: put the step condition inside the run mapping | 7 |
| `cb3244638` | fix(image): correct MARKITDOWN_MCP_VERSION ARG typo and fail fast on unset versions | 4 |
| `3c1e55c4b` | fix(runtime): keep the shared MCP bridge alive past the orphan sweep | 5, 6 |
| `6506a5a5c` | perf(image): run on production dependencies only | 1 |
| `0937b928f` | test(smoke): follow the server's real import graph | 7 |
| `3875d5638` | feat(image): make the browser flavour a build argument | 2 |
| `f8b5a5d2b` | docs(fork): record every fork change and the upstream sync procedure | doc |
| merge | sync: bring in upstream v2.5.1 (`@opencode/cli@2.1.3`, Bun 1.4.4); drops the dead `overlay/` | sync |

## Appendix B — file ownership

| Path | Owner | Notes |
|---|---|---|
| `Dockerfile` | **both** | fork blocks are listed in §2.1; upstream owns the stage skeleton |
| `scripts/docker-entrypoint.sh` | **both** | upstream owns SSH/UI-password/oh-my-opencode; fork owns vendor + bridge |
| `scripts/smoke-test.sh` | fork | no upstream counterpart |
| `.fork/*` | fork | never upstream |
| `.circleci/*` | fork | upstream uses GitHub Actions |
| `docker-compose.yaml` | fork | upstream ships a different one |
| `.github/workflows/*` | upstream | re-run the sync script after every merge |
| `renovate.json` | **both** | take upstream, re-apply fork additions |
| `packages/web/server/index.js` | **both** | reaping wiring only |
| `packages/web/server/lib/opencode/lifecycle.js` | **both** | reaping wiring only |
| `packages/web/server/lib/opencode/mcp-process-cleanup*.js` | fork | new files, no upstream counterpart |
| `packages/web/server/lib/opencode/shutdown-runtime.js` | **both** | one added getter/clearer |
| `package.json` / `bun.lock` | upstream | except `@opencode/client`, which must match the CLI pin |
| `AGENTS.md`, `CLAUDE.md`, `README.md` | upstream | do not put fork notes here, it conflicts every sync |

---

## Checklist (copy into the PR body)

- [ ] `git status` clean before starting; prod healthy before starting
- [ ] merged the upstream **tag**, not a random `main` commit
- [ ] `sh .fork/sync-upstream-workflows.sh` run after the merge
- [ ] `renovate.json` re-checked for the fork's `schedule` / Node ARG manager
- [ ] `Dockerfile`: all 12 fork blocks present, ARG defaults unchanged
- [ ] `Dockerfile` CLI version == `package.json` `@opencode/client`
- [ ] `prod-deps` still referenced by the runtime `COPY`s
- [ ] reaping wiring re-derived, not blindly resolved
- [ ] `bun.lock` regenerated, not hand-merged
- [ ] `package.json` version == `docker-compose.yaml` tag
- [ ] tests: cleanup module test, type-check, lint
- [ ] CI green, deploy step green
- [ ] `sh scripts/smoke-test.sh` → 12/12
- [ ] bridge pid alive with ppid 1, `/opt/browser/chrome --version` sane
- [ ] one project chat answers; Server Browser loads a page
- [ ] rollback target noted (previous image tag)
