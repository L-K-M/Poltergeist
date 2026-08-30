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
rules, {int manualOverrides = 0, required DateTime now})` — pure function,
golden-string tested (`now` is required precisely so the function stays
pure: an implicit `DateTime.now()` default would bake wall-clock into the
timestamped backup-dir and break the goldens). `ResolvedSyncEndpoints` carries user/host/port/path
per side; the app layer resolves `BookmarkServerRef` → identity before
calling. `manualOverrides > 0` emits the per-item-override comment below.
Output layout is part of the golden contract: all `# note:` comment lines
first (auth caveat, override count, approximation notes, in the order the
rules below introduce them — every "note comment" in the table lands in
this leading block, never after a command), then the commented dry-run
variant, then the real command (two dry-run/command pairs, one per
direction, in the Additive case; the both-remote case below legally
emits only its note and no command — a golden variant of its own):

```
# Preview first (matches Poltergeist's plan):  rsync -n -i <flags…> SRC DST
rsync <flags…> SRC DST
```

The live line is deliberately the real command: the exporter is reachable
only from the plan view, so the user has just reviewed exactly what it
will do — the dry-run line exists for re-verification outside the app,
not as a gate. Pasting the block executes the real run; the layout says
so here rather than pretending otherwise. This holds for **every**
configuration, `deletions: permanent` + `backups: none` included — a
considered decision, recorded here so it is auditable: inverting the
layout for one configuration would fork the golden contract and make
paste behavior depend on settings the paster may not remember, the
permanent+none combination already requires two explicit per-pair
opt-ins away from safe defaults, and the leading `# note:` block states
what the command does before any executable line appears.

Flag mapping from `SyncRuleSet` (§6):

