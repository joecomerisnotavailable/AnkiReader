# Recognition feasibility — first iPhone run

Measured on the user's iPhone 13 Pro (hardware identifier iPhone14,2), iOS
27.0.1. Report retrieved 2026-10-21. All 30 captures ran through all three
engines: 90 saved runs, with no reported pipeline errors. Private report:
`Benchmark/private/iphone-benchmark-report.json`.

## What the labels mean

The user has edited some Anki vocabulary independently of the photographed
page. Anki labels are retrieval hints, not transcriptions or ground truth.
An unmatched hint cannot be counted as a recognition failure; even a match
does not establish correct reading order, dictionary sense, or source location.
For example, photo `06f2261de4b117f1.jpg` prints **やせぎす**, whereas its
Anki label is **痩せぎす**. This spelling difference is visible in the photo.

The existing JSON keys `expected` and `recovered` are legacy names for reference
hints and automatic hint matches. The matcher checks whether a hint occurs in
recognized body text or equals a resolved dictionary expression. It is neither
a pure literal OCR comparison nor a validated vocabulary-accuracy metric.
All 30 cases in this run have `verified: false`.

## Latency

Seconds measured by the app around image loading, decoding, OCR, tokenization,
and dictionary resolution. UI rendering is not included. This is one sequential
run, with engine initialization included when it occurred; it is not a repeated
cold-start study. P95 uses the nearest-rank method. With eight horizontal samples,
P95 is the slowest sample.

| Engine | Layout | Pages | Median | P95 |
| --- | --- | ---: | ---: | ---: |
| Apple Vision | Vertical | 22 | 0.34 | 0.54 |
| ML Kit Japanese | Vertical | 22 | 0.40 | 0.46 |
| Tesseract | Vertical | 22 | 23.10 | 40.25 |
| Apple Vision | Horizontal | 8 | 0.41 | 0.65 |
| ML Kit Japanese | Horizontal | 8 | 0.33 | 0.40 |
| Tesseract | Horizontal | 8 | 1.83 | 18.51 |

## Interpretation and remaining gate

ML Kit is the leading candidate for further validation. Its latency is comfortably
within the target on this sample, and it returns substantial vertical body text.
Vision returns a median of only two body-text characters per vertical page in
this integration; its low latency does not represent useful vertical lookup.
Tesseract's current vertical configuration exceeds the latency target.

Text volume and dictionary-match counts are diagnostic, not accuracy measures.
Inspection of ML Kit output shows overlapping/duplicated text on some pages.
The shared furigana heuristic also incorrectly flags body text as ruby: in
`06f2261de4b117f1.jpg`, the printed body sentence beginning `になった。休日がなくなった。`
appears in the report with `isRuby: true`. These problems affect downstream
context and vocabulary, regardless of whether an Anki hint matches.

Before selecting the production engine:

1. Annotate actual target spans and their locations directly from the photos,
   retaining original Anki hints separately. Allow valid dictionary normalization
   while verifying that recognition preserved the photographed surface form.
2. Inspect and repair overlap handling, column order, and furigana classification.
   Preserve raw OCR output separately from layout-derived decisions for diagnosis.
3. Measure target lookup and source association against those annotations, then
   rerun latency with the corrected layout pipeline. Include fresh camera captures
   under ordinary lighting; imported Anki images alone do not cover the full goal.

The 95% lookup/source-association acceptance target remains unmeasured. These
results support continuing with ML Kit feasibility work, not declaring the
recognition milestone complete.
