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

## Word grouping and optional parsing suggestions

The reader-facing parse combines verb/adjective stems with grammatical endings
(e.g. 食べて, 貼った, 食べていた). The tokenizer still supplies the underlying
morphological analysis. A bounded longest dictionary-match pass then combines
listed expressions across token boundaries (e.g. ひと + つ → ひとつ), before
looking up their components individually. Membership queries are batched and
never cross punctuation, whitespace, or missing text offsets. This grouping applies to new captures and local parsing
suggestions; existing saved pages are not automatically reprocessed.

The bundled JMdict index includes spelling-specific headwords and senses,
respecting reading/spelling restrictions and prioritizing explicit spelling usage
notes. Alternate spellings have separate lookup identities, while existing
primary entry identities remain valid. Legacy dictionary indexes remain readable.
Existing saved entries/retained cards are not bulk rewritten: Edit → Keep refreshes
a saved occurrence's lookup, including when its spelling has not changed.

After an edit, optional term-boundary suggestions float above the context strip.
Tap to apply one (with Undo); tapping elsewhere or scrolling hides suggestions,
and tapping the edited neighborhood restores them. Hold a suggestion and swipe
up to dismiss it. Dismissals are saved with the page and included in backups.
Suggestions use a bounded neighborhood of saved text, never another OCR pass.
Photo alternatives dismiss the keyboard, change only the draft, and require Keep;
tapping the text field brings the keyboard back. Cancel discards the draft.

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

## Column order, character alternatives, and pitch accent

New OCR results are ordered using oriented column centerlines, not the left edge
of axis-aligned boxes. For an existing page use Page actions → Repair column order.
This permutes mapped text cells and occurrence offsets without rerunning OCR or
rewriting frozen cards. Corrections and manual examples survive; Undo is available.
Repair refuses a case where source mapping is missing or an existing term would
be torn apart by moving its columns, rather than silently discarding the edit.

Character alternatives now recognize tight individual-character crops. Select a
character in the editor to target it; short terms may offer a one-character change
within the term. Unrelated sentence output is rejected. These are OCR candidates,
not an exhaustive visual-similarity dictionary or calibrated probabilities.

Pitch graphs show dictionary-form accents from Uros O.'s Kanjium (CC BY-SA 4.0),
matched by spelling and reading, with source usage labels and multiple variants.
The hollow final dot represents a following particle. Inflected surface accents
are not inferred from dictionary-form data. Missing matches are labeled unavailable.

To reproduce the pitch index, download
https://raw.githubusercontent.com/mifunetoshiro/kanjium/master/data/source_files/raw/accents.txt
to `Resources/kanjium-accents.tsv`, then run `python3 Scripts/build_dictionary.py`
(or `python3 Scripts/index_pitch.py` to add pitch data to an existing local index).
The index records the source SHA-256 and attribution; the raw file is a local build
input. `Resources/Attribution.txt` is displayed in Sources & licenses.

## Pixel-guided local recognition refinement

New captures reuse ML Kit's saved column quadrilaterals to measure ink spacing
independently of the OCR character count. Long, coarse OCR elements with a count
discrepancy or mixed Latin text receive short retries with the bundled Tesseract
Japanese model. Crops are rectified, cut at observed whitespace, and recognized
off the main thread. This avoids distributing an entire column's placement error
uniformly across its characters.

Reconciliation requires a unique source match, agreement with the measured cell
count, and reliable image boundaries. It accepts unchanged text with finer anchors
or up to two internal missing characters between matching anchors. Conflicting
substitutions, deletions, ambiguous repeated text, and mixed Latin candidates are
left unchanged. This is a conservative recovery stage, not a guarantee that every
missing or extra character will be resolved. Fine character anchors still draw as
continuous term highlights, including after Join and Shatter.

Existing pages are not automatically reprocessed. On an unedited page, focus the
word of interest and choose **Page actions → Refine printed text**. The focused
crop is tried first. The action preserves selections and knowledge, keeps original
OCR in `rawLines`, leaves retained cards/exports unchanged, and supports Undo.
Pages with manual text, boundary, or example edits are excluded to protect that
work. Saved-page refinement uses existing column locations, not a full-page OCR
rerun. A result is discarded if the page changes while it is being prepared.

Work is bounded to two suspect columns and twelve crops, with soft budgets of
0.4 seconds for planning and 1.5 seconds for retries. Image decoding and an
in-flight engine initialization/request may exceed those budgets; iPhone 13 Pro
latency remains to be measured. The saved Oct 26 2:43 PM column recovered
`注目を集めている` and corrected 注's location in a targeted local test. On this
Mac, its pixel profile took about 37 ms and the five crop retries/placement fits
took about 1.06 seconds in Debug. These are not end-to-end phone measurements or
an OCR-engine benchmark.

`RecognitionRefinementTests` covers geometry, conservative matching, and repeated
refinement. `RefinedCaptureTests` covers state preservation and archive roundtrips.
Set `REFINEMENT_CAPTURE` to the local diagnostic folder to include the saved pixel
profile; OCR only runs if `REFINEMENT_TESSERACT` is explicitly supplied too.
`Scripts/placement/column_profile.swift` independently plots the rectified ink
profile without invoking recognition.
