# Chrome Web Store assets

Screenshots for the store listing. Chrome requires each to be **exactly
1280×800** or 640×400 — anything else is rejected at upload.

| File | Shows |
|---|---|
| `01-select-and-edit.png` | An element selected, with the dimension overlay and the toolbar |
| `02-inline-text.png` | Inline text editing, with the formatting bar |
| `03-insert-elements.png` | The insert panel, choosing a layout to add |

Generated from 3456×1994 captures by cropping to a 1.6 ratio from the centre
(~7.7% of width) and scaling to 1280×800. The source captures are 1.733, so
they cannot be scaled to spec without a crop; a centre crop is safe because
the toolbar sits ~10% in from the left and the right side is open canvas.

To regenerate from a new capture:

    h=$(sips -g pixelHeight shot.png | awk '/pixelHeight/{print $2}')
    cw=$(python3 -c "print(round($h*1.6))")
    sips -c $h $cw shot.png && sips -z 800 1280 shot.png

Known issue in `03-insert-elements.png`: the insert panel's layout-preset grid
is clipped at the panel's own right edge ("50 / 50 (col", "2/3 + 1/3 (c").
That is in the source capture, not the crop — the panel's content is wider
than the panel. Worth fixing in the overlay and re-capturing before this
screenshot is relied on.

## Still needed

- **Promo tile, 440×280.** Not derivable from a screenshot; it is a designed
  marketing tile. Optional for submission, but required to be featured.
