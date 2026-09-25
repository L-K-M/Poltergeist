# Poltergeist — plan overview and decision log

**Status:** Accepted chapter by chapter as its PR merges · **Date:** 2026-08-30

Poltergeist is a cross-platform, SFTP-first, two-pane file transfer client
patterned after the great macOS transfer apps (Transmit 5, ForkLift 4) and
built as a sibling of [Séance](https://github.com/L-K-M/Seance), the personal
SSH client whose transport, security, sync, and editor foundations it reuses.

This directory is the whole implementation plan. It was produced from a deep
read of the Séance codebase, feature studies of Transmit 5 and ForkLift 4, a
survey of ~20 competing clients and file managers, and design research on
sync engines and Flutter desktop capabilities. It is written so that an
implementation agent can execute it chapter by chapter without re-deriving
the design — **when a chapter conflicts with this overview's decision log,
the decision log wins; when code reality conflicts with the plan, stop and
update the plan first.**

## Reading order

| Chapter | Contents |
|---|---|
| [01-PRODUCT.md](01-PRODUCT.md) | What Poltergeist is and is not; competitive positioning; differentiators; trust stance; non-goals |
| [02-UX.md](02-UX.md) | The full UX specification: window, panes, tabs, sidebar, activity panel, keyboard/command system, dialogs, design language, performance budgets, accessibility & i18n |
| [03-ARCHITECTURE.md](03-ARCHITECTURE.md) | Packages, the one VFS, connection pool, transfer queue, isolate model, state management, platform seams, code-sharing mechanics |
| [04-SEANCE-INTEGRATION.md](04-SEANCE-INTEGRATION.md) | Bookmark schema and sync design; the Séance upstream PRs and their sequencing; the porting-back policy |
| [05-SYNC.md](05-SYNC.md) | The previewable sync feature: engine, plan model, preview UX, safety rails, the rsync verdict |
| [06-EDITOR.md](06-EDITOR.md) | Built-in editor, external editors, the managed-checkout pipeline, preview/Quick Look |
| [07-MILESTONES.md](07-MILESTONES.md) | Milestones M0–M10 with exit criteria; the distribution workstream; the mobile-constraints memo |
| [08-TESTING.md](08-TESTING.md) | Test strategy: engine tests, fakes, sshd-in-Docker matrix, perf benchmarks, a11y checks |
| [09-PLAYBOOK.md](09-PLAYBOOK.md) | The implementation playbook: conventions, guardrails, definition of done, PR workflow, what never to do |
| [10-WORKSPACE-REDESIGN.md](10-WORKSPACE-REDESIGN.md) | The D32 inspector workspace: window anatomy, header toolbar, shared sidebar (its two densities per D33), pane anatomy, inspector, Sync sheet, menus, Android posture, the Séance sibling contract |

Repository infrastructure (CI, GLM review workflow, release pipeline, build
scripts) already exists on `main` and is documented in
[AGENTS.md](../../AGENTS.md); [docs/STATUS.md](../STATUS.md) tracks live
progress.

## Requirements (from the product brief)

| # | Requirement | Where designed |
|---|---|---|
| R1 | Extremely high usability, polish, user-friendliness — *the point of the app* | 01, 02 (budgets §, design language §) |
| R2 | Two-pane UI; each pane browses local folders or remote servers | 02, 03 |
| R3 | Tabs per pane | 02 |
| R4 | Left bookmarks sidebar, ForkLift-style | 02, 04 (schema) |
| R5 | Bookmark backup integrates with Séance | 04 |
| R6 | Safe, fast, understandable/previewable sync | 05 |
| R7 | Optional bottom panel showing network activity | 02, 03 (queue) |
| R8 | Built-in editor | 06 |
| R9 | External editors | 06 |
| R10 | Improvements flow back to Séance | 04 (porting policy), 09 |

## Decision log

Every open question from the research phase is resolved here, once. Chapters
elaborate these decisions; they do not reopen them. Changing a decision means
editing this file (with rationale) in the same PR as the change.

Quick index: D1 monorepo · D2 code sharing · D3 one VFS · D4 bookmark
sync · D5 shell-less transport · D6 sync engine · D7 hashing · D8
isolates · D9 M0 spike · D10 agent/ProxyJump · D11 design language ·
D12 perf budgets · D13 single window · D14 drag & drop · D15 trash ·
D16 activity panel · D17 editor · D18 security model · D19 trust
stance · D20 a11y/i18n · D21 commands · D22 import · D23 distribution ·
D24 name · D25 parking lot · D26 local↔local · D27 archives · D28
permissions · D29 mobile hooks · D30 Séance license · D31 no mounting ·
D32 inspector workspace · D33 sidebar density · D34 colour vocabulary ·
D35 Android supported

### Stack and shape

- **D1 — Flutter/Dart monorepo mirroring Séance.** `packages/` (pure Dart) +
  `app/poltergeist_app` (Flutter). Desktop first — macOS leads the design,
  Windows and Linux ship from v1.0. Android is supported after v1.0.1
  (D35); iOS is post-v1 (D29). Single
  window, dual pane, tabs per pane in v1 (D13).
- **D2 — Code sharing, one call per layer.**
  - `seance_protocol` and `seance_core`: **git dependencies pinned to a
    Séance tag** — never forked, never copied. This is what guarantees
    sync-wire and TOFU compatibility. Bumping the pin is a routine chore.
    Steady state is a tag pin; a temporarily stalled upstream Séance PR may
    be pinned by commit rev, recorded as a dated open item in STATUS.md,
    and MUST be re-pinned to the next tag once it is released.
  - Séance **app-layer** assets (managed-checkout pipeline, atomic-file
    helpers, editor stack, toast system, `MiddleEllipsisText`, adaptive
    layout math, appearance/accent module, Swift channel patterns):
    **copy-with-attribution** into Poltergeist — blocked until Séance
    publishes a LICENSE (D30) — recorded in a
    `docs/PORTS.md` ledger (source path + Séance commit + local
    divergences). Upstream extraction into shared packages is a welcome
    later step, never a blocker.
  - New pure-Dart packages in this repo: `poltergeist_core` (local VFS
    adapter, connection manager/pool, transfer queue, bookmark
    model/coordinator) and `poltergeist_sync` (scan/diff/plan/executor/
    journal + rsync exporter).
- **D3 — One VFS.** `seance_core`'s `RemoteFileSystem` interface is *the*
  filesystem abstraction for panes, the transfer queue, and the sync engine.
  `LocalFileSystem implements RemoteFileSystem` (in `poltergeist_core`).
  The additive methods Poltergeist needs — `setTimes` (hard prerequisite for
  sync convergence), `setOwner` (chown/chgrp), optional per-call hashing —
  are one small upstream Séance PR, sequenced before the sync engine
  (04 §upstream). Ranged read is deferred to D25's resumable-transfer work
  and lands as its own upstream PR then — keeping the pre-sync PR minimal.
  No second or third filesystem interface may be introduced.

### Séance integration

- **D4 — Bookmark backup rides Séance's sync server, Design A with a B
  fallback.** A new `bookmark` record kind travels inside the existing
  encrypted-record protocol (zero server changes — kind lives inside the
  ciphertext). Sharing the user's Séance *account* (Design A: same
  passphrases, server list **read-write** — amended 2026-09-24 by owner
  directive: Poltergeist authors `serverConfig` records, including
  tombstones, under Séance's bare-id/LWW conventions so servers managed in
  either app appear in both, and publishes `secret:` records for
  credentials whose referencing servers opted into `syncSecret`; details
  in 04 §4.2 — host-key pins synced
  bidirectionally — Poltergeist honors pulled `hostkey:` records and pushes
  its own new pins as standard `hostkey:<host:port>` records — a push that
  diverges from the pin already on the account is held back behind the same
  MITM review, never LWW-published — mirroring
  Séance's own multi-device host-key sync, except that a pulled pin
  conflicting with a locally known key is quarantined unapplied behind a
  MITM warning, never LWW-installed as trusted (04 §3.2); same user, same
  devices) is the
  headline mode but is **gated on Séance shipping the `RecordKind.unknown`
  forward-compatibility fix** (un-patched Séance decodes unknown kinds as
  `serverConfig` — sync bricks or phantom servers appear). Until the user
  confirms every Séance install is updated, setup defaults to Design B: a
  separate account on the same server binary, which works today. Details and
  exact upstream diffs: 04.
