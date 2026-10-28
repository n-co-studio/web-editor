import { PROTOCOL_VERSION } from '@nco-studio/shared';

/**
 * Server protocol versions this extension still works with. 0.5.0 only added
 * the optional `notes` field to VISUAL_DIFF_BATCH, which a 0.4.0 server ignores
 * (the extension also sends the legacy `batchNote`), so a store-updated
 * extension keeps working against an `npx @^0` server that has not updated yet.
 * Drop an entry here when the extension can no longer talk to it.
 */
export const COMPATIBLE_SERVER_PROTOCOL_VERSIONS: readonly string[] = ['0.4.0'];

export function isCompatibleServerProtocol(serverVersion: string): boolean {
  return serverVersion === PROTOCOL_VERSION || COMPATIBLE_SERVER_PROTOCOL_VERSIONS.includes(serverVersion);
}
