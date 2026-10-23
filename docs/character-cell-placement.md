# Text-grid pane and character-cell refinement

The initial review pane has a bottom **Show text grid / Show photo** button. Both modes use the same occurrence identities, tap-to-row behavior, split popup, hold/drag merge handler and UIScrollView zoom/pan behavior. Each mode remembers its own zoom and offset while the screen remains open. Grid text retains OCR column/row membership and word spans across those breaks. Filtered terms remain interactive.

Grid grouping is conservative: overlapping reading-axis spans cannot join the same column/row merely because their bounding-box centers are close. This prevents skewed neighboring columns from being appended into one very long column. Disjoint fragments with closely matching cross-axis centers can still share a column. Existing incorrect/duplicate OCR is not silently deleted; missing breaks inside an OCR line remain a limitation.

## Photo refinement

`TermGeometry` preserves the full ML Kit element quadrilateral and its recognized character offsets as an anchor. Older captures without elements use their saved line geometry. Corrections still use the existing unique-text mapping rules; no invented location is assigned to unmappable edits.

`CharacterCellGeometry` samples a rectified grayscale strip along each anchor. It fits all character boundaries jointly with dynamic programming, using:

- the OCR box and character count as the initial spacing;
- a penalty for crossing dark pixels;
- a penalty for departures from regular cell spacing and the original positions;
- bounded adjustments (less than half a cell), with monotonic boundaries;
- one full cell for each grapheme, including Japanese punctuation.

Terms then take their edges from the shared fitted boundaries. Adjacent terms within an anchor cannot disagree about their common edge. Skewed quadrilaterals are retained; no full-page deskew or OCR rerun is needed. Sampling/fitting happens off the main thread. Fits are reused across terms within the pass, and the page raster is cached while viewing the photo.

The prior local whitespace refinement remains the fallback for unsupported or unreliable anchors. Predominantly Latin text, single-character anchors, low-contrast strips, and grids with insufficient whitespace agreement do not use the new fit. Uncertain transverse strokes remain suppressed. This is a rendering-only refinement; it does not modify saved recognition, decisions, examples or exports.

The projection-profile and character-spacing approach is informed by [Cherry Blossom: A System for Japanese Character Recognition](https://cedar.buffalo.edu/japanese/files/sdiut97.pdf); this implementation uses existing OCR anchors instead of recreating its OCR pipeline.

## Local validation, 2026-10-23

The text-grid-only iPhone build passed before work on photo refinement began. Subsequent builds include both changes.

An opt-in test exercises the refinement on the 30 existing saved ML Kit results and photographs. It respects JPEG EXIF orientation and downsamples to at most 2048 pixels, as the app does. It performs **no OCR**. These historical results contain line rectangles, not the element quadrilaterals now captured by the app. Element anchoring is separately covered by a skewed synthetic fixture.

Optimized Mac run: 17.6 ms median, 26.2 ms p95 for fitting the saved lines per photo, excluding decode/raster creation, OCR, and rendering. 315 of 601 saved lines admitted a fit. That acceptance count is not an accuracy score. No iPhone timing is claimed.

A locally rendered comparison on a saved novel column shows several proportional cuts moving off the glyphs and into gaps. It also exposes limitations when OCR omits characters or its box/count is wrong. This is visual evidence on an example, not a ground-truth evaluation of the whole corpus. Separate OCR elements are separate anchors; their edges are not globally constrained across element boundaries. Curved pages, incorrect character counts, missing breaks, and severe perspective remain unresolved cases.

Tests cover punctuation cell size, shared edges, both reading directions, ML Kit anchors overriding broad line boxes, unsupported/blank strips, multi-column word identity, manual-text insertion, and skewed overlapping column boxes. Simulator checks verified grid rendering, tapping 元旦 to focus its vocabulary row, and opening its split controls. Physical hold/drag/pinch feel and latency still need checking on the iPhone.

To repeat local saved-data fitting (optional):

```sh
PLACEMENT_CORPUS="$PWD/Benchmark/private" PLACEMENT_OUTPUT="$PWD/.build/cell-fits.json" swift test -c release --scratch-path .build/core --filter CharacterCellTests
```

`Scripts/placement/render_cells.py` renders a crop with proportional boundaries in red and fitted boundaries in blue, using the JSON output and the original photos. This comparison baseline is proportional geometry, not the previous independent whitespace snapper. Requires Pillow. Private photographs and generated crops stay local under `.build`.
