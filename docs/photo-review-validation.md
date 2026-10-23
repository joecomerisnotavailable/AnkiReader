# Photo-centered review validation

Implemented against saved recognition and synthetic fixtures. No benchmark or OCR
was rerun on existing captures.

## Automated checks

`swift test --scratch-path .build/core`: 36 tests pass. The new tests cover:

- Legacy session completion migration and completing one photo at a time.
- Known/Unknown overrides, current-photo exclusion, future proposals, and reselection.
- Vertical/horizontal/skewed geometry, SDK corner rotation/winding, repeated words,
  multi-column occurrences, estimated regions, and unavailable edited-text locations.
- Mapping the existing saved report without calling recognition engines.
- Adjacent merge rules, filtered 私 + 立 becoming 私立, grapheme-safe splits,
  and hold/drag cancellation decisions.
- Manual example expansion, page-text rebasing, source ranges, and frozen retained cards.
- Ink-gap boundary snapping in both text directions and suppressing hard cuts
  when there is no reliable gap. This is geometry refinement, not recognition.
- Persistent final-review marks, migration from legacy exclusions, editing marks
  after filtering, and retained removal preserving export history and Anki GUIDs.

The production iPhone target builds with its existing ML Kit/Rust dependencies.
`Scripts/verify_app_linkage.py` checks the built bundle for host-only libraries and
the dynamic Sudachi dependency that previously prevented launch.

## UI preview

`Tests/PhotoPreview/PreviewApp.swift` hosts the production views in an isolated
simulator bundle with a saved page. Recognition and morphology are intentionally
unavailable there; it never opens the real phone library. `Scripts/create_photo_preview.rb`
creates its disposable project under `.build/photo-preview`; local `fixture.json`
and `page.jpg` resources are required and are not distributed with source.

Inspected the two-pane layout at standard and Accessibility 2 text sizes. Verified
photo-to-row focus, Words-only-to-photo navigation, word-detail opening, saved-text
context expansion, the page-actions menu, and one/two-cut split controls. Filtered
tokens remain accessible on the photograph. The photo view hides the floating tab
bar so it does not cover the compact word pane.

The final-review fixture (`--final-review`) verifies Selected/Known/Unknown in the
upper pane and unmarked proposals below. Opening the source photo, marking another
word Known, and returning increases the marked count and decreases the unmarked
count. Finishing leaves the second fixture photo pending. Ink-gap rendering was
inspected on that same saved photograph; no new accuracy benchmark was performed.
The `--retained` fixture verifies that Remove removes the row and Undo restores
the retained word, reading, definition, example, and source. The production iPhone
build and linkage check pass after these changes.

## Physical iPhone checks still needed

Simulator visual checks and the gesture state tests do not establish the feel or
arbitration of physical multitouch. On the iPhone, use an existing photo and check:

1. Pinch, pan, double-tap, and row-to-photo reveal at several zoom levels.
2. Swipe rows in both list presentations; left swipe must require an explicit
   Known/Unknown choice. Confirm right swipe selects and deselects without reorder.
3. Hold/release for split, hold/drag onto either adjacent term (including gray
   filtered terms), invalid drop, pinch cancellation, and Undo parse edit.
4. Save an expanded/manual example, finish one photo, and reopen the remaining
   thumbnail backlog. Confirm exports and retained examples remain unchanged.

These are reading/review checks, not another recognition benchmark.
