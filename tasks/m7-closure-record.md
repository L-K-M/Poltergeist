# M7 CLOSURE RECORD — 2026-09-21

M7 (editor, managed checkouts, external editors, preview/Quick Look)
is CLOSED on evidence with one bounded residual recorded as open item
26. Audited against main head `31a15ab` (post-#172). One audit PR adds
the missing 06 §3.7 resume/review surface (the only real gap the audit
found), the store verb it needs, one coverage assertion, the STATUS
sweep, and this record; no pin bump, no M8 work, no Séance edits.

## What the audit PR changes

- `ui/local_edits_review.dart` (new): the §3.7 resume surface —
  `LocalEditsBanner` (the persistent per-pane banner while a bound
  server's checkouts hold dirty/missing edits) and
  `LocalEditsReviewDialog` (the server's dirty/missing records, its
  displaced records marked Recovered, and the preserved recordless
  payloads under "Recovered files" with the spec's pinned hint copy).
- `managed_remote_file_store.dart`: `deleteRecoveredFile` — §3.7's
  per-row Discard for recovered payloads (one file, never a
  record-owned dir, the dir goes when its last payload does).
- `checkout_manager.dart`: `forgetRecoveredFile` + `recoveredFile`
  passthroughs; `checkout_session.dart` mirrors both.
- `workspace_shell.dart`: the dialog's action lanes — record `Open`
  resolves through `effectiveDefaultFor` (built-in preflight with
  system-default re-resolution on over-cap/non-UTF-8, matching §3.7);
  `Upload` rides the same `_uploadCheckout` CAS escalation as the
  dirty toast and built-in editor; `Discard…` confirms then deletes.
- `pane_view.dart`/`pane_tabs_view.dart`: the banner mounts under the
  path bar for every remote-bound pane; the session joins the pane's
  rebuild listenable so a clean upload drops it on the spot.
- `sidebar_view.dart`: the remotePath favorite's `Local Edits…`
  context item — the server-scoped entry that also surfaces edits no
  pane currently touches.
- `external_editor_checkout_test.dart`: the activity-panel row
  assertion criterion 3 names (coverage gap — the plumbing existed).
- `built_in_editor_checkout_test.dart`: `EditorCheckoutHarness.open`
  accepts a preserved support dir (the relaunch seam).
- New `local_edits_review_test.dart`: six widget tests over a real
  process-death simulation (fresh store + session over the dead
  process's support dir).
- `app_en.arb` + regenerated localizations for the surface's copy.

## Exit criteria (07 §3.8)

1. **Edit round-trip conflict test: remote changes under an open
   checkout block the save with the conflict flow, never a silent
   overwrite — MET on HEAD.** Core:
   `checkout_manager_test.dart`'s remote-change/deletion/content-tamper
   cases block the upload and pin the CAS contract
   (`expectedTarget` + SHA-256 preflight, D7). App:
   `built_in_editor_checkout_test.dart`'s `a remote change under the
   open checkout blocks the upload at the conflict dialog — cancel
   writes nothing` reseeds the remote under a live checkout, attempts
   save, shows `Remote file changed`, and on Cancel asserts zero upload
   calls, unchanged remote bytes, no upload task, and the local edit
   preserved; the overwrite case retries with CAS waived. Verified
   green on the audit head.

2. **Kill the app with dirty checkouts; relaunch reconciles and offers
   resume per 06 — MET after this PR's gap fix.** The reconciliation
   half was already on HEAD: `CheckoutManager.start()` →
   `_restoreRecords()` → `reconcileAll()` rehashes every persisted
   checkout and re-arms watchers (proven by
   `checkout_manager_test.dart`'s `records survive a manager relaunch
   with reconciled state` and `a checkout file deleted while dead
   restores as missing`, and `checkout_session_test.dart`'s `a
   persisted record survives relaunch: exposed, watchable, reconciled
   dirty on edit`). The §3.7 *offer* was genuinely absent — HEAD had only the
   12 s dirty-prompt toast; no persistent banner, no review dialog, no
   sidebar entry, no per-row recovered-payload discard. This PR lands
   that surface: the banner counts `dirty || missing` copies for the
   pane's bound server; `Review…` opens the server-scoped dialog whose
   rows carry Open / Upload (disabled offline with the `Connect to
   upload` gate) / Discard…; displaced records list marked Recovered;
   preserved recordless payloads list per-file under "Recovered files"
   with Open / Discard… only (never uploadable — the record that would
   carry the CAS `expectedTarget` is gone) beside the pinned hint copy.
   `local_edits_review_test.dart` drives a real relaunch: checkout +
   dirty write, session shutdown (store lock released), a fresh store +
   session over the same support dir, then banner → dialog →
   upload-commits (remote bytes verified, banner clears, empty state),
   the offline gate (Upload disabled, Open/Discard live, zero upload
   tasks), discard-clears-record-and-file, per-row recovered-payload
   discard (sibling preserved; dir deleted at last file), the
   remotePath favorite's `Local Edits…` entry, and the clean-relaunch
   no-banner case.

3. **External editor save triggers upload with progress in the
   activity panel — MET.** `external_editor_checkout_test.dart`'s
   upload-on-save group drives the real watch → debounce → dirty →
   prompt → CAS upload loop (including the atomic-replace case below);
   the audit added the missing panel-side assertion: the completed
   managed-upload task lists as a row inside the activity panel (`task
   progress, bytes/rate/ETA` render through
   `activity_rows.dart`'s `_TaskProgress` — determinate when the spec
   carries a size, indeterminate otherwise).

4. **Spacebar previews local and remote files on macOS (via the
   preview cache + `TransferProducer`); the preview pane covers
   text/images/PDF elsewhere — MET with the native-runtime boundary
   recorded (open item 26).** CI-provable on HEAD: the 45 core preview
   tests (kinds, cache, byte gate, produce seam) and 28
   `preview_session_test.dart` cases pin the contract — local Space
   dispatches to the Quick Look channel on macOS, remote Space produces
   through the cache then `showPreview`/`updatePreview`, the mounted
   docked panel suppresses Quick Look, native close clears state, Esc
   cancels production inside the prepare window, over-threshold
   confirms and unknown-size gates park. The docked panel renders text
   (§2.1 document layer), images with dimension captions, and PDF via
   `pdfrx`; the panel/settings widget suites and the capture test
   (PNGs under `tasks/run3-task86/`) cover it. **Not CI-provable:** the
   native `QLPreviewPanel` runtime on macOS (the Linux/macOS matrix
   compiles the channel and runs the contract tests, but no runner
   opens the real panel) — recorded as manual QA in open item 26.

## M7 risk: atomic-replace saves

Confirmed with the design's own answer: the store watches the checkout
's parent directory, not the file, so a write-temp/rename-over (the
inode change that file-watching misses) still marks the record dirty
after the 600 ms debounce —
`external_editor_checkout_test.dart`'s `an atomic-replace save
(write-temp, rename-over) still marks the checkout dirty` proves it
against the real watcher, and the temp-shape filter keeps the writer's
scratch names from triggering it. Reconcile-on-resume remains the
fallback for a missed window.

## §3.12 close chores

- STATUS.md swept: header reads M3–M7 closed / M8 next; this dated
  section added; open item 26 added.
- PORTS.md re-diffed: the `managed_remote_file_store` and
  `checkout_manager` entries record the new per-row recovered-payload
  verbs as Poltergeist divergences (candidates for port-back); no
  upstream drift on ported files this audit.
- Pin unchanged: M7 added no pin-moving work; the `v0.9.1` re-pin
  stays in open item 25.
- No `TODO(pin)` markers in the tree.
- Mobile invariant (07 §5) re-verified: the checkout store, manager,
  and preview cache stay pure `poltergeist_core` Dart (file stores,
  no pane/window coupling); the Quick Look channel is an app-side
  platform seam by design, and the §3.7 surface reads only the
  session APIs.
- `v0.7.0`-style tag chore NOT run — matching M3–M6's untagged closes;
  a tag push publishes release assets, left to the supervisor/owner.

## Honest gaps carried forward

- **Open item 26 (new):** native macOS Quick Look runtime behavior is
  manual QA — the channel contract and dispatch decisions are
  CI-proven; the real `QLPreviewPanel` open/update/close path needs a
  macOS host. The same note covers the engine-driven remote checkout
  path end-to-end (all M7 checkout legs run against the scripted
  endpoint — the production engine's remote `checkout`/`upload` calls
  ride item 23's remaining half).
- Open item 25: Séance `v0.9.1` re-pin + "Your Séance servers" surface
  — unchanged by M7.
- Open item 24: AltGr chord family — unchanged.
- Open item 23: remote transfers still fail honestly until the engine
  protocol grows transfer verbs — unchanged.
- The `pdfrx` build hook downloads PDFium per worktree; this host hit
  an upstream HTTP 500 and reused a sibling worktree's cached artifact
  — environment, not a code issue; CI resolves it per-run (verify on
  this PR's run).

## Local verification (this audit host)

- `dart test packages/poltergeist_core` — **1440 passed, 15 skipped**
  (fixture-gated skips unchanged). One parallel-load flake pair in
  `linux_watch_backend_test.dart` passed on re-run and in isolation.
- `dart analyze packages/poltergeist_core` — clean.
- `flutter analyze` (app) — clean.
- `flutter test test/ui/workspace/` (all three M7 suites incl. the new
  `local_edits_review_test.dart`) + `test/workspace_shell_test.dart`
  — **all pass**; `test/ui/panes/` — **257 pass**;
  `test/ui/sidebar/sidebar_view_test.dart` +
  `test/services/preview_session_test.dart` + `checkout_session_test`
  — all pass.
- Exact-head CI run IDs and the review disposition are recorded in the
  audit PR body.
