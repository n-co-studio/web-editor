/**
 * Tools that return values parsed out of the project's own files lead with a
 * notice that the JSON after it is data (KL-7). The JSON block is unchanged.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { Bridge } from './bridge.js';
import { registerTools, SERVER_INSTRUCTIONS, REPO_DATA_NOTICE } from './server.js';

let dir: string;
let client: Client;
let server: McpServer;

before(async () => {
  dir = await mkdtemp(join(tmpdir(), 'nco-repo-data-'));
  const bridge = new Bridge(dir); // never started: no socket is opened
  server = new McpServer(
    { name: 'nco-web-editor', version: '0.0.0-test' },
    { instructions: SERVER_INSTRUCTIONS },
  );
  registerTools(server, bridge);
  client = new Client({ name: 'test-client', version: '0.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
  await server?.close();
  if (dir) await rm(dir, { recursive: true, force: true });
});

describe('repo-derived tool output is framed as data (KL-7)', () => {
  for (const name of ['get_design_tokens', 'get_project_components']) {
    it(`${name} returns the notice, then the unchanged JSON`, async () => {
      const res = await client.callTool({ name, arguments: {} });
      const content = res.content as Array<{ type: string; text: string }>;
      assert.equal(content.length, 2);
      assert.equal(content[0].type, 'text');
      assert.equal(content[0].text, REPO_DATA_NOTICE);
      assert.equal(content[1].type, 'text');
      assert.equal(typeof JSON.parse(content[1].text), 'object');
    });
  }
});
