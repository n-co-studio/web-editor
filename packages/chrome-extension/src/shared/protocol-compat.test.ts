import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { PROTOCOL_VERSION } from '@nco-studio/shared';
import { isCompatibleServerProtocol } from './protocol-compat';

describe('server protocol compatibility (version skew)', () => {
  it('accepts the current protocol version', () => {
    assert.equal(isCompatibleServerProtocol(PROTOCOL_VERSION), true);
  });

  it('accepts a 0.3.0 server (protocol 0.4.0) so a store-updated extension keeps working', () => {
    assert.equal(isCompatibleServerProtocol('0.4.0'), true);
  });

  it('rejects an unknown version', () => {
    assert.equal(isCompatibleServerProtocol('9.9.9'), false);
    assert.equal(isCompatibleServerProtocol(''), false);
  });
});
