/**
 * The version the server reports must be the installed package's own, on every
 * entry point. Expected values are read straight from package.json, never from a
 * copy of the number, so a hard-coded or wrongly resolved version fails here.
 *
 * No createServer() call: it binds ports 7890-7899, starts file watchers and
 * takes over stdio. The factory under test, createMcpServer(), is what
 * createServer() constructs its server through.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { createMcpServer } from './server.js';
import { readPackageVersion } from './version.js';

// From src/ the package root is one level up.
const { name, version } = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf8'),
) as { name: string; version: string };

describe('serverInfo version', () => {
  let client: Client;
  let server: McpServer;

  before(async () => {
    server = createMcpServer();
    client = new Client({ name: 'test-client', version: '0.0.0' });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  });

  after(async () => {
    await client?.close();
    await server?.close();
  });

  it('reports the package.json version over the MCP handshake', () => {
    assert.deepEqual(client.getServerVersion(), { name: 'nco-web-editor', version });
  });
});

describe('readPackageVersion', () => {
  it('resolves the version from the src/bin depth, as dist/bin/cli.js does', () => {
    assert.equal(readPackageVersion(new URL('./bin/cli.ts', import.meta.url).href), version);
  });

  it('skips package.json files that are not this package and keeps walking up', async () => {
    const root = await mkdtemp(join(tmpdir(), 'nco-version-'));
    try {
      const other = join(root, 'a');
      const deep = join(other, 'b');
      await mkdir(deep, { recursive: true });
      await writeFile(join(root, 'package.json'), JSON.stringify({ name, version: '9.9.9' }));
      await writeFile(join(other, 'package.json'), JSON.stringify({ name: 'unrelated', version: '1.0.0' }));
      await writeFile(join(deep, 'package.json'), '{ not json');
      assert.equal(readPackageVersion(pathToFileURL(join(deep, 'x.js')).href), '9.9.9');

      // A matching name without a string version is not a match either.
      await writeFile(join(root, 'package.json'), JSON.stringify({ name, version: 9 }));
      assert.throws(() => readPackageVersion(pathToFileURL(join(deep, 'x.js')).href), /Could not find/);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('throws, naming the start path, when no matching package.json is in reach', async () => {
    // Under os.tmpdir(), never inside the repo, so no matching package.json is above it.
    const dir = await mkdtemp(join(tmpdir(), 'nco-version-'));
    try {
      assert.throws(
        () => readPackageVersion(pathToFileURL(join(dir, 'x.js')).href),
        (err: unknown) => {
          assert.equal(err instanceof Error, true);
          const message = (err as Error).message;
          assert.match(message, /Could not find @nco-studio\/web-editor-mcp package\.json/);
          assert.equal(message.includes(dir), true);
          return true;
        },
      );
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