| Ruleset element | rsync rendering | Notes |
|---|---|---|
| base | `-r -p`, plus `-t` when `preserveMtime` | `-p` mirrors the engine's mode preservation (§4); `-t` is on by default; without it nothing converges |
| `direction` | source rendered first with a trailing `/`, destination second; `rightToLeft` swaps them | remote endpoint renders as **one single-quoted word** — `'user@host:path/'` — from `ResolvedSyncEndpoints` (quoting only the path half would leave `user@host:` outside the quotes, and a username or host containing shell metacharacters would be live; one quoted word keeps the whole remote spec inert); adds `-e 'ssh'` when either side is remote — single-quoted like every other generated argument, the same one-quoting-style rule as the port variant below |
| `mtimeToleranceSecs` | `--modify-window=2` | verbatim value; emitted only for `sizeAndMtime` pairs — under `--size-only` or `-c` rsync never consults mtimes. The caller passes the **effective** ruleset, not the configured one: a pair auto-downgraded to `sizeOnly` by §4's `mtimeUnreliable` fallback (state that lives in §9's `sync_state`, outside `SyncRuleSet` — the app layer resolves it before calling, exactly as it resolves `BookmarkServerRef`) or by `preserveMtime: false` exports `--size-only` with no `--modify-window`; golden fixture required |
| `comparison: sizeOnly` | `--size-only` | |
| `comparison: contentHash` | `-c` | |
| Update mode | no delete flag | rsync's default |
| Mirror mode | `--delete-delay` | deletions after transfers — same order as our executor (§6). rsync's default is close to our failure gate: it skips the whole delete phase on I/O errors (`IO error encountered -- skipping file deletion`, unless `--ignore-errors` is passed — which the exporter never emits); the residual divergence is non-I/O partial failures, where rsync may still delete and our executor never does — the approximation `# note:` describes exactly that residue |
| `maxDelete` | `--max-delete=500` | verbatim for values ≥ 1; a `0` must never be emitted, because its rsync meaning is **version-dependent** — rsync ≥ 3.0.0 reads `--max-delete=0` as "no deletions allowed", while older rsync (≤ 2.6.9 — long the system default on macOS, common on NAS boxes) reads it as *unlimited* — so the exporter omits `--delete-delay` and `--max-delete` entirely and the `# note:` states plainly: `# note: maxDelete is 0 — this command performs no deletions (the plan wouldn't either)`; golden fixture required. Values ≥ 1 carry their own divergence `# note:` — rsync deletes **up to** the cap and then stops with an error (deleted directories count toward the limit), while §8 rail 4's plan refuses to run **as a whole** when deletions exceed the cap — never a partial run: the note states exactly that asymmetry (the command may perform up-to-cap deletions in a run the plan would have refused to start); golden fixture for a Mirror export with the note |
| `deletions: trash` and/or `backups: trash` | `--backup --backup-dir='.poltergeist-trash/rsync-<yyyyMMdd-HHmmss>'` (or the destination side's `trashPathLeft`/`trashPathRight` when set, §8 rail 5 — rsync's backup-dir applies on the receiving side, so the exporter uses the destination side's setting) | timestamp computed at copy time (`now`); rsync's one backup-dir captures deleted and overwritten files alike, so when only one of the two knobs is `trash` the export approximates and a comment says so. The in-root default trash survives a Mirror export's `--delete-delay` **by explicit dependency on the emitted excludes**: the app-default `.poltergeist*` filter lands first on the command line (excludeGlobs row) and rsync does not delete excluded destination files unless `--delete-excluded` is passed — which the exporter never emits, an invariant the §11 Mirror-protection golden pins with a destination-only `.poltergeist-trash/` entry asserted absent from the deletion set. Anchoring is explicit: an absolute `trashPath*` renders verbatim; a relative value renders destination-root-relative, matching rsync's own resolution of a relative `--backup-dir` against the destination directory — golden fixture with an absolute custom trash path |
| `deletions: permanent` + `backups: trash` | `--backup --backup-dir='…'` as above | approximation in the safe direction: rsync's backup-dir also rescues the *deleted* files the plan would delete permanently, so the export deletes less than the plan — the comment must say so |
| `deletions: permanent` + `backups: none` | no backup flags | |
| `excludeGlobs` + defaults | one filter per pattern — plain → `--exclude='pat'`, `!` negation → `--include='pat'` — emitted in **reversed** pattern order, because gitignore is last-match-wins and rsync filters are first-match-wins: reversing makes the two agree (app defaults, evaluated last by the engine per §3, therefore land first on the command line) | rsync's filter language accepts `*`, `?`, `**`, and trailing-`/` dir-only patterns; re-including a file under an excluded directory is representable in neither engine (§3) nor export — where gitignore semantics otherwise diverge the export is an approximation and says so in a `# note:` |
| `includeHidden: false` | `--exclude='.*'` | approximation: matches dot-prefixed names only — the Windows hidden *attribute* is not representable (`# note:` when **either** side is Windows — a Windows-hosted remote hides by attribute exactly as a Windows client does); emitted in the position matching the engine's evaluation order (after user rules, before app defaults — i.e. between them in the reversed §-order above) |
| `symlinks: skip` | no `-l` | rsync without `-l` skips symlinks with a warning — same behavior |
| Additive two-way | two commands, each direction with `-u` and no delete flag | preceded by `# note: -u approximates conflicts as newer-wins; Poltergeist surfaces them instead` |
| `transferConcurrency` | not representable | note comment: `# note: rsync is single-stream` |
| `acceptedTimeShifts` | not representable beyond `--modify-window` | note comment when non-empty |

Additional rules:

- Paths are POSIX single-quoted; embedded `'` becomes `'\''`.
- A local **Windows** path is not directly runnable by Cygwin/cwRsync/MSYS
  rsync builds (`C:\Users\me\blog` needs `/cygdrive/c/Users/me/blog` or a
  build-specific prefix); the exporter renders the path as-is and emits
  `# note: adjust the local Windows path for your rsync build` — the
  spec deliberately does not pick one build's convention. The golden
  fixtures include a Windows-local pair.
- A remote side on a nonstandard port renders `-e 'ssh -p <port>'` —
  single-quoted like every other generated argument (one quoting style
  in the goldens, and no `$`/backtick interpolation if the transport
  string ever grows) — the
  port travels in `ResolvedSyncEndpoints` and must reach the command, or
  the copy silently talks to port 22.
- When both endpoints are remote, rsync refuses to run ("The source and
  destination cannot both be remote"); the exporter emits a comment saying
  the command is not directly runnable (Poltergeist routes such pairs via
  the local machine) instead of a command that fails.
- When the plan carries manual per-item overrides, prepend
  `# note: N manual per-item overrides are not reflected — this command
  applies the ruleset only and may copy or delete items you excluded in
  the plan`.
  Per-item edits are deliberately not compiled into `--exclude`/
  `--files-from` lists — rsync's include/exclude ordering is famously
  subtle, and a wrong translation would betray the feature's whole point.
- A comment line notes the auth caveat:
  `# note: uses your OpenSSH config and known_hosts, not Poltergeist's
  connections` — carrying the same `# note:` prefix as every other
  leading-block comment, so the layout contract stays uniform.
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
  rendered in the warnings strip (§7). A side whose sync **root** cannot
  be listed aborts planning with an error state — never an empty,
  "everything matches" plan.
- **Symlinks are never followed** (loop and escape-the-tree hazards). v1
  policy: skip with notice — symlink entries are counted and reported as one
  warning (`14 symbolic links skipped`); `SymlinkPolicy.copyAsLink` and
  `follow` are reserved enum values for v2. Scans use `followLinks: false`
  everywhere, matching the transfer queue (03 §4.2).
- **Ignore rules** are gitignore-style, evaluated during the scan so ignored
  subtrees are never descended: blank lines and `#` comments; `*`, `?`,
  `**`; trailing `/` matches directories only; leading `/` anchors to the
  sync root; `!` re-includes — but never within an excluded directory
  (pruned subtrees are simply not descended, exactly like git; the rsync
  export inherits the same limit). Per-pair rules come from
  `SyncRuleSet.excludeGlobs`; app-level defaults are always applied and not
  user-removable — evaluated **after** every per-pair rule, so under
  last-match-wins no user `!` can re-include them (a broad `!.*` must
  not re-admit the trash or temp files into planning):
  `.DS_Store`, `Thumbs.db`, `desktop.ini`, `.poltergeist*`,
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
    never overwrite silently. The check needs each side's case
    sensitivity, so the scan records it per side on `ScanResult`: the
    local side probes it empirically **before the walk starts** (create
    `.poltergeist-caseprobe` under the sync root — a name the
    non-removable `.poltergeist*` default exclusion guarantees no scan
    ever admits — stat its uppercase spelling, delete it; attributes
    lie less than platform guesses; on a root the app cannot write, the
    probe is skipped, the side is treated as case-sensitive, and a
    `ScanWarning` records the assumption); the remote side defaults
    to case-sensitive with a per-pair override in the pair editor
    (platform detection over SFTP is guesswork; a wrong "insensitive"
    guess would silently skip legitimate distinct-case files). A
    defaulted or assumed sensitivity is second-class on purpose: when
    case-variant names are actually present and the destination side's
    sensitivity came from a default or a skipped probe — not a probe
    result or an explicit override — the affected items render as
    `ask`-class conflict rows instead of proceeding, because a wrong
    "sensitive" guess there would let the second variant silently
    overwrite the first, the exact outcome `caseCollision` exists to
    prevent.
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
  `attrs.modifyTime` in seconds; Séance converts via `_timeFromSeconds`;
  a uint32 seconds field wraps in 2106 — not 2038, that is the signed
  boundary — so mtimes are clamped to the uint32-representable
  range [0, 2^32−1] **on both sides and at every seam**: before storage
  in `EntrySnapshot.mtimeSecs` and the journal, and before any
  `setTimes` request. A pre-1970 local mtime is negative and a
  high-bit value reads as negative through a signed lens; if the
  request went out unclamped while the observation came back clamped
  (or vice versa), §4's verification re-stat would disagree with its
  own request and brand a faithful server `mtimeUnreliable` — with
  both request and observation clamped identically the comparison is
  clamped-vs-clamped and the flag stays truthful), so
  **both sides are truncated to whole seconds before comparing** and no
  sub-second expectation is ever stored about a remote file. Optional
  `acceptedTimeShifts` (e.g. `[3600]`) additionally accepts ±N-second
  offsets **within `mtimeToleranceSecs` of ±N** — never an exact match:
  classic FAT stores mtimes at 2-second granularity, so the observable
  DST delta is 3599–3601, and an exact rule would never fire on the very
  filesystems this setting exists for. Advanced setting, default empty.
- **`sizeOnly`** — for servers with unreliable mtimes (also the automatic
  fallback below).
- **`contentHash`** — thorough mode, opt-in per pair (D7): sizes are
  compared first and only size-equal pairs are hashed with streamed
  SHA-256 on both sides (differing sizes already prove the difference, so
  the hash is skipped); the remote side is read over SFTP (Séance's
  `_remoteContentSha256` pattern — a full download, honest but slow). Exec-
  channel `sha256sum` and the SFTP `check-file` extension are v2
  accelerations (D25); the mode's contract does not change when they arrive.

Directories compare by existence only; a file/directory/symlink kind
mismatch at one path is reason `typeDiffers`, a conflict.

**mtime preservation is mandatory for convergence — and modes travel with
it.** After every upload the executor calls `setTimes(path, modifiedAt:
sourceMtime, accessedAt: sourceMtime)` — in SFTP v3, atime and mtime
travel under one flag, so both are set — and applies the source's
permission bits to the destination (`preserveMode` on the upload itself,
the adapter's existing parameter; `setMode` after write for the
kind-change path). Downloads apply the remote mode to the local file on
Unix and no-op on Windows (03 §2.2's local-mode rule). This is what
`EntrySnapshot.mode` is captured for; the exporter's `-p` mirrors it. After every download it sets the local mtime to the remote's.
`setTimes` is the D3 additive method: `LocalFileSystem` implements it from
day one, the remote side gates on the upstream Séance PR and pin bump
(03 §2.4); the remote-sync milestone in 07 sequences after that bump.
Setting `preserveMtime: false` (§6) forces a `sizeAndMtime` pair to
`sizeOnly` — an explicit `contentHash` pair is never downgraded, the
same exemption as the setstat fallback below — with the same visible
plan-header notice: a `sizeAndMtime` pair that stamps transfer-time
mtimes would re-flag every copied file as newer forever, the classic
never-converging sync.

**Verification and the setstat fallback.** After `setTimes`, the executor
re-stats and journals the *observed* mtime. Some servers ignore or clamp
setstat (chrooted or read-mostly setups). If the observed value differs from
the requested one beyond the tolerance, the item is journaled with
`setstatIgnored: true`; at run end the pair's local metadata (§9) records
`mtimeUnreliable: true`. From then on plans for that pair compare
**`sizeOnly` automatically** — only when the pair's mode is
`sizeAndMtime`; an explicit `contentHash` opt-in is never downgraded
(hashes don't depend on mtimes, and D7's thorough-mode contract holds) —
with a visible notice line in the plan header:
`This server does not keep modification times — comparing by size only.`
(pair settings offer an override back to `sizeAndMtime`; whenever the
pair's mtimes are untrusted — `mtimeUnreliable` recorded, or
`preserveMtime: false` — `ConflictDefault.newerWins` degrades to `ask`,
because "newer" is undefined without trustworthy mtimes, matching §7's
bulk-bar rule. The degradation keys on **mtime trust, not comparison
mode**: a `contentHash` pair is never downgraded to `sizeOnly`, yet a
recorded `mtimeUnreliable` still degrades its `newerWins` — hashes
prove *that* files differ, never *which* is newer). The journaled observed
mtimes are how the clamp is *detected*; the `sizeOnly` downgrade is what
prevents phantom flags on the next compare — overriding back to
`sizeAndMtime` knowingly re-opens the re-flag loop. Note that Transmit-style clock-skew probing is unnecessary here:
we compare *stored* mtimes that we set explicitly, not upload wall-clock
times, so server clock offset cancels out **for every file Poltergeist has
written**; first-run foreign files still rely on `mtimeToleranceSecs` (and
`acceptedTimeShifts`) to absorb skew. The remaining failure mode is
setstat being ignored, which this fallback handles.

## 5. Modes (D6)

Modes are **direction × deletion policy**, because that is how users reason
and how the preview explains itself. v1 ships exactly three:

| Mode | Ruleset encoding | Behavior |
|---|---|---|
| **Update** (default) | one-way, `deletions: none` | copy new + changed source→destination; with `backups: trash` (the default) it can never lose destination data — overwritten versions are backed up per §8 |
| **Mirror** | one-way, `deletions: trash` (or `permanent`, per-pair opt-in) | Update + delete destination-only orphans; deletions render red with a count; the >50 % and `maxDelete` rails apply (§8) |
| **Additive two-way** | `bidirectional`, `deletions: none` | union both directions; never deletes; same-path-changed-on-both-sides becomes a conflict item that is never *silently* overwritten — unresolved conflicts execute as skip, and only an explicit non-`ask` `ConflictDefault` resolves them at diff time |

The mode picker sits on the plan header (§7) as a segmented control
`Update · Mirror · Additive` with a direction toggle (`→` / `←`) for the
one-way modes. Mirror is a labeled choice made *on* the preview, not buried
in settings (Transmit's checkbox lesson); selecting it reveals the deletion
destination: `Deleted items go to .poltergeist-trash` (default) or
`Delete permanently` (explicit per-pair opt-in, D15).

Additive conflict handling: `ConflictDefault` (§6) resolves conflicts at
diff time (`newerWins` / `keepLeft` / `keepRight` / `skip`); the default
`ask` leaves them as conflict items. `newerWins` degrades to `ask`
whenever the pair's mtimes are untrusted (§4 — `mtimeUnreliable` or
`preserveMtime: false`, in **any** comparison mode, `contentHash`
included) — mtimes the engine itself
distrusts must not decide conflicts. Unresolved conflicts **execute as
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
  mtimes (absorbing setstat-clamping servers), optional hash, written
  incrementally as each item completes (the crash-safety bullet below is
  the authoritative timing — "end of run" would contradict it).
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
  // 04 §2.1 — BookmarkServerRef is serverConfigId XOR
  // EmbeddedHostIdentity; creds resolve via the vault, never embedded.
  final BookmarkServerRef server;
  final String path;
}
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
  final ConflictDefault conflictDefault; // default ask. Bidirectional
                                         // conflicts generally; in the
                                         // one-way modes it participates
                                         // only in §6 rule 4's typeDiffers
                                         // resolution (where the no-delete
                                         // modes force it to skip)
  final List<String> excludeGlobs;       // gitignore-style (§3)
  final bool includeHidden;              // default true (it's a file manager)
  final SymlinkPolicy symlinks;          // v1: skip
  final String? trashPathLeft;           // per SIDE, resolved on that side's
  final String? trashPathRight;          // host: null = in-root
                                         // .poltergeist-trash under that
                                         // side's sync root; set =
                                         // out-of-root trash there (§8
                                         // rail 5 — one shared string could
                                         // not be same-filesystem on both
                                         // hosts). The engine always
                                         // excludes the effective trash
                                         // roots from scans, regardless of
                                         // excludeGlobs/includeHidden
  final int maxDelete;                   // hard cap; default 500
  final double deleteFractionWarn;       // default 0.5 -> typed confirm (§8)
  final bool preserveMtime;              // default true; false forces a
                                         // sizeAndMtime pair to sizeOnly
                                         // (§4; contentHash is never
                                         // downgraded) — sizeAndMtime never
                                         // converges without preserved
                                         // mtimes
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

enum SyncItemStatus {
  pending, running, done, failed, skipped,
  conflicted, // rail 7's changed-since-preview flip — a race, not a hard
              // error, but it gates rule 3's delete phase like a failure
}

class SyncItem {
  final String relativePath;             // relative to the sync root,
                                         // '/'-separated, no trailing
                                         // separator, byte form preserved
                                         // (NFC only for matching, §3).
                                         // "Byte form" = the side's
                                         // NFC/NFD choice among valid
                                         // UTF-8, never arbitrary bytes:
                                         // names that don't decode as
                                         // UTF-8 are flagged per 02 §13
                                         // and never enter a plan. The
                                         // one normalization rule for
                                         // every relativePath in this
                                         // chapter, journal included
  final EntrySnapshot? left;             // null = absent on that side
  final EntrySnapshot? right;
  final SyncActionType suggested;        // the engine's proposal
  SyncActionType effective;              // after override / conflict pick
  final SyncReason reason;
  bool userOverridden;                   // renders the "manual" dot (§7)
  SyncItemStatus status;
  String? error;                         // side-neutral message:
                                         // RemoteFileException.message for
                                         // a remote-side failure, the local
                                         // filesystem error's message
                                         // (03 §2.2's funnel wording) for a
                                         // local commit/trash failure
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
  final int replacedFiles;               // §6 rule 4 pre-delete removals —
  final int replacedBytes;               // first-class here because the §7
                                         // replace clause, the Deletes
                                         // chip, and rails 3–4 all count
                                         // them, and they are not payload
                                         // bytes of any action class (an
                                         // ad-hoc second walk over items
                                         // is how one-item-one-deletion
                                         // drift creeps back in)
}

class SyncRunRecord {                    // journal header, JSONL (§8)
  final String runId;                    // '<first 8 hex of this
                                         // device's 04 §3.1 deviceId>-
                                         // <uuidV4>' — the prefix lets
                                         // §8 rail 5 tell this
                                         // machine's trash directories
                                         // from a sibling machine's
                                         // without remote journal
                                         // access; no layout change,
                                         // the prefix rides inside the
                                         // <runId> path segment
  final String pairId;                   // the canonical state key (§9),
                                         // never a bookmark id
  final DateTime startedAt;
  final SyncRuleSet rules;               // snapshot at run time
  final PlanTotals totals;               // §8 rail 9's header contents —
  final List<ScanWarning> warnings;      // the post-run report reads these
  // followed by per-item lines: relativePath, side, action, outcome,
  // bytes, durationMs, userOverridden, trashLocation?,
  // trashContentSha256? (rail 5 copy-fallback entries only — rail 9's
  // restore hash-verifies those), observedMtimeAfterWrite?,
  // setstatIgnored? — side and userOverridden
  // are what §7's override dot and §8's per-side accounting read back
}
```

**Ordering contract** (`SyncPlan.items` and the executor):

1. `makeDir*` items first, shallowest-first, so parents exist.
2. Copies and updates next; the executor may run them in parallel up to
   `transferConcurrency` (order within the group is not significant).
3. Deletions last, **deepest-first** (children before parents), and the
   delete phase starts only after the copy/update phase finished **without
   failures** — rsync's `--delete-delay` insight, hardened. "Failure"
   for this gate means exactly two statuses: `failed`, **and rail 7's
   `conflicted` flips** — a copy displaced by destination churn is
   precisely the run deletions must not proceed in. Every `skipped`
   item is exempt, engine-suggested and user-set alike: equal,
   excluded, and symlink rows are no-op skips present in virtually
   every plan, and counting them would gate every real run's delete
   phase forever. If anything
   gated, every deletion flips to `skipped` with error text
   `Skipped: earlier errors in this run`, and the summary says so.
4. **Kind changes pre-delete.** When an item's effective action creates a
   file or directory at a path whose destination entry has a different kind
   (`typeDiffers` resolved to a copy/mkdir), the executor
   removes the destination entry first — honoring `DeletionPolicy`/trash
   (in a no-delete mode the removal always goes to trash: there is no
   permanent-delete opt-in to honor there), deepest-first for a directory
   being replaced by a file — then performs
   the makeDir/copy. The removal and creation stay one plan item so the
   preview remains one row per path (a mkdir over an existing file, or a
   file write onto an existing directory, would otherwise fail and trip
   rule 3's deletion skip). When the entry being replaced is a
   **directory**, its descendants are **subsumed** into the parent item:
   the differ emits no separate items for paths that exist only under
   it — otherwise the parent's pre-delete would remove them first and
   every child item would then flip to a spurious rail-7
   `changed since preview` conflict. The pre-delete counts **every file
   it removes** toward `maxDelete` and the delete-fraction warning
   (never "one item = one deletion"), those files render in the §7
   replace clause's `{j}` and byte totals, and the journal writes one
   `trashLocation` line per removed file under the parent item. A
   pre-delete-carrying item keeps its rule-1/rule-2 phase and ordering —
   a makeDir with a pre-delete still runs in the makeDir group,
   shallowest-first, before any copy into it; only its *removal step* is
   what rule 3's gate checks (rule 2's "order not significant" applies
   to file copies with no parent-child dependency, never to makeDirs).
   Pre-delete removals render
   red and suppress the header's green no-deletion tail (§7, §8 rail 2).
   Who may resolve `typeDiffers` to a copy differs by mode: in Mirror,
   `ConflictDefault` and per-item overrides both may; in the no-delete
   modes (Update, Additive — `deletions: none`) an automatic
   `ConflictDefault` resolves `typeDiffers` to **skip** and only an
   explicit per-item override authorizes the pre-delete — a mode whose
   header can promise "nothing deleted" never removes anything without
   the user having picked that row by hand. Pre-deletes also inherit
   rule 3's failure gate, and under rule 2's parallelism the gate is a
   **barrier, not a peek**: before a removal step begins, the executor
   drains all in-flight transfers, re-checks the failure flag, and only
   then removes (parallelism resumes after) — a moment-in-time check
   would let a sibling transfer fail while the removal is mid-flight.
   An item carrying a pre-delete that reaches the barrier after the run
   has recorded any failure flips whole to `skipped` with
   `Skipped: earlier errors in this run` — a removal never happens in a
   degraded run.
5. **No symlink traversal on write.** The executor addresses every
   destination it creates, replaces, or removes with
   `followLinks: false` semantics end to end, matching the scan (§3):
   rail 7's pre-action re-stat additionally confirms that no component
   of the item's destination parent chain has become a symlink since
   the scan — a link introduced in that window would otherwise let a
   write, a rule-4 pre-delete, or a rule-3 deletion escape the sync
   root through it. A failed check flips the item to `conflicted` with
   `changed since preview`, exactly like any other precondition
   mismatch (and therefore gates the delete phase per rule 3).

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
  (omit either clause when its count is zero). Additive two-way
  aggregates both directions into `{n}`/`{m}` and renders
  `{destination}` as `both sides`; the per-direction split stays visible
  in the item table and filter chips — the §11 header goldens include an
  Additive plan with copies in both directions.
- No deletions (green-tinted tail): `Nothing will be deleted.` — rendered
  only when the plan holds no delete-phase items *and* no kind-change
  pre-deletes (§6 rule 4); a plan that removes anything never shows it.
- With deletions (red-tinted clause):
  `Delete {k} files on {side} (moved to trash at {trashLocation}).` — or
  `Delete {k} files on {side} permanently.` for the opt-out.
  `{trashLocation}` renders the named side's effective trash root — its
  in-root `.poltergeist-trash` default or that side's out-of-root
  `trashPathLeft`/`trashPathRight` (§8 rail 5) — so the sentence always
  says where the files went; the §11 header goldens cover both.
- Kind-change pre-deletes (§6 rule 4, red-tinted clause):
  `Replace {j} items of a different kind on {side} (previous versions
  moved to trash at {trashLocation}).` — the parenthetical becomes
  `(previous versions deleted permanently)` under Mirror's permanent
  opt-in; in no-delete modes it is always the trash form (rule 4).
- Conflicts (amber clause): `{c} conflicts need a decision.`
- Nothing to do: `Both sides match. Nothing to do.`
- sizeOnly fallback notice (§4) renders as its own line under the sentence.

**Item table** — virtualized (P-budget rules of 02 §12 apply), flat with a
path column by default, groupable by directory. Columns:

`name/path · left size · left mtime · action glyph · right size · right
mtime · reason` — a kind-change row carrying an authorized pre-delete
(§6 rule 4) tints **red** (the removal dominates, matching the header's
replace clause), counts in the `Deletes` filter chip with its removed
files so the chips reconcile with the header totals, and keeps its
copy/mkdir glyph with a small red removal badge.

Action glyphs, with color *and* shape carrying the meaning (color-blind
safe, D20): `→` copy new L→R, `⇒` update L→R, `←` / `⇐` mirrored, `⊞`
make directory (green — the `makeDir*` items were the one action class
without a glyph; its side shows in the row's columns), `✕`
delete (red), `↯` conflict (amber), `–` skip (dim). Row tint by action
class: create green, update blue, delete red, conflict amber — theme-aware,
contrast-checked status colors (D20).

**Reason strings are human**, from `SyncReason`: `only exists here` ·
`newer here (2 min ago vs 3 days ago)` · `sizes differ (1.2 MB vs 1.1 MB)`
· `contents differ` · `changed on both sides` · `type differs (file here,
folder there)` · `excluded by rule` · `names differ only by case` ·
`names differ only by Unicode form` · `name invalid on Windows` ·
`couldn't scan — subtree excluded` · `identical` (the `equal` reason —
the most common row whenever "only show actions" is off, so it must
never render blank or as a raw enum name) · `symbolic link — skipped`
(v1's `SymlinkPolicy.skip` rows).

**Filter bar**: chips with live counts — `All (120) · New (12) ·
Updates (3) · Deletes (5) · Conflicts (2) · Skipped (98)` — plus a text
filter and an `only show actions` toggle (hides equal/excluded rows;
default on).

**Per-item overrides** (the FL 4.0.3 lesson: veto is non-negotiable):

- The action glyph is a control: click cycles through the actions valid for
  that item's sides (e.g. a both-sides pair cycles update L→R → update R→L
  → skip → back); right-click offers `Skip`, `Copy left → right`,
  `Copy right → left`, `Delete`, `Reset to suggested`. `Delete` appears
  **only in Mirror** (and only for items whose target side has an entry);
  in the no-delete modes the sole delete-flavored override is §6 rule 4's
  explicit per-item pre-delete authorization on a `typeDiffers` row —
  anything more would hollow out rail 2's promise.
