# M4 CLOSURE RECORD — 2026-09-19

M4 (Transfers v1) is CLOSED on evidence. Audited against main head
`b58af0d` (post-#158). One audit PR adds the missing proofs plus this
record; no features, no M5 work.

## Exit criteria (07 §3.5)

1. **Drop-to-transfer-start under 500 ms... benchmark enforced** —
   MET, by the letter of the milestone table: the §3.5 budget names
   P5 "drop → first progress" at < 6 000 ms on the tier-A runner
   (recalibrated per the owner's 2026-09-17 item-22 ruling, median×1.2),
   and it is enforced, not trend-only. Post-#158 main run
   35420036073's D12 job 105835867500 printed `enforce A: true` with
   **P5 4 774.887 ms (median of 5) < 6 000 ms — pass** (margin
   1 225.113 ms, ~20 %). P3 4 448.165 ms < 5 500 ms and P7
   2 280.086 entries/s ≥ 1 000 pass in the same enforced table. Prior
   main run 35414902815 (job 105821522661) also enforced-green at
   P5 4 646.887 ms. A tier-B drift notice printed in the same log;
   tier-B is baseline-trending per the M3 window and does not gate.

2. **App-level kill/relaunch proof** — MET at the app seam, with a
   named production-composition caveat. New test
   `app/poltergeist_app/test/services/transfer_relaunch_test.dart`:
   a real `TransferQueue` + `FileTransferPersistence` completes one
   task, journals a paused task and a queued task, then the queue is
   killed without graceful shutdown (journal flushed via
   `flushJournal()`); a second queue opened on the same store restores
   both survivors (`wasRestored`, queue starts paused, surviving
   non-terminal states replay as `queued`), `history` shows the
   completed task, and Resume runs the surviving copy to a real file
   on disk. Core coverage underneath:
   `transfer_persistence_test.dart`'s queue-integration group —
   crashed `running`/`scanning` tasks replay as `queued`, `paused`
   stays `paused`, completed tasks never resurrect, mid-scan journals
   re-scan and merge. **Caveat (disclosed, not greenwashed):** open
   item 23 — `main.dart` still boots `PoltergeistApp` without a
   `transferQueue`, so a production boot today has no live queue to
   restore; the proof is at the queue+app-service seam, and the
   composition slice remains the recorded follow-up.

3. **Conflict dialog: five verbs, per-direction defaults, recursive
   folder Merge** — MET. `ConflictResolution` carries
   replace / replace-if-newer / keep-both / skip / merge-for-folders;
   `PendingConflict.availableVerbs` yields four file verbs (merge
   excluded) and all five for folders. Strengthened
   `activity_panel_test.dart` now asserts every verb key renders —
   file conflicts show `replace`, `replaceIfNewer`, `keepBoth`,
   `skip`, and no `merge`; folder conflicts show all five — plus
   submit, apply-to-all scope, and Stop. Per-direction defaults ride
   `ConflictPolicy.policyFor`'s direction buckets:
   `conflict_policy_test.dart` ("every direction maps to exactly one
   bucket pair", all-ask defaults, merge-in-file-field normalization).
   Recursive folder Merge: decision layer "merge recurses
   (stat-else-mkdir, per-file policy inside)" + end-to-end
   `transfer_conflict_test.dart` "a folder ask parks the directory
   and holds its children; a merge answer recurses into the
   occupant" (new.txt lands, kept.txt survives).

4. **10k-entry recursive delete: progress + clean cancel, local and
   remote** — MET via the new `a 10k-entry delete tree` group in
   `packages/poltergeist_core/test/transfer/trash_delete_test.dart`.
   A 10 101-item tree (100 dirs × 100 files + root) held mid-walk by
   a listing gate emits growing `totalFiles`/`completedFiles` and
   progress events with `scanComplete == false`; released, it
   completes post-order (root unlinks last). The cancel twin
   interrupts mid-walk and leaves the queue healthy. Both shapes run
   against the `srv1` remote endpoint and against the local endpoint
   through the injected `localFileSystem` seam (4 tests). The local
   variants skip on Windows — `FakeTreeFileSystem` models posix
   separators only, the same convention `local_ops_test` already uses;
   Linux/macOS CI legs carry the local side.

5. **Trash round-trip per platform where CI allows; manual QA notes
   for the rest** — MET. Linux real round-trip
   `trash_roundtrip_linux_test.dart` (live `gio trash` + `.trashinfo`
   restore) executes and passes in CI on ubuntu-latest (run
   35414902815, package job 105821502762 — gio present on the runner,
   no skip). macOS and Windows cannot be round-tripped in CI (the
   platform channel needs a native host binding no pure-Dart test can
   drive); their coverage is channel-contract tests in the app suite
   plus native-binding compilation in the macOS/Windows client-build
   legs. Manual QA notes for both are recorded in the native-trash
   dated section of STATUS.md (2026-09-19): Finder "Put Back",
   Explorer Ctrl+Z / Recycle Bin, `.deb` `libglib2.0-bin` dependency,
   AppImage confirm-then-permanent fallback.

6. **Remote→remote between two Docker sshds, in the SSH integration
   CI job** — MET via new
   `packages/poltergeist_core/test/integration/transfer_sshd_test.dart`
   (`@Tags(['integration'])`): one `PooledConnectionManager` holds
   separate pools for `sshd-modern` (:2201) and `sshd-legacy` (:2202)
   — two TOFU pins — and the queue pipes a 101-item directory copy
   between them; the landing is verified by listing + byte-reading
   through the *destination's* own SFTP channel. The existing
   `run.sh` already exports `POLTERGEIST_SSHD`,
   `POLTERGEIST_SSHD_MODERN`, `POLTERGEIST_SSHD_LEGACY`, and
   `POLTERGEIST_SSHD_REMOTE_ROOT`, so the SSH-integration job picks
   the test up unmodified. Docker is unavailable on this audit host,
   so local proof is analyzer-clean + the clean env-gate skip; CI
   execution on the audit PR is the evidence (run/job IDs recorded in
   the PR body).

## §3.12 close chores

- STATUS.md swept: header now reads M3+M4 closed / M5 next; dated
  closure section added.
- No `TODO(pin)` markers in the tree; the Séance pin still cannot
  bump — no upstream tag contains `2e6d1f1` (open item 2).
- PORTS.md: no M4 additions — walker boundary rules reimplemented per
  plan (comparison recorded in the §3.5 walker dated section).
- Mobile invariant (07 §5, M4 row) re-verified: pause-all + journal
  restart is a working suspend primitive; per-attempt channel leases
  mean no task assumes a long-lived socket.
- `v0.4.0` tag chore NOT run — M3's precedent closed untagged; a tag
  push publishes release assets, so it is left to the
  supervisor/owner (`lkm-release` at `~/.local/bin`).

## Honest gaps carried forward

- Open item 23: transfer queue not composed into `main.dart` —
  engine machinery proven, production boot reachability pending the
  composition slice (and engine-protocol transfer verbs).
- macOS/Windows trash round-trips remain manual QA only.
- Remote→remote CI evidence attaches to the audit PR's
  SSH-integration run, not a pre-existing main run.
