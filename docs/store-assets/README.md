# Chrome Web Store assets

Screenshots for the store listing. Chrome requires each to be **exactly
1280×800** or 640×400 — anything else is rejected at upload.

| File | Shows |
|---|---|
| `01-select-and-edit.png` | An element selected, with the dimension overlay and the toolbar |
| `02-inline-text.png` | Inline text editing, with the formatting bar |
| `03-insert-elements.png` | The insert panel, choosing a layout to add |
| `promo-tile-440x280.png` | Small promo tile — store homepage, category pages, search |

Generated from 3456×1992 captures. Retina captures are ~1.733, the store wants
1.600, so a crop is unavoidable — about 7.7% of the width.

**Crop from the left, not the centre.** Where the toolbar sits varies between
captures, and a centred crop removes ~134px from each side, which is enough to
slice the toolbar off when it is close to the left edge. A left-anchored crop
keeps it, because the surplus is always on the right where the canvas is empty.

To regenerate from a new capture:

    magick shot.png -crop 3187x1992+0+0 +repage -resize 1280x800 \
      +profile exif +profile xmp out.png

(`3187 = round(height × 1.6)` — recompute if the capture height differs.)

Drop EXIF and XMP, but **not** with `-strip`: that also removes the ICC colour
profile, which leaves one screenshot rendering differently from the others in
the same listing. `+profile exif +profile xmp` removes the metadata and keeps
the profile.

Open the result and check the toolbar and any open panel both survived before
trusting it — where the toolbar sits moves between captures.

## Still needed

- ~~**Small promo tile, 440×280.**~~ **Done** — `promo-tile-440x280.png`.
  Supplied as a 440×280 PNG carrying an alpha channel (fully opaque, but an
  alpha channel all the same, which Chrome rejects for promo tiles). Flattened
  to 24-bit truecolour on a white matte and verified pixel-identical to the
  original: `magick in.png -background white -alpha remove -alpha off -strip
  -define png:color-type=2 out.png`. Re-run that on any replacement.

  Original spec notes, kept for reference:

- **Small promo tile, 440×280.** Not derivable from a screenshot — Google
  explicitly asks for brand artwork rather than a capture. Treat it as
  **required**: the dashboard docs list it among the assets you must provide,
  and items without one rank below items with one. It appears on the store
  homepage, category pages and in search results, at roughly 220×140.
  PNG 24-bit with no alpha, or JPEG. Exact dimensions or it is rejected.

  **White ground**, to match the store icon and the three screenshots here.
  Type in `#0F0F0F`; green `#609D53` (the icon's) on arrows and shapes only —
  it is 3.3:1 on white, so nothing legible should depend on it. Full spec and
  the reasoning in `docs/store-listing.md`.

- **Marquee tile, 1400×560.** Genuinely optional — only for the homepage
  carousel, which an item cannot be chosen for without it.
