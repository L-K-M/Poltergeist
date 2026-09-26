# Poltergeist engineering backlog

_Consolidated 2026-09-26 at `b955213` (origin/main after #216 and #217).
Pubspecs 1.0.1, Séance pin `v0.9.1` = `035b0d8`. Code line references
are from `913ca3d` unless an entry says otherwise; the sibling review's
window-integration and theme-default notes were reconciled at `407343eb`.
PR status as of 2026-09-26._

**Sources.**

- [tmp.md](tmp.md): the sibling review. Complete evidence, reproduction
steps, scope limits and original ideas for the IDs `PGE-nn`, `PG-REV-nnn`,
`BOTH-REV-nnn`, `UI-nn` and `SOL-nnn`.
- [docs/reviews/deep-review-2026-09-26.md](docs/reviews/deep-review-2026-09-26.md):
the deep review. Slices P1 core, P2 data-moving code, P3 app services, P4
UI and theming, X cross-cutting; IDs `P1-nn`..`P4-nn`, `X-nn`, `S*-P`
(Séance findings with a Poltergeist half) and `T-nn`.
- [docs/STATUS.md](docs/STATUS.md): the implementation record and its
numbered **Open items**.
- [docs/plan/00-OVERVIEW.md](docs/plan/00-OVERVIEW.md): the decision log,
which governs product choices.

This file is the forward-looking engineering backlog: the findings of both
reviews, the follow-ups that surfaced while implementing the first fixes,
and the ideas those reviews produced. It does not replace STATUS: STATUS
remains the record of what shipped and its numbered Open items; this file
holds shovel-ready work. Where an entry overlaps an open item, it says so
("STATUS #n"), and the open item stays authoritative for its own scope.
Séance's `ANALYSIS.md` owns upstream SSH, protocol and server work; this
document owns Poltergeist integration and product work, and lists upstream
items only where Poltergeist depends on them.

This is an unfinished-work list. A PR in review is awaiting owner review,
not merged functionality: do not implement the same slice again. Source
findings are not live exploits. Where the two reviews overlapped, their
entries are merged here under both IDs; where they disagreed, the entry
states the fact as verified against `b955213`.

## How to use this file

- Pick an entry, cut a branch from the latest `origin/main`, and re-read the
cited code first. Line numbers are from `913ca3d`; files moved since then
need a fresh trace. Entries marked LIKELY or SPECULATIVE need their
failure reproduced before a fix.
- **Gate first.** Every entry names a regression test. Write it, watch it
fail on current code for the stated reason, then fix (AGENTS.md "Bug
fixes"). If the gate cannot fail today, the finding is wrong or already
fixed: record that instead of shipping a change.
- **Respect the hard rules** in [09-PLAYBOOK.md §6](docs/plan/09-PLAYBOOK.md)
and the decision log in [00-OVERVIEW.md](docs/plan/00-OVERVIEW.md). The
ones entries most often touch: one VFS (rule 1, D3); no rsync execution
from `lib/` (rule 2, D6); no crypto changes (rule 3, D18); no phoning home
(rule 4, D19); no unguarded deletes (rule 5, D15); no silent uploads on
external-editor saves (rule 6); nothing heavy on the UI isolate (rule 7,
D8); never fork `seance_core`/`seance_protocol` (rule 9, D2). A fix that
would need to bend one of these needs a 00 edit with rationale first.
- Path shorthand: `core:` = `packages/poltergeist_core/lib/src/`,
`sync:` = `packages/poltergeist_sync/lib/src/`,
`app:` = `app/poltergeist_app/lib/`, `seance:` = the pinned Séance
checkout (`v0.9.1`) unless a Séance main path is stated.
- **ID families.** Deep-review IDs (`P1-03`, `X-02`, `S1-02-P`, `T-01`)
and sibling-review IDs (`PGE-02`, `PG-REV-004`, `BOTH-REV-003`, `UI-05`,
`SOL-011`) are kept verbatim so both reviews stay searchable. Sibling-review
tasks that had no ID are numbered `SR-01`..`SR-09` here. A residual of an
entry takes a letter suffix (`P2-05a`, `PGE-03a`, `UI-01a`).
- When an entry lands, move it to the completion ledger (section 11) with
its PR link and any residuals, and update STATUS per the playbook.

### Priorities

| Priority | Meaning |
|---|---|
| **P0** | Data loss, or a security boundary crossed on a plausible path. Do next. |
| **P1** | Common-workflow breakage, privacy leak, or reliability defect. |
| **P2** | Performance, accessibility, polish, cross-platform correctness. |
| **P3** | Optional hardening, convenience, or cleanup. |

Status tags: **In review: #N** (PR open), **In progress** (branch, no PR),
no tag = not started. Effort: S (under a day), M (a few days), L (larger).

The sibling review used the same four levels (P0 trust boundary or
critical loss risk; P1 correctness, recovery or important usability; P2
performance, accessibility or polish; P3 optional product exploration).
Its priorities are carried over unchanged; a merged entry takes the higher
of the two and says so.

### Verification commands (from AGENTS.md)

```bash
dart pub get
dart analyze packages/poltergeist_core packages/poltergeist_sync
dart test    packages/poltergeist_core packages/poltergeist_sync
(cd packages/poltergeist_bench && dart pub get)
(cd tool/bench && dart pub get)
dart test    test/benchmarks
cd app/poltergeist_app && flutter pub get && flutter analyze && flutter test
```

Always pass explicit package paths; a bare `dart test` at the root tries to
resolve the Flutter app. (AGENTS.md's snippet names only `poltergeist_core`;
CI loops over `packages/*`, which includes `poltergeist_sync`. See X-21.)

**Environment note.** On a container running as root, two
`poltergeist_core` tests fail: `test/checkout/checkout_manager_test.dart`
group "review hardening", cases "snapshot cleanup failure never masks the
save result" (line 912) and "a conflict still reaches the caller when
cleanup fails" (line 934). They inject faults with `chmod 500` (lines 927,
952), which root ignores. They are environment artifacts, not regressions.
Fix tracked as **T-01** (section 8): skip when `euid == 0`.

Baseline at `913ca3d` in the review container (Flutter 3.47.2, Dart
3.13.2, root): package and app analysis clean; 2,786 app tests pass; core
passes except the two root-only failures above.

---

## In review

Open PRs from both reviews. Do not start these slices again; review and
merge them first. Merged PRs from both reviews are in the completion
ledger (section 11).

| IDs | PR | Source | Scope awaiting owner review | Residuals (tracked below) |
|---|---|---|---|---|
| P1-02 | [#218](https://github.com/L-K-M/Poltergeist/pull/218) | deep review | Engine adopts the edited server config per request; old pool drains | P1-02a |
| P2-07 | [#222](https://github.com/L-K-M/Poltergeist/pull/222) | deep review | rsync exporter: filters unescaped, `RSYNC_OLD_ARGS` prefix, `--backup-dir` fallback, exec test | P2-07a |
| X-02, X-05 | [#223](https://github.com/L-K-M/Poltergeist/pull/223) | deep review | Editor keeps `jumpHostId`; jump-routed configs refused before any dial | X-03, X-05a, P1-02a |
| P4-01, P4-02 | [#224](https://github.com/L-K-M/Poltergeist/pull/224) | deep review | Header filter returns focus to the listing; up/back keep your place | idea "where was I" |
| P1-03 | [#225](https://github.com/L-K-M/Poltergeist/pull/225) | deep review | Remote executable launch guard on every remote system-default open | P1-03a |

The sibling review's PRs (#209, #210, #211, #213) have all merged; none
of its work is in review.

---

## Recommended sequence

1. **Land what is in flight.** #218 (P1-02), #222 (P2-07), #223 (X-02,
 X-05), #224 (P4-01/P4-02), #225 (P1-03).
2. **P0 data safety, all small:** P2-06 (within-task twins), P2-11
 (restored delete identity check), P1-04 (normalized pin lookup), the
 P2-04 residual (backup rollback after a failed replacement).
3. **P1 sync and recovery safety:** PGE-02 (enforce the reviewed
 snapshot), PGE-04 (revalidate roots and source ancestors), PGE-06
 (restore across volumes), PGE-03a (platform durability), PG-REV-004
 (persist before publish).
4. **P1 reliability and stores:** P2-01 (parked-folder subfolders), P3-05 /
 BOTH-REV-003 (vault/pin read vs decode), P3-07 (workspace detail prune),
 P1-02a (retry/resume re-resolve config), X-01 (stale checkout refresh),
 P3-04 (rename migrates checkouts), P1-08 (checkout compare-and-patch),
 P2-09 (retry after compaction), P1-01a (engine survives uncaught errors),
 S1-02-P (keepLocalPin stamp).
5. **Security and platform hygiene, small:** P1-05 (download mode clamp),
 P1-06 (trusted local roots), P1-09 (destination-aware names), X-10
 (Android backup rules), X-08 / BOTH-REV-007 (verified appimagetool), X-09
 (single instance), P2-12 (D15 remote trash opt-in, M).
6. **Account sync:** PG-REV-002 (batched backup pushes, with the re-pin
 audit), BOTH-REV-005 (activation as one operation), SR-05 (remote-HTTP
 policy); BOTH-REV-006 / SOL-011 (authenticated envelopes) is an upstream
 P0 that Poltergeist must coordinate with, not fork.
7. **Keyboard and UI pack:** P4-03/P4-10/P4-11/P4-16, P4-04, P4-07,
 P4-05, P4-08, P4-06/P4-09, P3-01, UI-01a, UI-06; then UI-05's remaining
 window slices and UI-04/08/09.
8. **Cross-app coordination:** X-03 (Séance protocol) and S1-03 (cursor
 regression) upstream, then the X-25 re-pin carrying X-04, the SSH
 capability adoption audit and the Séance #138 upload fix.
9. **Performance and CI:** SR-08 (P4 tab-switch regression) and SR-07
 (D12 baseline) first, since they block clean benchmark signal; then P2-08
 with P1-05's chmod skip, P3-02 step 1, P3-03, P2-13, P1-07 with PGE-08,
 P3-10 with P4-15, P1-11.
10. **Features:** SR-01 (verification after transfer), SR-02 (recovery and
 retention), UI-07 (Android file access), P4-21 (clipboard first slice).
11. **Docs drift and test hygiene:** X-21, X-17 comment, T-01 with SR-09,
 T-02, SR-06 (incremental review scope), BOTH-REV-012 (port parity).

---

## 1. Data safety: transfer queue, journal, sync engine, rsync exporter

### P2-06 · P0 · Within-task destination collisions resolved as ordinary conflicts
- **Problem.** Case twins (`README`/`readme`), NFC/NFD twins and
same-basename roots in one task go through the conflict policy as if the
occupant pre-existed. With `replace` plus move, the second twin replaces
the first and both sources are deleted: one file's content is gone and
both rows say completed. 03 §4.2 requires in-plan collision detection;
Séance refuses the case (`seance: app/.../remote_files_controller.dart:581-587`).
Evidence: walker has no sibling-fold check (`core: transfer/recursive_walker.dart:177-191`);
registry then `_decideFile` sees the twin (`core: transfer/transfer_queue.dart:2670-2684`,
`:3096`, `:3129-3140`); `_fold` has no Unicode normalization (`:4978-4981`);
remote destinations are never case-insensitive (`:5101-5103`);
`_normalizeRoots` allows same-basename roots (`:5062`). Test fake
`FakeTreeFileSystem.upload` adds a second key instead of replacing a
folded occupant (`test/.../transfer_fakes.dart:386-456`). VERIFIED
decision flow; real-FS outcome inferred.
- **Next.** Per task, track `Map<(endpoint, destKey), sourcePath>` of
committed and in-flight keys (`simpleCaseFold(nfc(path))` on
insensitive destinations, `nfc(path)` on APFS-style, raw otherwise).
When a key is claimed by a different source path in the same task, never
apply `replace`/`replaceIfNewer`: fail the item ("two source items map to
the same destination name on this volume") or offer keep-both only.
Detect twins per closed listing at scan time. Feed
`isCaseInsensitiveDestination` from a per-server probe (reuse
`TreeScanner._resolveCaseSensitivity`). Fix the fake.
- **Gate.** Move + replace of case twins leaves both contents intact with
one failed row; NFC/NFD twins serialize; two same-basename roots do not
overwrite each other.
- **Refs.** Effort M. Ideas: plan-time collision lens, per-server FS traits.

### P2-04 / PGE-01 · P1 (was P0) · Sync update with `backups: trash`: a failed replacement leaves the destination absent
- **Partly landed in #209 (merged, PGE-01).** The update branch now
journals a `SyncJournalTrashLine` right after `_trashEntry` and before the
transfer (`sync: executor.dart:898-924` at `b955213`), and journal records
are flushed before the replacement, so a failed or cancelled replacement
keeps its restore mapping and Undo can bring the old version back. This
removes the deep review's data-loss path (repro at `913ca3d`:
`status=failed`, destination exists = false, `trashLines=0`,
`restoreTrashedFiles` restored `[]`). Priority lowered to P1 accordingly.
- **Problem (residual).** (a) The transfer is still not wrapped: on failure
`_runItem` replaces the outcome with an empty `_ItemOutcome()`
(`:767-793`) and the destination stays missing until the user runs Undo;
the deep review's rollback rename was not part of #209. (b) The
rename-before-journal crash window remains: a crash between `_trashEntry`'s
rename and `appendTrash` leaves an unjournaled backup (the sibling review's residual). (c)
Unknown-size backups are journaled as `bytes: destSnapshot.size ?? 0`,
inventing zero; standalone trash mappings require an int (see #209's
review decision in section 11). The orphaned backup otherwise sits until a
purge exists (STATUS #27, SR-02).
- **Next.** Wrap the transfer: on failure with the destination still absent,
rename the backup back and journal the rollback; report failed with the
destination intact. Close the crash window with an intent line before the
rename (or a reconciler that recognizes unjournaled `.poltergeist-trash`
entries, SR-02). A nullable-size representation needs a separate
schema/restore migration, not null in a required-int field. Rail 9 (Undo)
stays whole; rule 5 (no unguarded deletes) holds.
- **Gate.** Upload scripted to throw `disconnected`: destination keeps the
old bytes and the journal carries the rollback. Variant where the rollback
rename also fails: `restoreTrashedFiles` restores it (this half already
passes after #209). Kill between rename and journal append: the backup is
found and offered, never lost.
- **Refs.** Effort S-M. D15, 05 §8 rail 9.

### P2-11 · P0 · Restored delete tasks act on current paths without re-verifying identity
- **Problem.** A restored delete arms `_DeleteWork(entry: journaled source)`
and `_executeDelete` calls `fs.delete(entry)` with no stat.
`_finishDeleteItem` journals after the unlink, and appends fsync only
every 64 records or 250 ms, so a crash can leave already-deleted items
pending. Days later, Resume permanently deletes a new file at the same
path with no re-confirmation. A mid-scan restore re-walks the current
tree and deletes what is there now, not what the dialog counted.
`core: transfer/transfer_queue.dart:4497-4551`, `:2454-2473`,
`:4359-4369`. VERIFIED (code trace).
- **Next.** Before acting on a restored (or any) delete item,
`stat(followLinks: false)` and require `type`, `size`, `modifiedAt` to
match the journaled planEntry (`sourceType`, `sourceSize`,
`sourceModifiedAt`); otherwise skip "changed since the delete was
confirmed". A restored mid-scan permanent delete re-confirms or refuses;
trash disposition may proceed.
- **Gate.** Journal a delete task, replace the file with new content,
restore, resume: file survives, row skipped.
- **Refs.** Effort S. Rule 5 (02 §10 confirmation quantifies what is lost).

### P2-07 · P0 · rsync exporter mis-escapes filters and remote paths for remote pairs
- **In review: #222** (https://github.com/L-K-M/Poltergeist/pull/222).
- **Problem.** `arg()` applied `_escapeRemotePath` to every flag value when
any side is remote (`sync: rsync_export.dart:372-373`, filters `:397-402`,
`--backup-dir` `:391`, remote spec `:506-509`). rsync sends filters over
its protocol, so `.poltergeist\*` matches only a literal name: a pasted
Mirror deletes `.poltergeist-trash/`, and excludes with spaces never
match. rsync ≥ 3.2.4 escapes remote args itself, so pre-escaped roots
name a different directory. VERIFIED against rsync source.
- **Fix in #222.** Filters unescaped; `RSYNC_OLD_ARGS=2 RSYNC_PROTECT_ARGS=0`
prefix on commands with a remote side; `--backup-dir` remote-escaped for
a remote destination, and a pull with an unsafe local trash path falls
back to in-root `.poltergeist-trash/rsync-<ts>` with a `# note:`. An exec
test runs real rsync against the output (skips without rsync 3.x).
- **Residual P2-07a (P3).** Behavior on rsync 3.0 to 3.2.3, 2.6.9 and
openrsync is from source reading only. Gate: extend the exec test to a
matrix leg with an older rsync in CI (a container image), or record the
gap in the exporter's `# note:`. The exec test is test-only code; the
`lib/` never-executes invariant (rule 2, D6) stays.

### PGE-02 · P1 · The executor does not enforce the reviewed sync snapshot
- **Problem.** `sync: executor.dart:_verifySource` checks only kind and size
(`b955213` `:1090-1109`); `_verifyDestination` reuses the cross-endpoint
mtime tolerance, and `diff.dart:_matchedItem` does not retain the digests
computed in hash mode in the plan. A same-size edit to a source after
preview passes; a one-second destination edit passes inside the tolerance;
in hash mode, changed content with preserved size and mtime passes.
VERIFIED (code, `_verifySource`).
- **Next.** Split into three slices: source-mtime protection, retained hash
preconditions carried in the plan, and explicit same-endpoint destination
rules. Check before any destructive backup or removal. Do not reuse
accepted clock shifts or comparison tolerance to authorize a post-preview
mutation; adjust the documented plan contract where necessary.
- **Gate.** Same-length source edit, one-second destination edit, changed
content with preserved size/mtime in hash mode, Retry Failed, unreliable
timestamps, and unchanged files. Changed files conflict without touching
the destination.
- **Refs.** Effort M. 05 §6. Related: P2-10 (per-side spellings), PGE-04.

### PGE-04 · P1 · Sync roots and source ancestors are not revalidated
- **Problem.** `sync: executor.dart:_checkParentChain` starts below the root
(`b955213` `:1114-1133`) and is called only for the destination (`:841`).
A top-level item checks no ancestor; a source download checks the leaf
but can traverse a swapped parent. VERIFIED (code). The deep review's
P2-19 is the local-read variant of the same class.
- **Next.** Capture canonical roots and validate both roots plus the relevant
ancestor chains before execution and before restoration. Canonicalize
before planning so legitimately selected aliases keep working.
- **Gate.** Replace the destination root or a source subfolder with a link
after preview: an outside sentinel remains untouched and the item
conflicts. A path-stat fix does not eliminate concurrent races after
validation; handle-relative native operations are the longer-term
boundary.
- **Refs.** Effort M. 05 §6 rule 5. See P2-19.

### PGE-06 · P1 · Restore does not work across volumes
- **Problem.** `sync: journal.dart:restoreTrashedFiles` (`b955213` `:498`)
only renames back, although forward trash supports EXDEV. It can remove
the run-created current file before that reverse rename fails.
- **Next.** Validated, durable reverse copy with exclusive staging and a
recoverable final replacement. Reuse the snapshot checks (PGE-02) for later
user edits.
- **Gate.** Delete and update restores across volumes; a failed copy or
flush retains both the backup and the current origin; changed current
files are never overwritten; a successful restore preserves exact bytes
and the original name.
- **Refs.** Effort M. Rail 9.

### PGE-03a · P1 · Platform durability guarantees are incomplete
- **Problem.** Residual of merged #213 (PGE-03), which added the shared
local file/parent flush barrier before deleting a cross-device trash
source; do not reimplement it. `TransferJournalIo.fsyncDirectory` still
suppresses filesystem failures, and remote durability has no VFS
primitive. #213 honors post-copy cancellation for remote copies but skips
the local barrier for them, and adds no remote fsync guarantee.
- **Next.** Define platform-supported guarantees and surface actual POSIX
flush failures; document unsupported directory flushing distinctly. Remote
fsync needs its own capability (see the `fsync@openssh.com` idea) and must
not be implied by a local fix. Follow-up regression from #213's review:
cancel a non-local VFS after upload completion and prove the original
remains, the orphan trash copy is removed, and no recovery mapping is
emitted. Clarify STATUS that remote copies skip the local barrier but honor
post-copy cancellation.
- **Gate.** Actual file/parent flush failures prevent source deletion;
unsupported platforms have explicit behavior; ordinary rename stays fast;
a real cross-volume fixture and crash testing. Unit operation-order tests
do not prove power-loss durability.
- **Refs.** Effort M. Related: P2-18 (silent write-ahead degradation).

### P2-01 · P1 · Subfolders of a parked or disconnect-retried folder are skipped for good
- **Problem.** With the default `ask` folder policy, a colliding folder's
subfolders are skipped as collateral before the user answers; after
Merge only top-level files transfer and the task ends "completed" with
non-retryable skips. For a same-server drag (move) the tree ends half
moved. A transient disconnect during a parent `mkdir` does the same.
`core: transfer/transfer_queue.dart:2054-2073` (`_runDirectory` skips on a
pending container), `:4944-4949` (`_resolvedContainer` treats not-ready
as skipped), `:2091-2111` (disconnect retry re-chains at the tail),
`:3421-3431`, `:3462-3471` (resolving re-runs only the parent; only
`_retryItemInPlace` `:4060-4078` re-arms `containerSkips`). Existing
coverage is a flat folder only (`transfer_conflict_test.dart:508`).
VERIFIED (repros `park_repro_test`, `dir_retry_repro_test`).
- **Next.** In `_scheduleDirectory`, when `planned.containerKey != null` and
the container is pending, chain the op after `container.ready.future`
(read the current completer at completion time; retry swaps it), as
files already do (`_armFile`, `:2541-2552`). In `_runDirectory`'s
`disconnected` branch, retry in place with a fresh lease, as
`_runDeleteItem` does (`:2404-2406`).
- **Gate.** (a) nested `child/payload.txt` under an asked folder lands after
Merge; (b) a disconnect on the parent's materialize stat does not skip a
scheduled child; (c) a folder parked past `maxPendingConflicts: 1` keeps
its subfolders.
- **Refs.** Effort M.

### P2-05 · P1 · Transfer journal compaction thrash
- **Merged: [#217](https://github.com/L-K-M/Poltergeist/pull/217)** (2026-09-26).
- **Problem.** `_shouldCompact()` compared the whole journal against
`_compactBytes` (`core: transfer/file_transfer_persistence.dart:485-487`)
while `_compact` keeps every pending record (`:495-520`), so past ~5k
files every append rewrote and fsynced the journal on the UI isolate
(repro: 1,828 rewrites, 758 MB for 2,000 appends). Quit waited on the
backlog. VERIFIED.
- **Fix in #217.** Trigger on reclaimable (finished-task) bytes, and only
when dropping them frees at least what the rewrite writes.
- **Residual P2-05a (P2).** `_LiveTask.records` still retains every
`(record, rawLine)` pair of pending tasks in memory (`:815`). Next: keep
only what compaction must rewrite (encoded lines, or offsets into the
journal) and let planEntry upserts and item records with a terminal
record collapse. Gate: a 50k-item pending task stays under a memory
budget in a bench test, and compacted replay equals uncompacted replay
(property test).
- **Residual P2-05b (P3).** A persistently failing rewrite (disk full)
retries on each append once the trigger holds. Next: back off after a
failed rewrite (retry after N appends or T seconds) and surface it with
P2-18's warning event. Gate: scripted IO whose `atomicRewrite` throws is
called at most once per backoff window.

### P2-09 · P1 · Retry after compaction orphans the task's journal; duplicate history rows
- **Problem.** Compaction migrates finished tasks to history; a retry
journals only `taskState: queued` (`core: transfer/transfer_queue.dart:4167-4179`),
`_applyToLive` starts a spec-less live task (`file_transfer_persistence.dart:356-358`),
and at open spec-less tasks are dropped ("taskEnqueued was lost"). A crash
mid-retry silently loses exactly the retried task. Separately (verified in
#217's notes): when compaction runs on a task's own terminal record before
`appendHistory`, the task gets two history rows, because `appendHistory`
does not de-duplicate. With defaults this hits every 32nd finished task.
#217 narrows the window; the repro still fails. VERIFIED (repro
`retry_compaction_repro_test`).
- **Next.** Add `persistence.readmit(task)` that re-appends
`TaskEnqueuedRecord(spec)`, planEntries and terminal outcomes, a no-op
when the store still holds the task; call it from `_requeueTask` and
`_rescanRetry`. Make `appendHistory` replace an earlier row with the same
task id.
- **Gate.** The repro (`compactFinishedTasks: 1`, fail, compact, retry,
reopen: task restorable), plus one completed task under
`compactFinishedTasks: 1` yields exactly one history row.
- **Refs.** Effort S-M. #217 has merged; this is its main residual.

### P2-02a · P1 · Mirror deletes a directory's children under a twin-hazard key
- **Problem.** Residual of merged #216. When one side holds NFC/NFD or case
twins (files) and the other side holds a directory under that key, the
hazard rows skip but the directory's children still plan as Mirror
deletes. Verified in a scratch test: left `café` NFC + NFD files, right
`café/x.txt` → `deleteRight` on `café/x.txt`.
- **Next.** In `sync: diff.dart` `_hazardMap`, treat a hazard key exactly
like a symlink path from #216: add it to the excluded prefix set (by match
key) so descendants on either side become skip rows.
- **Gate.** The scratch case as a `diff_test.dart` case plus an executor
scanned-plan case: `café/x.txt` survives a Mirror run.
- **Refs.** Effort S. 05 §3.

### P2-02b · P2 · Scan-error exclusion compares raw prefixes
- **Problem.** Residual of #216. `excludedOn` (`sync: diff.dart:41-52`,
`_erroredSubtrees` `:118`) compares raw path prefixes, so on a
case-insensitive pair a failed listing of `Logs` does not cover the other
side's `logs/...`, which can plan as Mirror deletes. #216's symlink check
already compares by match key.
- **Next.** Compare scan-error prefixes by match key, reusing #216's helper.
- **Gate.** Case-insensitive pair, left listing of `Logs` fails, right has
`logs/a.txt`: row is `scanError` skip, not `deleteRight`.
- **Refs.** Effort S.

### P2-03a · P2 · One-way source directory under an unresolved typeDiffers gates the delete phase
- **Problem.** Residual of #216. When the directory side of an unresolved
`typeDiffers` is the source, its child copy rows still plan, conflict at
run time (the destination holds a file), and each conflict gates the
Mirror delete phase (rail 7).
- **Next.** In `_Differ.build`, while the parent kind conflict is
unresolved, emit the source-side children as skip rows with a reason
tied to the parent ("waiting on the folder/file decision"); once resolved
toward the directory, keep the copy rows (a resolved mkdir needs them).
- **Gate.** Mirror with source dir `p/` and destination file `p`, conflict
unresolved: no child rows fail, the delete phase is not gated.
- **Refs.** Effort S-M. 05 §6 rule 4.

### P2-03b · P2 · App offers the wrong per-row verbs for kind changes
- **Problem.** Residual of #216 (code reading, not exercised in the UI).
`SyncPlanController.availableOverrides` and `_copyAction` pick the verb
from the destination's kind: a file-over-directory `typeDiffers` row gets
`makeDir*`, a directory-over-file row gets `update*`. The executor rejects
or no-ops both, so a per-row kind change cannot be applied from the app.
- **Next.** Derive the verb from the source's kind for `typeDiffers` rows
(`app: services/sync_plan_controller.dart`).
- **Gate.** Controller test: for each direction of a `typeDiffers` row, the
offered override executes against a scripted executor.
- **Refs.** Effort S.

### P2-02c · P3 · Plan view labels entries under a link as "excluded by rule"
- **Problem.** Residual of #216. Descendants under a symlink render as
"excluded by rule" because neither side of those rows is itself a link.
Hidden while "only show actions" is on (default).
- **Next.** Add a dedicated skip reason (for example
`SyncReason.beneathSymlink`) in `poltergeist_sync`, an ARB string, and
the plan-view mapping (D20).
- **Gate.** Plan view test: a row under a link shows the new label.
- **Refs.** Effort S.

### P2-12 · P1 · D15 per-server remote-trash opt-in is never wired
- **Problem.** `remoteTrashEnabled` defaults to `_trashOptedOut`
(`core: transfer/transfer_queue.dart:113`, `:166`); production composition
never passes it (`app: services/transfer_queue_session.dart:160-164`); no
bookmark or setting field exists; the dialog's opt-in branch is dead
(`app: .../delete_confirm_dialog.dart:96`, `:215`). Every remote delete is
confirm-then-permanent with no undo path. VERIFIED.
- **Next.** Per-bookmark device-local `remoteTrash` flag stored with the
probe opt-outs; pass `remoteTrashEnabled: (id) => settings.remoteTrashFor(id)`;
surface it in the bookmark editor. Trash lands in
`.poltergeist-trash/<runId>/` so it ages with STATUS #27's purge once built.
- **Gate.** Composition test: an opted-in server's `prepareDelete` yields
`effectiveDisposition: trash`; opted-out stays confirm-then-permanent.
- **Refs.** Effort M. D15, rule 5. Consider STATUS #28's docroot warning
for trash under web roots.

### SR-01 · P1 (feature) · Verification after transfer is not exposed or honored
- **Problem.** D7 promises optional verification, but ordinary queue copies
and native local copies have no user-facing verification mode.
- **Next.** A persisted default plus a per-task choice; compare landed
content, not just outgoing bytes. Journal verification results; a move
must not delete its source before verification succeeds. Communicate the
cost and the unchecked status.
- **Gate.** A corruption-injecting destination, local/remote/remote-to-remote,
cancellation, failure reporting and source retention.
- **Refs.** Effort M-L. D7. Idea: transfer receipt.

### SR-02 · P1/P2 · Recovery and retention are not discoverable
- **Problem.** Consolidates **STATUS #27-29** and the PGE-01/PGE-06
residuals: interrupted runs, temps, journals, checkouts and trash exist
but nothing surfaces them; the rail-5 purge surface is unbuilt.
- **Next.** Interrupted-run history, conservative temp reconciliation and a
Recovery drawer over existing journals/checkouts/trash. Expose exact
origins, retained bytes and safe restore actions. Age/size notices and a
user-confirmed purge that excludes live runs. Warn when in-root backups may
be served from a web document root and offer out-of-root storage. Never
silently expire the only recovery copy. Preserve unknown-size backups
without inventing zero as their size (standalone trash mappings currently
require an int; see P2-04). Measure per-record journal-flush overhead under
many-small-file syncs. Resume is a distinct feature from
restart-from-scratch and belongs to the D25 design decision.
- **Gate.** Kill at each upload/rename/journal boundary, unknown temps,
active runs, orphaned journals, failed purge and later user edits. A
committed but unjournaled file needs reconciliation, not blind retry.
- **Refs.** Effort L. D15, D25. Ideas: Recovery drawer. Pairs with P2-12
(remote trash ages with the purge) and S3-03-P.

### P2-10 / PGE-05 · P2 · Sync addresses both sides with one spelling; NFC-folds sensitive sides
- **Problem.** `_matchKey` always applies `nfcKey` (`sync: diff.dart:159`)
although 05 §3 says a normalization-sensitive side is never folded;
`_matchedItem` sets `relativePath: leftPath` (`:472-542`) and the executor
addresses the right side with it (`sync: executor.dart:818-826`;
single field `plan.dart:361-381`). NFD-left/NFC-right pairs flip to
"changed since preview" every run and gate Mirror deletes; Linux↔Linux
distinct twins never converge. Fails safe (no deletes). VERIFIED (trace).
Both reviews found this (sibling review PGE-05: matching normalizes
NFC/case, but `SyncItem.relativePath` stores only one side's spelling).
- **Next.** Carry `leftPath`/`rightPath` on `SyncItem` (nullable, default
`relativePath`) through the plan, direction overrides, subtree operations,
journal and restore; retain a separate logical match/display key. Use each
side's spelling in every executor address and journal line; NFC-fold only
sides known insensitive (APFS/HFS+ local, or probed). Version serialized
plans compatibly. Never normalize I/O names globally. #216 already captures
the directory side's own spelling for subtrees.
- **Gate.** NFD-left/NFC-right on a sensitive right: update lands on the
right's spelling. Linux↔Linux NFC and NFD twins yield two items. NFC/NFD
and case differences in both directions on strict fake filesystems, mixed
case sensitivity, nested folders, no duplicate names and exact restore.
- **Refs.** Effort M.

### P2-14 · P3 · Folder conflict prompt loops when the occupant is not a directory
- **Problem.** `availableVerbs` offers `merge` whenever the source is a
directory (`core: transfer/conflict_policy.dart:348-354`); merge or
replaceIfNewer against a file/symlink occupant yields `ConflictAsk`
(`:256-261`, `:231-241`) and `_materializeDirectory` re-parks
(`transfer_queue.dart:2179-2226`): the same prompt returns forever.
- **Next.** Offer `merge`/`replaceIfNewer` only when `existing.isDirectory`;
for a symlink occupant, say it will not be followed.
- **Gate.** `PendingConflict.availableVerbs` for dir→file and dir→symlink.
- **Refs.** Effort S.

### P2-15 · P3 · Progress and ETA ignore skipped and failed bytes
- **Problem.** `_finishItem` never credits skipped/failed/cancelled sizes
(`core: transfer/transfer_queue.dart:3814-3839`); the bar and ETA use
`transferred/total` (`app: .../activity_rows.dart:322-324`,
`services/activity_panel_controller.dart:159-162`). A 95%-skip re-upload
sits at ~5% with an hours-long ETA.
- **Next.** `task.settledBytes`; use `total - settled` in fraction and ETA;
include it in `TransferQueueProgressEvent`.
- **Gate.** Two files, one skipped: progress reaches 1.0 at completion.
- **Refs.** Effort S.

### P2-16 / SR-03 · P2 (investigate first; deep review rated P3) · Source changes and overlapping copy roots
- **Problem.** `TransferQueue.enqueue` has no containment check
(`core: transfer/transfer_queue.dart:383-464`); the app guard is lexical
(`app: .../pane_drop.dart:192-210`, comment `:220-231`). Case aliases on
macOS and remote symlink aliases can make the BFS walk nest copies until
the disk fills. LIKELY (fake repro did not recurse). The sibling review
lists the same class among its lower-confidence findings (tmp.md), plus
two neighbours: a source mutated after copy but before a move deletes it,
and child-before-parent root normalization (see also P2-13's
`_normalizeRoots`).
- **Next.** Before changing code, reproduce each: folder copies into
destinations reached by aliases/symlinks; source mutation between copy and
move deletion; child-before-parent roots. Test all actual enqueue paths,
including OS drops. Escalate only reachable failures. Then, in `_runTask`,
canonicalize (and fold on insensitive endpoints) the destination and each
root for same-endpoint copy/move; fail if the destination is inside a
root; the walker skips the canonical destination. Do not reject valid
cross-device work.
- **Gate.** Fake FS with a case alias: task fails with a containment error.
A source edited between copy and move deletion is not deleted (compare
with P2-11's identity check).
- **Refs.** Effort S-M.

### P2-17 · P3 · Boot restore connects to servers before Resume
- **Problem.** `restore()` fires `_sweepRestoredTemps` un-awaited
(`core: transfer/transfer_queue.dart:4286-4303`), which leases a channel
to each restored destination server at launch (`:4585-4594`) while the
queue is force-paused: unexpected SSH connections and credential or
host-key prompts. Privacy-adjacent (D19 spirit).
- **Next.** Defer the sweep to first resume (`resumeQueue`/`resumeTask`),
or sweep only local destinations at boot.
- **Gate.** Restore with a remote task: no `leaseTransferChannel` before
`resumeQueue`.
- **Refs.** Effort S. Distinct from sync's run-startup sweep (STATUS #29).

### P2-18 · P3 · Transfer journal torn-write glue; silent write-ahead degradation
- **Problem.** `appendLine` writes `'$line\n'` with no leading `\n`
(`core: transfer/transfer_journal.dart:1185-1188`); the sync journal
prefixes one (`sync: journal.dart:387-399`). A partial write glues onto
the next record and the quarantine drops every later record. Write
failures become a notice while the queue proceeds. LIKELY.
- **Next.** Prefix `\n`, skip empty lines at parse; emit a queue-level
warning event on persistence write failure and consider pausing admission
while the store is failing.
- **Gate.** Scripted IO writes a partial line then throws; later records
still replay.
- **Refs.** Effort S. Related: PGE-03a (suppressed directory-flush failures).

### P2-19 · P3 · Symlink-swap TOCTOU on local source reads
- **Problem.** Local reads check type nofollow, then `FileStat.stat` and
`openRead` follow the path (`core: fs/local_file_system.dart:547-569`,
`:787-805`); `local_copy_pump.dart:174` opens without `O_NOFOLLOW`; the sync
executor re-checks only the destination parent chain (`sync: executor.dart:833`).
A writable source tree can swap in a link to `~/.ssh/id_ed25519` between
scan and read. SPECULATIVE (needs a local attacker).
- **Next.** Open with `O_NOFOLLOW` (FFI already present) or compare pre-open
lstat with post-open stat (dev/ino/size/mtime) as the Séance SFTP adapter
does; re-check the source parent chain in the sync executor.
- **Gate.** A test hook swaps the file for a symlink after scan: the read
fails, nothing is uploaded.
- **Refs.** Effort S-M. The sync-executor half (roots and source
ancestors) is PGE-04.

---

## 2. Core: connection, engine, security

### P1-03 · P0 (Windows) · Remote Open launches checkouts under their original extension
- **In review: [#225](https://github.com/L-K-M/Poltergeist/pull/225)**.
- **Problem.** The executable blocklist `previewWindowsExecutableExtensions`
has no production consumer (`core: preview/preview_kinds.dart:184-187`);
checkouts keep the remote extension (`core: checkout/managed_remote_file_store.dart:172-190`)
and go to `explorer.exe` (`core: engine/local_file_opener.dart:76-88`) from
`_launchCheckout` and the built-in-editor fallbacks
(`app: ui/workspace_shell.dart:2868-2880`, `:2910-2987`, `:1290-1315`;
`services/external_file_opener.dart:268-277`; default double-click is
`open`, `services/double_click_action.dart:15`). Double-clicking a remote
`.js`/`.hta`/`.vbs` on Windows runs it. Plan: 06-EDITOR around line 1248.
VERIFIED by trace.
- **Next (branch scope).** `isUnsafeRemoteLaunchName(name, host:)` in
`preview_kinds.dart` (Windows list plus `terminal`, `fileloc`, `inetloc`,
`webloc`, `command`, `tool`, `workflow`, `app`, `desktop`, `appimage`;
case-insensitive; trailing dot/space stripped); refuse or confirm
(default Cancel) at every remote `openSystemDefault`.
- **Gate.** Core table test (`app.JS`, `x.hta.`, `a.tar.gz` negative); app
widget test that `payload.hta` and `app.js` never reach a fake opener on a
Windows `EditorHostPlatform`.
- **Residual P1-03a (P3).** Stamp checkouts with Mark of the Web
(`Zone.Identifier` ADS, ZoneId=3) on Windows and `com.apple.quarantine`
on macOS so SmartScreen/Gatekeeper/Protected View apply. Gate: after a
checkout commit on Windows the ADS exists (Windows-only test).

### P1-04 · P0 · TOFU pin lookup is host-spelling sensitive
- **Problem.** Pools and incidents key on `PoolKey.normalize` (trim +
lowercase, `core: connection/pool_key.dart:56-60`) but pins use the raw
host (`core: connection/connection_manager.dart:1122`,
`connection/ssh_transport.dart:166-168`, pinned `ssh_session.dart:614`,
`InMemoryHostKeyStore` keys `'$host:$port'`). A MITM on `server.lan`
with a pin under `Server.lan` shows a routine first-use prompt, not the
changed-key block; trusting pins the attacker. Splits D18 incident logic.
VERIFIED (repro `tofu_case_test`: verdict `firstUse`, expected `changed`).
- **Next.** Wrap `EngineHost._seededPinStore` in a normalizing store: `get`
tries the normalized host then the raw spelling (legacy); `put` writes
normalized; seeding normalizes and treats spelling-duplicate mismatches as
`changed`. Use it in `_preflightHostKey` and the incident-restore filter.
`HostKeyPinnedEvent` carries the normalized host so the app store converges.
No crypto change (rule 3).
- **Gate.** The repro in `test/connection/pool_trust_test.dart`, plus a
legacy raw-spelling pin fallback case.
- **Refs.** Effort S. D18. Séance has the same raw-host lookup; offer the
fix upstream (S2-14 is the jump-route variant).

### P1-02 · P1 · Edited server config ignored for the session
- **In review: #218** (https://github.com/L-K-M/Poltergeist/pull/218).
- **Problem.** `_referenceFor` reused the cached reference so edits to host,
user, port or key never reached new dials until Disconnect or restart
(`core: connection/connection_manager.dart:1946-1948`, `:1980-1981`, `:559`).
- **Fix in #218.** The config on each request wins; an identity change
retires the old reference and its pool drains (live panes and transfers
are not force-closed). Credential-only edits on a live endpoint apply at
that pool's next first connect (by design, matches 03 §3.5).

### P1-02a · P1 · Retry, resume and SERVERS-pane paths resolve a stale or missing config
- **Problem.** Two follow-ups from #218 and #223, one root cause: pane
paths that do not re-resolve the server config.
- `PaneController.retry()` and restored-tab `resumeRestored()` rebuild the
  config from the tab's own bookmark copy (`serverConfigForBookmark`),
  ignoring the bookmark store and the pulled catalog. After an edit they
  dial the stale endpoint and retire the fresh reference (churn, no loss).
- Retry, duplicate tab, Home and reopen-closed-tab on a pane opened from
  SERVERS call `connectRemote` without `resolvedConfig`;
  `serverConfigForBookmark` throws on the identity-less bookmark, so the
  user sees a generic "connection failed" plus an error report (never a
  direct dial). Reproduced in a scratch test.
- **Next.** One resolver used by every connect path, the way
`WorkspaceShell._openBookmark` resolves (bookmark store, then catalog via
`serverConfigId`), in `app: services/pane_controller.dart` around
`:1001-1008` and the tab-strip actions. Keep #223's jump-host guard on the
resolved config.
- **Gate.** Pane tests: after editing the host, `retry()` and
`resumeRestored()` send the new host; Retry/duplicate/Home/reopen on a
SERVERS pane connect with the catalog config and show no generic failure.
- **Refs.** Effort S-M. Idea: "Settings changed, reconnect?" chip.

### P1-01 · P1 · Malformed SFTP packet kills the engine isolate; app never notices
- **Problem.** Spawned with `errorsAreFatal: true`
(`core: engine/engine_client.dart:122-127`), no zone in `engineMain`
(`core: engine/engine_host.dart:37-50`); pinned dartssh2 listens without
`onError` (`dartssh2-3.0.2/lib/src/sftp/sftp_client.dart:42`) and decodes
status strictly (`sftp_packet.dart:811`). One non-UTF-8 status or
truncated packet kills every remote and local pane; the app has no
consumer of `.terminated` (`app: services/engine_session.dart:41`,
`:186-187`). VERIFIED (decode crash and isolate death reproduced).
- **Next, split in two PRs.**
- **P1-01a (core, S):** run `engineMain` inside `runZonedGuarded`; route
  uncaught errors to a new `EngineFaultEvent(summary)` (protocol v14,
  message only) and keep serving. A stuck reply waiter then degrades via
  the adapter's 30 s timeout into normal recovery.
- **P1-01b (app, M):** `EngineSupervisor` respawns with the last
  `EngineConfig`, reseeded from pin and incident stores, publishing
  `Stream<EngineGeneration>`; `AppEngine.terminated` drives a
  "Connections were reset" banner and pane rebinding.
- **Upstream:** `onError` on `SftpClient`'s listener and
  `allowMalformed: true` for status/language strings, through a Séance or
  dartssh2 PR and a pin bump (rule 9: no fork).
- **Gate.** `engine_client_test.dart`: an entrypoint wrapping `engineMain`
throws from a microtask after boot; a later `openLocalChannel` succeeds
and one fault event arrives (fails today: isolate exits). App: a fake
`AppEngine` whose `terminated` completes causes respawn plus banner.
- **Refs.** D8. Idea: engine watchdog with state replay.

### P1-05 · P1 · Downloads apply remote mode verbatim; one `chmod` process per file
- **Problem.** `(mode & 0xFFF)` is chmodded onto the temp
(`core: fs/local_file_system.dart:681-688`, `:859-866`) with
`preserveMode: file.source.mode` for every hop including remote→local
(`core: transfer/transfer_queue.dart:2825`). A hostile server's `04755`
or `0777` lands as setuid-as-you or world-writable; umask ignored. Each
chmod spawn costs ~6.7 ms (67 s serialized for 10k files). VERIFIED.
- **Next.** Remote→local: `preserveMode: mode & 0x1FF & ~umask` (umask
computed once); never carry setuid/setgid/sticky across a trust boundary.
Skip chmod when the temp already has the wanted mode. Longer term FFI
`fchmod` (shared with P2-08).
- **Gate.** Queue test: remote `0x9ED` lands as `0x1ED`, `0x1FF` lands as
`0x1FF & ~umask`. `LocalFileSystem` test with a recording fake `chmod` on
`PATH`: no spawn when the mode already matches.
- **Refs.** Effort S.

### P1-06 · P1 · Destinations under a symlink or junction are refused
- **Problem.** `ensureSafeLocalDirectory` refuses any symlinked ancestor
(`core: fs/local_fs_safety.dart:189-225`) and is called on raw user roots
(`core: transfer/transfer_queue.dart:1999-2003`,
`preview/preview_cache.dart:80-83`). Every download into macOS `/tmp`, a
symlinked `~/Downloads`, or a junction-relocated Windows profile fails.
03-ARCHITECTURE:235-239 says callers must resolve first. VERIFIED (repro).
- **Next.** `resolveTrustedLocalRoot(String)` in `local_fs_safety.dart`:
deepest existing ancestor → `resolveSymbolicLinks()` → append missing
components (still validated). Use it in `_ensureDestinationRoot` and
`PreviewCache.open`. Remote-derived components keep the strict walk.
- **Gate.** Download into `tempDir/link/sub` (link → real) completes, bytes
in `real/sub`.
- **Refs.** Effort S.

### P1-08 · P1 · Checkout record lost update reverts a concurrent `migrateRename`
- **Problem.** `_upload`'s post-commit refresh and `_repairSnapshotAgainst`
capture the record, await (stat, hash, possibly minutes), then write the
whole record back (`core: checkout/checkout_manager.dart:487-536`,
`:700-726`); `update()` has no precondition. A rename during the window
snaps the record back to the dead path: next save CAS-fails, reopen
creates a second checkout. VERIFIED (repro with `statGate`).
- **Next.** `ManagedRemoteFileStore.patch(id, change)` inside `_serialized`;
post-commit refresh and repair patch only snapshot fields and only if
`current.remotePath` equals the path they statted (else keep
`needsReconcile: true`); `migrateRename` uses `patch`.
- **Gate.** The gated-stat repro; a second test gating the repair's digest
download.
- **Refs.** Effort S-M. Becomes live once P3-04 wires rename migration.

### P1-09 · P2 · Windows name rules enforced on POSIX destinations
- **Problem.** `validateLocalName` rejects `:*?"<>|`, trailing dot/space and
reserved stems on every platform (`core: fs/local_fs_safety.dart:95-119`;
consumers `local_file_system.dart:621`, `:762`, `local_fs_safety.dart:251`,
`transfer/recursive_walker.dart:375`). On Linux/macOS
`db-2026-09-26T03:00:00.sql.gz`, `aux.c`, `what?.md` cannot be downloaded.
03 §2.3 wording sanctions it; 09 §3.5 says destination-aware. VERIFIED.
- **Next.** `validateLocalName(name, {required bool windowsDestination})`
defaulting to `Platform.isWindows`; shape checks (`/`, `\`, NUL, `.`,
`..`, NAME_MAX) everywhere; optionally detect FAT/exFAT/NTFS mounts on
POSIX via `statfs`. Precision edit to 03 §2.3.
- **Gate.** On POSIX, `a:b` and `aux.c` pass; with `windowsDestination: true`
they throw; queue test downloads `x:y.txt` to a POSIX temp dir.
- **Refs.** Effort S. Later: a "rename on download" conflict verb.

### P1-10 · P3 · Host-key and keyboard-interactive prompts outlive their connect
- **Problem.** Only a reply or shutdown withdraws them
(`core: engine/engine_host.dart:1134-1159`, `:1161-1183`; only
`resolveCredentials` has a scope, `:1207`). Preflight waits 5 min
(`core: connection/ssh_transport.dart:195-201`, `:233`) while sshd's
`LoginGraceTime` (120 s) closes first with a misleading "closed before key
exchange". A late Trust can re-pin. LIKELY.
- **Next.** Dismissal token per attempt (the `CredentialResolutionScope`
pattern), fired when preflight/connect completes by any path or the pool
loses its last reference; map `client.done` after the verifier started to
"the server closed the connection while waiting for your answer".
- **Gate.** `engine_host_test`: preflight fake whose `client.done` completes
while the prompt is open → `PromptDismissedEvent` for that promptId.
- **Refs.** Effort S-M.

### P1-12 · P3 · Preview-cache index can point outside the cache directory
- **Problem.** `p.join(directory.path, fileName)` with an absolute or `../`
name escapes (`core: preview/preview_cache.dart:292-303`); `enforce()`,
`clear()` delete it (`:158`, `:182`), `lookup()` renders it (`:93-101`).
Needs a same-user writer. VERIFIED (code).
- **Next.** In `_loadIndex`, keep only single-component names matching
`^[0-9a-f]{64}(\.[A-Za-z0-9_-]{1,16})?$`.
- **Gate.** Index entries `/etc/hosts` and `../x` are dropped and `clear()`
never touches them.
- **Refs.** Effort S.

### P1-13 · P3 · ssh_config `%` tokens import literally
- **Problem.** `HostName %h.corp.example` and `IdentityFile ~/.ssh/%h_ed25519`
import verbatim with no D22 badge (`core: import/ssh_config_import.dart`;
the pinned importer does not expand either). Séance S2-10 also reports the
`Key = value` form importing `= value`.
- **Next.** Expand `%h`, `%u`/`%r`, `%p`, `%d`, `%%` in HostName and
IdentityFile; badge `%C`, `%L`, `%n`, `${ENV}` as
`SshConfigImportLimitation.unexpandedToken`. If the `=` form lives in the
pinned importer, fix it upstream and pick it up at the re-pin (X-25).
- **Gate.** Table tests in `ssh_config_import_test.dart`.
- **Refs.** Effort S. D22. Idea: import "explain" view.

### P1-14 · P3 · Metadata stores written at umask default
- **Problem.** `bookmarks.json`, `servers.json` and the record store are
written without `restrictToOwner` (`core: bookmarks/bookmark_store.dart:888-908`,
`sync/server_store.dart:425`, `sync/persistent_record_store.dart:407`):
0644 under a 0755 support dir on multi-user Linux, a reconnaissance map.
- **Next.** `restrictToOwner: true` for these stores; chmod the support dir
0700 once at startup (use the resolved `/usr/bin/chmod` path, P1-16).
- **Gate.** After a save, file mode is 0600 (POSIX-only test).
- **Refs.** Effort S. X-10 covers the Android side.

### P1-15 · P3 · `explorer.exe` comma parsing
- **Problem.** `core: engine/local_file_opener.dart:82-84` passes paths that
Dart quotes only for whitespace/quotes; `explorer.exe` splits on `,`, so
`report,final.pdf` may open the wrong target. SPECULATIVE.
- **Next.** `ShellExecuteExW` via FFI (`SEE_MASK_NOASYNC`, verb `open`, real
error codes); fallback `rundll32 shell32.dll,ShellExec_RunDLL`. Coordinate
with P1-03's guard (same call site).
- **Gate.** Windows-only test opening a comma path through a fake shell seam.
- **Refs.** Effort S-M. Reproduce on Windows first.

### P1-16 · P3 · Small correctness nits
- `core: preview/preview_produce.dart:309-312`: comment says a removed row
resolves its waiter as cancelled; code leaves it pending. Copy
`CheckoutManager._onQueueEvent` (`checkout_manager.dart:853-870`).
Gate: removing a pending task's row completes the waiter as cancelled.
- `core: fs/local_file_system.dart` `createDirectory`/`rename`/`createSymbolicLink`
skip `validateLocalName` on the new leaf (09 §3.5). Gate: invalid leaf
throws before any FS call.
- `core: fs/local_file_system.dart:982-987`: `_runUtility` runs `chmod`/`chown`
from `PATH`, unlike `restrictLocalPathPermissions` (`local_fs_safety.dart:140-150`).
Gate: a `PATH`-planted fake chmod is not invoked.
- Effort S together.

### P1-K · P2 · Known items rechecked (tracked in STATUS)
- `EngineHost._channels` never maps back to a serverId; per-serverId maps
grow (`core: engine/engine_host.dart:78`, `connection_manager.dart`).
**STATUS #3** (audit finding C) owns it; decide with the Quick Connect
lifecycle.
- Listings and `VfsContentDigest` over a lease are not cancellable.
**STATUS #12** owns it; needs an upstream VFS change and pin bump (rule 9).
P3-08's digest cancellation is the app-side half that does not need it.
Expanded with the sibling review's scan/hash cancellation task as PGE-07
below.

### PGE-07 · P1/P2 · Scan and hash cancellation does not release work
- **Problem.** `ScanCancellation` is only a boolean; a pending listing or a
whole-file digest can delay Cancel. Overlaps **STATUS #12** (listings and
`VfsContentDigest` over a lease are not cancellable; needs an upstream VFS
change and pin bump, rule 9) and P3-08 (the sync plan diff passes no
token), which is the app-side half that does not need upstream work.
- **Next.** Bridge a completion signal to VFS cancellation, release owned
leases, and ignore late completions. The pinned listing contract may need
upstream work. Only then consider bounded parallel hashing, based on
measured workloads.
- **Gate.** A stalled listing or digest cancels promptly, later work never
starts, leases return, browsing remains usable, no abandoned async errors.
- **Refs.** Effort M. D8.

---

## 3. App services and persistence

### P3-05 / BOTH-REV-003 · P1 · Vault and pin store quarantine the file on a transient read error
- **Problem.** The read sits inside the quarantine catch-all
(`app: services/file_stores.dart:112-131` `FileVaultStore._read`,
`:358-373` `FileHostKeyStore._load`), so a Windows sharing violation, EACCES
or EIO moves `vault.json` aside and the next save writes a vault holding
only the new secret; pins vanish and every host prompts as first-use.
`FileHostKeyStore.put` flushes unserialized from three owners
(`:393-397`); the comment at `:178` claims a per-path queue that does not
exist (X-17). The journal reader (`:151-173`), `SettingsStore._load` and
core `FileBookmarkStore._load` already propagate read failures. LIKELY.
Both reviews found this; the sibling review (BOTH-REV-003) scopes it as a
shared behavior fix for both apps.
- **Next.** Read bytes outside the guard (decode inside, as the journal
does) so I/O errors propagate and retryable failures are preserved;
`_load()` already un-memoizes failures. Quarantine only bad content, under
a unique retained name, and expose actionable recovery. Same split for
`FileHostKeyStore._load`; serialize `put` with a `_tail`; fix the comment.
Port back to Séance (`seance: app/seance_app/lib/services/file_stores.dart:305-314`).
Preserve re-key sidecar recovery.
- **Gate.** Reader seam throwing `FileSystemException`: `getSecretBlob`
throws, no `.corrupt-*` file, bytes and trust intact, second call returns
the secret. Bad UTF-8/JSON still quarantines. Concurrent startup agrees.
Failed saves cannot publish an empty or partially mutated cache.
Concurrent `put(A)`/`put(B)` with a delayed first writer: both pins
survive reload.
- **Refs.** Effort S. No crypto change (rule 3).

### P3-07 · P1 · A quarantined bookmarks.json erases every saved workspace's details
- **Problem.** Load-time prune drops details whose favorite is gone
(`app: services/workspace_library.dart:162-171`); a corrupt bookmarks file
starts empty (`core: bookmarks/bookmark_store.dart:733-751`). Repro:
475 bytes of details → `{"version":2,"workspaces":[]}`. Restoring the
bookmarks later brings back placeholders only; tab sets were device-local.
- **Next.** No prune on load. Remove details only on an observed
`BookmarkRemovedChange` (already handled in `_onStoreChange`) or explicit
delete. Optional GC gated on a clean-load signal
(`FileBookmarkStore.lastLoadQuarantined == false`) plus age.
- **Gate.** The repro: detail survives and rejoins when a bookmark with the
same id returns.
- **Refs.** Effort S.

### P3-04 · P1 · Pane rename never migrates managed checkouts
- **Problem.** `submitRename` renames with no hook
(`app: services/pane_controller.dart:1980-2146`, `channel.rename` `:2092`);
`checkout_session.dart:143-151` says the pane calls `migrateRename`, and
06-EDITOR §3.5 specifies it; grep finds only the definition. An external
editor save after a rename raises a false "changed or deleted" conflict;
Overwrite resurrects the old name, Discard loses the edit. VERIFIED.
- **Next.** `onRemoteRenamed(serverId, oldPath, newPath)` on
`PaneController`, stamped by the strip like `externalEditorOpen`, bound by
the shell to `checkoutSession.migrateRename`; call after a successful
remote rename even if the pane navigated away; report errors via
`_report`. Flag same-server queue moves as the core-side follow-up.
- **Gate.** Remote rename invokes the hook with the right triple, including
when the pane moved on; no call for local panes or failed renames; a
shell-level test with `checkout_session_test` fakes.
- **Refs.** Effort S-M. Land P1-08 first or together. Idea: rename-aware
relocation across stores.

### P3-12 · P1 · Typed secret saved before authentication succeeds
- **Problem.** `if (result.saveToVault) await _saveToVault(...)` runs before
the reply authenticates (`app: services/prompt_coordinator.dart:333`). A
typo with Save checked overwrites a known-good secret. VERIFIED (code).
- **Next.** Keep the pending save keyed by prompt id; commit on the pool's
`connected` status for that serverId; drop on auth failure.
- **Gate.** Fake pool: auth failure after the prompt → `vault.putSecret`
never called; success → called once.
- **Refs.** Effort S-M.

### P3-06 · P2 · Automatic bookmark backup scheduling is unimplemented
- **Problem.** "Scheduling (startup, 2 s debounce, 5 min periodic, queued
flag) is a later slice" (`app: services/bookmark_backup_service.dart:7-9`);
`backUpNow` returns null while syncing, with no queued round (`:512-550`);
only manual callers (`app: ui/workspace_shell.dart:3478-3484`). Spec
04-SEANCE-INTEGRATION §3.3 and checklist `:1609`. Enrolled users are
backed up only on a button press.
- **Next.** Scheduler inside the service: round on `load()` when enrolled;
2 s debounce on bookmark and server-store changes; `Timer.periodic(5 min)`;
`_roundQueued` loop; pause while `passphraseUnverified`, signed out or on
a dead-account notice; cancel on dispose/sign-out; failures silent except
manual rounds. User-initiated sync traffic only (rule 4, rule 8 gate
unchanged).
- **Gate.** Injected timer factory: startup round; three edits coalesce to
one round; periodic tick; a mid-round edit gives exactly one follow-up;
none after sign-out.
- **Refs.** Effort M. Idea: backup heartbeat chip.

### P3-01 · P2 · Quick Look "Download" diverts to the Info well; overlay wedges
- **Problem.** `_startProduction` gates on the panel phase
(`app: services/preview_session.dart:833-857`); with the Info tab visible
(default, `workspace_controller.dart:109`) `quickLookConfirm` (`:1218-1223`)
starts nothing; the overlay shows "Downloading… 0 B"; its Cancel falls
through to cancelling every background production (`:615-640`) and never
clears the card; Space is dead (`:469-480`). REPRODUCED. The suite
defaults `infoTabShown: false` (`test/support/preview_harness.dart:184`).
- **Next.** `_startProduction({required int generation, required _ThresholdGate gate})`
with `enum _ThresholdGate { ask, confirmed }` at its five call sites; in
`_cancelProduction`, when nothing was cancelled, clear the Quick Look card
and reset `_quickLookRequested` instead of cancelling everything.
- **Gate.** `big.txt`, `infoTabShown: true`: confirm starts a production;
Cancel on a wedged card leaves `producer.cancels` empty; parameterize the
QL suite over `infoTabShown`.
- **Refs.** Effort S. STATUS #26 covers native QL manual QA.

### P3-08 · P2 · Sync plan diff is not cancellable; superseded scans keep writing state
- **Problem.** `SyncPlanDiffer.diff` has no cancellation parameter and
`_EngineDiffer` passes none (`app: services/sync_plan_controller.dart:280-290`,
`:1417-1440`) although core checks one (`sync: diff.dart:36`, `:73`);
no generation check after `states.load/save` awaits (`:891`, `:916`,
`:922`), so a superseded scan clears newer `_pendingCaseOverrides` (`:923`);
override-mismatch branch reads the field token after awaits (`:902-911`);
`run()` does not require `phase == ready` (`:1073`); dispose cancels only
the scan (`:1374-1381`). contentHash pairs keep hashing after a rescan or
tab close. VERIFIED.
- **Next.** Local `ScanCancellation` per `_scanAndDiff`; forward it through
`SyncPlanDiffer.diff`; generation checks after each await; clear overrides
only when current; guard `run()` against `scanning`.
- **Gate.** Stub differ records its token: `rescan()` and `dispose()` cancel
it; `updatePairDefinition` during a parked `states.load` keeps overrides
on the new pairId.
- **Refs.** Effort S. D8 (hashing is off the UI isolate already). The
VFS-level half is PGE-07.

### P3-09 · P3 · Recents overwrite a newer-schema document
- **Problem.** A version mismatch is swallowed and the list starts empty
(`app: services/recent_locations.dart:125-157`); `_write` stamps v1
unconditionally (`:208-231`), contradicting "never overwritten unread"
(`:86-92`). REPRODUCED.
- **Next.** `_schemaBlocked` set when a stored document is present but
rejected; `_write` is a reported no-op while set (matches
`SessionStateStore`/`WorkspaceListStore`).
- **Gate.** A version-2 document survives `record()` + `flush()`.
- **Refs.** Effort S.

### P3-11 · P3 · Keystore probe per vault call; concurrent first mint race
- **Problem.** `DynamicSecretVault` probes per operation (`app: main.dart:119-126`);
`probeKeystore` reads null then mints (`services/secure_master_key.dart:95-111`).
After a late keyring unlock two concurrent ops can mint different keys;
secrets sealed under the loser read as absent. LIKELY (narrow).
- **Next.** Single-flight the create path (memoized future, re-read after
write, return the stored value); cache the resolved key in
`DynamicSecretVault` until `setKeystoreKey` bumps a revision. No crypto
change (rule 3).
- **Gate.** Fake storage returns null twice: two concurrent probes resolve
the same key with exactly one write.
- **Refs.** Effort S. Séance SOL-031 family.

### S3-03-P · P2 · Ported managed-checkout store: one bad checkout degrades startup
- **Problem.** From Séance #141's follow-ups: Poltergeist's ported store has
a milder form of Séance S3-03: the sweep's deletes/list are unguarded,
`reconcile` rethrows on an unreadable checkout, and the app then boots
without checkouts for the session. Séance #141 also left "newer-version
index still quarantined (open read-only instead)" and "Windows `*.tmp`
index not read back" (S3-08); check whether the Poltergeist port shares
both. Unverified here beyond the follow-up note.
- **Next.** Trace `core: checkout/managed_remote_file_store.dart` sweep and
reconcile; guard per checkout (skip and report one, keep the rest), and
mirror Séance #141's never-sweep-after-quarantine rule if absent.
- **Gate.** A checkout directory made unreadable (non-root, see T-01) does
not block the others from loading; a quarantined index does not trigger a
sweep.
- **Refs.** Effort S-M. Idea (Séance S3-12): "recovered edits" drawer for
preserved checkouts.

---

## 4. UI, keyboard, accessibility, i18n, theming

### UI-05 / PG-REV-008 · P1 · Extra workspace windows: remaining accessibility and usability slices
- **Already done (preserve, do not reimplement).** Current main removed the
silent-semantics wrapper: native updates route by view ID and actions by
node ownership. Per-window external drop-in/out, the macOS unified toolbar
and Quick Look ownership are implemented (#214, "Extra windows'
integrations" in STATUS; **STATUS #34** records what is still open). The
original review's missing-integration list is obsolete.
- **Problem (remaining slices).** Extra-window root-node `0` actions reach
the main window's root (each view's root node is 0); no Windows taskbar
progress while the main window is hidden; no per-window geometry
persistence; own-window drags are uncoordinated (a local item copies
through the OS drop path as a drop from another app would, a remote
promised item does nothing, since no window's drag-out controller claims
it); new windows copy the size of a maximized or full-screen source
window instead of its restored size; View ▸ Enter Full Screen labels miss
external full-screen changes until the next toggle; every window has the
same title.
- **Next.** One PR per slice, in the order above. Route root-node actions
without main-root ambiguity; seed new windows from restored dimensions;
give windows distinct titles.
- **Gate.** Native VoiceOver enumeration and activation in two windows,
close/hide/reopen of focused windows, toolbar clicks, Finder promises,
Quick Look ownership and private-embedder SDK upgrades. STATUS records
Linux Xvfb/openbox drop-in/out verification; macOS and Windows were
compiled by CI but not exercised natively. Source routing tests and CI
builds are not native QA. See also X-26 (macOS accessibility gate).
- **Refs.** Effort M per slice. D39.

### UI-07 · P1 (feature) · Android file access and background transfers are incomplete
- **Problem.** Android is supported (D35) but has no SAF import/export, no
foreground ownership of the queue, and no Share or share-to-upload.
- **Next.** Separate slices: SAF imports/exports with retained grants,
foreground queue ownership, Share, share-to-upload. DocumentsProvider is a
later capability. Do not treat content URIs as stable paths or request
all-files access when grants suffice. Preserve explicit target choice and
cancellation.
- **Gate.** Real providers and devices, revoked grants, background and
process kill, notification policy, low storage and restart. iOS remains
explicitly unsupported until its own storage, signing, editing and
lifecycle gates pass.
- **Refs.** Effort L. D35. Idea: port Séance's Android `KeepAliveService`
(**STATUS #33**).

### P4-01 · P2 · Esc/Enter in the header filter strands keyboard focus
- **In review: [#224](https://github.com/L-K-M/Poltergeist/pull/224)** (with P4-02).
- **Problem.** Esc calls `widget.focusNode.unfocus()` (scope disposition)
and the field has no `onSubmitted` (`app: ui/workspace_shell.dart:4384-4391`,
`:4392-4430`); after Esc or Enter, arrows, Space and Enter are dead until
a click. VERIFIED (test).
- **Next.** `onReturnToListing` callback → `_focusPane(workspace.activePane)`
on Esc, submit and ↓; put the cursor on row 0 when none exists.
- **Gate.** `test/ui/shell/header_filter_test.dart`: after Esc, Enter
(`TextInputAction.done`) and ↓, `primaryFocus.debugLabel ==
'pane.left.listing'` and ArrowDown sets `cursorIndex`.

### P4-02 · P2 · Going up or back loses your place
- **In review: [#224](https://github.com/L-K-M/Poltergeist/pull/224)**.
- **Problem.** `goUp()`/`goBack()` navigate with no reveal target
(`app: services/pane_controller.dart:1207-1213`, `:1338-1347`) and
`_syncReveal` jumps to offset 0 (`app: ui/panes/pane_view.dart:348-367`).
VERIFIED (test: `goUp: path=/home cursor=null`).
- **Next.** `_revealAfterListing` set by `goUp` and applied in `_applyEntries`;
per-history-entry `(cursorPath, scrollOffset)` captured in
`_issueNavigation`; `_syncReveal` reveals the cursor (centred) or restores
the offset; re-list/refresh must not consume it.
- **Gate.** goUp selects the child; with 80 siblings its row is in the
viewport; goBack restores the prior cursor; refresh does not re-trigger.
- **Refs.** Idea: "where was I" folder memory.

### P4-03, P4-10, P4-11, P4-16 · P2/P3 · Listing keyboard pack
- **Problems.**
- **P4-03 (P2):** PageUp/PageDown do nothing (`app: ui/panes/pane_view.dart:530-540`
  owned keys, `:566-678` switch); 02 §2.5 requires them. KNOWN in STATUS
  M3 row-selection section ("untouched"), not an open item.
- **P4-10 (P3):** Backspace during a live type-ahead navigates up
  (`pane_view.dart:615-625`).
- **P4-11 (P3):** numpad Enter ignored (`pane_view.dart:530-540`, `:590-604`;
  only Retry uses it, `:546`; `go.open` activator `app: ui/panes/pane_commands.dart:276`);
  the sidebar kit accepts it (`sidebar_kit.dart:1534`).
- **P4-16 (P3):** Esc never deselects (02 §8.2's last tier;
  `pane_view.dart:735-743`); no Deselect All command.
- **Next.** PageUp/Down: `rows = max(1, floor(viewport / rowExtent) - 1)`,
`moveCursorBy(±rows, update: cursorUpdate)`, `_revealCursor()`.
`controller.typeAheadBackspace()` when a buffer is live. Treat
`numpadEnter` as `enter` and add it to `go.open`. Final Esc tier
`clearSelection()` (`pane_controller.dart:1666`); register
`edit.deselectAll` (⌥⌘A macOS, Ctrl+Shift+A elsewhere; avoid
Ctrl+Alt+letter per **STATUS #24**).
- **Gate.** One test per key: PageDown moves a viewport minus one and Shift
extends (a stale listing swallows it); `fi` + Backspace keeps the location
and badge reads `f`; numpadEnter opens a folder on Linux; ⌘A then Esc →
`selectedCount == 0`, with the filter-first tier order intact.
- **Refs.** Effort S-M together (~200 lines).

### P4-04 · P2 · Names truncate at the end, hiding suffixes and extensions
- **Problem.** `Text(name, overflow: ellipsis)` in rows
(`app: ui/panes/pane_view.dart:2918-2928`, `ui/compact/compact_listing.dart:630-638`);
`photo_…_41.jpeg` and `…_42.jpeg` look identical. `MiddleEllipsisText`
(~8 layouts per row) is too costly per rebuild. VERIFIED (screenshot).
- **Next.** `_TailKeepingName`: tail = extension plus up to 6 preceding
graphemes (or last 8 when no extension); render
`Row([Flexible(Text(head, ellipsis)), Text(tail)])`; row semantics
unchanged; use in `_PaneRow`, `_CompactRow` and tab chip titles.
- **Gate.** At 260 px, `photo_with_a_somewhat_long_file_name_41.jpeg` renders
its tail inside the row; a short name renders as one `Text`.
- **Refs.** Effort S-M.

### P4-07 · P2 · Dates and times are always `en` (US, 12 h)
- **Problem.** `DateFormat.jm/yMd(localeName)` where `localeName` can only be
`en` (`app: ui/panes/pane_format.dart:62`, `:74`, `:83`; callers
`pane_view.dart:2845`, `compact_listing.dart:580`, `pane_column_header.dart:59`,
`history_view.dart:153`, `conflict_widgets.dart:224`, `:236`);
`alwaysUse24HourFormat` never read. A Swiss user reads `3/4/2026` as
3 April. VERIFIED.
- **Next.** `formattingLocale(context)` from the platform locale when
`DateFormat.localeExists`, else `en`; honor
`MediaQuery.alwaysUse24HourFormatOf` (`Hm` over `jm`); static formatter
cache keyed by `(locale, use24h)` (also P4-15). UI strings stay English
(D20).
- **Gate.** `de_CH` + 24 h → `14.03.2026 09:26`; `en_GB` → `14/03/2026 09:26`;
widget test with `platformDispatcher.localesTestValue`.
- **Refs.** Effort S-M.

### P4-05 · P2 · Inspector overlay covers pane B by default
- **Problem.** `inspectorOverlay = inspectorWanted && !inspectorInline`
(`app: ui/workspace_shell.dart:1872-1884`) renders an elevated sheet with
no barrier (`:1978-1990`); inline needs ≥ 1053 px content, so half-screen
and 1024 px windows and 800 dp tablets lose 280 px of pane B. VERIFIED.
- **Next.** Transient `_overlayRequested`, never persisted (10 §3.2); the
overlay stage shows the sheet only when requested (toggle, transfers,
alerts); outside tap and Esc dismiss; inline stage follows persisted
intent. Small product decision: confirm with the owner that the overlay
stage starts hidden (D32).
- **Gate.** `shell_stages_test.dart` at 1000x800: no overlay at launch;
toggle shows it; tapping pane B hides it; widening to 1400 shows inline.
- **Refs.** Effort S-M.

### P4-08 · P2 · Weak keyboard focus indicator on InkWell controls
- **Problem.** `focusColor: primary.withValues(alpha: 0.18)`
(`app: theme/app_theme.dart:770`) is ~1.3:1 on the header; toolbar
buttons (`shell/header_toolbar.dart:411`), tab chips
(`panes/pane_tabs_view.dart:839`), column headers
(`panes/pane_column_header.dart:285`), inspector tabs
(`inspector/inspector_view.dart:191`) and the ☰ button rely on it alone;
the sidebar kit draws a real ring (`sidebar_kit.dart:1320`, `:1675`).
Fails WCAG 2.4.7 / 1.4.11.
- **Next.** Lift the kit's ring into `app: ui/shell/focus_ring.dart`
(highlight-mode aware, 2 px `primary`, control radius) and wrap the five
controls; add primary vs header/strip/inspector ≥ 3:1 to
`contrast_matrix_test`.
- **Gate.** Tab to New Folder: a 2 px border decorates `command.file.newFolder`;
after a pointer click, no ring.
- **Refs.** Effort S-M. D20. STATUS #32 (screen-reader QA is manual).

### P4-06, P4-09 · P2/P3 · Back navigation on every input
- **Problems.**
- **P4-06 (P2):** the non-compact posture on Android tablets (≥ 600 dp) has
  no `PopScope` (`app: ui/workspace_shell.dart:1768-1828`;
  `compact/compact_posture.dart:17-20`), so system back finishes the app
  from anywhere and live sessions die. Android is supported (D35).
- **P4-09 (P3):** no mouse back/forward buttons (no `kBackMouseButton`
  anywhere; pane listener `app: ui/panes/pane_view.dart:1163-1184`).
- **Next.** Extract the phone's order into a pure `nextTouchBackStep(...)`
(close inspector overlay → close filter/Quick Select/path field → pane
`goBack()` → leave) and wrap the tablet body in `PopScope`. In the pane
listener, `kBackMouseButton` → `goBack()`, forward likewise, before focus
handling.
- **Gate.** Android override at 1200x900: `handlePopRoute()` returns true and
goes to the parent; false at root. Synthetic back button press goes back
and leaves selection unchanged.
- **Refs.** Effort S. **STATUS #33** (predictive back unverified on device).

### P4-12 · P3 · Sync plan table: no reveal, no paging
- **Problem.** Arrow keys only `setState` the focused row
(`app: ui/sync/sync_plan_view.dart:246-281`); the table's `ListView.builder`
has no controller (`sync_plan_table.dart:184`). Past row ~30 the focus
ring leaves the screen and Space toggles an unseen row, changing the run.
- **Next.** Own a `ScrollController`; fixed extents (`chrome.rowExtent`
`:524`, headers 28 px `:320`) give the offset; `jumpTo` minimally; add
Home/End/PageUp/PageDown; foreground focus decoration (`:533`).
- **Gate.** 200 items, ↓ 60 times: focused row inside the viewport.
- **Refs.** Effort S-M. Coordinate with P4-14's scaled extents.

### P4-13 · P3 · Type-ahead badge covers the revealed row
- **Problem.** Badge at `bottom: 8` (`app: ui/panes/pane_view.dart:1676-1684`);
`_revealCursor` scrolls minimally (`:369-389`), so a below-fold match
lands under it.
- **Next.** `bottomInset` (badge height + 16) on the type-ahead reveal, or
centre the match, or pin the badge to the header.
- **Gate.** Type-ahead to row 60 of 63: row rect does not intersect
`ValueKey('pane.typeAhead')`.
- **Refs.** Effort S.

### P4-14 · P3 · Large text scale layout gaps
- **Problem.** At 2x the date floor `scale(116)` beats the 0.35 share cap
(`app: ui/panes/pane_column_header.dart:32-45`), starving names; the
rename editor width can clamp to 0 (`pane_view.dart:1823`, `:1876`,
clamp `:2112`); Info labels use a fixed 86 px column
(`panes/info_panel.dart:915`, `:927`); sync rows, headers and column header
are fixed 22/28/24 px (`sync/sync_plan_table.dart:524`, `:320`, `:258`);
header filter 28 px and tab strip 30 px are fixed.
- **Next.** Guarantee a name minimum (`scale(140)`) with a compact-date
fallback before dropping the column; `scale(86)` or an intrinsic `Table`
for Info labels; scale sync extents with `MediaQuery.textScalerOf`.
- **Gate.** `PaneColumnMetrics.forWidth(390, TextScaler.linear(2))` leaves
≥ 140 px for the name; Info label is one line at 1.5x.
- **Refs.** Effort M. D20. Chrome heights (breadcrumbs, tabs, auth dialogs)
are UI-08, merged with UI-04/UI-09.

### P4-17 · P3 · No F10 for the ☰ menu; no region cycle
- **Problem.** `AppMainMenuButton` has no activator
(`app: ui/menus/app_menu_host.dart:398-462`; pane passes F10 through,
`pane_view.dart:642-647`); `view.cycleRegion` (Ctrl+F6, 02 §8.2/§8.3) is
not registered.
- **Next.** Expose the ☰ `MenuController`; `app.openMainMenu` on F10
(Linux/Windows) focusing the first submenu; `view.cycleRegion`/reverse over
sidebar, left listing, right listing, inspector switcher, splitters,
skipping unmounted.
- **Gate.** F10 opens the menu on File; Ctrl+F6 cycles left → right →
inspector.
- **Refs.** Effort S-M. D21 (registry). Mind STATUS #24.

### P4-18 · P3 · Drag-and-drop polish
- **Problem.** No edge auto-scroll (`app: ui/panes/pane_drop_area.dart:200-265`);
avatar shows generic file icons even for folders (`:564`, `:569`); count
badge is a circle with padding, so `128` overflows (`:639`).
- **Next.** 28 px edge zone with a 16 ms periodic `jumpTo` proportional to
depth, cancelled on leave/drop; `kindGlyph(paneKindCategory(...))` with the
family hue (D34) for single items; `StadiumBorder` badge.
- **Gate.** Hovering the bottom edge for 500 ms scrolls (`offset > 0`).
- **Refs.** Effort S-M.

### P4-19 · P3 · Tab chips steal horizontal swipes on touch
- **Problem.** `Draggable<PaneTab>` with no affinity on every platform
(`app: ui/panes/pane_tabs_view.dart:865-874`) inside a horizontal scroller
(`:474-476`); rows already skip `Draggable` on touch
(`pane_view.dart:1924-1931`). LIKELY.
- **Next.** `LongPressDraggable` or `affinity: Axis.vertical` on touch.
- **Gate.** Android override, fling a chip in a 10-tab strip: offset changes,
no `_TabDragAvatar`.
- **Refs.** Effort S.

### P4-20 · P3 · Inactive selection nearly invisible in custom presets
- **Problem.** `inactiveSelectionFill: n.containerHighest`
(`app: theme/app_theme.dart:573`, mix `:259-261`) measures 1.16:1
(Solarized) to 1.49:1 (default dark) against the surface.
- **Next.** Mix from surface toward text until contrast ≥ 1.3 (cap 0.25).
- **Gate.** `theme_build_test` over `ThemePresets.all` × both brightnesses:
≥ 1.25, and text on it ≥ 4.5:1.
- **Refs.** Effort S. D38; keep the first preset drawing its pre-theme look
(the first preset, Poltergeist, is all Automatic; new devices start in
Vapor since #215, so cover Vapor explicitly). Related: UI-11/UI-13.

### P4-21 · P2 · Daily features a Transmit/ForkLift user will miss
- **Problem.** KNOWN deferrals, recorded only in dated STATUS sections: file
Copy/Cut/Paste and Undo/Redo (02 §2.6/§8.3; STATUS "D32 adversarial
review fixes → Deferred"; no `edit.copy`/`edit.paste`/`edit.undo` in
`lib/`); optional Kind/Permissions/Owner/Group columns (C25) and column
resize; within-strip tab reorder (`pane_tabs_view.dart:376-377`); launcher
recents/server grid (C18); `tab.select1-9`.
- **Next (clipboard first slice).** App-internal `FileClipboard`
(`ChangeNotifier`: source `FsLocation`, root paths, copy|move);
`edit.copy`/`edit.cut` snapshot the selection (reuse `PaneEntryDrag`);
`edit.paste` enqueues via `PaneDropDelegate` so conflict and safety rules
apply; Edit-menu and context-menu rows. OS clipboard interop later. Check
07 §3.13 ordering before starting; none of these are in the D25 parking lot.
- **Gate.** Copy in pane A, paste in pane B enqueues the same task a drag
would; cut + paste is a move; paste with an empty clipboard is disabled.
- **Refs.** Effort M per feature. The D28 chown UI is separate (**STATUS #30**).

### UI-06 · P1/P2 · Phones name the destination as "B" while B is hidden
- **Problem.** `app: ui/compact/compact_selection_bar.dart` says Copy/Move
to B while pane B is not visible.
- **Next.** Show the host and folder from the command's target snapshot,
with an inspect/change action. Make unavailable targets actionable and
preserve full identity in semantics.
- **Gate.** Destination changes, reconnect/tab closure, long paths, 2x
text/RTL and queued transfers. The visible and the actually queued target
must match at activation.
- **Refs.** Effort S-M. Idea: ghost landing preview.

### UI-01a · P2 · Delete confirmation shows a spinner for a settled preparation error
- **Problem.** Residual of merged #210 (UI-01), which fixed the route
lifetime. The preparation-error view still shows an indeterminate counting
spinner when `_confirmation` is null.
- **Next.** Replace it with a settled error state and explicit Retry/Cancel
actions; a retry uses a fresh cancellable count and cannot dismiss a newer
route.
- **Gate.** Failed preparation stops announcing progress; retry succeeds or
fails clearly; dismiss/retry races keep #210's idempotent completion.
- **Refs.** Effort S.

### UI-04 / UI-08 / UI-09 · P2 · Bounded accessible notices, scaled chrome and private editing
- **Problem.** Both toast stacks are unbounded, unannounced and expire even
when their action is hard to reach (UI-04). Scaled text must drive chrome
height, not just row height (UI-08; overlaps P4-14). Remote text editors do
not request IME learning suppression (UI-09).
- **Next.** Port a bounded toast policy to both apps: visible limit,
overflow/history, live announcements, contrast-aware text and persistent
actionable safety notices; respect focus, accessible navigation and
reduced motion; keep toasts above the terminal prompt (Séance). Let the
text scaler drive breadcrumbs, tabs and auth dialogs (with P4-14). Disable
IME personalized learning for remote editor and search fields, preserving
composition and undo; it is a privacy hint, not OS isolation.
- **Gate.** 20 notices at 320x568 with 2x text and no overflow; one-shot
actions and native announcements; scaled breadcrumbs/tabs/auth dialogs;
keyboard-open layouts; no global clamp of the user's font scale.
- **Refs.** Effort M. D20. Idea: quiet motion.

### UI-11 / UI-13 · P2 · Theme editing, endpoint identity and useful inspectors
- **Problem.** Themes ship, and new devices and Reset now start in Vapor
(#215; `app: theme/theme_presets.dart` `initial`). Usable partial themes
still fill gaps from Poltergeist/Automatic, the palette every Automatic
slot belongs to. Missing: resolved contrast diagnostics, recoverable
preview/undo, and reliable keyboard discovery of the existing Reset for an
unreadable live palette (UI-13). The empty and multi-selection inspector
says little (UI-11). The narrow comfortable sidebar exposes little
endpoint detail.
- **Next.** Preserve saved choices and the partial-theme distinction. Add
contrast diagnostics and preview/undo; verify theme copy/paste with Séance,
unknown terminal fields, partial malformed values, selections and status
shapes. Make the empty/multi-selection inspector summarize selection,
destination and next action from existing data, with no remote I/O merely
from painting. Audit sidebar tooltips and semantics, then make full
user/host/port identity readily discoverable without widening every row.
- **Gate.** Extreme palettes, all presets, both settings engines, failed
persistence, single/multiple/no selection and a narrow inspector. Preserve
the shared semantic glyph hues, quiet surfaces and explicit server colors.
Sidebar: long labels, identical hosts with different users/ports, keyboard
access and an explicit reveal affordance.
- **Refs.** Effort M. D38, D34. Related: P4-20 (inactive selection
contrast), P4-05 (inspector overlay).

---

## 5. Performance

All UI-isolate items are D8 / rule 7 work. STATUS #23's residual (re-measure
the D8 gates under the bridged lease) and #31 (tier-B arming) govern how
budgets are enforced; add new benches under `packages/poltergeist_bench` or
`test/benchmarks`.

### SR-08 · P1 · Current-main P4 tab-switch regression
- **Problem.** The documentation-only main commit `0dd681d7` reproduced a P4
median of 86.267 ms, then 78.331 ms on the automatic retry, against a
40.004 ms baseline: +115.6% and +95.8%; the enforced +25% ceiling is
50.005 ms. The controlled/runtime axes, CPU and scenario config matched,
otherwise the checker would have skipped comparison; unrecorded load and
graphics conditions still need control in reproduction. P1/P2 and tier A
passed; unlanded P6 emitted error rows and supplies no passing P6
evidence. See the
[measured run](https://github.com/L-K-M/Poltergeist/actions/runs/36242878558/job/108407478002).
That source excluded #211's backup changes; the failure also prevents a
clean-run reset of the historical CPU-drift streak (SR-07). Not re-measured
at `b955213`. P4 measures from issuing `activateTab()` to `rasterFinish` of
the first frame whose build starts at or after the issue time. Five
preloaded tabs share a 10,000-empty-file local listing; the harness warms
every tab before recording five target activations.
- **Next.** Start at
`app/poltergeist_app/integration_test/perf/p4_tab_switch_test.dart`, its
`bench_harness.dart`, `scripts/bench-tier-b.sh` and the production
`PaneTabsController`/`PaneTabsView` activation path. Reproduce in the
pinned Linux profile harness, retain per-repetition artifacts and phase
timings, compare known-good and current source on the same
fingerprint/config, then bisect without attributing the slowdown from
commit titles. Isolate avoidable model/build/layout/raster work before
changing code. Do not simply rebaseline it.
- **Gate.** Repeated medians at or below the real enforced ceiling,
unchanged fixture scope and fingerprint, surrounding tab/lifecycle
correctness tests, and no reduced benchmark workload or relaxed threshold.
Native interactive frame pacing needs separate confirmation.
- **Refs.** Effort M. D12, D8.

### P2-08 · P2 · Local commits are O(N²) per directory; every file spawns `chmod`
- **Problem.** `replaceLocalFile` lists the whole directory to restore
orphaned backups whenever the target is absent (the common case)
(`core: fs/local_fs_safety.dart:268-290`, list `:403-427`); `Process.run('chmod')`
per file (`core: fs/local_file_system.dart:681-688`, `:859-866`; queue
passes source mode `transfer_queue.dart:2805`, `:2826`). Measured 2.7 →
5.7 ms/file from 500 to 4k files; +9 ms per chmod. VERIFIED.
- **Next.** Probe only `<target>.poltergeist-<8hex>.backup` names, or sweep
once per directory per task (cache a `Set<dirPath>`), or only at restore.
Skip chmod when the mode already matches, or FFI `fchmod` (shared with
P1-05).
- **Gate.** Unit test counting `list` calls through a seam: none per commit;
a bench in `packages/poltergeist_core/benchmark/`.
- **Refs.** Effort S.

### P3-02 · P2 · Full listings persisted in settings.json and re-encoded on the UI isolate
- **Problem.** `captureSessionTab` persists `_sortedListing` uncapped
(`app: services/pane_controller.dart:2835-2861`, `session_state.dart:89-91`);
workspaces snapshot listings too (`pane_tabs_controller.dart:491-503`);
every notify triggers capture + full `jsonEncode` for dedupe
(`session_persistence.dart:128-155`); any setting write re-encodes the map
(`settings_store.dart:143-145`). 50k-entry tab: 6.9 MB `settings.json`,
82 ms per cursor pause, 291 ms per unrelated setting. Remote names from
every server sit in plaintext in settings and workspaces (privacy).
- **Next.** Step 1 (S): cap remote tabs at `kSessionListingCap` (≈200) with
`listingTotal`/`listingTruncated`, none for local tabs, none in
workspaces (optional on decode). Step 2 (M): sidecar
`session-cache/<paneTabId>.json` via `writeStringAtomically`, and a
persisted-state revision bumped only on location/tab/listing change so
selection-only notifies skip capture.
- **Gate.** 5k-row remote tab persists ≤ cap with `listingTotal: 5000`;
local tab persists none; workspace round trip without listings; a
cursor-only change never calls `captureSessionTab` (spy strip).
- **Refs.** Effort S then M. Idea: viewport-exact restore.

### P3-03 · P2 · Filter keystrokes redo O(n) folds and keys (~300 ms at 100k)
- **Problem.** `_applyEntries` eagerly folds every visible row and rebuilds
keys and the row-key map (`app: services/pane_controller.dart:3749-3784`,
`:3768-3773`) on each `setFilterQuery` (`:2911-2916`), hidden toggle and
sort (`:1727-1781`); sorts run on the UI isolate (`:4157-4175`, `:3659`).
Filter keystrokes 268-321 ms, sort 355 ms at 100k (JIT); 02 §12 targets
100k-row listings. **STATUS #15** covers Quick Select folding only.
- **Next.** Lazy `_foldedNames` (build on first type-ahead); row keys once
per accepted listing, projected through lenses; ASCII fast path in
`typeAheadFold`; `Isolate.run` sorts above ~20k rows behind the
generation check.
- **Gate.** `typeAheadFold` not invoked during `setFilterQuery` (counter);
tier-B micro-bench "filter keystroke at 100k < 50 ms (release)".
- **Refs.** Effort M. Idea: ASCII fast lane.

### P2-13 · P2 · UI-isolate stalls in the queue and sync engine
- **Problem and next, per item** (each S, each independent):
- `_removeMovedDirectories` × `_subtreeFullyCompleted` is O(dirs × items)
  (`core: transfer/transfer_queue.dart:3645-3706`): compute completeness in
  one pass via the containerKey chain.
- `canRetryTask` → `items.any(canRetryItem)` with O(n) `_itemOf` and
  O(files) `_retryWork` (`:3991-4029`) called from row `build`
  (`app: .../activity_rows.dart:433`): index `itemId → work`.
- `_normalizeRoots` O(n²), 2-3× per delete (`:5062-5099`): sort, compare
  with the previous kept root.
- `lastAttempt` scans all item lines per item (`sync: journal.dart:292-303`):
  keep a map.
- `_matchKey` (pure-Dart NFC) recomputed ~5× per path, again in
  `_hazardMap` (`sync: diff.dart`): memoize.
- The `copy_file_range` chunking is P1-07.
- **Gate.** Complexity guards in the bench package (e.g. 50k synthetic items
under a time budget per bullet).
- **Refs.** Effort M total. Sync executor runs on the UI isolate
(`app: services/sync_plan_controller.dart:1284`).

### P1-07 · P2 · `copy_file_range` pump blocks the UI isolate in 16 MiB syscalls
- **Problem.** Synchronous FFI `open`/`copy_file_range` in 16 MiB chunks
(`core: fs/local_copy_pump.dart:42`, `:153-240`) on the UI isolate
(`app: services/transfer_queue_session.dart:160`; D8 addendum). ~160 ms
per chunk on HDD/USB; a stalled NFS/SMB mount hangs the app. The M9
measurement hid it (page cache).
- **Next.** (a) Run the pump in a worker isolate with progress and cancel
over ports (removes the hung-mount freeze), or (b) minimum: adaptive
chunking targeting ≤ 4 ms per syscall (start 1 MiB, floor 64 KiB).
- **Gate.** Injectable timing seam with a fake proportional syscall: no
synchronous section over budget (b), or the work runs off the calling
isolate (a).
- **Refs.** Effort M (a) / S (b). STATUS #23 residual (D8 re-measure).
Idea: off-isolate copy with live throughput. PGE-08 is the
bridge-wide measurement this belongs to.

### PGE-08 / PG-REV-009 / UI-10 · P2 · Benchmark the shipped bridge and the large editor
- **Problem.** D8's current queue and local hashing run on the UI isolate;
remote-to-remote bytes cross twice. Linux `copy_file_range` is synchronous
despite async callers (the deep review's P1-07 measures the stall). The
M0/D12 budgets were not measured on the actual bridge and slow volumes.
The large editor (UI-10): with 4 MiB inputs, giant lines and Unicode,
status byte/line scans and text layout remain after syntax highlighting
disables itself.
- **Next.** Measure M0/D12 budgets on the actual bridge and slow volumes,
then move local pumps and queue execution to workers if needed (P1-07's
option (a)). Keep bounded messages and durability. Profile the editor and
optimize measured hot paths, not a speculative renderer replacement.
- **Gate.** Frame/input percentiles, cancel latency, memory and throughput
under six transfers, hash mode and large listings; editor typing, search
and save correctness, BOM/line endings, and modest Android hardware.
- **Refs.** Effort M-L. D8, D12, **STATUS #23** residual.

### P3-10, P4-15 · P3 · Broad rebuilds on every pane notification and progress tick
- **Problems.**
- **P3-10:** every per-chunk `TransferQueueProgressEvent` (no throttle,
  `core: transfer/transfer_queue.dart:3054-3075`) runs O(tasks) work and
  `notifyListeners()` in `ActivityPanelController`
  (`app: services/activity_panel_controller.dart:372-385`); `AlertCenter`
  re-collects everything (`alert_center.dart:159-184`); the inspector
  rebuilds its whole column at frame rate (`ui/inspector/inspector_view.dart:85-96`).
  Contradicts 02 §12. LIKELY.
- **P4-15:** one pane notify rebuilt 46 rows, 8 toolbar buttons, 9
  `EditableText`, the Info tab and the menu host (measured with
  `debugOnRebuildDirtyWidget`). Sources: `enablement` merges both strips
  and `_activity` (`app: ui/workspace_shell.dart:1744-1753`, strip
  forwarding `pane_tabs_controller.dart:921`); header re-measures labels
  (`shell/header_toolbar.dart:190-248`); ☰ tree rebuilt closed
  (`menus/app_menu_host.dart:413-462`); `_HeaderFilterField._syncText`
  `setState` per notify (`workspace_shell.dart:4356-4365`); two
  `DateFormat`s per row (`pane_format.dart:62-86`, ~14 µs vs 0.6 µs
  cached); 3 `TextPainter`s per rebuild (`pane_view.dart:1428-1433`);
  O(n) `selectedEntries` per selected row (`:1937-1940`, `:2535-2542`);
  context-menu rows built while closed (`:1190`).
- **Next.** Split the activity controller into a structural notifier and a
~10 Hz progress `ValueListenable`; `AlertCenter` on structural only; prune
at task removal. `PaneController.commandStateKey` as a `ValueListenable`
for `enablement`; derived `({int live, bool paused})` for activity;
`_HeaderFilterField` sets state only on real changes; memoize formatters
(P4-07) and `modifiedWidthIn`; compute `selectedEntries` once per build;
build context-menu children only while open.
- **Gate.** 1,000 progress events: structural listener 0 times, tick ≤ 10/s
(fake clock). Rebuild-count test: a cursor move rebuilds no
`_ToolbarButton`/`AppMainMenuButton`.
- **Refs.** Effort M (each part S). Idea: per-task sparkline.

### P1-11 · P3 · Local `listDirectory` stats serially
- **Problem.** `await FileStat.stat` per entry
(`core: fs/local_file_system.dart:136-160`): 20k entries 1,176 ms vs
418 ms with a 64-wide window; 100k ≈ 6 s before first paint.
- **Next.** Stat in bounded `Future.wait` windows (~64), keep `followLinks:
false`; no `statSync` on the engine isolate (hung mounts).
- **Gate.** Order and contents unchanged; `benchmark/p3_listing_overhead.dart`.
- **Refs.** Effort S.

---

## 6. Cross-app: Séance, the shared account, and the pin

### BOTH-REV-006 / SOL-011 · P0 (upstream) · Version authenticated account envelopes
- **Problem.** Upstream Séance owns `RecordCodec`. Kind and data are
sealed; ID, time, device and deleted are not, and deletion blobs are
empty. Poltergeist's existing pin conflict quarantine stays, but it does
not authenticate the whole envelope; do not claim it does.
- **Next.** Upstream: specify canonical client-authenticated identity,
purpose, revision, epoch and typed deletion; the server sequence stays
outside. Add compatibility readers, an old-client policy and
migration/rollback fixtures before new writers. Coordinate opaque wire
IDs, durable revision history and replay protection in the same
migration. Poltergeist ships S1-02-P first so its kept pins stay valid.
Never fork shared crypto locally (rules 3 and 9).
- **Gate.** Field tamper, transplant, replay with winning metadata, forged
tombstones, old/new sibling interoperability and interrupted migration.
- **Refs.** Effort L (upstream). D18, D2. Related: S1-02-P, X-03, S1-03-P.

### X-02, X-05 · P1 · Editor drops `jumpHostId`; jump routes dialed directly
- **In review: #223** (https://github.com/L-K-M/Poltergeist/pull/223).
- **Fix in #223.** `_formConfig` keeps `jumpHostId`
(`app: ui/server_editor.dart:1048-1087`); `refuseJumpHostRoute` refuses
jump-routed configs before pane connect, every bridged lease and Test
connection; the sidebar stops probing them.
- **Residuals.** X-03 (below); P1-02a (retry/duplicate/Home/reopen on SERVERS
panes); **X-05a (P3):** no catalog-row badge for jump-routed servers.
Next: reuse the D22 chip style on catalog rows. Gate: widget test shows the
badge for a config with `jumpHostId`. Remove the guard and badge when the
pin executes jump hosts (X-25, D10).

### X-03 · P1 · `ServerConfig` discards unknown JSON keys
- **Problem.** `toJson`/`fromJson` handle only known fields
(`seance: packages/seance_protocol/lib/src/models/server_config.dart:327-360`,
`:362-400`). Poltergeist writes the shared catalog through a pin that
lags Séance, so any Poltergeist edit strips newer Séance fields and wins
LWW fleet-wide. Latent: no such key exists yet (`seance_protocol/lib`
unchanged since v0.9.1).
- **Next.** Upstream in `seance_protocol`: capture unknown keys (and raw
values of rejected enum names) in `fromJson`, merge in `toJson`, carry
through `copyWith`; same for `Bookmark` and `Snippet`. Then re-pin (X-25).
A Poltergeist-side shim would fork protocol behavior (rule 9, D2).
- **Gate (upstream).** Decode with extra keys → `copyWith(label:)` →
`toJson`: extras survive byte-identical. In Poltergeist after re-pin: an
editor save round-trips an unknown key.
- **Refs.** Effort M. Pairs with X-20 (Séance POLTERGEIST.md) and the
"protocol hygiene" idea.

### X-01 · P1 · A reopened managed checkout is not refreshed
- **Problem.** `checkout()` returns the existing record with no remote stat
(`core: checkout/checkout_manager.dart:214-226`; callers
`app: ui/workspace_shell.dart:2708`, `:2854`). Stale content loads
silently; the conflict dialog's Overwrite (`:3130-3165`) can then replace
newer server content. Séance #105 fixed this
(`seance main: app/seance_app/lib/services/remote_files_controller.dart:688-756`);
PORTS' M10 sweep wrongly called it "complementary; no port edit".
VERIFIED.
- **Next.** When a live record exists: `reconcile(id)`, lease and `stat`;
notFound → record it, return local; clean + moved snapshot → re-download
via `enqueueManagedCheckout` (keeps CAS and journal rails); dirty →
return it with `remoteChanged`; show "Server copy changed: Reload / Keep
mine" in `built_in_text_editor.dart`. Record the reversed M10 disposition
in PORTS. No silent upload (rule 6).
- **Gate.** `checkout_manager_test.dart`: clean refresh, dirty kept and
flagged, unreachable server returns local, dedupe flight unchanged.
- **Refs.** Effort M.

### X-04, X-25 · P1 (on Séance tag) · Re-pin to a Séance tag containing #131
- **Problem.** Séance main (#131, untagged) defaults new and keyless-imported
servers to ssh-agent (`seance main: app/seance_app/lib/ui/server_editor.dart:287`,
`packages/seance_core/lib/src/ssh_config/ssh_config_import.dart:35`); the
v0.9.1 opener throws `AgentAuthUnsupportedError`
(`seance: ssh_session.dart:542-555`), and `prompt_coordinator.dart:205-221`
answers agent prompts silently, so every such server fails in Poltergeist
once Séance tags. The re-pin is breaking: `KeyboardInteractiveResponder`
now takes a `KeyboardInteractiveChallenge` (used at
`core: poltergeist_core.dart:41`, `connection/reconnect.dart:317`,
`ssh_transport.dart:105`, `:252`, `connection_manager.dart:211`);
`AgentAuthUnsupportedError` removed; `openAuthenticatedClient` gained
`resolveJumpHost`, `forward`, `loadAgentIdentities`; `ffi: ^2.1.0` needs the
license gate re-run. Wire and record kinds unchanged.
- **Next.** Interim (S): on `AgentAuthUnsupportedError`, open the credential
dialog with "This server uses ssh-agent, which this build can't use yet".
Re-pin (M), coordinated with Séance tagging (ask Séance not to tag the
agent default before one path is ready): adapt the responder (feed the
challenge's `server` into the trusted-endpoint line); supply a
catalog-backed `SshJumpHostResolver`; flip the editor default to agent and
drop the warning (`app: ui/server_editor.dart:340-343`, `:667`); delete
`sshImportLimitProxyJump` once import maps ProxyJump; remove #223's guard;
re-run the pin audit and license gate. Also inherited at the re-pin:
Séance #138's upload fix (S2-02 below); its extra `fsetstat` for non-0666
modes may need `setStat` in Poltergeist's transfer fakes.
- **SSH capability adoption audit (sibling review).** Séance now supports
agent auth and saved-host jump chains; the older package pin and
Poltergeist's bindings need deliberate adoption, not another transport
fork. Audit signer lifetime, resolver capabilities, pool keys, every-hop
TOFU (S2-14, P1-04), interactive prompt serialization and unsupported
mobile behavior. Gate: real Unix/Windows agent, unavailable agent, chained
auth/cancel/reconnect, strict changed-key block at each hop, sftp-only
chroot and import warnings.
- **Gate.** Interim: an `AgentAuthUnsupportedError` connect shows the
credential dialog. Re-pin: the pin audit matches PORTS; an agent config
connects against the sshd fixture with a test agent; a jump-routed config
connects through a bastion fixture.
- **Refs.** D10 (first fast-follow, 07 §3.13), D2, **STATUS #2/#25** (pin
history). Idea: downstream canary in Séance CI.

### S1-02-P · P1 · `keepLocalPin` writes an envelope newer than its payload
- **Problem.** `keepLocalPin` seals `updatedAt: now` beside
`data: local.toJson()`, which carries the old `pinnedAt`
(`core: bookmarks/bookmark_coordinator.dart:475-499`). Séance's planned
S1-02 mitigation (reject records whose envelope stamp is boosted past the
payload stamp, to stop replayed old host-key blobs) would then skip
Poltergeist's legitimate kept pins. Poltergeist must ship first.
- **Next.** Seal `local.copyWith(pinnedAt: stamp)` (or a new `HostKey` with
that stamp) so envelope and payload agree. No crypto change (rule 3).
- **Gate.** `bookmark_coordinator_test`: after `keepLocalPin`, the sealed
record's `updatedAt` equals the payload's `pinnedAt`.
- **Refs.** Effort S. Then Séance S1-02 can land.

### S1-03-P · P1 · Persisted cursor goes deaf after a server-side regression
- **Problem.** Poltergeist persists its sync cursor; after "Delete backup
account…" plus re-creation under the same username, or a restored server
DB, the server answers `since > latestSeq` with an empty list and devices
skip every new record. `SyncCursorRejectedException`
(`core: sync/persistent_record_store.dart:54-61`) is caught in
`bookmark_coordinator.dart:904-913` but nothing throws it (the transport is
a bare `HttpSyncClient`). Reproduced in Séance's slice.
- **Next.** Upstream (Séance S1-03): server 409 `cursor_ahead`; move the
exception into `seance_core` with the 409 mapping; engine resets on it or
when `latestSeq < since`. Poltergeist switches its import to the core type
at the re-pin; its catch path then works. Interim option in Poltergeist:
treat `resp.latestSeq < since` in the persistent store's pull wrapper as a
cursor rejection.
- **Gate.** Delete, re-register and push: a persistent-cursor client still
receives the new records (integration over the sync-server leg).
- **Refs.** Effort S (Poltergeist) after upstream M.

### PG-REV-004 · P1 · Record store publishes state in memory before it persists
- **Problem.** `PersistentLocalRecordStore._mutate`
(`core: sync/persistent_record_store.dart`) changes live state before
`_write`, then heals its tail on failure. A failed cursor or tombstone
write can appear committed to later readers.
- **Next.** Stage the next state and publish after persistence, or define a
recoverable rollback/reload policy. Consider failures after rename
separately. Domain changes and the backup outbox still span separate
files: plan a transactional store if cross-file crash consistency is
required.
- **Gate.** Inject failures into every record/cursor/displaced-winner
mutation and immediately perform another read/write; memory and reopened
state obey the declared contract.
- **Refs.** Effort S-M. Related: S1-03-P (same store).

### PG-REV-002 · P1 · Backup pushes are not batched
- **Problem.** `BookmarkCoordinator.runRound`
(`core: bookmarks/bookmark_coordinator.dart:756`) pushes all dirty
records at once; current upstream Séance uses advertised limits and
`batchForPush`.
- **Next.** Audit the pinned dependencies, bump them with the port audit
(X-25), and consume the shared batcher in this coordinator. Preserve
exact-record settlement (#211) and accepted batches after a later failure.
- **Gate.** Record and byte caps, advertised custom limits, old-server
fallback, interruption between batches, an oversized single record and
real HTTP server convergence.
- **Refs.** Effort S-M after the re-pin.

### BOTH-REV-005 · P1 · Account activation is not one recoverable operation
- **Problem.** The staged vault re-key already exists. The account URL,
token, settings, key generation and sync-ledger transition around it are
not journaled together.
- **Next.** Journal enrollment activation, block sync while unresolved, and
retain the old usable state until the replacement is validated. Empty
accounts need explicit key confirmation.
- **Gate.** Failure/restart at every persistence boundary, locked or
missing key, old/new account rollback and orphaned local secrets. Never
upload under mixed account/key state or synthesize a fresh master key over
existing ciphertext.
- **Refs.** Effort M. Shared with Séance.

### SR-05 · P1/P2 · Remote-HTTP account policy
- **Problem.** Credentials and bearer tokens are not protected by record
encryption over cleartext HTTP.
- **Next.** Specify a policy for remote HTTP account URLs, allowing explicit
loopback and tunnel use where intended.
- **Gate.** Redirects, IPv6 and reverse-proxy base paths.
- **Refs.** Effort S-M. Coordinate with Séance.

### Inherited from the pinned `seance_core` (fix upstream, pick up at a re-pin)
These Séance findings live in shared core code that Poltergeist's
transfers and connections use. Evidence is from the Séance slice at Séance
`dd7e105`; S2-04 onward have table rows only and need their evidence
re-traced. Do not patch locally (rule 9).

| ID | Pri | Finding (Séance review) | Poltergeist relevance |
|---|---|---|---|
| S2-02 | P1 | Upload "Replace" over a symlink replaced the link with a 0777 regular file; type bits sent | Fixed in Séance #138 (merged); arrives with X-25. Residuals from #138: temp readable before `fsetstat` (dartssh2 open has no attrs), uid/gid not preserved on replace, kept setuid/setgid moves to uploader identity, link planted between second preflight and rename (no SFTP compare-and-rename). |
| S2-06 | P2 | `_cancelWhenRequested` adds a listener per chunk to a never-completing future | Bulk transfers use the same adapter. |
| S2-07 | P2 | Exec, shell and channel-open requests have no deadline; dartssh2 never fails them on transport close | SFTP channel opens can hang a lease. |
| S2-09 | P2 | Upload temp world-readable while staging; replace drops uid/gid | Every upload. |
| S2-14 | P2 | TOFU pins keyed by bare `host:port` collide across jump routes | Relevant once jump hosts execute (X-25); design with P1-04. |
| S2-15 | P2 | Upload throughput capped at one local chunk per round trip | Upload throughput; D8 gates. |
| S2-17 | P3 | Host-key algorithm preference ignores the pinned key type (false "changed") | Same opener. |
| S2-19 | P3 | SFTP listing does not validate server-supplied names (`/`, `..`, NUL) | Pane listings and the walker; relate to STATUS #13 raw names. |
| S2-22 | P3 | Weak default algorithms (dh-group1-sha1, hmac-md5, ssh-rsa/SHA-1, CBC); no strict-KEX | Same opener. |

Further upstream Séance tasks named by the sibling review, owned by
Séance's `ANALYSIS.md` and picked up at a re-pin: synced-pin
reconciliation, stale trust-dialog CAS, hashed/revocable sessions, atomic
account lifecycle (see BOTH-REV-005) and bounded server quotas.

### P3-05 port-back and Séance-side items touching Poltergeist docs
- P3-05's fix ports back to Séance's identical `file_stores.dart`.
- X-16: Séance `badge_image` encode catches only `Exception`; Poltergeist
already catches everything (`app: services/badge_image.dart:253`), but
Poltergeist's PORTS entry "badge_image.dart: Divergences: none, carried
verbatim" is wrong. Next: correct the PORTS entry (S); Séance ports the catch.
- X-20: Séance `docs/POLTERGEIST.md:348-350` still says Poltergeist treats
`serverConfig` as read-only. Fix lives in Séance; a Séance agent trusting it
would dismiss X-02/X-03.

---

## 7. Release, packaging, platform

### X-10 · P1 · Android auto-backup left on
- **Problem.** `android/app/src/main/AndroidManifest.xml` sets no
`allowBackup`, `fullBackupContent` or `dataExtractionRules`; no `res/xml/`.
A restore brings back vault ciphertext and flutter_secure_storage prefs
without the Keystore key, and clones `deviceId`. Android supported since
D35. VERIFIED manifest; LIKELY restore effects.
- **Next.** `android:allowBackup="false"`, `android:fullBackupContent="false"`,
`android:dataExtractionRules="@xml/data_extraction_rules"` excluding
root/file/sharedpref for `cloud-backup` and `device-transfer`; README
line ("reinstall and sign in to move to a new phone").
- **Gate.** Unit test parsing the manifest for the three attributes and the
rules file.
- **Refs.** Effort S. Same fix due in Séance (SOL-040/056).

### X-09 · P1 · No single-instance guard on Linux and Windows
- **Problem.** `linux/runner/my_application.cc:131` uses
`G_APPLICATION_NON_UNIQUE`; `windows/runner/main.cpp` has no mutex. STATUS
(`docs/STATUS.md:1537-1548`) relies on one process (D13, now D39 windows
in one process). Two processes each cache `servers.json`, `vault.json`,
settings and flush whole maps (`app: services/file_stores.dart:175-215`);
a re-key in one plus a secret save in the other can make the vault
unopenable. Only the checkout store refuses a second instance. LIKELY.
- **Next.** Linux: `G_APPLICATION_DEFAULT_FLAGS`, route `activate` to "new
workspace window" (D39). Windows: named mutex keyed on the application id,
`FindWindow`/`SetForegroundWindow`, exit. Dart backstop: exclusive
`RandomAccessFile.lock` on `app-support/instance.lock` with an "already
running" message.
- **Gate.** Dart test: a second lock attempt on the same support dir fails
with the typed error; runner changes verified manually on Linux and
Windows (record in the QA checklist, STATUS #32).
- **Refs.** Effort S-M. Séance SOL-034.

### X-08 / BOTH-REV-007 · P1 · `appimagetool` and the AppImage runtime are fetched unverified
- **Problem.** `scripts/package-linux.sh:455-478` downloads
`appimagetool-$arch.AppImage` 1.9.1, `chmod 755`, runs it, no hash; invoked
without `--runtime-file` (`:519-527`), so the runtime comes from the mutable
`type2-runtime` "continuous" release. The release job holds
`contents: write`. VERIFIED (no checksum), LIKELY (runtime fetch).
- **Next.** Pin `APPIMAGETOOL_SHA256_x86_64`/`_aarch64` and `sha256sum -c`
before `chmod`; pin a `type2-runtime` release asset with its SHA-256 and
pass `--runtime-file`. Use source-aware cache keys so a binary cached from
another URL is never reused. Keep the existing complete
release/checksum/version/license gates and the documented personal signing
policy.
- **Gate.** Script test (or CI step) that a tampered download fails the hash
check before execution; a wrong cached binary and an interrupted download
are refused; `dpkg-deb -I`/AppImage smoke unchanged.
- **Refs.** Effort S. Same change in Séance.

### X-22 · P3 · No local-network usage string
- **Problem.** Neither iOS nor macOS `Info.plist` has
`NSLocalNetworkUsageDescription`; iOS and macOS 15+ prompt generically on
the first LAN connection, and a denial yields an unexplained EHOSTUNREACH.
Ad-hoc signatures may re-ask after updates (SPECULATIVE). LIKELY.
- **Next.** Add the string to both plists; map EHOSTUNREACH on Apple
platforms to a Local Network permission hint (ARB, D20).
- **Gate.** Plist test for the key; error-mapping unit test.
- **Refs.** Effort S.

### X-26 · P3 · The macOS accessibility guard has no regression gate of its own
- **Problem.** PORTS says `scripts/test-macos-accessibility.sh` is not ported;
Poltergeist relies on Séance's gate "against the same Flutter line", but
Séance floats on `stable` (X-11) while Poltergeist pins 3.47.2.
- **Next.** Port the ~45-line script; run it after `flutter build macos` in
the macOS legs of `ci.yml` and `release.yml`. Extra windows now carry
semantics (#214, UI-05), so extend the fixture to an extra window once the
main-window gate is green; the root-node-0 edge (UI-05) is a known gap.
- **Gate.** The script itself, green on the macOS CI leg.
- **Refs.** Effort S.

### X-14 · P3 · Dependabot `gradle` entry points at `/`
- **Problem.** `.github/dependabot.yml` has `package-ecosystem: gradle`,
`directory: /`; Gradle files live under `app/poltergeist_app/android/`.
AGP/Kotlin/wrapper updates never arrive, so the file_picker/AGP-9
workaround goes unnoticed.
- **Next.** `directory: /app/poltergeist_app/android`.
- **Gate.** Config review; a Dependabot gradle PR appears on the next run.
- **Refs.** Effort S. Same in Séance.

### X-24-P · P3 · Checkouts keep the write token in `.git/config`
- **Problem.** No workflow sets `persist-credentials: false`, so the token
sits in `.git/config` during `pub get`/`flutter build`, where package
build hooks run code.
- **Next.** `persist-credentials: false` on every `actions/checkout` that does
not push; keep it only where a job pushes.
- **Gate.** Workflow lint/grep step in CI asserting the setting.
- **Refs.** Effort S.

### Séance-side release items (tracked in Séance; listed so nothing is lost)
Poltergeist is already ahead on these and serves as the template: X-06
(Séance macOS sandbox likely blocks the ssh-agent socket), X-07 (Séance
`release.yml` lacks SHA pins, refuse-overwrite, draft-then-publish,
SHA256SUMS, tag checks), X-11 (Séance builds on unpinned Flutter; blocks
X-26's "same line" assumption), X-12 (Séance `.deb` libstdc++ floor always
satisfied), X-13 (desktop-file id, copyright text, build.sh exit status,
black resize flash), X-18 (APK `versionCode` always 1), X-19 (iOS name
"Seance App"), X-23 (floating Docker base images), X-24 (review retry,
secret scan, multi-OS Dart tests). No Poltergeist change needed.

---

## 8. Docs drift, test hygiene and CI maintenance

### X-21 · P3 · Agent-misleading docs drift
- **Problem.** `AGENTS.md:29` calls `poltergeist_core` a "scaffold today"
(63 lib files) and the layout omits `poltergeist_sync`,
`poltergeist_bench` and `tool/`; the build snippet analyzes/tests only
`poltergeist_core`; §2 omits `secret-scan.yml` and the pin-audit,
integration, sync-integration and bench jobs, and still describes the app
as possibly absent; `CLAUDE.md:18` says platform folders "get committed
once scaffolded"; CHANGELOG has "Unreleased" plus "1.0.0" although 1.0.1 is
tagged (README, STATUS:8564); `release.yml` comment "The app scaffold
milestone sets this up" (APK signing) is stale.
- **Next.** Refresh each; add `packages/poltergeist_sync` to the AGENTS
commands (matching CI's `packages/*` loop); add a 1.0.1 CHANGELOG section.
- **Gate.** Docs-only; a CI grep that AGENTS names every `packages/*` dir is
optional.
- **Refs.** Effort S.

### X-17 · P3 · `writeStringAtomically` does not order same-path writes
- **Problem.** Unique temps, no per-path queue
(`app: services/atomic_file.dart:12-41`); Séance added one. The ported
comment `file_stores.dart:178` claims it exists. Unserialized caller:
`app: services/sync_state_store.dart:45-46` (older snapshot can land last).
- **Next.** Port Séance's per-path tail queue (keep unique names), or at
minimum fix the comment (the P3-05 PR touches it anyway).
- **Gate.** Two overlapping writes with a delayed first: the second's
content wins.
- **Refs.** Effort S.

### X-15 · P3 · `syntaxLanguageFor` ignores `\` separators
- **Problem.** `app: ui/editor_syntax.dart:890-893` splits on `/` only; local
Windows paths reach it (`built_in_text_editor.dart:89`, `:174`;
`workspace_shell.dart:2676-2683`; `preview_panel.dart:529`), so
`C:\proj\Dockerfile` gets no highlighting and `C:\app.v2\README` a bogus
extension. Séance fixed it (`lastIndexOf(RegExp(r'[/\\]'))`, `76d2d9b`).
- **Next.** Port the two lines.
- **Gate.** Backslash-path cases in the syntax test.
- **Refs.** Effort S.

### T-01 · P3 · Root-only failures in `checkout_manager_test.dart`
- **Problem.** See the environment note: the two "review hardening"
cleanup-failure cases rely on `chmod 500`, which root bypasses.
- **Next.** Probe once (`id -u` via `Process.runSync`, or attempt a write into
the chmodded dir) and `markTestSkipped` with a reason when the fault
cannot be injected (root or Windows).
- **Gate.** Run as root: both cases skip with the reason; as a normal user
they still run and pass.
- **Refs.** Effort S. The macOS-host failures are SR-09.

### T-02 · P3 · Test gaps observed by the review
- Preview suite defaults to a hidden inspector, so every Quick Look plus
visible-well combination (the app default) is untested (P3-01).
- No test for `RecentLocationsStore` schema preservation (P3-09) or
workspace-detail survival across a bookmark quarantine (P3-07).
- No test separating read failure from decode failure in
`FileVaultStore`/`FileHostKeyStore` (P3-05).
- No test pins rename-to-checkout migration (P3-04) or backup scheduling
(P3-06).
- No large-listing interaction benchmark: tier-B P2 measures first paint
only, not filter keystrokes or session writes (P3-02, P3-03).
- `FakeTreeFileSystem.upload` does not replace folded occupants (P2-06).
- Each gap closes with its entry's gate; list here only until then.

### SR-07 · P1 (CI maintenance) · Restore a valid D12 baseline
- **Problem.** The refreshed #211 check at `cd382560` passed its measured
P3/P5/P7 budgets (4310.888 ms < 5500 ms; 4650.908 ms < 6000 ms; 2350.495
entries/s >= 1000) but failed the shared stale-baseline gate: `tier-b/cpu`
drift persisted for at least seven consecutive main runs. #211 has since
merged; whether main's streak has cleared was not re-checked for this
consolidation. A PR's tier-A measurements cannot clear or justify
replacing main's tier-B baseline.
- **Next.** Follow the [dedicated refresh procedure](test/benchmarks/README.md):
distinguish mixed CPU assignments from a fleet migration, collect at least
three main-run tier-B artifacts, pool only matching complete fingerprints
and scenario configs, and compute medians/counts from real successful
observations. Preserve the documented exception for newly landed scenarios
with fewer runs. Do not fabricate missing scenarios or change budgets,
enforcement, landing flags or cached state to make a feature PR green. A
truly clean main tier-B run may also clear the streak naturally; rerun an
affected PR only after valid state recovery.
- **Gate.** Baseline contract tests and analysis, checker validation against
real artifacts, and a separate measured baseline PR if recalibration is
needed. Until resolved, disclose the shared maintenance failure as a CI
blocker on affected PRs.
- **Refs.** Effort S-M. D12, **STATUS #31** (tier-B arming). Related: SR-08.

### SR-06 · P2 (CI maintenance) · Keep incremental review inside the PR
- **Problem.** The pinned review action compares the last reviewed head with
the new head and retains every changed file. After merging main, its
hybrid mode can review unrelated inherited changes; its full mode uses the
actual current PR diff. Verified in both source and the executed bundle at
[`8e718ac`](https://github.com/L-K-M/zai-code-review/blob/8e718ac45f13c5ae0e57b19a00afd54d42e5b8f7/src/index.js#L937-L1015).
- **Next.** Fix the shared action upstream, then update both sibling pins:
constrain review to current PR changes, or deliberately fall back to full
PR review when the comparison base changes. Measure requests/runtime
before and after. Until fixed, use a full review after integrating main.
Mode labels come from the triggering event payload; adding a label and
rerunning an old event does not refresh that payload. A ready-for-review
event can request the correctly scoped review without another code commit
or repeating CI. Restore the PR to ready and remove any temporary mode
label afterward.
- **Gate.** Main merges adding unrelated files and unrelated hunks within a
PR-touched file, renames/deletions, previous-head removal, and retained
rotating coverage.
- **Refs.** Effort S-M (upstream action).

### SR-09 · P1/P2 (investigate) · Make macOS test failures reproducible
- **Problem.** The sibling review's macOS baseline is not clean (section
10): two `setTimes` access-time assertions, `/var` versus `/private/var`
temp-path failures, and a stalled `pane_session_lifetime_test` with a
disposed `PaneController` notification. Distinct from T-01 (root-only
failures in Linux containers).
- **Next.** Isolate each. Run default macOS temporary paths and a canonical
`TMPDIR=/private/tmp` separately. Identify whether each failure is a
fixture assumption, filesystem behavior or a reachable product defect
before changing containment rules.
- **Gate.** Each confirmed defect has a focused failing regression; full app
tests terminate under both temp configurations; delayed callbacks cannot
notify disposed panes; genuine symlink escapes remain rejected. Do not
loosen safety checks or refresh goldens merely to obtain a green run.
- **Refs.** Effort S-M. Related: P1-06 (trusted local roots resolve
`/tmp`-style links), T-01.

### BOTH-REV-012 · P2 · Executable port-parity checks
- **Problem.** Security-sensitive files copied from Séance drift silently;
the PORTS ledger records historical source timestamps, not behavior. X-16
(a wrong "Divergences: none" entry) and X-17 (a missing per-path queue the
port's comment claims) are instances.
- **Next.** Maintain executable parity checks for security-sensitive copied
files and the PORTS ledger; shared packages stay upstream. Compare
atomic-file, vault, editor and prompt behavior, not only timestamps.
- **Gate.** A deliberately diverged copy fails the check.
- **Refs.** Effort M. Idea: mechanical shared-file guard.

---

## 9. Ideas

Optional product and engineering ideas, merged across slices. "Plan fit"
names where the plan already places it; anything in D25 needs a 00 edit.

| Idea | Source | First useful slice | Plan fit |
|---|---|---|---|
| Engine watchdog with state replay | P1 | Expose `terminated` plus a "Reconnect all" banner (P1-01b) | D8 |
| "Settings changed, reconnect?" chip on panes of an edited server | P1 | `ServerStatus.detail` "settings changed" from #218's identity check | |
| Mark of the Web / quarantine xattr on everything leaving a remote | P1 | Checkouts only (P1-03a) | |
| Randomart plus SSHFP check in the TOFU dialog; fingerprint sigil / connection passport | P1, sibling, Séance "fingerprint sigils" | Pure randomart from the SHA-256 fingerprint, with the full fingerprint, approval origin and jump route; a memory aid only, a changed key remains blocked; coordinate with Séance | D18 unchanged (display only) |
| NFC-aware name identity on macOS (badge for normalization-only twins) | P1 | Pure `namesEquivalentOnHost()` for the rename preflight | |
| Adaptive off-isolate local copy with live throughput ("kernel copy" hint) | P1 | P1-07 (b) chunk timing budget | D8 |
| ssh_config import "explain" view (effective directives with file:line) | P1 | Carry `sourcePath:line` in `SshConfigImportRow` | D22 |
| Plan-time collision lens for transfers ("2 items map to one name") | P2 | Detection plus a failed row naming both sources (P2-06) | |
| Per-server filesystem traits probed once (case, normalization, setstat, posix-rename) | P2 | Case sensitivity for the queue | |
| Opt-in NFC-on-upload from macOS, per server | P2 | Transform in the walker's `plannedDest` with a flagged row | |
| Transfer receipts (JSONL manifest per task, "export receipt") | P2, sibling | Manifest for completed items from `fileCompleted`: exact destination, counts, skips/failures, verification and retained backups, Reveal and Retry failed; partial/cancelled runs never look successful; respect disabled history | SR-01 |
| Chaos property test for moves (seeded tree, fault injection, byte conservation) | P2 | Move-only, disconnect and cancel faults | |
| rsync exporter self-check in CI (`rsync -n -i` vs engine plan, hostile names) | P2 | Partly delivered by #222's exec test; add the sshd-fixture leg and plan comparison | D6 (test code only) |
| `fsync@openssh.com` before deleting a moved local source | P2 | Upstream VFS addition, then a flush before the post-commit delete | D26 twin; rule 9 |
| Viewport-exact restore (visible rows plus scroll offset) | P3 | Record `firstVisibleIndex`/`visibleCount` in tab state | |
| Rename-aware relocation across stores (`LocationRenamed` event) | P3 | Fan P3-04's hook out to `RecentLocationsStore.relocate` | |
| ASCII fast lane for folds and filters | P3 | ASCII branch in `typeAheadFold` with a property test (P3-03) | |
| Backup heartbeat chip ("Backed up 2 min ago") | P3 | Expose `nextRoundAt`/`lastSyncAt` after P3-06 | |
| Quick Look next-row prefetch | P3 | Text kinds ≤ 256 KB, cancel on focus change | 07 §3.13 v1.x backlog |
| Per-task transfer sparkline | P3 | Render `TransferRateTracker`'s window from P3-10's tick | |
| "Where was I" folder memory (per-location LRU cursor and scroll) | P4 | In-memory LRU of 200 in `WorkspaceController` | |
| Ghost rows for incoming files | P4 | Overlay rows from tasks whose destination equals the pane location | |
| Compare panes at a glance (only-here / newer-here / same tint) | P4 | Pure `comparePaneListings(a, b)` plus a 3 px bar | 07 §3.13 "cross-pane Compare" |
| Type-ahead substring fallback with a "contains" badge | P4 | Second pass in `PaneController.typeAhead` | |
| "Recently haunted" dot on rows modified in the last 5 minutes | P4 | `modifiedAt` threshold in `_PaneRow`, D34 attention hue | D34 |
| Hold-⌘ shortcut hints drawn from the registry | P4 | `HardwareKeyboard` listener toggling a `ValueNotifier` | D21 |
| Path field Tab completion | P4 | Local-only completion from `controller.entries` | |
| Handoff URLs (`poltergeist://open`, `seance://connect?cd=`) | X | One verb on macOS/Linux with an `sftp://` clipboard fallback | 07 §3.13 item 5 (deep links, 04 §7.1) |
| Drag from Poltergeist onto a Séance terminal pastes a quoted path | X | Séance accepts `text/uri-list` `sftp://` drops | D39 drag limits apply |
| One theme for the family ("Use Séance's theme") | X | Read Séance's `settings.json` on desktop; synced record later | D38 |
| Downstream canary: Séance CI builds Poltergeist against the PR's `seance_core` | X | Analyze-only, non-blocking | D2 |
| Mechanical shared-file guard (manifest plus CI hash check) | X | Reuse `tool/seance_pin_audit` machinery | |
| Server-side operations over an exec channel (`cp --reflink`, `sha256sum`, git chip) | X | Read-only git branch chip | Needs X-25 (`runCommand`); D5 shell-less transport stance to confirm |
| Séance session tray (cross-app presence over a local socket, no secrets) | X | Announce `{serverConfigId, state}` | D19 (local only) |
| Port Séance's Android `KeepAliveService` for transfers | X | Port verbatim; anchor while the queue is non-empty | **STATUS #33** |
| Protocol hygiene: "every model round-trips unknown keys" golden per model | X | One golden in `seance_protocol` run by both repos | X-03 |
| Echo-free cursor advance after a contiguous push | Séance S1 | Behind the persistent store, Poltergeist first | |
| Rollback tripwire (warn when `latestSeq` goes backwards) | Séance S1 | Log the S1-03 regression as a warning | |
| "Who changed this?" sync receipts (device and time per record) | Séance S1 | Sealed device-name record plus a tooltip | |
| Explain this sync row / change postcard | Sibling | Reasons and counts from the immutable plan, metadata/tolerance/hash policy and folder summary; overrides and exclusions match execution, with bounded rendering | 05 |
| Ghost landing preview | Sibling | Live destination breadcrumb and the actual Copy/Move/count badge during drag; modifier and spring-navigation updates follow the real command snapshot, without delays or extra I/O | UI-06 |
| Recovery drawer | Sibling, Séance S3-12 | Discoverable interrupted runs, dirty checkouts, trash usage and safe actions over existing stores; exact original paths, no silent cleanup | SR-02 |
| Connection flight recorder | Sibling | Opt-in bounded phase timings and a previewed redacted export; no telemetry, credentials, commands or raw traces by default | D19 |
| Production wards | Sibling | Existing explicit host labels/colors appear in destructive-action review; never suggest arbitrary terminal commands are intercepted | |
| Breadcrumb return trail | Sibling | Surface endpoint-scoped existing recents/history for fast returns; no duplicate store or hidden shell commands | |
| Quiet motion | Sibling | One reduced-motion policy for transitions, receipts and toasts; real progress remains visible and terminal text never animates | UI-04 |

---

## 10. Baselines and verification limits

**Deep review (at `913ca3d`, review container, Linux, root).** Flutter
3.47.2, Dart 3.13.2. Package and app analysis clean; 2,786 app tests pass;
core passes except the two root-only failures (T-01). See the environment
note near the top.

**Sibling review (macOS host).** Flutter 3.47.3/Dart 3.13.3 locally; CI
pins Flutter 3.47.2. Baseline core/sync analysis and app analysis were
clean. Package baseline: 1780 passed, 26 skipped, two macOS access-time
assertions failed. The full app baseline reached 2721 passing, 2 skipped
and 61 failures and then stalled; it was stopped after more than ten
minutes without progress (two additional incomplete-test errors were
reported during shutdown). Many failures rejected the Mac temp alias
`/var`; a controller teardown assertion also occurred. This is not a green
full-suite claim (SR-09).

All nine baseline sidebar capture tests passed, producing ten PNGs, with
Arial/Courier substituted through the fixtures' font aliases. The stock
fixture explicitly selects Poltergeist/Automatic, so these are not renders
of the newer Vapor default. Light/dark, narrow and phone/sidebar renders
look coherent without obvious overlapping rows. They do not prove native
accessibility, complete screen layout, IME behavior or release typography.

**Not performed by either review:** local power-loss tests, physical mobile
devices, Windows/Linux native interaction, sustained frame-time tests. CI
results are per PR (section 11); a consolidation at `b955213` re-ran no
suites.

---

## 11. Completion ledger

Merged work from both reviews. Residuals stay as active entries above.

| ID | PR | State | Summary | Residuals (tracked above) |
|---|---|---|---|---|
| PGE-01 | [#209](https://github.com/L-K-M/Poltergeist/pull/209) | Merged | Retain the backup's restore mapping when a replacement upload fails or is cancelled; flush journal records before the replacement | P2-04 residual (rollback, rename-before-journal crash window, unknown-size zero), SR-02 |
| UI-01 | [#210](https://github.com/L-K-M/Poltergeist/pull/210) | Merged | Idempotent delete-dialog route completion and cancellation on dismissal/teardown | UI-01a settled preparation error |
| PG-REV-001 | [#211](https://github.com/L-K-M/Poltergeist/pull/211) | Merged | Settle account-backup replies against their exact sent record so newer edits/deletes remain dirty | Shared LWW/revision policy (BOTH-REV-006); typed diagnostics for malformed/duplicate backup responses; SR-07 (merged with the stale-baseline gate failing) |
| PGE-03 | [#213](https://github.com/L-K-M/Poltergeist/pull/213) | Merged | Shared file/parent flush ordering before deleting a local cross-volume trash source; originals preserved on reported flush failure | PGE-03a (parent-fsync error suppression, remote durability, remote-cancel regression, STATUS wording) |
| P2-02, P2-03 | [#216](https://github.com/L-K-M/Poltergeist/pull/216) | Merged | Mirror never deletes beneath a symlink on either side; a replaced directory subsumes its destination-only descendants (05 §3, §6 rule 4); engine now agrees with the rsync exporter | P2-02a hazard counterpart, P2-02b scan-error prefix, P2-02c plan-view label, P2-03a one-way source dir, P2-03b app override verbs |
| P2-05 | [#217](https://github.com/L-K-M/Poltergeist/pull/217) | Merged | Compaction only when reclaimable bytes pay for the rewrite | P2-09 (with duplicate history rows), P2-05a memory, P2-05b failing rewrite backoff |

### Review record for the sibling review's merged PRs

Kept from the sibling review's handoff so review decisions are not
re-litigated. The snapshot was recorded at publication and does not
certify later commits or native behavior.

| PR | Branch | Final reviewed head | Remote checks and review |
|---|---|---|---|
| #209 | `codex/preserve-sync-backup-recovery` | `70d30e3c` | 19 checks passed; two dispatch-only M0 checks skipped. Two completed distinct-revision assessments, no agreed important findings. |
| #210 | `codex/guard-delete-dialog-lifetime` | `90f73b59` | 16 checks passed, including all five client builds; five integration/benchmark checks skipped by change filters. Two completed distinct-revision assessments, no agreed important findings. |
| #211 | `codex/preserve-backup-edit-revisions` | `cd382560` | 18 checks passed, including full review, all five client builds and package/app/integration checks; two dispatch-only M0 checks skipped. D12's measured scenarios passed but its shared stale-baseline gate failed (SR-07). One superseded overbroad review was cancelled and is excluded. Two clean implementation assessments plus a completed full assessment after main integration; no agreed important findings. |
| #213 | `codex/flush-sync-trash-copies` | `7ddeff0a` | 19 checks passed, including SSH/server integration, benchmarks and all five client builds; two dispatch-only M0 checks skipped. Two completed distinct-revision assessments, no agreed important findings. |

| PR | Local evidence |
|---|---|
| #209 | Failed/cancelled replacement regressions failed before repair; executor/journal and full sync suites pass, with real SSH fixtures skipped locally. Legacy journal compatibility is covered. |
| #210 | Six failing lifetime regressions repaired; 22 focused dialog/command tests and full Flutter analysis pass. Added the preparation-error dismissal case during review. |
| #211 | Three races failed before repair. After integrating main, 110 core sync and 48 app backup/settings tests plus both analyzers pass. The unchanged implementation previously passed 53 app checks. A deduplication mutation makes the new duplicate-result regression fail. |
| #213 | File-flush failure, operation-order and cancel-before-flush regressions failed before repair; 255 affected tests pass, three real-SSH fixtures skip, core/sync analysis clean. Unit barriers are not power-loss evidence. |

**Review decisions to retain.**

- #209: the unknown-size recovery representation needs a separate
schema/restore migration, rather than supplying null to a required-int
field (P2-04, SR-02).
- #211: the fake already clears displaced winners through `markSynced`, so
an additional clear is redundant. The repeated fake-store suggestion was
deferred: its helpers mutate synchronously and already clear displaced
winners. Removing the inherited `markSynced` contract requires a
compatible upstream API migration, not just deleting a method from this
implementing interface. Typed diagnostics for malformed/duplicate backup
responses remain a small observability follow-up; do not log credentials
or repurpose decryption-corruption warnings for protocol anomalies.
- #211: the second assessment on `65cce109` found zero actionable
suggestions. A later main merge required retaining both adjacent STATUS
entries; all four PR source/test files remained byte-identical. Its hybrid
review was cancelled after verifying the inherited-main scope issue
(SR-06), then a full-current-PR assessment completed at `cd382560` with no
important findings.
- #210: the second assessment only suggested a STATUS prose line wrap;
deferred after two assessments on distinct revisions without agreed
important findings. #209 also reached two such assessments.
- #213: review prompted the cancel-before-flush regression and a
clarification that directory-flush failures may be absorbed by the
existing shared helper (PGE-03a). The second distinct-revision assessment
found no agreed important issues; optional direct coverage for remote copy
cancellation and tighter STATUS wording were deferred (PGE-03a). The
shared cancellation/cleanup path also handles remote copies, but no remote
fsync guarantee is added or claimed. No new remote failure was
demonstrated during review.

**Combined-patch check (before merge).** #209 `70d30e3c`, #210 `90f73b59`,
#211 `65cce109` and #213 `7ddeff0a` applied together in a disposable
checkout: core/sync analysis, 642 backup/transfer/sync tests (three
real-SSH skips), 70 app backup/settings/delete-dialog tests and full app
analysis passed. The two sync patches needed an ordinary three-way
test-file merge; no source conflict remained. A read-only merge preview of
#209 and #213 confirmed an adjacent STATUS documentation conflict only;
keep both entries. All four have since merged.
