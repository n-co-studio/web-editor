/**
 * Tool-schema contract tests for the MCP server.
 *
 * Pins the agent-facing tool surface (name, description, inputSchema as seen
 * by a real MCP client) against a committed fixture, and pins runtime
 * validation behaviour. Guards dependency moves of zod / the MCP SDK.
 *
 * The fixture is never regenerated automatically; this test only compares. To
 * change the tool surface deliberately, build the same array the snapshot test
 * builds (listTools -> name/description/inputSchema, sorted by name), write it
 * with `JSON.stringify(actual, null, 2) + '\n'` to `src/__fixtures__/tools-list.json`,
 * and review the diff as a change to the agent-facing contract.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { Bridge } from './bridge.js';
import { registerTools, SERVER_INSTRUCTIONS } from './server.js';

let dir: string;
let client: Client;
let server: McpServer;
/** The arguments each real handler last received, after the SDK parsed them. */
const received = new Map<string, unknown>();

before(async () => {
  dir = await mkdtemp(join(tmpdir(), 'nco-tool-schemas-'));
  const bridge = new Bridge(dir); // never started: no socket is opened
  server = new McpServer(
    { name: 'nco-web-editor', version: '0.0.0-test' },
    { instructions: SERVER_INSTRUCTIONS },
  );
  // Record what each real handler receives. Name, config and schema pass through unchanged.
  type Handler = (...a: unknown[]) => unknown;
  type RegisterTool = (name: string, config: unknown, cb: Handler) => unknown;
  const original = server.registerTool.bind(server) as unknown as RegisterTool;
  (server as unknown as { registerTool: RegisterTool }).registerTool = (name, config, cb) =>
    original(name, config, (...a) => {
      received.set(name, a[0]);
      return cb(...a);
    });
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

/**
 * Call a tool and report whether the server rejected its input. The SDK returns
 * a validation failure as an isError result whose text contains
 * "Input validation error: Invalid arguments for tool <name>" (McpError prefixes
 * its own code). Any other isError result (unknown tool, handler crash) fails the
 * test, and a transport or protocol failure throws out of it.
 */
async function rejected(name: string, args: Record<string, unknown>): Promise<boolean> {
  const res = await client.callTool({ name, arguments: args });
  if (res.isError !== true) return false;
  const content = res.content as Array<{ type: string; text?: string }>;
  const text = content[0]?.text ?? '';
  if (text.includes(`Input validation error: Invalid arguments for tool ${name}`)) return true;
  assert.fail(`${name} returned an error that is not an input-validation rejection: ${text}`);
}

describe('tool list snapshot', () => {
  it('matches the committed fixture', async () => {
    const { tools } = await client.listTools();
    const actual = tools
      .map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema }))
      .sort((a, b) => a.name.localeCompare(b.name));
    const fixture = JSON.parse(
      await readFile(new URL('./__fixtures__/tools-list.json', import.meta.url), 'utf8'),
    );
    assert.deepEqual(JSON.parse(JSON.stringify(actual)), fixture);
  });
});

describe('input validation', () => {
  it('rejects a missing required field', async () => {
    assert.equal(await rejected('acknowledge_visual_change', {}), true);
  });

  it('rejects a wrong-typed field', async () => {
    assert.equal(await rejected('acknowledge_visual_change', { diffId: 123 }), true);
  });

  it('accepts omitting optional fields', async () => {
    assert.equal(await rejected('get_pending_visual_changes', {}), false);
  });

  it('accepts unknown extra keys (zod strips them; inputObject in server.ts)', async () => {
    assert.equal(await rejected('get_pending_visual_changes', { bogus_extra_key: 'x' }), false);
  });

  it('strips unknown keys before the handler runs (acknowledge_visual_change)', async () => {
    received.delete('acknowledge_visual_change');
    assert.equal(
      await rejected('acknowledge_visual_change', { diffId: 'x', bogus_extra_key: 'y' }),
      false,
    );
    assert.deepEqual(received.get('acknowledge_visual_change'), { diffId: 'x' });
  });

  it('strips unknown keys before the handler runs (get_pending_visual_changes)', async () => {
    received.delete('get_pending_visual_changes');
    assert.equal(await rejected('get_pending_visual_changes', {}), false);
    const clean = received.get('get_pending_visual_changes');
    received.delete('get_pending_visual_changes');
    assert.equal(await rejected('get_pending_visual_changes', { bogus_extra_key: 'x' }), false);
    assert.deepEqual(received.get('get_pending_visual_changes'), clean);
    assert.deepEqual(clean, {});
  });
});
