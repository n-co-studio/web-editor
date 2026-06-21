/**
 * Integration test: Batch Identity end-to-end
 *
 * Verifies that a single Apply-Changes dispatch carries one batchId through
 * the bridge ingest path and is correctly surfaced by the MCP tools.
 *
 * Coverage:
 * - All diffs in one payload share the same batchId
 * - batchNote is correlated to batchId in stored PendingNote
 * - batches summary lists the batch with the correct diffCount
 * - get_queue_status.latest_batch_id matches the ingested batchId
 * - batchId filter on getPendingChanges returns only matching diffs
 * - Legacy diffs (no batchId) pass through without errors
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { VisualDiffBatchPayload, VisualDiff } from '@nco-studio/shared';
import { Bridge } from './bridge.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const baseRect = { x: 0, y: 0, width: 100, height: 20, top: 0, right: 100, bottom: 20, left: 0 };

function makeDiff(id: string, batchId?: string): VisualDiff {
  return {
    id,
    timestamp: new Date().toISOString(),
    batchId,
    element: {
      selector: `.el-${id}`,
      tagName: 'div',
      sourceFile: 'src/App.tsx',
      sourceLine: 1,
      attributes: {},
      boundingRect: baseRect,
    },
    changes: [{ property: 'color', fromValue: '#000', toValue: '#fff' }],
    context: { url: 'http://localhost:3000', viewport: { width: 1280, height: 800 }, tabId: 'tab-1' },
    status: 'pending',
    sourceVerified: false,
  };
}

/** Access a private Bridge method for testing without a running WebSocket. */
function ingest(bridge: Bridge, payload: VisualDiffBatchPayload): Promise<void> {
  return (bridge as unknown as Record<string, (p: VisualDiffBatchPayload) => Promise<void>>)
    .processDiffBatch(payload);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

let tmpDir: string;

before(async () => {
  tmpDir = await mkdtemp(join(tmpdir(), 'nco-bridge-test-'));
});

after(async () => {
  await rm(tmpDir, { recursive: true, force: true });
});

describe('Batch identity — bridge ingest', () => {
  it('all diffs in one payload share the batchId from the envelope', async () => {
    const bridge = new Bridge(tmpDir);
    const batchId = 'batch-20260621-143052-a3f7';

    const diffs = [makeDiff('d1'), makeDiff('d2'), makeDiff('d3')];
    await ingest(bridge, { diffs, batchNote: 'Adjust hero colors', batchId });

    const { diffs: changes, notes, batches } = bridge.getPendingChanges();

    // All three diffs are present with the shared batchId
    assert.equal(changes.length, 3);
    for (const diff of changes) {
      assert.equal(diff.batchId, batchId, `diff ${diff.id} should carry batchId`);
    }

    // Note is correlated to the batchId
    assert.equal(notes.length, 1);
    assert.equal(notes[0].text, 'Adjust hero colors');
    assert.equal(notes[0].batchId, batchId);

    // batches summary lists the batch
    assert.equal(batches.length, 1);
    assert.equal(batches[0].batchId, batchId);
    assert.equal(batches[0].batchNote, 'Adjust hero colors');
    assert.equal(batches[0].diffCount, 3);

    // get_queue_status.latest_batch_id matches
    const status = bridge.getQueueStatus();
    assert.equal(status.latest_batch_id, batchId);
  });

  it('batchId filter returns only diffs matching that batchId', async () => {
    const bridge = new Bridge(tmpDir + '-filter');
    const batchA = 'batch-20260621-100000-aaaa';
    const batchB = 'batch-20260621-110000-bbbb';

    await ingest(bridge, { diffs: [makeDiff('a1'), makeDiff('a2')], batchId: batchA });
    await ingest(bridge, { diffs: [makeDiff('b1')], batchId: batchB });

    const { diffs: all } = bridge.getPendingChanges();
    assert.equal(all.length, 3);

    const { diffs: filtered } = bridge.getPendingChanges(undefined, batchA);
    assert.equal(filtered.length, 2);
    assert.ok(filtered.every((d: { batchId?: string }) => d.batchId === batchA));

    const { diffs: filteredB } = bridge.getPendingChanges(undefined, batchB);
    assert.equal(filteredB.length, 1);
    assert.equal(filteredB[0].id, 'b1');
  });

  it('batches summary is ordered newest-first', async () => {
    const bridge = new Bridge(tmpDir + '-order');
    const older = 'batch-20260620-120000-cccc';
    const newer = 'batch-20260621-120000-dddd';

    // Ingest older batch first, then newer
    await ingest(bridge, { diffs: [makeDiff('c1')], batchId: older });
    await ingest(bridge, { diffs: [makeDiff('d1'), makeDiff('d2')], batchId: newer });

    const { batches } = bridge.getPendingChanges();
    assert.equal(batches.length, 2);
    // newer batch must appear first
    assert.equal(batches[0].batchId, newer);
    assert.equal(batches[0].diffCount, 2);
    assert.equal(batches[1].batchId, older);
    assert.equal(batches[1].diffCount, 1);
  });

  it('legacy diffs (no batchId) pass through in changes without errors', async () => {
    const bridge = new Bridge(tmpDir + '-legacy');
    // Simulate pre-batchId extension: no batchId on diffs or envelope
    const legacyDiff = makeDiff('leg1');
    await ingest(bridge, { diffs: [legacyDiff] });

    const { diffs: changes, batches } = bridge.getPendingChanges();
    assert.equal(changes.length, 1);
    // Bridge stamps a synthetic legacy batchId — diff should have a batchId
    assert.ok(changes[0].batchId, 'legacy diff should get a synthetic batchId from bridge');
    // The batches index includes the synthetic batch
    assert.equal(batches.length, 1);
    assert.ok(batches[0].batchId.startsWith('batch-legacy-'));
  });

  it('latest_batch_id tracks the most recently ingested batch', async () => {
    const bridge = new Bridge(tmpDir + '-latest');
    const first = 'batch-20260621-090000-1111';
    const second = 'batch-20260621-100000-2222';

    await ingest(bridge, { diffs: [makeDiff('x1')], batchId: first });
    assert.equal(bridge.getQueueStatus().latest_batch_id, first);

    await ingest(bridge, { diffs: [makeDiff('x2')], batchId: second });
    assert.equal(bridge.getQueueStatus().latest_batch_id, second);
  });
});
