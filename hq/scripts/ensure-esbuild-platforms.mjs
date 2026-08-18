#!/usr/bin/env node
// Keep an esbuild binary for BOTH platforms this repo is edited from.
//
// The repo lives on a Mac and is ALSO mounted into a Linux container where agents run. esbuild
// ships a native binary per platform and npm installs only the one matching the current host, so
// whichever side installed last leaves the other broken:
//
//   You installed esbuild for another platform than the one you're currently using.
//   the "@esbuild/darwin-arm64" package is present but this platform needs "@esbuild/linux-arm64"
//
// `npm test` (tsx → esbuild) then fails on the other side, which agents hit repeatedly and read
// as their own code being wrong.
//
// Why this UNPACKS A TARBALL instead of running `npm i`:
//   * declaring the foreign package in devDependencies makes `npm install` FAIL on this host —
//     npm validates os/cpu on every declared dependency;
//   * installing it undeclared works once, and the NEXT `npm i` prunes it again as extraneous —
//     worse, installing the foreign one prunes the native one, so the two take turns breaking;
//   * as a postinstall hook it cannot work at all: npm exports the host's platform to lifecycle
//     scripts as npm_config_os/npm_config_cpu, which beats flags and env in the child.
//
// `npm pack` performs no platform check, and unpacking into node_modules leaves the dependency
// tree alone, so nothing prunes it and nothing fails. Run it after any install:
//   npm run fix:platforms
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const WANTED = ['darwin-arm64', 'linux-arm64'];

// Match the version esbuild itself resolved to, or the binary and the JS disagree at runtime.
let version;
try {
  version = JSON.parse(readFileSync('node_modules/esbuild/package.json', 'utf8')).version;
} catch {
  console.error('[esbuild] esbuild is not installed — run `npm install` first');
  process.exit(0);
}

const missing = WANTED.filter((p) => !existsSync(`node_modules/@esbuild/${p}/package.json`));
if (!missing.length) {
  console.log(`[esbuild] both platform binaries present (${version})`);
  process.exit(0);
}

for (const platform of missing) {
  const tmp = mkdtempSync(join(tmpdir(), 'esb-'));
  try {
    const spec = `@esbuild/${platform}@${version}`;
    const out = execFileSync('npm', ['pack', spec, '--pack-destination', tmp], { encoding: 'utf8' });
    const tarball = join(tmp, out.trim().split('\n').pop());
    const dest = `node_modules/@esbuild/${platform}`;
    mkdirSync(dest, { recursive: true });
    // The tarball's single top-level `package/` directory becomes the package root.
    execFileSync('tar', ['-xzf', tarball, '-C', dest, '--strip-components=1']);
    console.log(`[esbuild] added ${spec}`);
  } catch (e) {
    console.warn(`[esbuild] could not add @esbuild/${platform} — tests will fail there: ${e.message}`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}