- **D5 — Shell-less transport via one Séance refactor.** Extract
  `openAuthenticatedClient(...)` (socket + TOFU + auth + connection log +
  failure summarizer, minus shell/PTY) from `SshSessionManager.connect` as an
  upstream PR; Séance recomposes `connect()` on top, behavior unchanged.
  Poltergeist builds its `ConnectionManager` on it: per-server pool, one
  browse SFTP channel per pane-tab plus N transfer channels over one or more
  `SSHClient`s, interactive-auth-aware pool growth (never N parallel 2FA
  prompts), keepalive, auto-reconnect with backoff.
- **D30 — Séance needs a LICENSE file.** Séance currently has none;
  Poltergeist is Unlicense. The license gates two things: **no Séance
  source is copied per D2, and no release binaries embedding the
  git-pinned packages are published**, until it lands (suggest Unlicense
  to match). Git-pin *consumption* for development and CI is deliberately
  not gated (pre-license CI must stay ephemeral — no published,
  downloadable artifacts embedding the pinned code — enforced by never
  uploading embedding binaries as a CI artifact at all; a short
  `retention-days` window is not a substitute — a public repo's default
  artifact retention leaves GitHub-hosted builds downloadable by anyone
  with read access for up to 90 days, and even a one-day window still
  publishes the exact downloadable artifact this rule exists to prevent,
  just for less time — the same
  leak the `release.yml` guard below exists to close on the release
  side) — both repos share one rights holder, who needs no license
  from themselves (01 §9 records the full rationale and the
  third-party-facing reason binaries wait) — an assumption to revisit if
  any external contribution lands in Séance before its LICENSE does, since
  the `release.yml` guard below covers only this repo's own `v*` tags, not
  third-party forks or builds — and in the planned order the
  binary gate never actually bites: M2, the first milestone whose shipped
  app consumes Séance code, already hard-gates on the license landing
  (07 §2). Tracked in the Séance-side
  integration notes (04) and the 07 milestone gates. A mechanical guard
  backs the ordering discipline rather than relying on it alone: a
  pre-publish check in `release.yml` fails on every publish path — a `v*`
  tag push or a manual `workflow_dispatch`/re-run alike — unless **every**
  pinned Séance revision's **tree** carries a license file (resolve each
  Séance git pin from **every** `pubspec.lock` in the monorepo — the
  revisions a build actually embeds, not one package's `pubspec.yaml`;
  `seance_protocol` and `seance_core`
  may sit on different revs under D2's rev-pin hatch — the check MUST run
  after dependency resolution in the build workspace and MUST fail closed
  when any `pubspec.yaml` declares a Séance git dependency that no
  `pubspec.lock` resolves — a missing or stale lockfile must never let the
  gate pass by seeing nothing — and inspect each
  pinned tree for any of
  `LICENSE`/`LICENSE.txt`/`LICENSE.md`/`LICENCE`/`UNLICENSE`/`COPYING` —
  e.g. `git cat-file -e <rev>:LICENSE` for each name — and requires the
  file's text to match the canonical SPDX text of a permissive allowlist
  (Unlicense, MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC), ignoring
  a copyright-notice line wherever it appears — SPDX's own matching
  guidelines exclude the copyright notice from every license's
  substantive text, not just MIT/BSD/ISC's, and it is commonly prefixed
  above the Unlicense text too even though the canonical Unlicense body
  carries none itself —
  not merely to exist or to name a license: a repo
  whose HEAD carries a LICENSE can still have pre-license pinned revs,
  and a *restrictive* license landing in a pinned rev (a `COPYING` file
  with GPL text, say) must fail this gate exactly as a missing one
  does — an existence-only check would green-light publishing
  Unlicense-labeled binaries embedding incompatibly-licensed code,
  precisely the compliance failure this guard exists to make impossible,
  so a prematurely cut tag cannot publish binaries embedding unlicensed
  **or license-incompatible** code
  (07 §2 owns wiring the check).

  **Hard ordering rule:** the guard MUST land in `release.yml` no later
  than the first Séance git pin lands in any `pubspec` — a `v*` tag cut
  in the window between that pin and the guard would publish unlicensed
  revisions the guard exists to block. Backed mechanically too, not by
  discipline alone: a PR-level CI check fails when a diff adds a Séance
  git dependency to any `pubspec.yaml` while `release.yml` lacks the
  license-gate step — and, symmetrically, when a diff removes or renames
  the gate's marker comment from `release.yml` while any `pubspec.lock`
  in the monorepo still resolves a Séance git pin, since an unrelated
  workflow refactor deleting the gate is exactly as dangerous as a pin
  landing before it — anchored on a grep-able marker comment inside the
  workflow so the check stays stable across refactors.
