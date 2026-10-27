# Chrome Web Store assets

Screenshots for the store listing. Chrome requires each to be **exactly
1280×800** or 640×400 — anything else is rejected at upload.

| File | Shows | Caption |
|---|---|---|
| `01-batched-changes-over-mcp.png` | Change queue dispatching a batch to the local MCP server | Send batched changes over MCP that map to your source code. |
| `02-drag-and-drop-editor.png` | Selection overlay and the editing panels — spacing, type, effects | Turn Chrome into a drag & drop editor with a full suite of tools. |
| `03-sections-layouts-components.png` | Insert panel adding sections and layout presets | Add new sections, layouts, and components to and from your code. |
| `04-edits-from-design-tokens.png` | Token snapping — edited values resolving to named tokens | All edits work from the design tokens established in your CSS. |
| `promo-tile-440x280.png` | Small promo tile | — |
| `store-icon-512.png` | Store listing icon | — |

Four screenshots, not the five Chrome allows. The fifth was dropped rather
than padded: each of these four carries one claim, and a fifth frame existed
only to restate one of them.

Each carries a caption band rather than being a bare capture. At the size
these render in a listing, an unlabelled screenshot of an editor UI reads as
visual noise, and the caption is what makes the frame legible before anyone
studies it. The captions lead on MCP, which is the thing competitors do not
do — they hand you a prompt to paste; this dispatches a batch and your agent
works while you keep designing.

**Ground: `#2F2F2F`,** with mint caption type. Decided 2026-10-19, replacing an
earlier white-ground set: the store page is itself white, so a white-ground
screenshot dissolves into it, and a dark frame is what separates the listing
from the extensions above and below it. The promo tile and the store icon were
re-cut to match, so all three surfaces agree.

Supplied already at 1280×800 with no alpha, so no crop or flatten was needed —
only EXIF and XMP stripped.

If a future capture is not already 1280×800, crop it from the left rather than
the centre — where the toolbar sits moves between captures, and a centred crop
takes ~134px off each side, enough to slice it off:

    magick shot.png -crop 3187x1992+0+0 +repage -resize 1280x800 \
      +profile exif +profile xmp out.png

Drop EXIF and XMP, but **not** with `-strip`: that also removes the ICC colour
profile, leaving one screenshot rendering differently from the others in the
same listing.

## Promo tile

`promo-tile-440x280.png` — 440×280, 24-bit, no alpha, `#2F2F2F` ground.
Chrome rejects a promo tile carrying an alpha channel even when it is fully
opaque, so flatten any replacement before uploading:

    magick in.png -background '#2F2F2F' -alpha remove -alpha off -strip \
      -define png:color-type=2 out.png

## Still needed

- **Marquee tile, 1400×560.** Genuinely optional — only for the homepage
  carousel, which an item cannot be chosen for without it.
