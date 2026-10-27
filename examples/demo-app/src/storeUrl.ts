/**
 * The published Chrome Web Store listing. Approved 2026-10-15; extension id
 * aifpecjojmlgdhgnkmkaobmfipdmppea.
 *
 * Exported from one module because two places link it — the masthead's install
 * button and the setup guide's install step. When this lived as a const inside
 * SetupGuide it carried a comment calling itself "the single place the store is
 * linked from"; a second copy would have made that false silently, which is the
 * shape of the bug that left a dead pre-rename search URL on the live page for
 * three days.
 *
 * Carries no authuser= or hl= parameters: those are specific to whoever copied
 * the URL out of their own browser and are wrong for everyone else.
 */
export const CHROME_STORE_URL =
  'https://chromewebstore.google.com/detail/ai-agent-visual-editor/aifpecjojmlgdhgnkmkaobmfipdmppea';
