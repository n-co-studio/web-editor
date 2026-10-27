/**
 * Install link for the masthead: Google's "Available in the Chrome Web Store"
 * badge, used plain.
 *
 * The Figma guide design (node 52:3788) places the badge bare — no outline, no
 * padding, no overlaid glyph — at 212 x 59.86px, bottom-aligned with the
 * product title. Earlier iterations of this component had an outlined
 * container, a hover ring and an external-link arrow drawn over the artwork;
 * the design supersedes all three.
 *
 * That also resolves a compliance question. Google's branding guidelines allow
 * the badge with one modification only, resizing, and require a resized badge
 * to "preserve the ratio of dimensions" and stay "legible and fully visible".
 * Bare and unobscured satisfies both without argument.
 *
 * BADGE_H is 56px against the design's 59.86px — the asset is 340x96 and its
 * "Available in the" line sits near 14px in the original, so anything much
 * under ~56px drops that line below legibility. Width is never set, so the
 * 3.54:1 ratio cannot drift.
 */

import { CHROME_STORE_URL } from '../storeUrl';

const BADGE_H = 56;

export default function StoreInstallButton() {
  return (
    <a
      href={CHROME_STORE_URL}
      target="_blank"
      rel="noopener noreferrer"
      aria-label="Install from the Chrome Web Store — opens in a new tab"
      // line-height 0 stops the inline image leaving a descender gap beneath
      // it, which would read as padding the design does not have.
      style={{ display: 'inline-block', lineHeight: 0, textDecoration: 'none', flexShrink: 0 }}
    >
      {/* alt="" and aria-hidden: the anchor's aria-label already names the
          destination, so labelling the image too announces it twice. */}
      <img
        src={`${import.meta.env.BASE_URL}chrome-web-store-badge.png`}
        alt=""
        aria-hidden="true"
        style={{ height: BADGE_H, width: 'auto', display: 'block' }}
      />
    </a>
  );
}
