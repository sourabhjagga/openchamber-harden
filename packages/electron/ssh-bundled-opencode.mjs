// Bundled-OpenCode probe for a managed remote. Kept out of ssh-manager.mjs so
// that large file does not grow past the repository's 800-line file-size gate.
export async function probeRemoteBundledOpenCode(manager, parsed, controlPath, binPath, remotePathPrefix, shellQuote) {
  if (!binPath) return false;
  const probeScript = [
    `PATH="${remotePathPrefix}:$PATH"`,
    `node -e 'const fs=require("node:fs"),path=require("node:path");`,
    `if(process.versions.bun)process.exit(1);`,
    `const[maj,min]=(process.versions.node||"").split(".").map(Number);`,
    `if(!(maj>=24||(maj===22&&min>=16)))process.exit(1);`,
    `if(process.platform==="linux"&&!process.report?.getReport?.()?.header?.glibcVersionRuntime)process.exit(1);`,
    `const real=fs.realpathSync(process.argv[1]);`,
    `const dir=path.resolve(path.dirname(real),"..","opencode-server");`,
    `if(!fs.existsSync(path.join(dir,"serve.mjs"))||!fs.existsSync(path.join(dir,"assets","manifest.json")))process.exit(1);`,
    `process.stdout.write("bundled\\n");'`,
    shellQuote(binPath),
    '2>/dev/null || true',
  ].join(' ');
  try {
    const output = await manager.runRemoteCommand(parsed, controlPath, probeScript);
    return output.trim() === 'bundled';
  } catch {
    return false;
  }
}
