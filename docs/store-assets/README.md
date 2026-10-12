# Chrome Web Store assets

Screenshots for the store listing. Chrome requires each to be **exactly
1280×800** or 640×400 — anything else is rejected at upload.

| File | Shows |
|---|---|
| `01-select-and-edit.png` | An element selected, with the dimension overlay and the toolbar |
| `02-inline-text.png` | Inline text editing, with the formatting bar |
| `03-insert-elements.png` | The insert panel, choosing a layout to add |

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

- **Promo tile, 440×280.** Not derivable from a screenshot; it is a designed
  marketing tile. Optional for submission, but required to be featured.
