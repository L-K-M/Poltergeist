# 05 — Sync: the previewable engine

This chapter turns R6 — "safe, fast, understandable/previewable sync" — into
a buildable specification. It elaborates D6 (native engine, rsync as an
exporter), D7 (hashing policy), and D15 (one trash story); the decision log
in [00-OVERVIEW.md](00-OVERVIEW.md) is the authority wherever a decision
number appears. The engine lives in `packages/poltergeist_sync` (D2), runs
entirely over the one VFS (`RemoteFileSystem`, D3), and shows up in the UI
as the plan view (this chapter) plus one task row in the activity panel
(02 §6). The persisted saved-sync schema is 04's contract.

## 1. Product framing: safe means previewable

The core insight that drives everything here: **"previewable" and "safe" are
the same requirement.** Safety does not come from confirmation dialogs bolted
onto a black box; it comes from the preview *being* the execution plan. The
engine produces a typed `SyncPlan` of per-file actions; the UI renders
exactly that plan; the user edits it; the executor executes exactly those
items, re-verifying each item's precondition immediately before acting. There
is no second engine whose behavior the preview merely predicts.

Prior art, compressed to what each proves:

| App | Model | What we take |
|---|---|---|
| Transmit 5 | one-way only; Simulate dry-run with per-file exclusion; "Delete orphaned destination files" is an explicit off-by-default checkbox | deletion as a labeled opt-in; preview with per-item veto |
| ForkLift 4 | one/two-way; preview of adds/updates/deletes; saveable to the sidebar as a saved pair; removed per-item veto at 4.0 and had to restore it after loud complaints | saved syncs in the sidebar; per-item veto is non-negotiable; analysis needs visible progress |
| WinSCP | the Synchronization Checklist: one row per action, per-row checkboxes, reversible direction, bulk (un)check | the gold-standard checklist UX, cross-platform for the first time |
| FreeFileSync | per-item direction overrides; 2 s mtime tolerance; >50 %-deleted warning; state DB (`sync.ffs_db`) for true two-way | tolerance default; the >50 % typed confirm; the lesson that two-way needs a baseline DB — and that in-tree DB files annoy people |
| Unison | true two-way over archives; never propagates on conflict by default | conflicts are surfaced and skipped, never silently resolved |

Nobody ships WinSCP's checklist with Transmit's polish on all three desktops
(01 §4, differentiator 1). This chapter is that feature.

## 2. The rsync verdict (D6) and the exporter

D6 settles it: rsync is not the engine. It fails *always works* — the remote
side must run a compatible rsync binary, which is absent on Windows servers,
sftp-only chroots (`ForceCommand internal-sftp`), shared hosts, and
busybox-based NAS boxes, and there is no native rsync on Windows *clients*
either; macOS 15.4+ quietly swapped in openrsync with a subset of flags. It
fails *polished* — `rsync -e ssh` spawns the system OpenSSH client, a second
auth-and-trust stack that cannot see Poltergeist's vault keys, in-app
password prompts, or TOFU host-key store. And it fails *exactly what you
previewed* — a `--dry-run` preview and the later real run are two separate
executions of a foreign engine, so the preview is a prediction, not a plan.

What survives is the spirit of the original idea, as a zero-risk feature:
**"Copy as rsync command"** renders any plan's ruleset as the equivalent
`rsync` invocation to the clipboard — power users get exactly what they
would hand-write, and the command doubles as documentation of what the sync
will do in a lingua franca admins already trust. It is generated text only:
`poltergeist_sync` never executes rsync, never imports `dart:io` `Process`,
and the exporter has no code path that runs anything (a tested invariant,
08). The opt-in per-item rsync *accelerator* stays a documented v2
possibility (D25); it may never be needed.

### 2.1 Exporter spec (`lib/src/rsync_export.dart`)

`String buildRsyncCommand(ResolvedSyncEndpoints endpoints, SyncRuleSet
rules, {int manualOverrides = 0, DateTime? now})` — pure function,
golden-string tested. `ResolvedSyncEndpoints` carries user/host/port/path
per side; the app layer resolves `BookmarkServerRef` → identity before
calling. `manualOverrides > 0` emits the per-item-override comment below.
Output is two lines: a commented dry-run variant, then the real command:

```
# Preview first (matches Poltergeist's plan):  rsync -n -i <flags…> SRC DST
rsync <flags…> SRC DST
```

Flag mapping from `SyncRuleSet` (§6):

