# Reading Companion

Native, offline iPhone reading and vocabulary collection app. SwiftUI, AVFoundation,
ML Kit Japanese, Sudachi, indexed JMdict, and SQLite. Deployment target: iOS 18.
Development phone: iPhone 13 Pro / iOS 27.0.1.

## Run the reading app

Open **ReadingCompanion.xcworkspace**, select **ReadingCompanion** and your iPhone,
then Run. Keep the existing signing team. The app now opens to **Read**, not the
recognition benchmark. No benchmark runs automatically from the reading app.

- **Read:** point at a page. Automatic capture requires a detected page rectangle,
  steady motion, and settled focus/exposure. Use the shutter for curved pages or
  screens that do not trigger it. Capture saves first and opens the photo immediately;
  the top-left arrow returns to the camera. Choose vertical/horizontal text layout
  or import a photo. Source is optional.
- **Page:** pinch, pan, or double-tap the photo. Below it, a large, single-line
  context strip shows every parsed occurrence in page order, including filtered
  terms. The vocabulary list stays at the bottom. Tap any of the three panes to
  focus the same occurrence in the others. A focused filtered term temporarily
  appears in the vocabulary list without changing knowledge or filters.
  Dashed photo outlines indicate estimated geometry. Vertical text has horizontal
  separators; horizontal text has vertical separators. Local ink gaps refine the
  edges asynchronously; no OCR rerun is required for existing captures.
- **Words:** long-press a row for details. Swipe right to select/deselect; swipe left
  to reveal explicit **Known** and **Unknown** buttons. Known clears pending
  selections globally; Unknown excludes the word only from this photo's proposals.
  Show all words permits explicit reselection without changing knowledge. The
  top-right menu includes sorting, Words-only, zoom reset, page-text editing,
  previous/next pending photo, backlog, and Final review. Selection does not reorder rows.
- **Repair:** hold a context term and drag onto its adjacent neighbor to merge;
  hold and drag upward into the labeled Discard target to delete exactly that term.
  Hold and release for **Edit**, **Join**, or **Shatter**. Shatter separates visible
  characters. Join places two character-level handles; Confirm joins the selected
  range and preserves outside fragments. The page menu provides **Undo last edit**
  for up to 20 edits per photo during the app session. Undo refuses to overwrite
  subsequent review decisions.
- **Edit:** the compact bottom editor keeps the photo interactive. **Keep** saves
  one replacement term, preserving neighboring boundaries; an empty replacement
  deletes it. **Cancel**, outside tap, or downward dismissal discards the draft.
  The drawing icon replaces the keyboard with a handwriting pad; a chosen candidate
  inserts at the saved cursor or replaces the selected characters. Download the
  Japanese handwriting model once for offline recognition. Photo alternatives run
  only when requested and edit only the draft. Corrections retain their photo source
  mapping and orange before→after history. Existing retained cards stay unchanged.
  Word details retain reading/definition editing and example editing/expansion;
  **Edit on page** opens this same compact editor. Manual examples survive parse
  changes as saved alternatives; invalid selected examples must be repaired before
  final retention.
- **Review:** a thumbnail backlog grouped by session. Open a photo's **Final review**:
  Selected, Known, and Unknown marks are in the upper pane; eligible unmarked words
  are in the lower pane. Both panes scroll independently. Marks can be changed with
  row swipes or the row's status menu. Known/Unknown take effect immediately. The
  Page button opens the photo; its back arrow returns to final review with updated
  marks. **Keep selected & finish** completes only that photo; its session
  completes when all photos are done. Unchecked suggestions remain in history.
  Retained examples stay frozen, and export remains separate.
- **Library:** import Anki Notes in Plain Text using explicit word/reading mappings,
  inspect unresolved terms, edit knowledge overrides/basic filtering, and export
  retained vocabulary to `.apkg`. Share the generated package to Anki. Old package
  snapshots are available for retry. Sharing does not imply successful Anki import.
  In **Retained words**, swipe left and choose **Remove**, or use the row's context
  menu. Undo restores the last removed word. Removing a word clears its pending
  selections but does not change knowledge or modify packages already generated
  or imported into Anki. Recollection preserves its Anki note ID.
- **History:** inspect old captures, search their text/words, rename sessions, or
  merge pending sessions.
- **Data:** create/share a backup, restore it, explicitly remove photos, and install
  or roll back a prepared JMdict index. Restoration saves a pre-restore snapshot.
  Photos are never aged out automatically.

Existing recognition-lab cases and reports remain under Library → Recognition lab.
The user's completed benchmark report was copied read-only to
`Benchmark/private/iphone-benchmark-report.json`. It has not been regenerated.
See [recognition findings](docs/recognition-feasibility.md) for interpretation.

## Durability and identity