- **D31 — No volume mounting, ever.** FUSE/WebDAV-mount/network-drive
  presentation of a remote is refused durably, never deferred to v2 —
  unlike everything on the D25 parking lot, there is no future version
  where this ships. Mounting hides every transfer behind the OS's own
  I/O layer (01 §3's Mountain Duck row, the frozen-"Synchronization
  ongoing" failure class; 01 §5 trap 3), defeating the D16 activity
  panel's visibility/cancellability/inspectability guarantee at exactly
  the operations — bulk copies to a remote — where losing it hurts most.
  This is the one durable refusal in 01 §8's non-goal table that had no
  governing decision number, leaving it uniquely unprotected by this
  file's own change-control rule ("changing a decision means editing
  this file"); recorded here so reversing it requires editing this entry
  first, exactly like every other refusal.

### Sync and deletion/trash policy (R6)

- **D6 — Native engine; rsync survives as an exporter.** The sync engine is
  pure Dart over the one VFS: parallel scans, then size+mtime comparison
  with a **2 s tolerance** — the wider of the window's two drivers (SFTP
  v3 stores whole-second mtimes, so a preserved sub-second local mtime
  truncates on upload — a ≤ 1 s error; FAT volumes quantize to 2 s), the
  default 05 §4 specifies and FreeFileSync ships. A finer per-endpoint
  window is deliberately not attempted: SFTP v3 has no filesystem-type
  attribute at all, and `statvfs@openssh.com`, where a server even
  supports it, returns block size and inode counts, not a filesystem type
  name, so a remote endpoint's FAT-family status is unknowable from the
  protocol — tuning stays manual via the per-pair tolerance knob (05 §6).
  The window's false-equal hazard is a **documented limitation**, stated
  here rather than discovered: a same-size edit whose mtime lands
  inside the tolerance is classified unchanged and skipped — rsync
  (whose default `--modify-window` is 0/exact, with the window an opt-in
  documented for FAT) and WinSCP share the *hazard* and document it
  likewise — with the opt-in
  `contentHash` mode (D7) as the escape hatch. The engine produces a typed
  `SyncPlan` that
  **is** the preview (the executor executes exactly the reviewed items,
  re-verifying preconditions per item). v1 modes: **Update** (one-way, no
  deletions — default), **Mirror** (one-way + explicit orphan deletion),
  **Additive two-way** (union, never deletes, conflicts surfaced). True
  two-way with a baseline database (tombstones, move detection) is v2.
  rsync is *not* the engine — it fails always-works (absent on Windows
  servers, sftp-only chroots, busybox NAS), bypasses the in-app auth/TOFU
  stack, and breaks the preview-equals-execution promise. The user-suggested
  rsync idea ships as **"Copy as rsync command"**: renders the pair's
  ruleset as the equivalent rsync invocation, shell-safely. 05 §2.1's
  exporter contract owns the specifics:
  - POSIX single-quote every path and argument, with the embedded-quote
    escape (`'` → `'\''`).
  - Never emit `-s`/`--protect-args`: unsupported on the builds this
    exporter's busybox/NAS/macOS-client audience is most likely running
    (rsync ≤ 2.6.9, long the macOS system default and common on NAS
    boxes; macOS 15.4+'s openrsync). Instead backslash-escape every
    remote-path byte outside a safe allowlist — `[A-Za-z0-9._/+@%=:,-]`
    passes through; everything else is escaped, space and the shell
    control operators (`; & | < > ( ) { } # ~`, tab, newline) included —
    before local
    POSIX-quoting (05 §2.1's double-escaping rule, which owns this
    allowlist's normative definition and golden tests): this is the
    single constant the whole no-`-s` design's remote-shell safety rests
    on, so it is stated explicitly rather than left to infer from the
    pointer alone, closing the
    remote-shell re-splitting hazard `-s` would have addressed — no
    version floor, and no need to probe the far end's rsync build (a
    pure command-string renderer has no exec channel; D5 gives it none).
  - Emit `--` before the first path argument and `./`-prefix (or
    absolutize) every path: quoting alone stops word-splitting and quote
    breakout, not argv-level reinterpretation by rsync itself — `--delete`
    must never parse as an option, `host:path` must never reparse as a
    remote spec. Quoting and these prefixes govern the *local* shell
    that parses the pasted command.
  - 09's shared path validator rejects newlines/control characters
    upstream of the exporter, so an untrusted remote filename cannot
    break out of the quoted argument.
  - The exported command targets a POSIX shell (bash/zsh); cmd.exe and
    PowerShell are out of contract. Hazards get `# note:` lines; the
    exporter is golden-tested.
  - **Known gap, tracked as a 05 follow-up, out of this PR's scope**: 05
    §2.1's already-merged exporter renders a nonstandard port
    (`-e 'ssh -p <port>'`) but not an identity file or a jump host from
    the pair's connection settings — a pair using either produces a
    pasted command that connects to the wrong endpoint or with the wrong
    credentials rather than failing loudly. Not fixed here since 05 is
    a separate, already-merged chapter this PR does not touch — but per
    this section's own "hazards get `# note:` lines" rule, the exporter
    must render a prominent `# note:` line (or refuse to render) whenever
    the pair's connection settings include an identity file or a jump
    host, so the gap is loud rather than latent until 05 closes it; this
    interim patch to 05's already-merged exporter is recorded as a dated
    open item in STATUS.md, not an untracked prose promise, and blocks
    "Copy as rsync command" from shipping in any milestone until it lands.

  Manual per-item overrides are
  annotated in a comment, never compiled into filters. An opt-in rsync
  accelerator remains a documented v2 possibility, driven per-item from our
  own plan; it may never be needed. Full analysis: 05.
- **D7 — Hashing policy, finalized by M0.** The managed-checkout/edit
  pipeline keeps Séance's mandatory streamed SHA-256 (it is the conflict
  authority). Bulk transfers default to hashing off and expose the opt-in
  "verify after transfer" setting; sync defaults to `sizeAndMtime` and keeps
  `contentHash` as its opt-in thorough mode. M0's same-run 100 MB and 1 GB LAN
  cells measured a 19.8–21.2% throughput cost from streamed hashing, while
  the shaped same-run cells were mixed and showed no stable compensating
  benefit. Paying that LAN cost for every bulk operation is therefore not
  justified; the user selects it when content verification outweighs speed.
