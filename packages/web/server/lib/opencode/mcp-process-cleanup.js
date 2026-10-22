// Cleanup for the MCP servers OpenCode starts.
//
// OpenCode spawns each MCP server DETACHED: the child leads its own process
// group. A group kill that OpenChamber sends to the OpenCode server therefore
// never reaches them. When that server goes away they are reparented to init
// and keep running, holding their memory for the rest of the container's life.
//
// On a host with many project locations this is the single largest consumer
// of memory in the setup: OpenCode opens one MCP connection per location, so
// every configured local server is started once per location, and the ones
// left behind by a server that was killed are never reclaimed.
//
// Two entry points:
//   killMcpChildrenOf(pid)  end the MCP servers a given OpenCode pid started.
//                           Call it while that pid is still alive, because the
//                           parent link is how the children are identified.
//   reapOrphanedMcpServers() end the MCP servers whose parent is gone.
//
// Both are deliberately narrow. A process is only ever considered when its
// command line looks like an MCP server, so a shell or a language server
// started by the same parent is never touched.

import { execFile } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const defaultExecFileAsync = promisify(execFile);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isPidAlive = (pid) => {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM = the process exists but we may not signal it → still alive.
    return error?.code === 'EPERM';
  }
};

// A process is an MCP server when its command line names one. This keeps the
// cleanup away from unrelated children even when they share a parent.
const looksLikeMcpServer = (command) => {
  if (typeof command !== 'string') return false;
  const lower = command.toLowerCase();
  if (lower.includes('mcp')) return true;
  if (lower.includes('markitdown')) return true;
  return false;
};

const readProcessTable = async (execFileAsync) => {
  const { stdout } = await execFileAsync('ps', ['-o', 'pid=,ppid=,command='], {
    encoding: 'utf8',
    timeout: 5000,
    windowsHide: true,
  });
  return stdout || '';
};

const parseProcessTable = (listing) => {
  const rows = [];
  for (const line of listing.split('\n')) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (!match) continue;
    rows.push({
      pid: Number.parseInt(match[1], 10),
      ppid: Number.parseInt(match[2], 10),
      command: match[3],
    });
  }
  return rows;
};

const endProcess = async (pid, { log } = {}) => {
  try {
    process.kill(pid, 'SIGTERM');
  } catch {
    return false;
  }
  for (let waited = 0; waited < 1000 && isPidAlive(pid); waited += 100) {
    await sleep(100);
  }
  if (isPidAlive(pid)) {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      // already gone
    }
  }
  log?.(`[lifecycle] stopped MCP server pid ${pid}`);
  return true;
};

/**
 * End the MCP servers the given OpenCode pid started.
 *
 * The children are found through the parent link, so this has to run while
 * that pid is still alive. Returns how many were ended.
 */
export const killMcpChildrenOf = async (pid, { log, execFileAsync = defaultExecFileAsync } = {}) => {
  if (process.platform === 'win32') return 0;
  if (!Number.isInteger(pid) || pid <= 0) return 0;

  let rows;
  try {
    rows = parseProcessTable(await readProcessTable(execFileAsync));
  } catch {
    return 0;
  }

  let killed = 0;
  for (const row of rows) {
    if (row.ppid !== pid) continue;
    if (!looksLikeMcpServer(row.command)) continue;
    if (await endProcess(row.pid, { log })) killed += 1;
  }
  return killed;
};

/**
 * End the MCP servers whose owner is gone.
 *
 * A process whose parent is init was reparented there because its owner
 * exited, which is exactly the case to reclaim. Anything still owned by a
 * live parent is left alone. Returns how many were ended.
 */
export const reapOrphanedMcpServers = async ({ log, execFileAsync = defaultExecFileAsync } = {}) => {
  if (process.platform === 'win32') return 0;

  let rows;
  try {
    rows = parseProcessTable(await readProcessTable(execFileAsync));
  } catch {
    return 0;
  }

  let killed = 0;
  for (const row of rows) {
    if (row.ppid !== 1) continue;
    if (!looksLikeMcpServer(row.command)) continue;
    if (await endProcess(row.pid, { log })) killed += 1;
  }
  return killed;
};

/**
 * End an OpenCode server that was orphaned, together with the MCP servers it
 * started.
 *
 * OpenChamber starts its OpenCode server detached, so a server whose owner
 * exited is reparented to init and keeps running. The registry usually
 * remembers the pid, but that file is gone when the owner was killed before
 * it could write one, which leaves the server running with no trace. Finding
 * it in the process table covers that case.
 *
 * Only a server running from the OpenChamber user's own install is
 * considered, so a standalone `opencode` the user started themselves is not
 * touched.
 */
export const reapOrphanedOpencodeServers = async ({ log, execFileAsync = defaultExecFileAsync } = {}) => {
  if (process.platform === 'win32') return 0;

  let rows;
  try {
    rows = parseProcessTable(await readProcessTable(execFileAsync));
  } catch {
    return 0;
  }

  const managedPrefix = path.join(os.homedir(), '.npm-global');
  let killed = 0;
  for (const row of rows) {
    if (row.ppid !== 1) continue;
    const command = row.command || '';
    if (!command.includes(managedPrefix)) continue;
    if (!command.toLowerCase().includes('opencode')) continue;
    if (!command.toLowerCase().includes('serve')) continue;
    // The MCP servers it started are detached, so they need their own pass.
    await killMcpChildrenOf(row.pid, { log, execFileAsync });
    if (await endProcess(row.pid, { log })) {
      log?.(`[lifecycle] reaped orphaned OpenCode server pid ${row.pid}`);
      killed += 1;
    }
  }
  return killed;
};
