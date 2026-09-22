# M8 CLOSURE RECORD — 2026-09-22

M8 (sync — 05 in full: scan/diff/plan/preview/execute, rsync exporter)
is CLOSED on evidence with bounded residuals recorded as open items
27–30 (DoD item 8 PARTIAL; D28 chown deferred to M9). Audited against
main head `187d5b7` (post-#177, the rsync
exporter merge). One audit PR adds the missing setstat-ignoring
integration leg and the sizeOnly-notice render proof (the only
testable gaps the audit found), the STATUS sweep, and this record; no
feature work, no pin bump, no Séance edits.

## What the audit PR changes

- `packages/poltergeist_sync/test/integration/sync_sshd_test.dart`
  (new): the Docker-matrix sync leg 05 §11/§8 and 07 §3.9 name. Two
  tests, both env-gated like every sibling integration test:
  - *restricted*: a real local→`sshd-restricted`
    (`sftp-server -P setstat,fsetstat`) pair run end to end — scan,
    diff, execute, journal — asserting the copy completes with
    `setstatIgnored` on the item line AND on the replayed journal,
    `mtimeUnreliableRight` set on the run, the destination mtime left
    at write-instant (the server really ignored the stamp), the naive
    re-diff still planning `updateLeftToRight`, and the flagged
    re-diff converging to `skip`/`equal` on size only.
  - *modern control*: the same pair against `sshd-modern` —
    `setstatIgnored` false, `mtimeUnreliableRight` false, the landed
    destination mtime equal to the pinned source stamp (whole-second),
    and the unflagged re-diff converging.
  - `test/integration/run.sh` already launches `sshd-restricted`,
    exports `POLTERGEIST_SSHD_RESTRICTED`, and loops
    `packages/*/test/integration` — no harness change was needed.
- `app/poltergeist_app/test/ui/sync/sync_plan_view_test.dart`: a new
  widget test drives a refused `setTimes` (a `LocalFileSystem`
  subclass standing in for the restricted server) through the real
  `SyncPlanController` and asserts the run completes, the
  `pairState.mtimeUnreliableRight` flag lands, and the header renders
  05 §4's size-only notice (`comparing by size only`) — absent before
  the run, present after.
- `docs/STATUS.md`: header sweep, the missing dated section for #177,
  this audit's close section, open items 27–30.
- `tasks/m8-closure-record.md`: this record.

## Exit criteria (07 §3.9)

05's Definition of done is the checklist (walked item by item below);
§3.9 adds three remote-gated criteria — the gate itself is satisfied
(PR-S3 merged upstream as Séance #62; the pin sits on tag `v0.9.1` /
`035b0d8`, which carries `setTimes`, `setOwner`, and opt-out
`computeHash`).

