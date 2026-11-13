import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PACKAGE_NAME = '@nco-studio/web-editor-mcp';
const MAX_LEVELS = 6;

/**
 * Reads this package's version from its own package.json.
 *
 * tsup bundles this module into both dist/server.js (one level below the
 * package root) and dist/bin/cli.js (two levels below), so no fixed relative
 * path is right for both. Walk up from the calling file instead and identify the
 * package by name, so an unrelated package.json (a monorepo root, a consumer's
 * project) is never mistaken for it. Throws rather than falling back: a broken
 * install must fail loudly, not announce a placeholder version.
 */
export function readPackageVersion(fromUrl: string = import.meta.url): string {
  const start = dirname(fileURLToPath(fromUrl));
  let dir = start;
  for (let level = 0; level < MAX_LEVELS; level++) {
    try {
      const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')) as {
        name?: unknown;
        version?: unknown;
      };
      if (pkg.name === PACKAGE_NAME && typeof pkg.version === 'string') {
        return pkg.version;
      }
    } catch {
      // Unreadable or not JSON: keep walking.
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(`Could not find ${PACKAGE_NAME} package.json at or above ${start}`);
}

export const PACKAGE_VERSION = readPackageVersion();
