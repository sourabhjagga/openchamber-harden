import { afterEach, describe, expect, it, vi } from 'vitest';

import { killMcpChildrenOf, reapOrphanedMcpServers, reapOrphanedOpencodeServers } from './mcp-process-cleanup.js';

const ORIGINAL_PLATFORM = Object.getOwnPropertyDescriptor(process, 'platform');
const ORIGINAL_KILL = process.kill;

const setPlatform = (platform) => {
  Object.defineProperty(process, 'platform', { value: platform, configurable: true });
};

const restorePlatform = () => {
  if (ORIGINAL_PLATFORM) {
    Object.defineProperty(process, 'platform', ORIGINAL_PLATFORM);
  }
};

// The process table the helpers read, as `ps` would print it.
const psTable = (rows) =>
  rows.map(([pid, ppid, command]) => `${String(pid).padStart(5)} ${String(ppid).padStart(5)} ${command}`).join('\n');

const execFileAsyncFor = (listing) => async (cmd, args) => {
  if (cmd === 'ps') return { stdout: listing, stderr: '' };
  throw new Error(`unexpected command ${cmd}`);
};

describe('mcp process cleanup', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    if (ORIGINAL_PLATFORM) {
      Object.defineProperty(process, 'platform', { value: ORIGINAL_PLATFORM, configurable: true });
    }
    Object.defineProperty(process, 'kill', { value: ORIGINAL_KILL, configurable: true });
  });

  it('ends the MCP children of a given OpenCode pid', async () => {
    setPlatform('linux');
    const kill = vi.fn();
    Object.defineProperty(process, 'kill', { value: kill, configurable: true });

    const listing = psTable([
      [100, 1, 'opencode serve --hostname 127.0.0.1'],
      [101, 100, 'node /home/openchamber/.config/opencode/vendor/keywords-mcp/dist/index.js'],
      [102, 100, 'python3 /home/openchamber/.local/bin/analytics-mcp'],
      [103, 100, 'bash -c some shell the user ran'],
      [104, 100, '/usr/local/bin/uv tool uvx markitdown-mcp'],
    ]);

    const killed = await killMcpChildrenOf(100, { execFileAsync: execFileAsyncFor(listing) });

    // The shell is not an MCP server and must be left alone.
    expect(killed).toBe(3);
    const signalled = kill.mock.calls.map((call) => call[0]);
    expect(signalled).toContain(101);
    expect(signalled).toContain(102);
    expect(signalled).toContain(104);
    expect(signalled).not.toContain(103);
  });

  it('ends MCP servers whose parent is gone', async () => {
    setPlatform('linux');
    const kill = vi.fn();
    Object.defineProperty(process, 'kill', { value: kill, configurable: true });

    const listing = psTable([
      [200, 1, 'node /home/openchamber/.config/opencode/vendor/keywords-mcp/dist/index.js'],
      [201, 1, '/usr/local/bin/uv tool uvx markitdown-mcp'],
      [202, 1, 'bash -c a shell the user ran'],
      // Still owned by a live parent: not an orphan, must survive.
      [203, 300, 'python3 /home/openchamber/.local/bin/analytics-mcp'],
    ]);

    const killed = await reapOrphanedMcpServers({ execFileAsync: execFileAsyncFor(listing) });

    expect(killed).toBe(2);
    const signalled = kill.mock.calls.map((call) => call[0]);
    expect(signalled).toContain(200);
    expect(signalled).toContain(201);
    expect(signalled).not.toContain(202);
    expect(signalled).not.toContain(203);
  });

  it('does nothing when the process table cannot be read', async () => {
    setPlatform('linux');
    const kill = vi.fn();
    Object.defineProperty(process, 'kill', { value: kill, configurable: true });

    const failing = async () => {
      throw new Error('ps is missing');
    };

    expect(await killMcpChildrenOf(100, { execFileAsync: failing })).toBe(0);
    expect(await reapOrphanedMcpServers({ execFileAsync: failing })).toBe(0);
    expect(kill).not.toHaveBeenCalled();
  });

  it('ignores an invalid pid', async () => {
    setPlatform('linux');
    expect(await killMcpChildrenOf(0, { execFileAsync: execFileAsyncFor('') })).toBe(0);
    expect(await killMcpChildrenOf(-1, { execFileAsync: execFileAsyncFor('') })).toBe(0);
  });

  it('ends an orphaned OpenCode server and the MCP servers it started', async () => {
    setPlatform('linux');
    const kill = vi.fn();
    Object.defineProperty(process, 'kill', { value: kill, configurable: true });

    const home = process.env.HOME || '/home/openchamber';
    const listing = psTable([
      // The orphaned server: parent is init, running from the managed install.
      [400, 1, `${home}/.npm-global/lib/node_modules/@opencode/cli/bin/opencode.exe serve --service`],
      // Its MCP servers, which it started and which are detached.
      [401, 400, 'node /home/openchamber/.config/opencode/vendor/keywords-mcp/dist/index.js'],
      [402, 400, 'python3 /home/openchamber/.local/bin/analytics-mcp'],
      // A server that is not ours: a standalone install, and still owned.
      [403, 1, '/usr/local/bin/opencode serve --hostname 127.0.0.1'],
      [404, 500, `${home}/.npm-global/bin/opencode serve --hostname 127.0.0.1`],
    ]);

    const killed = await reapOrphanedOpencodeServers({ execFileAsync: execFileAsyncFor(listing) });

    expect(killed).toBe(1);
    const signalled = kill.mock.calls.map((call) => call[0]);
    expect(signalled).toContain(400);
    // The MCP servers it started go with it.
    expect(signalled).toContain(401);
    expect(signalled).toContain(402);
    // A standalone opencode, and one with a live owner, are left alone.
    expect(signalled).not.toContain(403);
    expect(signalled).not.toContain(404);
  });
});