1. **Sync scan ≥ 1 000 remote entries/s on LAN (P7, D12) — MET,
   enforced.** P7 is tier-A and landed in
   `test/benchmarks/budgets.json` (`p7/v1`: root
   `/home/poltergeist/bench/fixtures`, 10 813 entries, 10 dirs,
   2 warmups, 5 reps, readdir depth 8, pipelined single channel).
   Latest main run
   [`35718273275`](https://github.com/L-K-M/Poltergeist/actions/runs/35718273275)
   at `187d5b7` measured samples 2332.277 / 2364.448 / 2336.627 /
   2343.975 / 2334.324 → **median 2 336.627 entries/s** under
   `BENCH_ENFORCE_A`; the evaluator line reads
   `P7 a 2336.627 entries/s (median of 5) >= 1000 entries/s pass` —
   an enforced pass against the Docker sshd fixture, not a drift
   skip. The 1 000 entries/s plan budget stands: the M3
   recalibration policy (pooled median × 1.2) was considered and is
   deliberately not applied — P7's number is a rate floor, and this
   run more than doubles it; recalibrating would only raise a bar
   the milestone already clears.
2. **Docker matrix includes the setstat-ignoring server; the
   `sizeOnly` fallback notice appears — MET after the audit's gap
   fix.** The matrix leg existed
   (`test/integration/docker-compose.yml` `sshd-restricted` on 2204,
   `sshd_config.restricted` denying `setstat,fsetstat`,
   `run.sh` exporting `POLTERGEIST_SSHD_RESTRICTED`), but no sync test
   exercised it and no widget test proved the notice. This PR lands
   both proofs (above). The fallback chain itself was already
   implemented: `SyncExecutor._stampAndVerify` journals
   `setstatIgnored` and raises the side's `mtimeUnreliable` flag on a
   refused `setTimes` or a divergent re-stat; `diffScans` honors the
   flags on the sizeOnly path; `sync_plan_view.dart` renders
   `syncHeaderSizeOnlyNotice` whenever `!preserveMtime` or either
   side is untrusted. One §8-matrix sub-case is **not** covered by
   the new leg: "a resume-after-interrupt run … asserting
   committed-but-unjournaled items are journaled done under rail 8's
   sizeOnly-path post-state rule" — that rule has no entry point on
   HEAD (no `resume(journal)` API; see open item 29), so the leg
   asserts the sizeOnly convergence itself and the gap is recorded,
   not faked.
3. **chown UI (D28) — DEFERRED to M9 (open item 30).** The merged pin
   carries `setOwner`, so the conditional arm is active; the audit
   task's close-scope rule prefers a dated deferral over new scope,
   and D28's own text allows M8/M9. Recorded dated with reason in
   STATUS.md.

## 05 Definition of done — item walk

| # | DoD item | Verdict | Satisfying evidence |
|---|----------|---------|---------------------|
| 1 | `poltergeist_sync` per §11; no Flutter/dartssh2/`Process` | MET | `invariants_test.dart` AST-walks the package: `Process` banned at symbol level (comments/strings excluded), Flutter/dartssh2 imports banned, `dart:io` allowlisted to `journal.dart` only. |
| 2 | Scanner: pipelined readdirs (8), progress, both-sides subtree exclusion, symlinks skipped+counted, gitignore + `.poltergeist*` defaults | MET | `scan.dart` (`defaultReaddirConcurrency = 8`, `onProgress`, `symlinksSkipped` warning with count), `ignore.dart` (gitignore matcher + compiled defaults incl. `.poltergeist*` and the trash-root prefix exclusion), `diff.dart` rule-8 subtree mirroring; `scan_test.dart`, `ignore_test.dart`, `diff_test.dart` (`a hazard counterpart never plans as an orphan delete`, scan-error exclusion cases). |
| 3 | Name hazards → conflict-class items with §7 reasons, never silently fixed | MET | `compare.dart` hazard detection + `diff.dart` classification; `compare_test.dart`/`diff_test.dart` hazard groups (NFC/NFD pairing keeps the destination byte form, case collisions, Windows-invalid names → `conflict`). |
| 4 | Comparison: size+mtime 2 s + whole-second truncation; sizeOnly; contentHash size-gated; setTimes+mode preservation + re-stat; auto sizeOnly fallback + notice | MET | `compare_test.dart` boundary fixtures (exact-2 s equal, 3 s different, sub-second dropped); executor uploads carry `preserveMode` and `_stampAndVerify` re-stats; fallback chain proven by `executor_test.dart` (`a setstat-ignoring destination flags the side unreliable`), the new Docker leg, and the new widget test. |
| 5 | Exactly three modes = direction × deletion policy; unresolved conflicts skip | MET | `SyncRuleSet` (Update default, Mirror, Additive = bidirectional + no deletes, `validateDirectionDeletions`); `diff_test.dart` (`a no-delete mode auto-resolves to skip, suggested conflict`). |
| 6 | `SyncPlan` per §6 incl. ordering (mkdirs first, deletes last deepest-first, delete phase behind a clean copy phase, rule-4 pre-delete) | MET | `executor.dart` three phases + rule-4 barrier items; `executor_test.dart` ordering/pre-delete/delete-gate cases. |
| 7 | Plan view per §7: exact header copy, glyph+color+reason table, filter chips with counts, override cycling + context menu, bulk conflict resolve, consequence-stating Run | MET | `sync_plan_view.dart` + `sync_plan_format.dart`; `sync_plan_view_test.dart` (header clauses, chips, override menu, conflict bar, typed-DELETE, refusal banner, consequence labels); header goldens via format tests; captures under `tasks/run3-task90/captures/`. |
| 8 | Safety rails: mandatory preview, >50 % typed confirm under `maxDelete`, `maxDelete` refusal, `.poltergeist-trash/<runId>/` rename trash **+ age-notice chip + `sync.purgeTrash`**, out-of-root `trashPath*` **+ docroot warning**, tmp+rename writes **+ startup sweep**, per-item re-stat, JSONL journal (live-trash retention) + Retry Failed + Restore | **PARTIAL** | MET: rails 1–4, trash rename/flat-seq naming/out-of-root paths/EXDEV-fallback, VFS sibling-temp writes, rail 7 preconditions, rail 9 journal+retry+restore+retention — all test-pinned (`executor_test.dart`, `journal_test.dart`, widget DELETE/refusal/restore tests). **NOT MET:** the purge chip + `sync.purgeTrash` + cross-pair/cross-machine rules (item 27); the docroot warning chip in editor + plan view (item 28); the run-startup `.poltergeist-*.tmp` orphan sweep and rail 8's committed-but-unjournaled resume post-state rule — no resume entry point exists (item 29). |
| 9 | "Copy as rsync command": golden-tested §2.1 exporter, clipboard-only, dry-run line, caveat/override comments | MET | `rsync_export.dart` + `rsync_export_test.dart` goldens (every flag-table row, quoting, negation order, Windows pair); `sync.copyRsyncCommand` verb + widget tests; `Process` ban machine-checked. |
| 10 | savedSync bookmarks persist, open from sidebar, sync via Séance server, `sync_state/` | MET | `saved_sync_codec.dart` (⇄ `BookmarkKind.savedSync` → `Bookmark.sync` in seance_protocol — rides M6's Design A record sync), `bookmarkFromSyncPair`/`syncPairFromBookmark`, sidebar open + malformed-payload reporting (`workspace_shell.dart` §2490+), `FileSyncStateStore` under `sync_state/`; codec/state-store/widget tests. |
| 11 | One activity-panel task with per-item rows, shared throttling/limits, live row updates | MET | `SyncQueueTasks` + `CompositeAppTransferQueue` (pause/cancel route to the run, retry → `retryFailed`, per-item rows); facade/widget tests; `transferConcurrency` honored under the global limits. |
| 12 | Test hooks per §11: in-memory VFS + fault injection, property tests, exporter goldens, Docker matrix incl. setstat-ignoring, P7 | **MET with two recorded deviations** | Fault injection exists via `LocalFileSystem` subclasses over real temp dirs (`_SetTimesIgnoringFs`, `_ExdevTrashFs`, `_FakeClockFs`); goldens exist; the setstat leg landed in this PR; P7 above. **Deviations:** the shared `poltergeist_core/lib/testing.dart` `InMemoryFileSystem` never landed (per-package fakes carry the matrix instead — the §11 drift-avoidance motivation is noted; the invariants test still bans any sync-private VFS in `lib/`), and the §3.3 invariants are pinned by deterministic tests rather than seeded generators. Both are coverage-equivalent today; recorded here rather than rewritten at audit time. |

## Honest residuals carried forward (open items 27–30)

- **27 — purge surface (rail 5's notice/command half):** no age-notice
  chip, no `sync.purgeTrash`, no scope/forfeit confirm dialog, no
  device-prefix classification, no absent-directory `purged` marking.
  Journal substrate (`markPurged`, `hasUnpurgedTrash`, live-trash
  retention, `trashCache` model) is in place; until the surface lands,
  trash directories and their guarding journals accumulate forever.
- **28 — docroot warning chip (rail 5):** no `public_html`/`www`/
  `htdocs`/`/var/www` detection, editor field warning, or plan-view
  chip. In-root trash under a published docroot stays silent.
- **29 — temp sweep + resume post-state rule (rails 6/8):** no
  sync-side startup sweep of orphaned `.poltergeist-*.tmp`/
  `.seance-upload-*.tmp` siblings (the transfer queue sweeps only its
  own destinations), and no resume-from-journal entry point —
  connection loss fails the item and `Retry Failed` is the shipped
  recovery. The §11 Docker-matrix "resume-after-interrupt" case is
  parked here.
- **30 — D28 chown UI:** deferred to M9 (see criterion 3).
- **Remote sync endpoints** remain honestly unsupported —
  `SyncEnvironment` throws `unsupported` for `RemoteEndpoint`s; the
  whole remote-pair surface rides open item 23's engine-protocol gap.
  The new integration leg therefore drives the *executor* over a real
  remote `RemoteFileSystem`, which is the honest ceiling today.
- Items 23–26 unchanged; item 25's "Your Séance servers" surface still
  open.

## §3.12 close chores

- STATUS.md: header, the #177 dated section, this close section, open
  items 27–30.
- PORTS.md: untouched — no ported file changed this audit.
- Pin: unchanged (`v0.9.1`); no `TODO(pin)` markers in the tree.
- Mobile invariant (07 §5): re-verified — the audit's additions are
  tests only; `poltergeist_sync` stays pure Dart (analyzer guard
  green), no engine-protocol change.
- Tag chore not run — matching every prior untagged close.
- Docker is unavailable on this host: the new integration leg is
  CI-verified (it self-skips cleanly without
  `POLTERGEIST_SSHD`/`POLTERGEIST_SSHD_RESTRICTED`,
  which keeps local `dart test packages/poltergeist_sync` honest).

## Local verification (this audit host)

- `dart analyze packages/poltergeist_sync` — clean.
- `dart test packages/poltergeist_sync` — **223 passed, 2 skipped**
  (the two new env-gated integration legs; no Docker locally).
- `flutter analyze` (app) — clean.
- `flutter test test/ui/sync/sync_plan_view_test.dart` — **13 pass**
  (incl. the new size-only-notice case);
  `test/ui/sync/` + `sync_plan_controller_test.dart` +
  `sync_queue_facade_test.dart` — **68 pass**.
- Exact-head CI run IDs and review dispositions are recorded in the
  audit PR body.
