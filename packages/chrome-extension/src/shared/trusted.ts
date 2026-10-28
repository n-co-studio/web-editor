/**
 * Editor listeners on `document` / `window` are reachable by page script: it can
 * dispatch synthetic events (isTrusted === false) at them. Those events must not
 * select elements, run shortcuts or drive drags (KL-4). Wrap every such
 * listener with this so the check is applied the same way everywhere.
 */
export function trustedOnly<E extends Event>(handler: (e: E) => void): (e: E) => void {
  return (e: E) => {
    if (!e.isTrusted) return;
    handler(e);
  };
}