| Ruleset element | rsync rendering | Notes |
|---|---|---|
| base | `-r`, plus `-t` when `preserveMtime` | `-t` is on by default; without it nothing converges |
| `direction` | source rendered first with a trailing `/`, destination second; `rightToLeft` swaps them | remote endpoint renders as `user@host:'path/'` from `ResolvedSyncEndpoints`; adds `-e ssh` when either side is remote |
| `mtimeToleranceSecs` | `--modify-window=2` | verbatim value |
| `comparison: sizeOnly` | `--size-only` | |
| `comparison: contentHash` | `-c` | |
| Update mode | no delete flag | rsync's default |
| Mirror mode | `--delete-delay` | deletions after transfers — same ordering as our executor (§6) |
| `maxDelete` | `--max-delete=500` | verbatim value |
| `deletions: trash` and/or `backups: trash` | `--backup --backup-dir='.poltergeist-trash/rsync-<yyyyMMdd-HHmmss>'` (or the pair's `trashPath` when set, §8 rail 5) | timestamp computed at copy time (`now`); rsync's one backup-dir captures deleted and overwritten files alike, so when only one of the two knobs is `trash` the export approximates and a comment says so |
| `deletions: permanent` + `backups: trash` | `--backup --backup-dir='…'` as above | approximation in the safe direction: rsync's backup-dir also rescues the *deleted* files the plan would delete permanently, so the export deletes less than the plan — the comment must say so |
| `deletions: permanent` + `backups: none` | no backup flags | |
| `excludeGlobs` + defaults | one `--exclude='pat'` per pattern, app defaults first; gitignore `!` negations become `--include='pat'` emitted before the excludes | rsync's filter language accepts `*`, `?`, `**`, and trailing-`/` dir-only patterns; where gitignore semantics diverge the export is an approximation and says so in a comment |
| `includeHidden: false` | `--exclude='.*'` | |
| `symlinks: skip` | no `-l` | rsync without `-l` skips symlinks with a warning — same behavior |
| Additive two-way | two commands, each direction with `-u` and no delete flag | preceded by `# note: -u approximates conflicts as newer-wins; Poltergeist surfaces them instead` |
| `transferConcurrency` | not representable | trailing comment: `# note: rsync is single-stream` |
| `acceptedTimeShifts` | not representable beyond `--modify-window` | trailing comment when non-empty |

Additional rules:

- Paths are POSIX single-quoted; embedded `'` becomes `'\''`.
- A remote side on a nonstandard port renders `-e "ssh -p <port>"` — the
  port travels in `ResolvedSyncEndpoints` and must reach the command, or
  the copy silently talks to port 22.
- When both endpoints are remote, rsync refuses to run ("The source and
  destination cannot both be remote"); the exporter emits a comment saying
  the command is not directly runnable (Poltergeist routes such pairs via
  the local machine) instead of a command that fails.
- When the plan carries manual per-item overrides, prepend
  `# note: N manual per-item overrides are not reflected in this command`.
  Per-item edits are deliberately not compiled into `--exclude`/
  `--files-from` lists — rsync's include/exclude ordering is famously
  subtle, and a wrong translation would betray the feature's whole point.
- A comment line notes the auth caveat:
  `# uses your OpenSSH config and known_hosts, not Poltergeist's connections`.
- Surfaced as command `sync.copyRsyncCommand` — a button in the plan view's
  action bar and `Commands > Copy as rsync Command` (02 §9). On copy, toast:
  `Copied rsync command`.

## 3. Scanning

`lib/src/scan.dart` — one `TreeScanner` per side, both sides walked
concurrently in the engine isolate (D8).

- **Remote**: SFTP v3 `READDIR` returns names *with* attributes (size,
  mtime, mode), so a full tree walk costs about one round trip per directory
  page with no per-file stat. Pipeline directory listings with bounded
  concurrency — 8 outstanding `listDirectory` calls by default, tunable
  8–16 after M0 reports (D9) — over one browse channel leased from the
  connection pool (03 §3.2). Budget P7: ≥ 1 000 remote entries/s on LAN
  (D12; benchmark in 08).
- **Local**: `LocalFileSystem.listDirectory` (03 §2.2); cheap.
- Output per side: `ScanResult` = flat map
  `relativePath → EntrySnapshot` (§6) plus a list of `ScanWarning`s.
  Relative paths use `/` separators on both sides and are the join key.
- **Scan errors are exclusions, never emptiness.** A directory that cannot
  be listed (permission denied, I/O error) excludes that subtree from
  planning **on both sides** — if only the failing side were excluded, a
  Mirror run would see the other side's entries as orphans and delete them:
  the classic mirror-wipes-destination disaster. The exclusion becomes a
  `ScanWarning` and a plan item with reason `scanError`, action `skip`,
  rendered in the warnings strip (§7).
- **Symlinks are never followed** (loop and escape-the-tree hazards). v1
  policy: skip with notice — symlink entries are counted and reported as one
  warning (`14 symbolic links skipped`); `SymlinkPolicy.copyAsLink` and
  `follow` are reserved enum values for v2. Scans use `followLinks: false`
  everywhere, matching the transfer queue (03 §4.2).
- **Ignore rules** are gitignore-style, evaluated during the scan so ignored
  subtrees are never descended: blank lines and `#` comments; `*`, `?`,
  `**`; trailing `/` matches directories only; leading `/` anchors to the
  sync root; `!` re-includes. Per-pair rules come from
  `SyncRuleSet.excludeGlobs`; app-level defaults are always applied and not
  user-removable: `.DS_Store`, `Thumbs.db`, `desktop.ini`, `.poltergeist*`,
  `*.poltergeist-*` (together the last two cover `.poltergeist-trash/`,
  `.poltergeist-*.tmp` temps, the editor's `<name>.poltergeist-<uuid>.edit`
  / `.backup` siblings, and any future app droppings — D15). The pair
  editor offers quick-pick chips for `.git/` and `node_modules/`.
- **Name hazards are surfaced, never silently "fixed"** — each becomes a
  plan item with a conflict-class reason (§6):
  - macOS local filesystems return NFD Unicode; Linux servers usually store
    NFC. Paths are NFC-normalized for matching, so `café` pairs correctly
    across sides; when updating, the destination's existing byte form is
    kept (no renames). Two entries on *one* side that collide after
    normalization → reason `normalizationCollision`, suggested `skip`.
  - Two entries on a case-sensitive side differing only by case, destined
    for a case-insensitive side → reason `caseCollision`, suggested `skip`;
    never overwrite silently.
  - Names invalid on a Windows destination (reserved names, forbidden
    characters, trailing dot/space — checked via `validateLocalName`,
    03 §2.3) → reason `invalidNameOnDestination`, suggested `skip`.
- **Scan progress is visible** (ForkLift 4.0's launch regression is the
  anti-model): while scanning, the plan view shows live counters —
  `Scanning… left 3,214 entries · right 1,876 entries` — and Cancel.

## 4. Comparison

`lib/src/compare.dart`. Three modes via `ComparisonMode` (D7):

- **`sizeAndMtime` (default).** Two entries are equal iff same kind, same
  size, and `|mtimeLeft − mtimeRight| ≤ mtimeToleranceSecs` (default **2 s**).
  SFTP v3 mtimes are a uint32 of *whole seconds* (dartssh2 exposes
  `attrs.modifyTime` in seconds; Séance converts via `_timeFromSeconds`), so
  **both sides are truncated to whole seconds before comparing** and no
  sub-second expectation is ever stored about a remote file. Optional
  `acceptedTimeShifts` (e.g. `[3600]`) additionally accepts exact ±N-second
  offsets for FAT/exFAT DST artifacts — advanced setting, default empty.
- **`sizeOnly`** — for servers with unreliable mtimes (also the automatic
  fallback below).
- **`contentHash`** — thorough mode, opt-in per pair (D7): both sides
  hashed with streamed SHA-256; the remote side is read over SFTP (Séance's
  `_remoteContentSha256` pattern — a full download, honest but slow). Exec-
  channel `sha256sum` and the SFTP `check-file` extension are v2
  accelerations (D25); the mode's contract does not change when they arrive.

Directories compare by existence only; a file/directory/symlink kind
mismatch at one path is reason `typeDiffers`, a conflict.

**mtime preservation is mandatory for convergence.** After every upload the
executor calls `setTimes(path, modifiedAt: sourceMtime, accessedAt:
sourceMtime)` — in SFTP v3, atime and mtime travel under one flag, so both
are set. After every download it sets the local mtime to the remote's.
`setTimes` is the D3 additive method: `LocalFileSystem` implements it from
day one, the remote side gates on the upstream Séance PR and pin bump
(03 §2.4); the remote-sync milestone in 07 sequences after that bump.

**Verification and the setstat fallback.** After `setTimes`, the executor
re-stats and journals the *observed* mtime. Some servers ignore or clamp
setstat (chrooted or read-mostly setups). If the observed value differs from
the requested one beyond the tolerance, the item is journaled with
`setstatIgnored: true`; at run end the pair's local metadata (§9) records
`mtimeUnreliable: true`. From then on plans for that pair compare
**`sizeOnly` automatically**, with a visible notice line in the plan header:
`This server does not keep modification times — comparing by size only.`
(pair settings offer an override back to `sizeAndMtime`). Because observed
mtimes are journaled, the run never flags phantom changes on the next
compare. Note that Transmit-style clock-skew probing is unnecessary here:
we compare *stored* mtimes that we set explicitly, not upload wall-clock
times, so server clock offset cancels out; the only failure mode is
setstat being ignored, which this fallback handles.

## 5. Modes (D6)

Modes are **direction × deletion policy**, because that is how users reason
and how the preview explains itself. v1 ships exactly three:

| Mode | Ruleset encoding | Behavior |
|---|---|---|
| **Update** (default) | one-way, `deletions: none` | copy new + changed source→destination; with `backups: trash` (the default) it can never lose destination data — overwritten versions are backed up per §8 |
| **Mirror** | one-way, `deletions: trash` (or `permanent`, per-pair opt-in) | Update + delete destination-only orphans; deletions render red with a count; the >50 % and `maxDelete` rails apply (§8) |
| **Additive two-way** | `bidirectional`, `deletions: none` | union both directions; never deletes, never auto-overwrites a conflicted pair; same-path-changed-on-both-sides becomes a conflict item |

The mode picker sits on the plan header (§7) as a segmented control
`Update · Mirror · Additive` with a direction toggle (`→` / `←`) for the
one-way modes. Mirror is a labeled choice made *on* the preview, not buried
in settings (Transmit's checkbox lesson); selecting it reveals the deletion
destination: `Deleted items go to .poltergeist-trash` (default) or
`Delete permanently` (explicit per-pair opt-in, D15).

Additive conflict handling: `ConflictDefault` (§6) resolves conflicts at
diff time (`newerWins` / `keepLeft` / `keepRight` / `skip`); the default
`ask` leaves them as conflict items. Unresolved conflicts **execute as
skip** and are counted in the header and summary — surfaced, never silently
resolved (Unison's rule).

One-way semantics are mirror-the-source, stated explicitly because it is
the most common sync surprise: a changed pair whose **destination** is
newer still copies source→destination (matching rsync without `-u`). The
item renders with reason `newerOnRight`/`newerOnLeft` so the
backwards-in-time copy is visible in the table before running, and with
`backups: trash` (the default) the overwritten newer version lands in the
run's trash, recoverable via §8 rail 9.

**True two-way is deferred (D25), but designed for now** so the v1 data
model needs no rework. Without last-run state, "exists on A, missing on B"
is ambiguous — new on A, or deleted on B? DB-free two-way either never
propagates deletions (our Additive mode, honestly labeled) or resurrects
deleted files forever. The v2 baseline design, sketched so v1 reserves the
seams:

- Per pair, a **baseline listing** stored under the app-provided support
  directory (`EngineConfig`, 03 §5) —
  `<app-support>/sync_state/<pairId>.baseline.jsonl` — rclone-bisync-style
  local listings, **never** FreeFileSync/Unison-style files planted inside
  the synced trees. One record per path: kind, size, *both sides' observed*
  mtimes (absorbing setstat-clamping servers), optional hash, recorded at
  the end of the last successful run.
- Decision rule: each side diffs against the baseline into
  unchanged/modified/new/deleted; the 3×3 matrix yields copy/delete/
  conflict; both-modified or modified-vs-deleted is a conflict (default:
  keep both via rename, `name (conflict from <side> <date>)`, or ask).
- Crash safety: the baseline updates incrementally per completed item from
  the run journal (§8), not atomically at run end; endpoint identity change
  invalidates it.

v1 already writes everything the baseline needs: `EntrySnapshot` carries
both sides' data and the journal records `observedMtimeAfterWrite` per item.

## 6. The plan model (`lib/src/plan.dart`)

```dart
/// A saved, bookmarkable sync definition. Persisted as the savedSync
/// bookmark kind (04) and synced via Seance's E2E server like bookmarks.
class SyncPair {
  final String id;                 // uuidV4() from seance_protocol
  final String name;               // "Blog -> webserver"
  final SyncEndpoint left;
  final SyncEndpoint right;
  final SyncRuleSet rules;
  final DateTime? lastRunAt;       // local metadata (sync_state), not synced
}

sealed class SyncEndpoint {}
class LocalEndpoint extends SyncEndpoint { final String path; }
class RemoteEndpoint extends SyncEndpoint {
  final BookmarkServerRef server;  // 04 §2.1: serverConfigId XOR
  final String path;               // EmbeddedHostIdentity; creds resolve
}                                  // via the vault — never embeds secrets
// Ad-hoc pairs (built from the panes, §7/§9) always carry the
// EmbeddedHostIdentity form of BookmarkServerRef.

enum SyncDirection { leftToRight, rightToLeft, bidirectional }
enum DeletionPolicy { none, trash, permanent }      // trash = D15, §8
enum BackupPolicy { trash, none }                   // overwrite backups, §8
enum ComparisonMode { sizeAndMtime, sizeOnly, contentHash }
enum ConflictDefault { ask, newerWins, keepLeft, keepRight, skip }
enum SymlinkPolicy { skip /* v1 */, copyAsLink, follow /* reserved, v2 */ }

class SyncRuleSet {
  final SyncDirection direction;
  final DeletionPolicy deletions;        // != none only in Mirror
  final BackupPolicy backups;            // default trash; independent of
                                         // the deletion policy (§8 rail 5)
  final ComparisonMode comparison;
  final int mtimeToleranceSecs;          // default 2
  final List<int> acceptedTimeShifts;    // e.g. [3600] for FAT/DST; default []
  final ConflictDefault conflictDefault; // bidirectional only; default ask
  final List<String> excludeGlobs;       // gitignore-style (§3)
  final bool includeHidden;              // default true (it's a file manager)
  final SymlinkPolicy symlinks;          // v1: skip
  final String? trashPath;               // null = in-root .poltergeist-trash;
                                         // set = out-of-root trash (§8 rail 5)
  final int maxDelete;                   // hard cap; default 500
  final double deleteFractionWarn;       // default 0.5 -> typed confirm (§8)
  final bool preserveMtime;              // default true
  final int transferConcurrency;         // default 4, clamp 1..8
}

enum EntryKind { file, directory, symlink, other }

class EntrySnapshot {
  final EntryKind kind;
  final int? size;
  final int? mtimeSecs;                  // whole seconds (SFTP v3 precision)
  final int? mode;
  final String? symlinkTarget;
  final String? sha256;                  // only when comparison == contentHash
}

enum SyncActionType {
  copyLeftToRight, copyRightToLeft,      // create at destination
  updateLeftToRight, updateRightToLeft,  // overwrite (backs up per policy)
  makeDirLeft, makeDirRight,
  deleteLeft, deleteRight,               // honors DeletionPolicy
  skip,                                  // equal, excluded, or user-skipped
  conflict,                              // needs a decision (or default)
}

enum SyncReason {
  onlyOnLeft, onlyOnRight, newerOnLeft, newerOnRight, sizeDiffers,
  contentDiffers, typeDiffers,           // file vs dir vs symlink at one path
  excluded, equal, bothChanged, caseCollision, normalizationCollision,
  invalidNameOnDestination, scanError,
}

enum SyncItemStatus { pending, running, done, failed, skipped }

class SyncItem {
  final String relativePath;
  final EntrySnapshot? left;             // null = absent on that side
  final EntrySnapshot? right;
  final SyncActionType suggested;        // the engine's proposal
  SyncActionType effective;              // after override / conflict pick
  final SyncReason reason;
  bool userOverridden;                   // renders the "manual" dot (§7)
  SyncItemStatus status;
  String? error;                         // RemoteFileException.message
}

class ScanWarning {
  final String relativePath;
  final String side;                     // "left" | "right"
  final String message;                  // e.g. 'Could not list "logs/"…'
}

class SyncPlan {
  final SyncPair pair;
  final DateTime scannedAt;
  final List<SyncItem> items;            // ordering contract below
  final List<ScanWarning> warnings;
  PlanTotals get totals;                 // counts + bytes per action class
}

class PlanTotals {
  final Map<SyncActionType, int> counts; // items per action class
  final Map<SyncActionType, int> bytes;  // payload bytes per action class
}

class SyncRunRecord {                    // journal header, JSONL (§8)
  final String runId;                    // uuidV4
  final String pairId;
  final DateTime startedAt;
  final SyncRuleSet rules;               // snapshot at run time
  // followed by per-item lines: relativePath, action, outcome, bytes,
  // durationMs, trashLocation?, observedMtimeAfterWrite?, setstatIgnored?
}
```

**Ordering contract** (`SyncPlan.items` and the executor):

1. `makeDir*` items first, shallowest-first, so parents exist.
2. Copies and updates next; the executor may run them in parallel up to
   `transferConcurrency` (order within the group is not significant).
3. Deletions last, **deepest-first** (children before parents), and the
   delete phase starts only after the copy/update phase finished **without
   failures** — rsync's `--delete-delay` insight, hardened: if anything
   failed, every deletion flips to `skipped` with error text
   `Skipped: earlier errors in this run`, and the summary says so.
4. **Kind changes pre-delete.** When an item's effective action creates a
   file or directory at a path whose destination entry has a different kind
   (`typeDiffers` resolved via override or `ConflictDefault`), the executor
   removes the destination entry first — honoring `DeletionPolicy`/trash,
   deepest-first for a directory being replaced by a file — then performs
   the makeDir/copy. The removal and creation stay one plan item so the
   preview remains one row per path (a mkdir over an existing file, or a
   file write onto an existing directory, would otherwise fail and trip
   rule 3's deletion skip).

## 7. Preview UX — the plan view

Sync opens as a **plan view**: a first-class screen in the active pane's tab
(like a Beyond Compare session), never a modal wizard. Entry points:
`sync.synchronizePanes` (⌥⌘Y / Ctrl+Alt+Y, 02 §8.3) builds an ad-hoc
`SyncPair` from the two panes' current locations; clicking a saved-sync
favorite opens its plan view directly (02 §4). Scanning starts immediately
with live progress (§3); the plan renders when the diff completes.

**Layout**: header · warnings strip (when any) · item table · action bar.

**Header** — mode picker (§5) plus one plain-language sentence, exact copy
patterns (placeholders in braces; destination rendered as
`{favoriteLabel}:{path}` or a shortened local path):

- Base: `Copy {n} new files ({bytes}) and update {m} on {destination}.`
  (omit either clause when its count is zero).
- No deletions (green-tinted tail): `Nothing will be deleted.`
- With deletions (red-tinted clause):
  `Delete {k} files on {side} (moved to .poltergeist-trash).` — or
  `Delete {k} files on {side} permanently.` for the opt-out.
- Conflicts (amber clause): `{c} conflicts need a decision.`
- Nothing to do: `Both sides match. Nothing to do.`
- sizeOnly fallback notice (§4) renders as its own line under the sentence.

**Item table** — virtualized (P-budget rules of 02 §12 apply), flat with a
path column by default, groupable by directory. Columns:

`name/path · left size · left mtime · action glyph · right size · right
mtime · reason`

Action glyphs, with color *and* shape carrying the meaning (color-blind
safe, D20): `→` copy new L→R, `⇒` update L→R, `←` / `⇐` mirrored, `✕`
delete (red), `↯` conflict (amber), `–` skip (dim). Row tint by action
class: create green, update blue, delete red, conflict amber — theme-aware,
contrast-checked status colors (D20).

**Reason strings are human**, from `SyncReason`: `only exists here` ·
`newer here (2 min ago vs 3 days ago)` · `sizes differ (1.2 MB vs 1.1 MB)`
· `contents differ` · `changed on both sides` · `type differs (file here,
folder there)` · `excluded by rule` · `names differ only by case` ·
`names differ only by Unicode form` · `name invalid on Windows` ·
`couldn't scan — subtree excluded`.

**Filter bar**: chips with live counts — `All (120) · New (12) ·
Updates (3) · Deletes (5) · Conflicts (2) · Skipped (98)` — plus a text
filter and an `only show actions` toggle (hides equal/excluded rows;
default on).

**Per-item overrides** (the FL 4.0.3 lesson: veto is non-negotiable):

- The action glyph is a control: click cycles through the actions valid for
  that item's sides (e.g. a both-sides pair cycles update L→R → update R→L
  → skip → back); right-click offers `Skip`, `Copy left → right`,
  `Copy right → left`, `Delete`, `Reset to suggested`.
- Multi-select (the 02 §2.5 selection model) + the same context menu
  applies bulk overrides.
- When conflicts exist, a bulk bar appears above the table:
  `Resolve conflicts:  Newer wins · Keep left · Keep right · Skip all`.
- Overridden rows show a small "manual" dot; overrides are journaled
  (`userOverridden: true`).
- Double-click a both-sides pair opens the preview seam (06) side by side;
  a text diff view is 06's v1.x item.

**Action bar**: `Copy as rsync Command` (§2.1) · `Save as Favorite…` (§9) ·
the Run button. The Run button always states its consequence (02 §10 verbs,
never "OK"): `Copy 15 Files` / `Copy 12, Delete 5` / disabled
`Nothing to Do`. First run of a pair with a lopsided plan gets a suggestion
chip when one directory contributes over half the items and matches a known
heavy set (`node_modules`, `.git`, `build`, `target`, `__pycache__`):
`node_modules is 4,812 of these files — exclude?` (one click adds the glob).

## 8. Safety rails

1. **Preview is mandatory and is the plan.** No "sync now" bypasses it; the
   executor executes exactly `plan.items` with `effective` actions. (An
   "auto-run when no deletes/conflicts" preference is a possible later
   addition, not v1.)
2. **No-delete default.** Update is the default mode; deletions exist only
   in Mirror and are red, counted, and named in the header sentence.
3. **The >50 % rail.** When planned deletions exceed
   `deleteFractionWarn` (default 0.5) of the destination side's files —
   and at least 10 files — Run opens a typed confirmation:
   `This will delete 320 of 512 files on webserver — more than half of
   that side. Type DELETE to continue.` The confirm button stays disabled
   until the word matches. Precedence: the `maxDelete` cap (rail 4) is
   checked first and dominates — the typed confirmation only ever fires
   for plans whose deletion count is under the cap.
4. **`maxDelete` cap** (default 500): a plan whose deletions exceed the cap
   refuses to run with deletions; the dialog explains and points at the
   pair's rules to raise it deliberately. No override button on the spot.
5. **Trash, one story (D15).** Two independent knobs feed one trash:
   deletions follow `deletions` (`trash` moves them; `permanent` — an
   explicit per-pair opt-in — deletes outright), and the previous versions
   of files an update overwrites are backed up per `backups` (`trash` by
   default; `none` skips overwrite backups). Both use a cheap
   same-filesystem rename into
   `.poltergeist-trash/<runId>/<relativePath>` under the sync root of the
   side being changed, on both local and remote sides (sync uses the
   rename trash even locally so undo is journal-driven and symmetric).
   Because the trash lives under the sync root, the rename never crosses
   devices, and the default ignore rules (`.poltergeist*`, §3) keep it out
   of every scan. **Webroot caveat:** when the sync root is a published
   HTTP docroot (the flagship `Blog → webserver` pair!), in-root trash
   means previous versions of overwritten/deleted files — old configs,
   secrets — may be retrievable over HTTP until purged. The per-pair
   `trashPath` rule (§6) moves the trash outside the root (a
   cross-filesystem rename falls back to copy-then-delete), and the pair
   editor warns when trash is in-root and the destination path looks like
   a docroot (`public_html`, `www`, `htdocs`, `/var/www`). No code path
   removes trash as a side effect (09 §6 rule 5): at plan time, if the
   pair's trash holds entries older than 30 days, the plan view shows a
   notice chip — `N trashed items older than 30 days — delete them?` —
   whose action performs the purge; the `sync.purgeTrash` command empties
   it on demand. The age check is cheap by construction: one
   `listDirectory` of the trash root per side returns the `<runId>`
   directories with their mtimes (READDIR carries attributes) — never a
   recursive walk — and the newest observed trash state is cached in
   `sync_state` (§9).
6. **Atomic writes.** Uploads write to an exclusive sibling
   `.poltergeist-<8 hex>.tmp` and rename over the target; downloads commit
   via `replaceLocalFile` (03 §2.3). No torn file ever holds the final
   name; failed temps are cleaned up.
7. **Per-item precondition re-stat.** Immediately before acting, each item
   re-verifies against its plan snapshot: copy-new requires the destination
   still absent; update and delete require the destination's size+mtime to
   equal the snapshot (uploads additionally use the adapter's
   `expectedTarget` compare-and-swap, 03 §2.1). Any mismatch flips the item
   to `conflict` with `changed since preview`, and the run continues — the
   preview→execute race that rsync's two-run model cannot close. A source
   that vanished mid-run fails the item (`failed`), never aborts the run.
8. **Per-item errors never abort the run.** Permission, disk-full, and
   vanished-file errors mark the item `failed` with its
   `RemoteFileException.message`; the summary reports
   `14 copied, 2 failed, 5 deleted (in trash)` with one-click
   `Retry Failed` (re-scans just those paths, rebuilds their preconditions,
   re-executes). Connection loss pauses the run; on resume, items whose
   journal line records completion are marked done without re-executing.
   The journal line is written *after* the commit rename, so a
   committed-but-unjournaled window exists: a resumed item whose
   destination no longer matches the plan snapshot but matches the
   intended post-state (source size+mtime, with this run's trash/backup
   entry present where the plan expected one) is journaled as done rather
   than flipped to conflict; anything else falls through to rail 7's
   precondition flip as usual.
9. **Run journal.** JSONL per run at `<app-support>/sync_runs/<runId>.jsonl`
   (under the app-provided support directory — `EngineConfig`, 03 §5)
   — a `SyncRunRecord` header line (pair, ruleset snapshot, totals,
   warnings), one line per executed item (outcome, bytes, duration,
   `trashLocation`, `observedMtimeAfterWrite`, `setstatIgnored`), one
   summary line. Journals are pruned to the newest 20 per pair — **except**
   a run whose `.poltergeist-trash/<runId>/` entries still exist, whose
   journal is retained until the purge (rail 5) removes them: Undo must
   never lose its source while the trash it reverses is still there
   (`sync.purgeTrash` is what finally lets those journals be pruned). The
   journal powers the post-run report, `Retry Failed`, and **Undo**: v1's
   `Restore Trashed Files…` restores every trashed/backed-up file by
   reversing the recorded renames (conflict-checked with a re-stat per
   file). Note the explicit scope: because overwrite backups are restored
   too, this also reverts files the run *updated* back to their pre-run
   versions — the confirm dialog says so (`Restores 5 deleted and 3
   overwritten files to their pre-run versions.`). Full undo (also
   removing copies the run created) is v2, and the journal already
   records enough for it.
10. **Scan errors exclude, on both sides** (§3) — never read as emptiness.

## 9. Saved syncs

A configured `SyncPair` saves as a favorite of the **savedSync bookmark
kind** — 04 owns the persisted schema, and the exact
`SyncPair` ↔ `SavedSyncSpec` field mapping is 04 §2.1's; 02 §4 defines the
sidebar behavior (custom icon/color, drag-reorder; clicking opens the
plan view and starts scanning; saved-sync favorites reject file drops).
Saved pairs travel inside the encrypted bookmark record kind through
Séance's sync server (D4), so a pair defined on one machine appears on all
of them; `RemoteEndpoint` carries a `BookmarkServerRef` (§6), so
credentials and host identity resolve through the catalog/vault and never
ride in the pair itself.

Local, non-synced pair state lives at `<app-support>/sync_state/
<pairId>.json`: `lastRunAt`, `mtimeUnreliable` (§4), and — in v2 — the
sibling baseline file (§5). "Save as Favorite…" in the plan view's action
bar creates the favorite (command `sync.saveAsFavorite`). For an ad-hoc
pair (built from the panes, never saved), `pairId` is the SHA-256 over
both resolved endpoint identities plus paths — stable across invocations —
so ad-hoc pairs get a `sync_state` file too (`mtimeUnreliable` persists)
and the newest-20 journal pruning (§8) applies per `pairId` as usual;
`sync_state` files for ad-hoc pairs untouched for 90 days are pruned
together with their journals (subject to §8 rail 9's live-trash
exception).

## 10. Execution and the activity panel

A running plan is one task in the transfer queue (D16): the executor —
running in the engine isolate (D8) — registers a sync task facade with
`TransferQueue`, so the activity panel (02 §6) shows a single row titled
`Sync "Blog → webserver"` with the standard anatomy: progress bar, byte and
file counts, speed/ETA per 02 §5.3, and per-item sub-rows under the
chevron. Pause and cancel follow 03 §4.4 semantics unchanged (pause stops
new items, the in-flight file's bytes are re-sent on resume; cancel is
sticky and cleans temps). Transfers acquire channels through the same
per-server leases (03 §3.2), count against the same global in-flight limit,
and await the same `BandwidthLimiter` token bucket — a sync run is throttled
and scheduled like any other work, with `transferConcurrency` (default 4)
as its own upper bound.

The plan view stays open during execution, ticking rows
`pending → running → done/failed/skipped` live; the panel row and the plan
view render the same engine state (per-row `ValueListenable`s, never a
global notifier — 02 §12). The finished run appends one record to the queue
history (03 §4.6) and leaves its journal (§8) as the detailed report; the
plan view's summary bar offers `Retry Failed · Restore Trashed Files… ·
Copy Report` (plain-text summary to the clipboard).

## 11. Package layout and testing hooks

`packages/poltergeist_sync` — pure Dart, no Flutter imports, no `dartssh2`
(03 §1 dependency rules). Per D3 there is **no sync-private VFS**: the
engine takes two `RemoteFileSystem` instances (a `LocalFileSystem` from
`poltergeist_core` and/or a leased remote adapter) and nothing else.

```
packages/poltergeist_sync/
  lib/poltergeist_sync.dart        barrel: plan model, scanner, differ,
                                   executor, journal, exporter
  lib/src/
    ignore.dart                    gitignore-style matcher + app defaults (§3)
    scan.dart                      TreeScanner -> ScanResult (§3)
    compare.dart                   comparison modes, tolerance, NFC matching,
                                   name-hazard detection (§3, §4)
    diff.dart                      (ScanResult, ScanResult, SyncRuleSet)
                                   -> SyncPlan (§5, §6)
    plan.dart                      the data model (§6)
    executor.dart                  SyncExecutor: preconditions, tmp+rename,
                                   trash moves, setTimes+verify (§8)
    journal.dart                   RunJournal: JSONL, retry set, undo (§8)
    rsync_export.dart              buildRsyncCommand (§2.1) — never executes
app/poltergeist_app/lib/sync/      Flutter: plan view, filters, overrides,
                                   header, run summary (§7)
```

Testing hooks, elaborated in 08:

- **In-memory VFS**: an `InMemoryFileSystem implements RemoteFileSystem`
  test fake (shared with the queue tests) with fault injection — unlistable
  directories, setstat-ignoring mode, mid-run mutations for precondition
  tests, EXDEV-style rename failures.
- **Property tests** over generated trees, asserting the invariants: Update
  and Additive plans contain no `delete*` items; applying a Mirror plan
  makes destination converge to source under every comparison mode;
  executor + journal replay is idempotent; undo restores every trashed
  path; plan ordering obeys §6's contract.
- **Golden tests** for the rsync exporter (§2.1) and the header sentence
  copy (§7), plus a static check that `poltergeist_sync` never references
  `Process` (§2's never-executes invariant).
- **sshd-in-Docker matrix** (08): OpenSSH variants including a chrooted
  `internal-sftp` config and a setstat-ignoring configuration to exercise
  the §4 fallback end to end; the P7 scan benchmark (≥ 1 000 remote
  entries/s on LAN, D12) runs against this fixture.
- Remote-side `setTimes` tests gate on the Séance pin bump (03 §2.4); until
  then the engine's remote tests run with `mtimeUnreliable` forced on, which
  keeps every other code path testable.

## Definition of done

- [ ] `poltergeist_sync` exists with the §11 layout; no Flutter, no
      dartssh2, no `Process` usage anywhere in the package.
- [ ] Scanner: pipelined remote readdirs (8 outstanding, M0-tuned), live
      progress counters, both-sides subtree exclusion on scan error,
      symlinks skipped and counted, gitignore-style rules with the
      `.poltergeist*` defaults applied.
- [ ] Name hazards (NFC/NFD, case collisions, Windows-invalid names) appear
      as conflict-class plan items with the §7 reason strings — never
      silently fixed.
- [ ] Comparison: size+mtime with 2 s tolerance and whole-second
      truncation; `sizeOnly` and `contentHash` modes; `setTimes` after
      every transfer with re-stat verification; automatic `sizeOnly`
      fallback plus visible notice when a server ignores setstat.
- [ ] Exactly three modes — Update (default), Mirror, Additive two-way —
      encoded as direction × deletion policy; unresolved conflicts execute
      as skip.
- [ ] `SyncPlan` model as specified in §6, including the ordering contract
      (mkdirs first, deletes last deepest-first, delete phase only after a
      clean copy phase, kind-change pre-delete per rule 4).
- [ ] Plan view: header sentence with the exact §7 copy patterns, glyph +
      color + reason table, filter chips with counts, per-item override
      cycling and context menu, bulk conflict resolution, Run button that
      states its consequence.
- [ ] Safety rails: mandatory preview, >50 % typed confirmation (under the
      `maxDelete` cap, which dominates), `maxDelete` refusal,
      `.poltergeist-trash/<runId>/` rename trash with the age-notice purge
      chip and `sync.purgeTrash` (never automatic), the out-of-root
      `trashPath` option with the docroot warning, tmp+rename writes,
      per-item precondition re-stat, JSONL run journal (live-trash
      retention exception) with Retry Failed and Restore Trashed Files.
- [ ] "Copy as rsync command": golden-tested exporter implementing the §2.1
      flag table, clipboard-only, with the dry-run line and the
      caveat/override comments.
- [ ] Saved pairs persist as the savedSync bookmark kind (04 schema), open
      from the sidebar, and sync via Séance's server; local state in
      `sync_state/`.
- [ ] Execution appears as one activity-panel task with per-item sub-rows,
      shared throttling/limits, and live plan-view row updates.
- [ ] Test hooks in place per §11: in-memory VFS with fault injection,
      property tests, exporter goldens, Docker matrix incl. the
      setstat-ignoring server, P7 benchmark.

## Explicitly out of scope

| Deferred item | Where it lives |
|---|---|
| True two-way sync with baseline DB, tombstones, move detection | v2 (D25); design sketch §5; milestone parking in 07 |
| rsync accelerator (opt-in, per-item, `--files-from` from our plan) | v2 (D25) |
| Full undo (removing copies a run created, beyond restoring trash) | v2; journal already records what it needs (§8) |
| Content-hash acceleration via exec channel or SFTP `check-file` | v2 (D25); mode contract fixed in §4 |
| Scheduled / watched / auto-run sync | v2 (D25); parked in 07 |
| Symlink `copyAsLink` / `follow` policies | v1.x/v2; enum reserved in §6 |
| Remote `setTimes` before the Séance pin bump | upstream PR + pin sequencing in 04/07 (03 §2.4) |
| Named reusable skip-rules engine (Transmit-style Rules) | 07 parking; sync ships its own ignore rules (§3) |
| Text diff view for double-clicked pairs | 06 (editor/preview), v1.x |