The reading library lives in `Documents/ReadingLibrary`. SQLite commits the library
state transactionally. Photos are written before queued jobs are committed; jobs
interrupted while processing resume on launch. OCR raw lines, layout output,
processing version, occurrence corrections, knowledge overrides, retained examples,
and export snapshots are separate records. The current SQLite implementation stores
these records in a versioned JSON payload; it is not yet a normalized relational
schema optimized for very large reading histories.

JMdict identities include entry and reading. Unknown expressions get local IDs.
Imported, explicitly known/not-known, selected, retained, and exported are separate
facts. A dictionary update does not regenerate retained cards or discard overrides.
Remembered dictionary choices are preferences gated by matching morphology readings,
not global character-sequence replacements. Repeated identical image bytes share a
fingerprint; longer near-identical OCR prose within a source is also coalesced for
recurrence. Short or substantially different OCR results are conservatively kept
separate.

Backups are versioned, uncompressed ZIP archives with per-file CRC checks. They
contain library records and referenced photos/exports, excluding replaceable
dictionaries. Restore validates paths and stages files under a fresh directory
before committing the replacement state. Old files are retained as recovery data.
Large backup creation currently constructs the archive in memory; streaming and
cleanup of old recovery archives remain hardening work.

## Dictionary updates

1. Obtain the current `JMdict_e.gz` from EDRDG under its published license; put it
   in `Resources/JMdict_e.gz`.
2. Run `python3 Scripts/build_dictionary.py`. It creates the indexed SQLite file
   with a source hash, source URL, and license metadata.
3. Transfer that SQLite file to iPhone Files; in the app, Library → Dictionary
   version → Install dictionary index. The app checks integrity/schema/metadata
   before atomically selecting the new version. Rollback selects the previous
   index, ultimately returning to the bundled index.

Sudachi engine 0.6.10 and core dictionary 20241021 are pinned together in this
checkout. Rebuild both together through `Scripts/build_native.sh` when changing
that pair. The Rust archive is linked explicitly by filename, preventing a Mac
absolute dylib path from leaking into the iPhone app.

## Validation

```sh
swift test --scratch-path .build/core
xcodebuild -workspace ReadingCompanion.xcworkspace -scheme ReadingCompanion \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData-device \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
python3 Scripts/verify_app_linkage.py DerivedData-device/Build/Products/Debug-iphoneos/ReadingCompanion.app
.tools/anki-validation/bin/python Scripts/validate_anki_export.py
```

The Anki check uses the official Anki 25.9 Python backend against a disposable
collection. It imports two separately generated packages and checks that only one
note/card exists, with the same GUID, fields, and rendered front/back. It never
opens or modifies the user's Anki collection. This does not replace a real
AnkiMobile import check.

`Scripts/sync_project_sources.rb` adds new Swift files without regenerating signing
or CocoaPods configuration. Avoid rerunning `generate_project.rb` on this configured
checkout; it creates a new project. Native dependencies, dictionaries, Pods, test
fixtures, and private page photos are ignored local build inputs. A fully automated
clean-machine bootstrap is still needed.

## Editing performance checks

Join/Shatter reuse character-cell fits for unchanged OCR anchors on the current
photo. The cache is discarded on image changes; changed anchors are refitted.
Context-strip glyph measurements are reused until text, offsets, font size, or
pane size changes. Recommendation scoring indexes recurrence and sentence
knowledge once per pass, preserving the original scores and example selection.
Transactional saving and edit/undo semantics are unchanged.

`RecommendationPerformanceTests` compares indexed scoring against the original
implementation. Optionally set `EDIT_PERFORMANCE_LIBRARY` to a saved LibraryState
JSON file when running `swift test` to compare and time both on that library.
This reads saved data only and performs no OCR. On the local 3,106-occurrence
fixture, Debug Mac scoring took approximately 804 → 9 ms (filtered) and
1,782 → 12 ms (Show all). These are scoring times, not end-to-end iPhone timings.

## Remaining acceptance and release work

The existing benchmark supports choosing ML Kit for implementation; it does not
establish a 95% recognition/lookup accuracy result. Per user instruction, no further
benchmark run is requested or performed. Layout fixes have deterministic fixture
tests, not new device OCR measurements.

The new camera/UI flow, interruption behavior under iOS suspension, long-session
performance, and large imports/backups need normal on-phone use checks. The app
currently delivers each page's vocabulary together after processing, rather than
streaming rows from partially recognized text. A steady rectangle plus settled
focus is a capture heuristic, not a quantified sharpness guarantee. Some furigana,
columns, ambiguous readings, and slang will still require repair.

AnkiMobile import, Release-device signing/launch, accessibility and visual QA,
App Store icons/privacy metadata, removal of development-only corpus/dependencies,
and distribution preparation remain before a sustained-use release. Public App
Store submission is a separate action. No study scheduler, live Anki sync, account,
server, translation, generated examples, manga support, or multi-device sync is
included.
