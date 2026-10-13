# Chrome Web Store assets

Screenshots for the store listing. Chrome requires each to be **exactly
1280×800** or 640×400 — anything else is rejected at upload.

| File | Shows | Caption |
|---|---|---|
| `01-spacing-on-the-page.png` | Spacing panel, padding/margin overlays live on the page | Design on the page. Your agent writes the code. |
| `02-typography-by-eye.png` | Typography panel adjusting the headline | Fine-tune type by eye, right on the page. |
| `03-insert-layouts.png` | Insert panel with layout presets | Add sections and layouts without writing CSS. |
| `04-edits-land-on-tokens.png` | Change queue showing token-named values | Edits land on your tokens, not one-off values. |
| `05-localhost-own-mcp-server.png` | Setup step 2 on localhost, MCP config | Runs on localhost. Talks only to your own MCP server. |
| `promo-tile-440x280.png` | Small promo tile | — |

Five screenshots, the store maximum. Each carries a caption band rather than
being a bare capture: at the size these render in a listing, an unlabelled
screenshot of an editor UI reads as visual noise, and the caption is what
makes the frame legible before anyone studies it.

Supplied already at 1280×800 with no alpha, so no crop or flatten was needed —
only EXIF and XMP stripped.

If a future capture is not already 1280×800, crop it from the left rather than
the centre — where the toolbar sits moves between captures, and a centred crop
takes ~134px off each side, enough to slice it off:

    magick shot.png -crop 3187x1992+0+0 +repage -resize 1280x800 \\
      +profile exif +profile xmp out.png

Drop EXIF and XMP, but **not** with `-strip`: that also removes the ICC colour
profile, leaving one screenshot rendering differently from the others in the
same listing.

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