- **D15 — One trash story.** Local deletions go to the OS trash via a thin
  in-repo plugin (macOS `FileManager.trashItem` with Put Back; Windows
  `IFileOperation`+`FOF_ALLOWUNDO` via `win32` FFI; Linux `gio trash`,
  behind a detected-once capability probe plus a runtime-failure path:
  where `gio` is absent — minimal distros — or `gio trash` fails at run
  time (no writable trash dir, read-only home, a removable volume with no
  usable trash), the plugin falls back to
  confirm-then-permanent with a one-time notice, never a crash and never
  an unconfirmed permanent delete; 07 §6 risk 10 pre-authorizes the same
  fallback per platform).
  Remote deletions from browsing default to confirm-then-permanent
  (Transmit's model) with a per-server opt-in "move to
  `.poltergeist-trash/<runId>/` instead" (same per-run layout as sync's
  trash below, rather than an unretained flat folder, so it ages and
  purges under the identical 30-day rule); sync deletions *and* the
  previous versions of files that sync
  overwrites default to the same `.poltergeist-trash/<runId>/` rename-based
  trash, with entry names uniquified inside the run by a per-run sequence
  prefix (`<runId>/000042-<name>`) so same-basename items from different
  source directories cannot collide and rename stays the common path
  even against SFTP v3's fail-when-target-exists — falling back to
  copy-then-delete only for a genuine cross-device/permission failure
  cross-filesystem (EXDEV for local pairs, mirroring D26's local rule; for
  a remote pair the SFTP status code carries no errno, so *any* rename
  failure not resolved by the sequence prefix still triggers the fallback
  rather than one classified as
  cross-device; 05's rail 5 owns this
  fallback, including the interrupted-copy recovery it tests for — 05's
  own text states the fallback trigger as "cross-filesystem" without this
  remote/errno distinction or the sequence-prefix naming rule, a
  precision gap recorded as a dated open item in STATUS.md for closing
  there too, out of this PR's scope) —
  (overwrite backups sit behind their own `backups` knob — default
  `trash`, matching 05's `BackupPolicy` — independent of the deletion
  policy). One directory name everywhere;
  default ignore rules exclude `.poltergeist*` and `*.poltergeist-*`.
  Sync trash is never reclaimed as a side effect — retention is 05 §8
  rail 5's story: a plan-time notice surfaces trash older than 30 days
  (orphaned, journal-less run directories included, aged by each run's
  recorded `startedAt` where a journal exists and by the `<runId>`
  directory's own mtime for journal-less orphans — never by the trashed
  files' own mtimes, which a rename leaves untouched) with
  a user-confirmed purge, plus the explicit `sync.purgeTrash` command —
  accumulation is visible and reclaim is always a deliberate act,
  matching the no-unguarded-deletes rule (09 §6).

### Engine and performance

- **D8 — Isolate architecture, confirmed by M0.** The engine isolate owns
  the connection pool, every SSH/SFTP socket, transfer execution, inline
  hashing, and sync scan/diff; short-lived `Isolate.run` workers own archive
  work and later non-stream-shaped CPU bursts. The UI isolate holds only view
  state and talks to the engine through the typed message-port API. M0 measured
  0.997 throughput parity, 40.938 ms cancellation, 22.83 progress flushes/s,
  and a 4.401 ms maximum UI-isolate timer stall, all inside D8's gates, so the
  single engine-isolate split is final for v1.
  - **Addendum (2026-09-24) — the bridged transfer lease.** The shipped app
    composes the transfer queue, the managed-checkout manager, the preview
    producer, and the sync scanner/executor on the UI isolate, so the plan's
    engine-hosted queue (03 §5's `EnqueueTransferRequest` sketch) was never
    built and remote transfers failed (STATUS item 23). Protocol v13 bridges
    the lease instead: the engine keeps every socket, SFTP channel, and pool
    lease, and the UI-isolate `EngineConnectionManager` hands those consumers
    a proxy `RemoteFileSystem` whose metadata calls cross as typed VFS ops and
    whose bytes cross as credit-flow-controlled `TransferableTypedData`
    streams. What D8 guarantees still holds: no socket, SFTP handle, or
    remote-side hash leaves the engine (digest-only reads run engine-side via
    `VfsContentDigest`, so they move no bytes), and the platform trash is
    reached through the engine too. What changes: the queue's scheduling,
    journal writes, bandwidth gates, local disk I/O, and local-side hashing
    run on the UI isolate. That was already true for local↔local work before
    this addendum; it now covers remote legs too, and remote→remote bytes
    cross the port twice. A local 32 MiB loopback measurement put bridged
    throughput at roughly 0.85–0.95 of an in-process pool on a loaded host.
    That is indicative, not a D8 gate re-run: the M0 gates must be re-measured
    under the bridge before this is declared final, and moving the queue
    executor engine-side stays the escalation if they fail.
- **D9 — M0 ends at fallback rung 4: keep dartssh2 3.0.2 and document the
  ceiling.** Version 3.0.2 is the minimum: earlier releases can abandon
  pipelined read futures when a consumer cancels the stream, while 3.0.2 owns
  every issued read completion and retains pipelining. The canonical M0
  evidence established three boundaries:
  - Modern and legacy OpenSSH defaults, rsa-sha2-256/512, ed25519,
    aes128/256-gcm, and curve25519-sha256 all connected. dartssh2 lacks
    chacha20-poly1305 and mlkem768x25519-sha256, so a strict server requiring
    that cipher/KEX pair failed; strict Chacha/PQ-only servers are a documented
    compatibility ceiling.
  - On LAN, hashing-off 1 GB dartssh2 transfers reached 22.79 MB/s download
    and 21.98 MB/s upload, while OpenSSH reached 225.46 and 249.15 MB/s. That
    roughly 10–11× single-large-file gap is a documented throughput ceiling;
    shaped downloads were competitive and shaped uploads remained slower.
  - Pooling materially recovers aggregate throughput. Four transfer channels
    beat three by 23.9% on LAN and were the shaped-link maximum; eight
    regressed on the shaped link. Two transports nearly doubled the LAN
    aggregate; although four transports recovered shaped aggregate after two
    did not, 2 transports × 4 channels already expose 8 transfer slots above
    the global dispatch cap of 6. More transports cannot raise v1 dispatch
    concurrency. The final `PoolPolicy` is therefore 2 transports, 4 transfer
    channels per transport, and 8 total channels per transport; the scanner
    uses 8 outstanding readdirs.

  **Rung-4 rationale:** the 3.0.2 correctness fix, passing modern-default
  compatibility, passing D8 proof, and bounded pool compensation satisfy v1's
  required behavior. Native libssh2 FFI would add three-platform packaging,
  security-audit, and maintenance surface without removing the product's need
  for the Dart engine and one VFS. That cost is not justified solely to close
  a LAN single-file ceiling and support strict Chacha/PQ-only configurations,
  neither of which violates a v1 budget. Keep those limits explicit and
  revisit libssh2 only with user compatibility failures or workload evidence.
- **D12 — Numeric performance budgets** (tracked as benchmarks in CI, 08):
  first paint of a 10k-entry local directory < 150 ms; 100k entries < 1 s
  (virtualized); remote listing = network time + < 50 ms overhead, always
  cancellable; tab switch < 100 ms; drop-to-transfer-start < 500 ms (no
  upfront full-tree stat); scrolling drops no more than one frame per 10 s;
  sync scan ≥ 1 000 remote entries/s on LAN (pipelined readdirs).
- **D26 — Local↔local operations are first-class.** v1: streamed copy with
  progress + cancellation + mtime preservation; cross-device moves as
  copy+delete — the copy is flushed to durable storage (an fsync of the
  file data, then of the destination parent directory) and only then is
  the source deleted, so cancellation, failure, or a crash leaves either
  the original intact or a durable copy, never neither;
  case-only renames handled on case-insensitive filesystems.
  A native fast-path spike (APFS `clonefile`, Linux `FICLONE`, Windows
  `CopyFileEx`) is scheduled in 07; metadata beyond mtime+mode (xattrs,
  ACLs) is explicitly out of v1 scope and documented as such.

### UX surface

- **D11 — Design language: "quiet chrome".** Flutter with a bespoke
  desktop-density design system seeded from Séance's theme approach
  (`ColorScheme.fromSeed`, its own accent seed), never stock
  Material-mobile. Per-platform conventions are non-negotiable: native
  titlebar on Windows/Linux in v1; macOS gets a unified-toolbar look via
  `macos_window_utils`; menus via `PlatformMenuBar` (macOS) — with the
  proven Séance Swift-retargeting fallback if the M3 menu spike finds it
  insufficient — and a Flutter-drawn `MenuBar` (Windows/Linux);
  platform-correct shortcuts, dialogs, and scrolling physics. Details: 02.
  *M3 spike outcome (TASK40): `PlatformMenuBar` suffices — the §9
  Edit-menu retargeting is expressed in Dart, so the Swift fallback stays
  on the shelf. A natively bound key equivalent intercepts the keystroke
  before any in-window surface, so only modifier chords bind natively;
  when activation of a field-owned chord (⌘A/⌘C/⌘X/⌘V/⌘Z/⌘⇧Z/⌘⌫) reaches
  the menu while a text field holds focus, the item re-dispatches the
  matching text intent to the focused `EditableText` instead of running
  the command. Resolving focus at activation time replaces Séance's
  `poltergeist/menu` focus-flag channel — there is no flag to stale
  (SEA-008 is moot by construction). `NSWindow.allowsAutomaticWindowTabbing
  = false` is set in `MainFlutterWindow`.*
- **D13 — Single window in v1.** One window, dual pane, tabs per pane; a
  `WorkspaceController` owns one window's state so multi-window becomes
  mechanical when Flutter's windowing API stabilizes. Multi-window itself
  is parked in D25.
- **D16 — The activity panel is a trust organ.** A first-class
  `TransferQueue` service above panes drives the optional bottom panel:
  per-item rows (never just a summary bar — Transmit's launch mistake),
  reorder, per-item cancel/retry, queue pause, conflict policy
  (Replace / Replace-if-newer / Keep Both / Skip, Merge for folders, with
  per-direction configurable defaults), bandwidth throttle (token bucket),
  remote→remote piping tasks, **persistent queue (re-enqueued from
  scratch — mid-file resume waits for D25) and a working history log**
  across restarts — the history records endpoints, root names, byte/file
  counts, timestamps, and outcome (never credentials), caps at 10 000
  entries, and ships a `Clear History` action (02 §6) — the log lives in
  the app's regular local data store rather than sealed under D18's OS
  keystore (that's sized and scoped for small secrets, not a growing log
  of endpoints/paths), so anyone who wants none of that persisted at all
  gets a `Disable History` setting alongside `Clear History` (02 §6) —
  turning it on stops recording immediately and offers to purge the
  already-stored entries too (mirroring `Clear History`'s own action),
  so "none of that persisted" holds retroactively — once the user
  accepts the purge — not just going forward.
  Hidden or dishonest transfer state is the category's
  cardinal sin; every long operation is visible, cancellable, inspectable.
- **D21 — Command registry from day one; palette in v1.** Every user action
  is a registered command (id, label, shortcut, enablement) feeding menus,
  shortcuts, context menus, and the Quick Open palette (ForkLift's
  shortcut-teaching loop: palette rows show and accept their shortcuts).
  Keyboard completeness is a tested invariant, not an aspiration.
- **D14 — Drag & drop scope.** In-app pane↔pane drags use Flutter widgets;
  OS drop-IN uses `desktop_drop`; OS drag-OUT (promised files) is
  deliberately v1.x — the transfer queue exposes a produce-on-demand hook
  from day one so any promised-file backend can attach later.
  - **Amendment (2026-09-25): OS drag-out ships, first-party.** No
    `super_drag_and_drop` / `super_native_extensions`: on macOS it cannot
    see a press under `desktop_drop`'s overlay, cannot promise folders,
    writes every remote file twice, and brings CocoaPods and a Rust build
    into an SPM-only project. Instead one Dart seam
    (`lib/services/os_drag_out.dart`: `DragOutBackend`, the
    `poltergeist/dragout` channel whose protocol that file documents, and
    a no-op backend on mobile, web, and in tests) with small native
    backends per platform. The rules:
    - *Hand-off, not replacement.* In-app drags stay Flutter `Draggable`s
      with every existing target, verb rule, spring-load, and test. Only
      when a row drag's pointer leaves the window does the pane hand the
      payload (every selected item) to a native session, once per
      gesture; the pane then cancels its own pointer, and the native side
      ends the embedder's view of the press so no click stays stuck.
    - *Local items* travel as plain file URLs; the destination picks copy
      or link. Delete is never offered (a Dock-Trash drop would be an
      unguarded delete, D15), and nothing on the source side deletes.
    - *Never move (owner decision, 2026-09-25).* The owner decided the
      Windows Recycle Bin must not accept a drag-out, and applied the
      rule on every platform: a drag out of Poltergeist only ever offers
      copy and link, never move, on Windows, Linux, and macOS. So no
      trash (the Recycle Bin, a Linux file manager's Trash, the macOS
      Dock Trash) can take the source by a move, and no drop elsewhere
      can move it either: a destination that would have moved copies
      instead. Dart's `allowedOperations` is the source of truth, and
      each native backend enforces the rule itself whatever a request
      says (GTK actions, the `NSDragOperation` mask for both dragging
      contexts, `DROPEFFECT`). A session end that reports a move anyway
      is read and acted on by nothing. Drags between Poltergeist's own
      panes are in-app drags and still move, and a drag that leaves and
      comes back (the own-drag echo below) still lands with the in-app
      verb.
    - *Remote items* are file promises on macOS (`NSFilePromiseProvider`,
      `public.folder` for directories). A file is produced straight into
      the path the OS gave: an exclusive produce hop (never replacing a
      same-named file) on a two-slot drag-out budget separate from Quick
      Look's. A folder is an ordinary recursive download task, awaited to
      its end. It does not bypass the queue pause: a paused queue fails
      the promise at once, and a pause mid-download cancels the task,
      each with an Alert, so the OS never waits on a pause. A Pause on
      a drag-out's own Transfers row (a file hop or a folder download)
      cancels it the same way, with the same Alert. Both show in
      Transfers; the OS-side cancel cancels the task; a failure fails the
      promise and keeps its failed row and Alert. A receiver that asks
      for a different folder name fails with an Alert (the queue lands a
      root under its own name; whether Finder ever renames is open).
      Symbolic links and flagged names are never promised (links are
      never transferred; a flagged name cannot become a local one). A
      drag that holds some leaves them behind and the pane's notice says
      how many and why; a drag that holds only those stays in-app with
      the same notice.
    - *Linux and Windows* carry local items only for now (GTK
      `text/uri-list`, built and verified under Xvfb; Windows
      `CF_HDROP` in the shell's own data object, built but not yet
      run on Windows). Remote rows there show a
      "use Download To…" hint and keep dragging in-app; File ▸ Download
      To… is the fallback everywhere. Windows virtual files are the
      follow-up.
    - *Own-drag echo.* A drag of ours that comes back into the window
      lands on `desktop_drop`; the controller recognizes its session (the
      dropped paths, or a promise called into `desktop_drop`'s staging
      folder, which fails fast) and the pane applies the in-app verb
      rules from the stored payload.
    - *macOS backend* (`macos/Runner/DragOutChannel.swift`, same day). A
      local event monitor supplies the press whichever view it hit
      (`desktop_drop`'s overlay, `macos_window_utils`' passthrough
      views). A synthetic mouse-up to the FlutterViewController ends
      Flutter's press, then the session begins from the newest drag
      event so the image keeps its offset from the pointer. Items show
      their Finder icons and names, several in a pile under AppKit's
      count badge. Promise writes hop from a private queue to the main
      queue and never wait on Dart; each publishes a cancellable
      `NSProgress` on the promised URL. Not yet run on a Mac.
    - *Windows backend* (`windows/runner/drag_out.cpp`, same day). The
      items leave as their folder's own `IShellFolder::GetUIObjectOf`
      data object, the one Explorer drags (`CF_HDROP` plus the shell
      formats), not `SHCreateDataObject`, which only promises the shell
      ID list; they must share one folder, as a pane selection does.
      `startDrag` requires the primary button down and the mouse
      capture still on the Flutter view (a pen or touch drag has none
      and stays in-app), posts a registered message, and replies; the
      message's handler sends the view a synthetic `WM_LBUTTONUP` and
      runs `SHDoDragDrop` under the Dart PNG (decoded through WIC).
      `sessionEnded` reports the logical performed effect first, since
      the shell's optimized move returns none. Move is never offered
      (the owner decision above), so the Recycle Bin has no move to
      take and Explorer copies where it would have moved; nothing is
      deleted. Not yet run on Windows; virtual files for remote items
      are the follow-up.
- **D17 — Editor.** Séance's editor stack (document I/O with BOM/CRLF
  fidelity, syntax engine, find bar, conflict-aware save-and-upload) is
  ported per D2 and kept behaviorally identical; external editors reuse the
  `EditorRegistry`/launch channels; the in-app preview panel
  (text/images/PDF) exists on all three platforms — the primary preview
  surface on Windows/Linux, supplementary to the macOS Quick Look channel.
  Checkout ownership is per **server**, never per pane/tab
  (`CheckoutManager`, specified in 06 and ported per D2).
- **D28 — Permissions UI.** chmod via octal + checkboxes with recursive
  apply (app-level walker with progress/cancel); chown UI lands once the D3
  `setOwner` addition ships; uid→username shown when the server's `longname`
  provides it, numeric otherwise.
- **D22 — Import is adoption fuel, staged.** v1 imports `~/.ssh/config`
  (Séance's importer, IdentityFile included) **with a preview + dedupe
  + unsupported-directive warnings** — an imported host whose real
  behavior depends on `ProxyCommand`, `ProxyJump`, `Match`, or an
  `Include` nested inside a `Match` block (D10 defers ProxyJump
  *execution* to the first post-1.0 fast-follow, so at v1 it is exactly
  as unsupported as the others) gets an
  explicit "won't behave as in ssh" badge in the preview rather than
  silently importing as a bookmark that then fails to connect the way
  the user's actual config does — a plain, top-level `Include` is
  resolved read-only at import time instead (the same local-file trust
  already granted to `~/.ssh/config` itself and any `IdentityFile` it
  references), so the common `Include ~/.ssh/config.d/*` layout doesn't
  badge every imported host and drown the signal on the hosts that
  actually need it; FileZilla `sitemanager.xml`, WinSCP
  INI, and Cyberduck bookmarks
  follow in v1.x behind the same preview UI.
- **D27 — Archives.** v1.x, not v1: local zip create/extract via
  `package:archive` with zip-slip-safe extraction (validate every component
  — Séance's path-validation tradition), per-entry and total
  decompressed-size caps (a zip bomb is a distinct hazard from path
  traversal), and symlink-entry rejection (an extracted symlink can
  redirect a later entry's write outside the target directory) —
  traversal is not the only extraction hazard; pin an audited
  `package:archive` version at implementation time. Remote-side extraction and
  browsable archives are later, consciously scheduled in 07.

- **D32 — The inspector workspace (2026-09-24, owner-directed redesign).**
  The v1.0 chrome is replaced by a ForkLift/Transmit-grade layout
  specified in [10-WORKSPACE-REDESIGN.md](10-WORKSPACE-REDESIGN.md):
  a curated, registry-driven header toolbar (a command appears only if it
  declares a toolbar placement — D21 holds), a full-height sidebar with
  DEVICES / FAVORITES / SERVERS in the anatomy Séance shares, panes with
  a location header and column header, and a resizable right
  **inspector** with Info / Transfers / Alerts tabs. It supersedes:
  02 §1's bottom activity panel, always-on status bar, and stage table
  (the inspector collapses first, then the sidebar, then pane B); 02
  §2.6's per-pane Get Info overlay and 06 §5.2's separate preview rail
  (both merge into the Info tab); 02 §2.9's footer (its facts move to
  the location header); 02 §9's "Commands" menu (renamed Server, Settings
  moves to the macOS app menu, Linux/Windows render the tree behind a ☰
  header button instead of a menu-bar band); 05 §7's "never a modal
  wizard" (sync opens Transmit's options sheet with a truthful
  plain-language plan sentence; Simulate opens the existing review) and
  05 §8 rail 1 for the one case of a plan with no deletions, no
  replacements, and no conflicts, which Synchronize may run without the
  review step (every other plan still lands on the review; rails 2–4 are
  unchanged); and 04 §4.1's default of a separate backup account (the
  shared Séance account becomes the default, per the owner's "same
  server, same account" requirement; the version gate and pin-trust
  disclosure stay). D16's substance is untouched: per-item rows, pause,
  cancel, retry, History, and bandwidth all live in the Transfers tab,
  the header shows a progress ring whenever work runs, and new work
  opens the inspector on Transfers. Anything D32 does not name in 02
  still holds.
- **D33 — Sidebar density and restored row detail (2026-09-25,
  owner-directed; amends D32 and 10 §2, §5, §8, §9, §10).** Aligning
  both apps' sidebars on one kit had lost what the owner used: the two
  views (Séance's comfortable and compact lists), the address or path
  on a second line, and several marks. The owner's calls, binding for
  both apps:
  - **Two densities, one switch.** Compact is D32's one-line rail,
    unchanged; comfortable is the default on every platform: 52 px rows
    (56 dp on a tablet's touch rail) with a 32 px mark, a 14 px title
    and a 12 px second line the kit draws only when comfortable, so the
    hosts always hand it over and cannot drift. Comfortable headers keep
    their chevron, count and "+" in view, and every comfortable or
    touch row shows its "⋮". The choice is device-local
    (`sidebar.density`) and set from the bottom bar's switch, a phone
    Home's app bar, or View ▸ Use Compact/Comfortable Sidebar Rows (one
    item naming the other density: the macOS menu cannot show a check).
    A phone Home is the Material list when comfortable and the rail's
    touch rows when compact.
  - **The second line** says what each row's tooltip says first: free
    space, a home-relative path, a sync's two sides, a workspace's kind,
    or a server's endpoint, with the state words first while it is
    connecting, failed, blocked or unreachable, and a remote favorite's
    landing path after it.
  - **Marks:** the 4 px accent line in a server's colour
    (`ServerAccentBar.width`) and a green connected ring around a
    connected server's mark come back in both densities, beside the one
    status dot. A blocked host key gets its own no-entry dot and an
    unreachable host a red ring, so three states no longer share one
    red dot. A header that hides a live server (folded, or filtered)
    shows a dot for it.
  - **Poltergeist's sections:** remote locations are favorites again,
    under FAVORITES beside local folders as 10 §5 always said (the first
    D32 build had moved them under SERVERS, a deviation recorded
    nowhere); SERVERS is the shared account's list plus the live Quick
    Connect sessions, and the session verb reads "Save to Favorites…".
    Poltergeist gains a PINNED shortlist above the others (a device-local
    pin set, "Pin to top" / "Unpin", as in Séance), and the account's
    rows carry a small cloud mark and "From your Séance account".
  - **PINNED, as the owner confirmed it** ("Pin servers to a shortlist
    at the top, as Séance has"): the account's servers and the remote
    favorites both pin, so PINNED works without the shared account, and
    it is the rail's first section, before DEVICES. A pinned row leaves
    FAVORITES or SERVERS (its group's count drops with it) and keeps its
    own row in PINNED. The mix is ordered by label, case folded, then by
    id. A pinned row neither drags nor takes drops, since PINNED has no
    user order; Move to Group still refiles it. Deleting a pinned
    favorite drops its pin; the stored key stays `sidebar.pinnedServers`.
  - **Kept as D32 built it:** ungrouped rows come first with no
    "Ungrouped" header.
  - **The filter** shows at five servers again (both apps' old
    threshold), its count names "↵ opens the first", "No matches" offers
    Clear filter, and a query drops itself once the rail it filtered is
    empty.
- **D34 — Colour that means something (2026-09-25, owner-directed;
  amends D11 and 10 §4, §5, §6, §10).** The owner found the chrome's
  glyphs too bland to tell apart ("I used to like apps better when they
  had colorful buttons that helped you identify things not just based
  on location and shape, but also color"), citing iTunes' source list,
  Postbox's toolbar and the old Finder sidebar. Hue is the one visual
  channel the eye sorts before it reads, and those apps spent it on
  *kinds*: every podcast purple, every playlist blue. Binding for both
  apps:
  - **One vocabulary, twelve hues.** Blue for places and folders, cyan
    for motion (transfers, copies, links), teal for saved recipes
    (workspaces, Séance's snippets), green for go (Connect), yellow for
    attention (alerts, favorites), orange for code (source files, Git),
    red for destruction and PDF, pink for images, purple for audio,
    video and Séance's assistant, indigo for sync, brown for cargo
    (archives, removable drives), graphite for the neutral rest
    (documents, disks, navigation). The table lives in
    `lib/theme/family_hues.dart` here and `lib/family_hues.dart` in
    Séance, byte-identical, and a hue means the same thing in both.
  - **Quiet chrome stays quiet.** D11 holds for the surfaces: the slate
    and Finder-light neutrals, the one accent, the status dots. Colour
    goes on glyphs that name a kind of thing, never on text, surfaces or
    state; its only fills are the small ones that carry a glyph (a
    place's tile, a disc's wash, the open inspector tab's wash). The
    status dots keep green, amber and red to themselves, and selection
    keeps the accent (the active selection repaints glyphs on-accent).
  - **Verbs are coloured and filled; navigation is neither.** A
    toolbar, context-menu or palette command that declares a hue
    (`RegisteredCommand.hue`) paints its filled glyph in it while
    enabled and drains to grey when disabled, so a live verb is told
    from a dead one at a glance. Back, forward and the panel toggles
    keep the neutral outline.
  - **Places lead with a tile.** A sidebar place without a colour of
    its own wears its hue's tile, lit from the top, in both densities,
    the silhouette of a server's badge; standard folders directly under
    home (Desktop, Documents, Downloads, Pictures, Music, Movies,
    Applications) get their own glyphs. A favorite's own colour still
    wins.
  - **Kinds are coloured.** The listing's kind glyphs are the filled
    faces in their hue, with text split into documents and code and
    media into audio and video; the info panel, the preview well,
    Quick Look and the transfer rows use the same table.
  - **Contrast is pinned.** Every hue holds 3:1 on every chrome surface
    it can sit on, at rest, hovered and on the neutral selection, and
    on its own wash; every tile glyph holds 3:1 on both ends of its fill
    (`family_hues_test.dart`).

### Security, trust, distribution

- **D18 — Séance's security model is inherited unchanged.** TOFU with hard
  changed-key block; OS keystore holds the master key; whole-record sealed
  blobs (no per-attribute encryption — it conflicts with the shared
  protocol and buys nothing at bookmark sizes); credentials resolved
  in-memory at connect; identity-file reads audited. No new crypto.
- **D19 — Trust stance.** Open source, zero telemetry, no crash reporting
  in v1, no Poltergeist account — the only account ever involved is the
  user's own opt-in Séance sync account (D4) — link-only update check
  (Séance's banner pattern) —
  the check is the app's only outbound call absent a user-initiated
  connection or the opt-in Séance bookmark backup (D4), on by default and
  one setting away from off (01 §6); every
  shorter "zero telemetry" tagline elsewhere in this plan is shorthand
  for this same scoped claim, never a silent contradiction of it.
  Stated in the README with this scoped wording itself — "no telemetry
  beyond an on-by-default, one-setting-off update check" — never a bare
  "zero telemetry"; treated as a feature (the category punishes
  rent-seeking and opacity).
- **D23 — Distribution mirrors Séance.**
  - **Artifacts.** GitHub Releases via the existing `release.yml`
    publish, from every `v*` tag: the unsigned/ad-hoc macOS bundle,
    Windows zip, Linux `.deb` + AppImage + bundle, Android APK, and
    unsigned iOS IPA (all already scripted); the mobile product remains
    post-v1 (D29; D35 has since made the APK a supported build, so this
    now covers the IPA alone) — the artifacts merely exist, and the IPA's
    filename and the release notes label it unsigned and unsupported so no one
    mistakes an artifact that cannot be installed on any device without
    a separate signing step for a usable build. No paid signing in v1
    (documented first-launch steps).
  - **Publishing and checksums (decision change 2026-09-03, owner —
    replaces "Drafts and signing" and "Key trust").** Releases
    publish straight from CI with **no human step**, Séance's posture.
    The original text specified a per-release ceremony — draft pause
    for a maintainer-local build spot-check, a detached
    `SHA256SUMS.asc` signature, an out-of-band key fingerprint — and
    the owner, having walked the `v0.1.0` rehearsal short of the
    signing steps (the draft, assets, sums, and flags were verified;
    the detached signature was never attached), decided
    its cost exceeds what a single-maintainer personal project gets
    back. The mechanical safety survived the cut where the ceremony
    did not: `release.yml` still refuses to update an existing release
    for a tag — an explicit existence check in its own step,
    independent of any draft flag (action-gh-release's default would
    overwrite same-named assets) — and still serializes runs behind a
    concurrency group keyed on the tag that *queues*, never cancels
    in progress (a cancelled mid-attach run would strand a
    half-attached draft that the existence guard then blocks re-runs
    on until someone deletes it). The release is created hidden while the
    client matrix attaches its assets; CI publishes it once
    `SHA256SUMS` (computed over the complete asset set), the notes
    with the same sums and the unsupported-platform labels, and the
    rehearsal-floor check are all done — a public release is never
    partial or sum-less, and a failed run leaves only an invisible
    draft (recovery: delete it, re-run). Tags are plain annotated
    tags; `scripts/release.sh` does not require a signer (the v0.1.0
    tag happened to be cut signed, hours before this change; it stays
    as cut). The v0.1.0 *release* also predates the change: the
    existence guard stops CI from ever publishing its already-created
    draft, so it ships via a one-time manual publish with the
    pre-release flag kept. **The
    honestly stated residual:** the checksums are an
    integrity channel only — they catch corrupted downloads and
    foreign mirrors — and a compromised CI runner or stolen repo
    token can publish arbitrary binaries *and* matching sums; origin
    assurance is "this repo's CI built from the pushed tag", nothing
    more, and INSTALL.md must not overstate it. Reversing any of this
    requires editing this entry first, exactly like every other
    D-number.
  - **Sandbox posture.** Architecture stays sandbox-ready (a
    `ScopedPathAccess` service fronts all local file access; sidebar
    bookmarks double as future sandbox grants) but v1 desktop builds
    are unsandboxed. Auto-update stays link-only.
- **D20 — a11y and i18n from day one.** All user-facing strings in ARB via
  `gen-l10n` (English only at v1, but externalized); semantics hand-built
  for custom rows/tables (announced name–size–date, selection, sort state);
  focus-visible styling; contrast-checked, theme-aware status colors (fixing
  the class of Séance's SEA-019 finding rather than copying it). Linux
  screen-reader support is broken upstream in Flutter; documented honestly.
- **D24 — The name stays Poltergeist.** Known name collisions (the Capybara
  PhantomJS driver, an Xcode watcher tool) are acceptable for a personal
  open-source app in an unrelated category; noted for discoverability.
  Personality (icon, tagline "the ghost that moves your files", human
  release notes) is part of the product.

### Roadmap posture

- **D10 — Agent auth and ProxyJump are table stakes, not "eventually".**
  Both will be implemented in `seance_core`, serving both apps — ssh-agent via
  `$SSH_AUTH_SOCK` / Windows named pipe with a custom `SSHKeyPair` signer,
  and ProxyJump execution behind the already-modeled `jumpHostId`.
  Scheduled as the first fast-follow after v1.0 (07), with the transport
  seams prepared during M2.
- **D29 — Mobile is later, but never foreclosed.** v1 architecture keeps
  the hooks: panes collapse to one; all local access flows through
  `ScopedPathAccess`; the transfer queue is suspendable; no desktop-only
  assumption in `poltergeist_core`/`poltergeist_sync`. The mobile
  constraints memo (07) records what iOS/Android will demand.
- **D35 — Android is a supported target (2026-09-25, owner-directed;
  amends D1, D23, and D29 for Android only).** The APK every release
  already builds becomes a supported build, beside macOS, Windows, and
  Linux, from the first release after v1.0.1 (whose notes still carry
  the rehearsal label). Its UI is D32's compact
  posture (10 §9) below 600 dp and the desktop layout on tablets.
  - **Distribution is unchanged:** the `poltergeist-android.apk`
    release asset, sideloaded (no Play Store), signed with the
    committed public key. That key gives upgrade continuity, not origin
    assurance, and INSTALL.md says so. The release notes drop the
    APK's rehearsal label; the IPA keeps its unsigned, unsupported
    label, since iOS stays post-v1 under D29.
  - **Supported means shipped with its gaps named.** The slices 10 §9
    defers (STATUS open item 33) stay open and are listed in the
    README's known issues until each lands: the local pane is the
    app's own storage (no all-files access), transfers stop when
    Android freezes the backgrounded app (no foreground service), and
    there is no Share, share-to-Poltergeist intent, or DocumentsProvider.
    The on-device checks automation cannot run (predictive back, IME
    insets, TalkBack) join the release checklist.
- **D25 — v2-and-beyond parking lot** (recorded so nobody "helpfully"
  builds them early): true two-way sync with baseline DB; resumable
  transfers (ranged read/write); rsync accelerator; S3/WebDAV behind a
  capability matrix; browsable archives; scheduled/watched sync;
  multi-window; Custom Tools (user scripts); content search on remotes;
  byte-preserving *operations* on non-UTF-8 remote filenames — v1's
  policy for them (strict-decode; lossy display with a warning badge,
  paired with a byte-accurate escaped rendering wherever a lossy-render
  collision could otherwise make two distinct names — flagged or not —
  look identical (a flagged name's U+FFFD rendering can just as easily
  collide with a legitimately-named, fully valid UTF-8 file that
  contains a literal U+FFFD, not only with another flagged name; 02 §13);
  operations on the flagged name terminally skipped — no retry affordance,
  since retry can never succeed — until byte-preserving handling lands;
  itemized with a tallied count in the same per-file reporting a transfer
  or sync scan already uses for any skip, so a "complete" run can never
  silently omit one) is already specified, not
  deferred (02 §13).

## The one-sentence product

> WinSCP's sync checklist with Transmit's polish and ForkLift's sidebar, on
> all three desktops, with E2E-encrypted bookmark backup through the Séance
> you already run — and no Poltergeist account, no telemetry, no rent.