- Multi-select (the 02 §2.5 selection model) + the same context menu
  applies bulk overrides.
- When conflicts exist, a bulk bar appears above the table:
  `Resolve conflicts:  Newer wins · Keep left · Keep right · Skip all`.
  `Newer wins` is hidden whenever the pair's mtimes are untrusted
  (§4 — `mtimeUnreliable` or `preserveMtime: false`, in any comparison
  mode, `contentHash` included) — no bulk
  resolution may trust a clock the engine itself has
  flagged; the remaining options and per-item overrides stay available.
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
2. **No-delete default.** Update is the default mode; delete-*phase*
   items exist only in Mirror and are red, counted, and named in the
   header sentence. The one removal a no-delete mode can perform is §6
   rule 4's kind-change pre-delete, and only when the user explicitly
   overrides that row to a copy/mkdir — automatic `ConflictDefault`
   resolution executes `typeDiffers` as skip in no-delete modes (rule 4),
   so the untouched default path removes nothing, ever. Override-driven
   pre-deletes count toward `maxDelete` and the >50 % rail, render red,
   and replace the green `Nothing will be deleted.` tail with the §7
   replace clause.
3. **The >50 % rail.** Planned deletions (delete-phase items and rule-4
   pre-deletes alike) are grouped by **target side**; the rail fires when
   one side's deletions exceed
   `deleteFractionWarn` (default 0.5) of *that side's* file count —
   and **≥ 10** files, or *every* file on that side however few (a
   full wipe of an 8-file destination must not slip under the floor) —
   whichever side trips it. Deletion counting
   is **per file everywhere** — this rail, the `maxDelete` cap, the §7
   header's `{k}` and the Deletes chip all count the same unit: an
   extraneous directory is never "one deletion" — the scan enumerates
   its contents, each contained file is its own delete-phase item
   (rule 3's deepest-first order presupposes exactly that), and the
   directory itself is a zero-count cleanup item — otherwise one
   extraneous tree of any size would slide under the default cap of
   500. The denominator is that side's scanned file count (planned
   deletions included, the effective trash root excluded — it is never
   scanned, rail 5). Run opens a typed
   confirmation:
   `This will delete 320 of 512 files on webserver — more than {pct} of
   that side. Type DELETE to continue.` — `{pct}` renders as the word
   `half` at the 0.5 default (so the default sentence reads "more than
   half of that side") and as the numeric percentage for **any** other
   value, raised or lowered — a user-adjusted threshold must never claim
   "half". The confirm button stays disabled
   until the word matches. Precedence: the `maxDelete` cap (rail 4) is
   checked first and dominates — the typed confirmation only ever fires
   for plans whose deletion count is under the cap.
4. **`maxDelete` cap** (default 500): a plan whose deletions exceed the cap
   refuses to run **at all** (Run stays disabled — never strip-and-run,
   which would silently diverge the destination); the dialog explains and
   points at the pair's rules to raise it deliberately — and for an
   ad-hoc pair (§9), which has no saved ruleset to point at, it offers
   `Save as Favorite & Adjust Rules…` (saves the pair, opens the pair
   editor focused on `maxDelete`, rescans on close), so Run-disabled is
   never a dead end. No override button
   on the spot.
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
   secrets — may be retrievable over HTTP until purged. The `trashPath`
   rule is **per side** (`trashPathLeft`/`trashPathRight`, §6 — each
   resolved on that side's host; one shared string could not be
   same-filesystem on both machines) and moves that side's trash outside
   that side's root (a
   cross-filesystem rename falls back to copy-then-delete), and the
   docroot warning — trash in-root while the destination path looks like
   a docroot (`public_html`, `www`, `htdocs`, `/var/www`) — appears both
   in the pair editor *and* as a plan-view notice chip: ad-hoc pairs (§9)
   never pass through the pair editor, so the plan view is their only
   chance to catch it. The chip is **persistent, not one-shot**: it
   renders on every plan for the pair until that side's `trashPath*`
   points out of root (or the pair's policies send nothing to trash on
   that side), and its action opens the trash-path field prefilled with
   an out-of-root suggestion (a dot-directory in the same account's
   home, outside the docroot — e.g. `~/.poltergeist-trash`), so the
   fix is one click rather than a settings hunt — dismissing a chip
   once must not permanently silence a secrets-over-HTTP hazard. No
   code path removes trash as a side effect (09 §6
   rule 5): at plan time, if the pair's trash holds entries older than
   30 days, the plan view shows a notice chip — `N trashed files from M
   runs older than 30 days — delete them?` — whose action performs the
   purge; the `sync.purgeTrash` command empties it on demand. Both
   routes confirm through the same dialog, whose body states the two
   things a quick click would miss: the **scope** — trash lives per
   (host, root), so the purge also removes trashed files belonging to
   other sync pairs that use the same root, and the dialog says so
   whenever the matched journals span more than this pair — and the
   **forfeit** — purged runs drop out of `Restore Trashed Files…`
   (rail 9) permanently, so the dialog names the undo it is giving up
   (`These files can no longer be restored.`). The check
   is cheap by construction: run ages and per-item counts come from
   the **local journals of every pair sharing that side's trash root**
   — trash lives per (host, root), not per pair, and two pairs may
   legitimately sync the same root, so a pair-scoped match would
   misread a sibling pair's runs as crash orphans and a purge here
   could empty them unmarked (`startedAt` plus the recorded
   `trashLocation` lines — no remote access for those); a purge writes
   its `purged: true` marker into **every** journal it matched,
   other pairs' included, so rail 9's retention stays correct for all
   of them, and confirming
   which `<runId>` directories still exist takes one `listDirectory` of
   the trash root per side — the check's only remote access, never a
   recursive walk. Cross-**pair** matching is not enough, because the
   sharing is cross-**machine** too: saved pairs replicate to every
   device (§9, D4) while journals stay per machine, so two machines
   legitimately write runs into one remote trash root and each sees
   only its own journals — `runId`'s device prefix (§6's
   `SyncRunRecord`) is what keeps their purges apart. A `<runId>`
   directory that listing finds with **no matching local journal** is
   classified by that prefix. Carrying **this device's** prefix, it is
   a crash orphan (a crash between the trash rename and the journal
   write): it joins the same notice using the directory's own mtime as
   its age, and the purge removes it by directory — orphaned trash is
   never invisible, docroot secrets included. Carrying a **foreign**
   device's prefix, it is a sibling machine's run history and is
   **never counted or purged by this machine's notice** — the owning
   machine's own notice ages it out (without the prefix rule, machine
   A would misread machine B's journal-backed trash as crash orphans
   and silently empty B's undo). The explicit `sync.purgeTrash`
   command is the escape hatch for a machine that is gone for good: it
   empties the whole trash root on demand, foreign-prefix directories
   included, and its confirm dialog names them as another machine's.
   The listing also closes the loop in the other direction: a local
   journal whose recorded `<runId>` directory is **absent** from the
   listing is marked `purged: true` on the spot — its trash is already
   gone (purged by a sibling machine, or removed by hand), nothing
   restorable remains, and rail 9's retention releases the journal
   instead of holding it forever. Trash directories created
   by an exported rsync command (§2.1's `rsync-<ts>` backup dirs) are
   journal-less on every machine and carry no device prefix — their
   literal `rsync-` prefix classifies them — and they keep the
   crash-orphan treatment: the same notice ages them out by mtime and
   the same purge removes them, but journal-driven `Restore Trashed
   Files…` (rail 9) cannot restore what the app never journaled — an
   exported command runs outside the app's undo story, which is part of
   what its `# note:` lines already disclaim. When a side is unreachable
   that listing is skipped and
   the notice falls back to the newest cached trash state in `sync_state`
   (§9) — it degrades, never blocks or errors the plan view: the chip
   labels its staleness from the cache's `lastListedAt` (`as of 3 days
   ago`) and its purge action is **disabled** for that side, because a
   purge must act on a live listing, never on a cache that a sibling
   machine's purge or a manual cleanup may already have invalidated. A
   purge
   writes a
   `purged: true` marker line into each affected run's journal, which is
   what releases those journals for pruning (rail 9) and makes the
   retention exception locally evaluable.
6. **Atomic writes.** Uploads write to an exclusive sibling
   `.poltergeist-<8 hex>.tmp` and rename over the target; downloads commit
   via `replaceLocalFile` (03 §2.3). No torn file ever holds the final
   name; failed temps are cleaned up.
7. **Per-item precondition re-stat.** Immediately before acting, each item
   re-verifies against its plan snapshot: copy-new requires the destination
   still absent — except a §6-rule-4 `typeDiffers` item resolved to
   copy/mkdir, whose destination is present *by definition*; its
   precondition is that the destination still matches the plan snapshot
   (same kind; for a file, size plus mtime under the same tolerant
   comparison the update/delete rule below mandates — never exact mtime
   equality, or sub-tolerance drift would flip the item and its
   conflict would gate the whole delete phase), because the pre-delete
   is what legalizes
   the write; update and delete require the destination to match the
   snapshot — **for files**, size plus mtime compared with the pair's
   `mtimeToleranceSecs`/`acceptedTimeShifts`, never exact equality;
   **for directories**, kind only (still a directory — and, for a
   delete-phase parent, empty of everything but entries this run
   already removed): a directory's mtime changes the moment rule 3's
   deepest-first pass deletes its children, so an mtime precondition
   there would spuriously flip every parent after its children and
   Mirror would leave empty directory husks behind on every run
   (uploads additionally use the adapter's
   `expectedTarget` compare-and-swap, 03 §2.1). Any mismatch flips the
   item to status `conflicted` with `changed since preview`, and the run
   continues — the
   preview→execute race that rsync's two-run model cannot close. A
   `conflicted` item is distinct from `failed` in the journal and
   summary — a race flip, not a hard error — but **counts as a failure
   for rule 3's delete gate**: deletions must never proceed in a run
   where a copy was displaced by destination churn, the exact window
   the `--delete-delay` hardening exists to close. `Retry Failed`
   covers `failed` items; `conflicted` items return through a re-scan,
   which re-plans them from current reality. A source
   that vanished mid-run fails the item (`failed`), never aborts the run.
8. **Per-item errors never abort the run.** Permission, disk-full, and
   vanished-file errors mark the item `failed` with its
   `RemoteFileException.message`; the summary reports
   `14 copied, 2 failed, 5 deleted (in trash)` with one-click
   `Retry Failed` (re-scans just those paths, rebuilds their
   preconditions, re-executes) — with rail 1 intact on the **source**
   side too: a retried item whose source stat no longer matches the
   plan snapshot returns to the plan view as a fresh conflict row
   instead of executing, because a retry must never quietly push
   content the user never previewed. Connection loss pauses the run; on
   resume, items whose
   journal line records completion are marked done without re-executing.
   The journal line is written *after* the commit rename, so a
   committed-but-unjournaled window exists: a resumed item whose
   destination no longer matches the plan snapshot but matches the
   intended post-state is journaled as done rather than flipped to
   conflict; anything else falls through to rail 7's precondition flip as
   usual. "Intended post-state" means source size always, source mtime
   only when the run is not on the `sizeOnly` path (§4's fallback or
   `preserveMtime: false` — a setstat-ignoring server can never satisfy
   an mtime match, and requiring one would flip every committed item to a
   spurious conflict), and this run's trash/backup entry present where
   the plan expected one.
9. **Run journal.** JSONL per run at `<app-support>/sync_runs/<runId>.jsonl`
   (under the app-provided support directory — `EngineConfig`, 03 §5)
   — a `SyncRunRecord` header line (pair, ruleset snapshot, totals,
   warnings), one line per executed item (outcome, bytes, duration,
   `trashLocation`, `observedMtimeAfterWrite`, `setstatIgnored`), one
   summary line. Every line is appended with an immediate flush — no
   userspace buffering — so a killed process loses at most the line it
   was mid-writing (a torn final line is dropped on replay — 03 §4.6's
   journal-recovery pattern, applied here too) and rail 8's
   resume rule can trust that a missing line means the item did not
   journal, not that a buffer died with it. Journals are pruned to the
   newest 20 per pair — **except**
   a run whose journal records trash entries without a `purged` marker
   (rail 5) — the same locally evaluable rule §9 applies to ad-hoc-pair
   pruning, requiring no existence probe of the trash itself; such a
   journal is retained until the purge (rail 5) marks it: Undo must
   never lose its source while the trash it reverses is still there
   (`sync.purgeTrash` is what finally lets those journals be pruned).
   That retention deliberately has **no age-based upper bound** — a
   journal guarding live trash is undo's only source, rail 5's 30-day
   notice is the pressure valve that eventually clears trash and
   journal together, and its absent-directory rule releases journals
   whose trash disappeared some other way. The
   journal powers the post-run report, `Retry Failed`, and **Undo**: v1's
   `Restore Trashed Files…` restores every trashed/backed-up file by
   reversing the recorded renames — with the parent chain handled for
   the general case, not only the rule-4 replace: files rename into
   trash under their `relativePath` (rail 5's trash mirror creates
   trash-side parents as needed), the emptied source directories are
   then rmdir'd with their own journal lines, and restore recreates
   that directory chain from the journal shallowest-first before
   reversing the file renames — a naive reverse-rename of a deep tree
   would ENOENT on every child whose parent was removed. Each restore
   is conflict-checked with a re-stat per
   file **against the run's recorded post-state** — absent for a
   deletion, the written file's size + `observedMtimeAfterWrite` for an
   update, the created entry for a rule-4 replace; *never* the pre-run
   plan snapshot, which by construction no longer matches anything the
   run touched (comparing against it would skip every restore). A
   destination that no longer matches that post-state
   (changed by a later run or by hand) is **skipped and listed in the
   result** — Undo never overwrites newer changes. For a §6-rule-4
   replace, restore runs in order: conflict-check the run's created
   entry — a created *directory's* recorded post-state is its
   **end-of-run entry set**, the copies this run placed inside it
   included (the journal's item lines under and inside the parent carry
   it) — then remove the entry together with that set, recreate the
   original entry's directory chain shallowest-first, and reverse the
   recorded renames; the per-file `trashLocation` lines under the
   parent item carry the rest. Reverting a replace is atomic on
   purpose: the pre-run file cannot come back while the created
   directory stands, so this is the **one place v1 undo removes
   run-created copies** — the confirm dialog counts those files among
   what it removes, and any file inside the created directory that no
   longer matches its recorded post-state skips the whole replace
   revert (listed in the result) rather than deleting someone's newer
   work. The trashed entry
   itself is verified too: its size is re-statted against the journal
   line — and a rail 5 **copy-fallback** trash entry is additionally
   verified against the `trashContentSha256` its journal line recorded
   at trash time (rename-based entries stay size-only: a rename cannot
   truncate, and hashing every rename would tax the common path for
   nothing) — a mismatch is skipped-and-reported: rail 5's
   copy-then-delete fallback can leave a half-written trash copy when
   interrupted — same-size truncation included, which the size check
   alone would pass — and Undo must never resurrect a truncated
   "previous version" over a good file. Note the explicit
   scope: because overwrite backups are restored
   too, this also reverts files the run *updated* back to their pre-run
   versions — the confirm dialog says so (`Restores 5 deleted and 3
   overwritten files to their pre-run versions.`). Full undo (removing
   every copy the run created) is v2 — the rule-4 replace revert above
   is the sole v1 exception, forced by the restore itself — and the
   journal already records enough for it.
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
<pairId>.json`: `lastRunAt`, `mtimeUnreliable` (§4), `trashCache` —
the per-side newest-known trash summary that §8 rail 5's
unreachable-side fallback reads: `lastListedAt` plus one
`{runId, ageBasis, fileCount}` entry per observed `<runId>` directory,
written after every successful plan-time trash-root listing — and, in
v2, the
sibling baseline file (§5). "Save as Favorite…" in the plan view's action
bar creates the favorite (command `sync.saveAsFavorite`). `pairId` — the
key for `sync_state` and the journals, **for every pair, saved and
ad-hoc alike** — is the SHA-256 over
both sides' **canonicalized** identities — `user@host:port` with the
host lowercased and default port/user made explicit (the default user
resolved from the endpoint's stored identity — the vault/catalog behind
`BookmarkServerRef`, §6 — never the ambient local username, which would
fork every pair on an OS-account rename), plus the absolute
path without trailing separator, case-folded on any side **known**
case-insensitive — a local side via §3's definition-time probe, a
remote side only via the pair editor's explicit override (§3 has no
remote probe by design; the default-sensitive remote is never folded,
since folding a case-sensitive root would merge genuinely distinct
pairs) — with the sensitivity inputs resolved before the first
`sync_state` write, so the id never changes mid-history; flipping the
remote override later is an identity edit and re-keys state like any
endpoint change (`/Users/Alice` and `/users/alice` are one root on a
known-insensitive side) — the two sides hashed in **sorted
order**, so the id survives pane swaps and spelling variants (without
canonicalization, `Example.com` vs `example.com` or a trailing slash
would fork one logical pair into several `sync_state`s and journal
sets) — stable across invocations. The savedSync favorite's own
bookmark id (04 §2.1's `SyncPair.id` mapping) is the *favorite's*
identity, never the state key — which is exactly what makes "Save as
Favorite…" after an ad-hoc run lossless: the canonical `pairId` does
not change at save time, so `mtimeUnreliable`, `trashCache`, journals,
and the live-trash retention they carry all survive the save instead
of orphaning under a freshly minted id. So
ad-hoc pairs get a `sync_state` file too (`mtimeUnreliable` persists)
and the newest-20 journal pruning (§8) applies per `pairId` as usual;
`sync_state` files for ad-hoc pairs untouched for 90 days are pruned
together with their journals — subject to §8 rail 9's live-trash
exception, which is evaluated **locally**: a journal that records trash
entries without a `purged` marker (rail 5) is retained, no remote access
required, so the prune is fail-safe even when the pair's endpoints are
long unreachable.

## 10. Execution and the activity panel

A running plan is one task in the transfer queue (D16): the executor —
running in the engine isolate (D8) — registers a sync task facade with
`TransferQueue`, so the activity panel (02 §6) shows a single row titled
`Sync "Blog → webserver"` with the standard anatomy: progress bar, byte and
file counts, speed/ETA per 02 §5.3, and per-item sub-rows under the
chevron. Pause and cancel follow 03 §4.4 semantics unchanged (pause stops
new items, the in-flight file's bytes are re-sent on resume; cancel is
sticky and cleans temps — which for a sync run means
`.poltergeist-*.tmp` temp files on **either side**, uploads and
download commits alike; the "only" is temps-versus-everything-else,
never upload-versus-download: the run's
`.poltergeist-trash/<runId>/` directory and its journal are undo
material and always survive a cancel, rail 9's retention depends on
it). Transfers acquire channels through the same
per-server leases (03 §3.2), count against the same global in-flight limit,
and await the same `BandwidthLimiter` token bucket — a sync run is throttled
and scheduled like any other work, with the pair's
`SyncRuleSet.transferConcurrency` (§6, default 4) as the run's own
per-pair upper bound *beneath* those global limits — a sync-scoped rule
field, not a rename of any 03 queue setting (03's knobs are the global
in-flight constant and `PoolPolicy`).

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
                                   raw name-hazard detection (§3, §4);
                                   hazard -> conflict-item classification
                                   with §7 reason strings lives in diff.dart
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
  test fake — one instance of the concept, importable across packages
  because it is exported from `poltergeist_core`'s public
  `lib/testing.dart` barrel (08 §3.1's layout; `test/` directories are
  not importable across packages, and a per-package copy would let the
  fault matrix drift) — shared with the queue tests, with fault
  injection: unlistable
  directories, setstat-ignoring mode, mid-run mutations for precondition
  tests, EXDEV-style rename failures, and an interrupted out-of-root
  trash copy (rail 5's copy-then-delete fallback) asserting Undo
  skips-and-reports the truncated trash entry (rail 9).
- **Property tests** over generated trees, asserting the invariants: Update
  and Additive plans contain no `delete*` items (kind-change pre-deletes
  live inside copy items by design, and in Update/Additive an unresolved
  kind change is a *conflict* whose embedded pre-delete runs only on an
  explicit per-item override — which is exactly why a companion property
  can assert a no-delete-mode plan with no user overrides performs zero
  removals, §6
  rule 4); an item carrying a pre-delete that is reached after any failed
  item is skipped and performs zero removals (rule 4's failure gate); a
  user `!` pattern matching an app-default exclude never re-includes it
  (§3's defaults-last rule); applying a Mirror plan
  makes destination converge to source for **hazard-free** generated
  trees, judged by **each mode's own equality relation** — byte-identical
  for `sizeAndMtime` and `contentHash`; for `sizeOnly`, convergence to
  size-equality, with same-size/different-content pairs — known to the
  *generator*, undetectable by the engine in this mode by design —
  asserted absent from every copy and delete item, and the plan header's
  `sizeOnly` notice asserted present (the blind spot is the mode's
  documented contract, so the property pins its boundary and its
  visibility instead of pretending per-pair detection exists)
  (conflicts execute as skip, so
  hazard-bearing trees converge only up to their conflict items — a
  companion property asserts every generated name hazard surfaces as a
  conflict item, never auto-fixed); crash-resume re-execution and a
  second `Retry Failed` pass leave the destination convergent, perform
  no duplicate trash moves, and append no duplicate journal line for the
  same `(runId, relativePath, side)` — the concrete meaning of
  "replay is idempotent"; every executed copy/update journals an item
  line carrying `relativePath` + side + action and every trash move its
  `trashLocation` (the two invariants the out-of-scope table's
  full-undo row depends on — they must not regress); undo restores every trashed path whose destination is
  unmodified since the run, and skips-and-reports mutated ones; plan
  ordering obeys §6's contract.
- **Rail tests**: `maxDelete` refusal fires before any item executes and
  dominates the typed confirmation; the >50 % gate rejects near-miss
  typed input; the trash purge is reachable only through the notice
  chip's action and `sync.purgeTrash` — never as a side effect; a
  journal-less `<runId>` directory carrying a foreign device prefix is
  never counted or purged by the notice while a local-prefix one is
  (rail 5's cross-machine rule), and a local journal whose trash
  directory is absent from the listing is marked `purged: true`.
- **Golden tests** for the rsync exporter (§2.1) and the header sentence
  copy (§7) — the exporter fixtures include a negation preceding a later
  matching exclude (the reversed-order rule must reproduce gitignore's
  outcome), a Mirror export where a destination-only ignored file
  **and the in-root `.poltergeist-trash/` itself** are protected from
  `--delete` by the emitted excludes (§2.1's trash-row dependency: the
  app-default filter lands first and `--delete-excluded` is never
  emitted), the `maxDelete: 0`
  no-delete-flags case, a path pair requiring shell quoting (spaces,
  single and double quotes, `$`, glob metacharacters, an NFD name —
  an unquoted space would split the argument and could retarget
  `--delete` at the wrong directory; POSIX-sh quoting is the pinned
  contract, the Windows-local fixture keeping the same quoting plus its
  adjust-note), and the Windows-local pair; the header goldens
  include the Additive both-directions sentence and both trash-location
  forms per side — plus a static check that `poltergeist_sync` never
  references `Process` (§2's never-executes invariant), enforced at the
  symbol level (an analyzer-based ban on the `dart:io` `Process` API,
  aliased imports included — never a substring scan, which would
  false-positive on comments and reason strings; 08 §3.3 specifies the
  mechanism). A blanket `dart:io` *import* ban is deliberately not the
  rule: `journal.dart`'s own JSONL file I/O under app-support is the
  package's one legitimate `dart:io` use — the invariants being guarded
  are never-executes (the `Process` symbol ban) and no sync-private VFS
  (the review rule that all *sync* filesystem operations flow through
  the two injected `RemoteFileSystem`s), not an I/O-free package.
- **sshd-in-Docker matrix** (08): OpenSSH variants including a chrooted
  `internal-sftp` config and a setstat-ignoring configuration to exercise
  the §4 fallback end to end — including a resume-after-interrupt run on
  the setstat-ignoring server asserting committed-but-unjournaled items
  are journaled done under rail 8's `sizeOnly`-path post-state rule, not
  flipped to conflict; the P7 scan benchmark (≥ 1 000 remote
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
      truncation; `sizeOnly` and `contentHash` (size-gated) modes;
      `setTimes` + mode preservation after every transfer with re-stat
      verification; automatic `sizeOnly`
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
      per-side `trashPathLeft`/`trashPathRight` option with the docroot
      warning, tmp+rename writes,
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
| Full undo (removing copies a run created, beyond restoring trash) | v2 (D25); the §8 journal already suffices *because of two specifics that must not regress*: per-item copy lines (relativePath + side + action) name every created path, and pre-overwrite versions live in trash via `trashLocation` — keep both and v2 undo needs no journal migration; §11's journal property tests pin both invariants |
| Content-hash acceleration via exec channel or SFTP `check-file` | v2 (D25); mode contract fixed in §4 |
| Scheduled / watched / auto-run sync | v2 (D25); parked in 07 |
| Symlink `copyAsLink` / `follow` policies | v1.x/v2; enum reserved in §6 |
| Remote `setTimes` before the Séance pin bump | upstream PR + pin sequencing in 04/07 (03 §2.4) |
| Named reusable skip-rules engine (Transmit-style Rules) | 07 parking; sync ships its own ignore rules (§3) |
| Text diff view for double-clicked pairs | 06 (editor/preview), v1.x |
