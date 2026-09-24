# M9 CLOSURE RECORD — 2026-09-22

M9 (polish pass — 07 §3.10) is CLOSED on evidence with bounded residuals
recorded as open items 30–32: the tier-B arming tail stays
supervisor-owned (the repo variable is deliberately unset pending a clean
seeding run — details below), the D28 chown UI is unscheduled rather than
dropped, and native screen-reader walkthroughs remain a human QA pass.
Audited against main head `495dd9e` (post-#185, the polish-2 merge). The
audit PR is documentation-only: no code changes were needed — every gap
found was a missing committed artifact, not a behavior defect.

## What the audit PR changes

- `README.md`: the §3.10-required known-issues section — the Linux
  screen-reader caveat (upstream flutter/flutter#159460, ATK→AT-SPI, open
  and checked 2026-09-22) and the Windows IMM32 IME caveats
  (flutter/flutter#128323, open and checked 2026-09-22). Missing on HEAD;
  §3.10's exit criteria name it and 08 §9 requires the note to link and
  date the upstream issue.
- `docs/qa/RELEASE-CHECKLIST.md` (new): 08 §9's per-release manual-QA
  checklist — chrome, IME smoke, screen-reader smoke, trust/platform
  behaviors, reference-hardware tier-B run — verbatim in structure from
  §9. 08's definition of done requires it to exist at M9 ("created with
  the M9 PR"); neither polish PR created it.
- `docs/qa/screen-reader-notes.md` (new): the §3.10 walkthrough-notes
  criterion answered honestly — a dated record of what the automated
  semantics suites prove and what a native-reader pass still owes. No
  walkthrough is claimed that did not happen.
- `docs/PORTS.md`: the missing entry for
  `app/poltergeist_app/lib/ui/update_banner.dart` (ported from Séance's
  `_UpdateBanner` in `server_list_pane.dart`, verified present at pin
  `v0.9.1`/`035b0d8`). 09 §4 requires the entry in the same PR as the
  port; #185 missed it — recorded as landed-late here.
- `docs/STATUS.md`: header sweep, this close section, open items 30–32.
- `tasks/m9-closure-record.md`: this record.

## The task's eight audit items

1. **Quick Open palette (02 §8.4, D21) — MET.** `app.quickOpen` is a
   registered command (⇧⌘P / Ctrl+Shift+P, File-menu placement) opening
   the palette over the live command registry — commands, favorites,
   recents, fuzzy-ranked, disabled rows greyed with localized reasons,
   right-aligned shortcuts on rows that carry them, modifier-Enter
   variants (other pane / new tab), chord-scope suspension while open,
   re-entrancy guard. Evidence: `lib/ui/quick_open/quick_open_palette.dart`,
   `lib/services/quick_open_match.dart`, `lib/services/recent_locations.dart`;
   tests `quick_open_palette_test.dart`, `quick_open_match_test.dart`,
   `recent_locations_test.dart`; inspected captures
   `tasks/run3-task93/quick-open.png` (palette with shortcut column and
   footer), `quick-open-filtered.png` (filtered "web": commands +
   favorite row + disabled-reason rows). All landed in #184.
2. **Import experience finished (D22) — MET.** `favorite.importSshConfig`
   is the single entry point routed through `_runCommand` from the File
   menu, the Quick Connect adoption offer, and the empty-favorites
   sidebar offer (hidden once favorites exist); preview keeps
   selection/duplicate/limitation surfaces with merged row semantics.
   Verified no FileZilla/WinSCP/Cyberduck strings or UI in `lib/` —
   ssh_config-only confirmed by grep. Tests:
   `test/ui/import/ssh_config_import_command_test.dart`,
   `ssh_config_import_dialog_test.dart`,
   `test/services/ssh_config_import_setup_test.dart`; capture
   `tasks/run3-task93/ssh-import-preview.png` inspected (preview dialog
   with per-row checkboxes, endpoint/user/auth/notes columns). #184.
3. **Tier-B enforcement flip + full-D12 audit — CODE LANDED; RUNTIME
   ARMING IS THE RECORDED SUPERVISOR TAIL.** #185 landed the flip:
   `budgets.json` `landed: true` on P1/P2/P4, `ci.yml` forwards
   `vars.BENCH_ENFORCE_B`, the §6 drift-state store is wired
   (cache restore before grading, save on `refs/heads/main` only), the
   one automatic tier-B rerun before red, contract tests re-pinned. The
   full-D12 audit table lives in `tasks/run3-task94/audit.md` — P6 stays
   `landed: false` (structural: ~830 frames vs the ≥1800 floor under
   llvmpipe; no honest median, none fabricated).
   **Verified state at audit time (2026-09-22):**
   - `gh variable list`: `BENCH_ENFORCE_A=true` (set 2026-09-17);
     **`BENCH_ENFORCE_B` is unset** — per the brief this is the
     supervisor's open tail; not duplicated here.
   - Merge run
     [35780236673](https://github.com/L-K-M/Poltergeist/actions/runs/35780236673)
     (`495dd9e`, success): bench job ran `enforce A: true, enforce B:
     false`; seeded the drift store (`Cache saved:
     d12-drift-state-35780236673`). Measured on the **pre-rotation** image
     `ubuntu-latest@20260907.300.1` while committed fingerprints sit on
     `20260920.314.1` — every row verdict `skipped: hardware drift`.
   - Dispatch run
     [35781589991](https://github.com/L-K-M/Poltergeist/actions/runs/35781589991)
     (same head; artifact inspected): measured on `300.1` again (CPU
     `AMD EPYC 9V74`); saved drift state now records
     `tier-b/controlled/runnerImage` at **8 consecutive main runs** —
     at/above the 7-run staleness threshold. A second dispatch
     (35782936812) was pending at audit time.
   - **Consequence for the tail:** arming `BENCH_ENFORCE_B` before a
     fully clean main run lands will redden main — the persisted streak
     clears only on a run with no failures, no fired drift keys, and all
     landed tier-B comparisons, which requires the rotated image *and*
     the baseline CPU model (`AMD EPYC 7763`; a CPU mismatch alone fires
     `tier-b/cpu` and preserves the streak). Tier-A enforcement is
     likewise armed-but-inert on the same drift (the job annotates this
     loudly). The mechanism is working exactly as designed; the gate is
     the runner pool's mixed rotation state, not a code defect.
4. **a11y audit (02 §13, D20) — MET with one honest boundary.** File rows
   announce merged name–kind–size–date; selection follows actual
   selection; rename is a `CustomSemanticsAction` only where valid;
   flagged names carry warning badge + semantics reason and
   `startRename` refuses them; path-bar segments are labeled buttons;
   sidebar headers merge title + count + expanded state; tab chips carry
   selected state + labeled close; 2 px focus-visible rings;
   `contrast_matrix_test.dart` pins every foreground×surface pair at
   WCAG AA with recorded exemptions; activity rows keep
   `liveRegion: true` completion/failure announcements.
   **Linux boundary (honest, per D20/§6-risk-6):** no AT-SPI bridge for
   custom widgets upstream — semantics verified via `flutter_test`'s
   tree, not a native reader; now in README known-issues.
   **Native-reader walks:** `docs/qa/screen-reader-notes.md` records that
   VoiceOver/NVDA walkthroughs were not performed (no macOS/Windows host
   in the loop) — the §3.10 "notes committed" box is ticked by that
   honest record; the walks themselves remain open item 32's
   release-QA rows.
5. **i18n sweep zero hard-coded (D20) — MET.**
   `test/localization_contract_test.dart` walks `lib/**` and fails on
   user-facing literals outside ARB (allowlist entries are technical
   literals with per-entry comments; generated-code exclusions are
   guarded against vanishing). M9 strings (Quick Open, import offer,
   sidebar counts, flagged names, update banner, settings toggle) are in
   `app_en.arb`. The contract test is the CI-enforced grep — it runs in
   the `flutter test` job. 190-test focused battery green locally.
6. **Chrome QA (02 §9–11) + IME notes — MET for the automatable
   surface.** The registry-invariant test (`app_menus_test.dart`)
   re-verifies every command — Quick Open included — is menu- or
   chord-reachable on macOS/Linux/Windows maps, Meta on macOS vs Ctrl
   elsewhere; per-command §8.3 chord assertions dispatch real key events
   (`pane_commands_test.dart`, `sync_commands_test.dart`, et al.).
   Titlebar posture unchanged (`TitlebarSafeArea` on macOS). The Windows
   IMM32 caveats are now written into README known-issues. Human-only
   residual (native frames, scroll feel, native dialogs, Quick Look,
   readers) stays on the release checklist — open item 32 covers the
   standing manual-QA tail. #184's dated manual-QA note in STATUS is the
   record of what was and wasn't automatable.
7. **Fast-path spike (D26) — MET: adopted `copy_file_range(2)` on
   Linux.** #185's measurement table (`tasks/run3-task94/audit.md` §3):
   ~6–15× the streamed path (3.2–3.3 GB/s vs ~0.3 GB/s at 64–256 MiB),
   16 MiB chunks preserving progress/cancel, decline conditions falling
   back to streamed. `lib/src/fs/local_copy_pump.dart` +
   `local_file_system.dart` + `transfer_queue.dart` short-circuit; 20
   local-ops tests cover the seam. FICLONE: EOPNOTSUPP on every
   filesystem here — deferred with numbers. Windows CopyFileEx and APFS
   clonefile: source-research notes pending their hosts (v1.x).
8. **Update check (D19) — MET: link-only.** `UpdateCheckController`
   wraps the pinned `seance_core` `UpdateChecker` against
   `L-K-M/Poltergeist`'s latest-release endpoint — a plain GET compared
   locally; the banner's only action opens the releases page externally;
   `updates.checkEnabled` opt-out in General settings reverts on persist
   failure and disables all network access when off. 17 targeted tests
   (`update_check_controller_test.dart`, `update_banner_test.dart`,
   `general_settings_test.dart`, shell mount). #185.

## 07 §3.10 exit criteria

| # | Criterion | Verdict |
|---|-----------|---------|
| 1 | Command-completeness invariant test green over the full registry | MET — `app_menus_test.dart` "every registered command is menu- or shortcut-reachable on every platform" green locally and in CI; exception list hygienic. |
| 2 | Palette opens, filters, executes, teaches shortcuts | MET — tests + inspected captures (item 1 above). |
| 3 | a11y checklist in 08 fully ticked; VoiceOver and NVDA walkthrough notes committed | MET-with-recorded-boundary — every 08 §7 automated suite exists and passes (semantics, keyboard-completeness, contrast, hardcoded-string); walkthrough notes are committed at `docs/qa/screen-reader-notes.md` as an honest record that native-reader walks have not run (no hosts) — the walks stay on the release checklist (open item 32). |
| 4 | Every D12 benchmark green and enforced (both tier flags on) | **PARTIAL — supervisor tail (open item 31) plus a P6 structural gap.** P6 stays `landed: false` (~830 frames vs the ≥1800 floor), so it is neither green nor enforced even once both flags arm; `BENCH_ENFORCE_A` set (currently inert on runner-image drift); `BENCH_ENFORCE_B` deliberately unset pending a clean-fingerprint seeding run — drift streak at 8 consecutive main runs makes early arming red; precise state in item 3 above. |
| 5 | Known-issues section (Linux a11y, Windows IME) in README | MET by this PR — the section was missing on HEAD; added with linked+dated upstream issues. |

## §3.12 close chores

- STATUS.md: header, this audit's close section, open items 30–32.
- PORTS.md: swept — added the `update_banner.dart` entry #185 owed
  (verified against the pin: `_UpdateBanner` exists in
  `server_list_pane.dart` at `035b0d8`). No other ported file changed in
  M9 (`localization_contract_test.dart` touched only allowlist comments
  about ported text).
- Pin: unchanged at `v0.9.1` (`035b0d8`) — still the latest Séance tag
  (checked 2026-09-22); nothing newer to bump to. No `TODO(pin)`
  markers in the tree.
- Tag chore not run — matching every prior untagged close since v0.2.0.
- Mobile invariant (07 §5 M9 row): re-verified — the palette, import,
  chrome, a11y, i18n, and update-check surfaces add no pane, watcher, or
  window coupling (app-layer UI + an injectable launch seam);
  `local_copy_pump.dart` is pure Dart in `poltergeist_core` with no
  Flutter/window dependency; earlier rows unaffected.
- Docker unavailable on this host — the env-gated integration legs were
  not re-run locally; their last CI evidence stands per the M8 record
  and run 35780236673's green integration jobs.

## Honest residuals carried forward

- **30 — D28 chown UI: still unlanded, now unscheduled.** M8 deferred it
  to M9; §3.10's scope never contained it, so the deferral target passed
  without the work. The pin capability (`setOwner`) is proven; what is
  owed is UI + wiring. Closing M9 without it does not resolve D28 —
  flagged for an owner/plan decision (v1.x or a scoped slice), not
  quietly dropped.
- **31 — `BENCH_ENFORCE_B` arming (supervisor-owned tail).** Variable
  unset at audit time; drift streak `tier-b/controlled/runnerImage` at 8
  consecutive main runs; safe arming requires a clean main run on the
  committed fingerprint (`20260920.314.1` + `AMD EPYC 7763`) first —
  otherwise the next enforced run reds on the stale streak and the
  controlled-axis mismatch. Two supervisor dispatches at `495dd9e`
  (35781589991 completed soft, 35782936812 pending) appear to be the
  seeding attempts; the merge run and the completed dispatch drew the
  pre-rotation image, while the pending run's image was unknown at
  audit time.
- **32 — Human-only QA residual.** Native-reader walkthroughs
  (VoiceOver/NVDA), native chrome/dialogs, scroll feel, Quick Look on a
  real macOS host, and real-IME entry — all rows of
  `docs/qa/RELEASE-CHECKLIST.md`, first fill due at v1.0.
- Items 23–29 unchanged (remote transfers/sync endpoints, purge surface,
  docroot chip, temp sweep/resume post-state — all previously recorded).

## Local verification (this audit host)

- `dart analyze packages/poltergeist_core packages/poltergeist_sync
  test/benchmarks` — clean.
- `flutter analyze` (app) — clean.
- Focused battery, 190 tests pass: `app_menus_test.dart` (registry
  invariant incl. Quick Open), `quick_open_palette_test.dart`,
  `quick_open_capture_test.dart`, `contrast_matrix_test.dart`,
  `localization_contract_test.dart`, `update_banner_test.dart`,
  `update_check_controller_test.dart`, `test/ui/import/`,
  `sidebar_view_test.dart`, `test/ui/activity/`, `pane_view_test.dart`,
  `quick_open_match_test.dart`, `recent_locations_test.dart`.
- Repo state checks: `gh variable list`, run/job logs for 35780236673,
  bench-results artifact + `bench-drift-state.json` for 35781589991,
  upstream issue states, Séance `server_list_pane.dart` at `v0.9.1`.
- Exact-head CI run IDs and review dispositions are recorded in the
  audit PR body.
