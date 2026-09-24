# Screen-reader walkthrough notes — M9 audit, 2026-09-22

07 §3.10 asks for committed VoiceOver and NVDA walkthrough notes. This file
is the honest record: **no native screen-reader walkthrough has been
performed** — the implementation loop has no macOS or Windows desktop host,
and Linux screen readers are excluded by the upstream caveat below. What
exists instead, and what remains for a human QA pass, is recorded here so
the gap is visible rather than implied.

## Verified by automation (Flutter `flutter_test` semantics tree)

The semantics tree is real and asserted — this is what a native reader
would consume where the platform bridge works:

- File rows: one merged semantics node announcing name–kind–size–date in
  spec order regardless of column layout; selection reflects actual
  selection; open and rename are semantic actions (rename only where
  valid; flagged U+FFFD names carry a warning reason).
  (`test/ui/panes/pane_view_test.dart`, `pane_selection_ui_test.dart`)
- Column headers: button semantics with sort state.
- Sidebar group headers: merged node with expanded state and spelled-out
  item counts. (`test/ui/sidebar/sidebar_view_test.dart`)
- Tab chips: selected state plus a labeled close control.
- Activity rows: `Semantics(liveRegion: true)` announces completion and
  failure once; continuous progress percentages are deliberately not
  announced. (`lib/ui/activity/activity_rows.dart`,
  `test/ui/activity/`)
- Focus-visible rings: 2 px on every surface M9 touched (sidebar rows,
  headers; the pane splitter was already compliant).
- Contrast: `test/ui/contrast_matrix_test.dart` pins every
  foreground×surface pair at WCAG AA; decorative hairlines and
  disabled-reason text are exempt with recorded rationale.

## Not verified — human passes still owed

- **macOS VoiceOver** and **Windows NVDA** traversals of the surfaces
  above, plus one keyboard-and-reader-only transfer. These are rows in
  `docs/qa/RELEASE-CHECKLIST.md`; they remain open until a release QA
  pass on real hardware fills them.
- **Linux (Orca)**: excluded — Flutter's Linux embedder exposes semantics
  through the legacy ATK layer, so the tree above is largely invisible to
  AT-SPI clients. Upstream: flutter/flutter#159460 (open, checked
  2026-09-22). The exclusion is re-checked per release per the checklist.
