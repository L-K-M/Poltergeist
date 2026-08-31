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
permissions · D29 mobile hooks · D30 Séance license · D31 no mounting

### Stack and shape

- **D1 — Flutter/Dart monorepo mirroring Séance.** `packages/` (pure Dart) +
  `app/poltergeist_app` (Flutter). Desktop first — macOS leads the design,
  Windows and Linux ship from v1.0. iOS/Android are post-v1 (D29). Single
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
  passphrases, server list visible read-only, host-key pins synced
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
  may sit on different revs under D2's rev-pin hatch — and inspect each
  pinned tree for any of `LICENSE`/`LICENSE.md`/`LICENCE`/`COPYING` —
  e.g. `git cat-file -e <rev>:LICENSE` for each name — because a repo
  whose HEAD carries a LICENSE can still have pre-license pinned revs),
  so a prematurely cut tag cannot publish binaries embedding unlicensed
  code (07 §2 owns wiring the check — which MUST land no later than the
  first Séance git pin, since a `v*` tag cut in the window between that pin
  and the guard would publish unlicensed revisions the guard exists to
  block).
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
  pure Dart over the one VFS: parallel scans, size+mtime comparison with a
  2 s tolerance (SFTP v3 stores whole-second mtimes, so a preserved
  sub-second local mtime truncates on upload; FAT-family volumes
  additionally quantize to 2 s — the two drivers of the window. The
  window's false-equal hazard is a **documented limitation**, stated
  here rather than discovered: a same-size edit whose mtime lands
  inside the tolerance is classified unchanged and skipped — rsync
  (whose default `--modify-window` is 0/exact, with the window an opt-in
  documented for FAT) and WinSCP share the *hazard* and document it
  likewise — with the opt-in
  `contentHash` mode (D7) as the escape hatch and the per-pair
  tolerance adjustable in 05 §6), a typed
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
  ruleset as the equivalent rsync invocation, shell-safely — 05 §2.1's
  exporter contract owns the specifics (POSIX single-quoting of every
  path and argument, including the embedded-quote escape (`'` → `'\''`);
  never `-s`/`--protect-args` — that flag is unsupported on exactly the
  rsync builds this exporter's busybox/NAS/macOS-client audience is most
  likely running (rsync ≤ 2.6.9, long the system default on macOS and
  common on NAS boxes, and macOS 15.4+'s own openrsync), so relying on it
  would break the flagship platform's default client; the exporter
  instead backslash-escapes every remote-path byte outside a safe
  allowlist before local POSIX-quoting the result (05 §2.1's own
  double-escaping rule), closing the same *remote*-shell re-splitting/
  reinterpretation hazard `-s` would have addressed — without a version
  floor, and without the exporter ever needing to detect which rsync
  build the far end is running, since it is a pure command-string
  renderer with no exec channel to probe one (D5's shell-less transport
  gives it none) — quoting and `--`/`./`-prefixing
  (below) only govern the *local* shell that parses the pasted command; a `--` end-of-options separator before the first path argument plus
  `./`-prefixing (or absolutizing) every path, so a name like `-delete`
  can never be parsed as an rsync option and a name like `host:path` can
  never be reparsed as a remote host spec once the shell strips the
  quotes — quoting alone stops word-splitting and quote breakout, not
  argv-level reinterpretation by rsync itself; and, upstream of the
  exporter, 09's shared path validator rejecting
  newlines/control characters from ever reaching it, so an untrusted
  remote filename can never break out of the quoted argument — the
  exported command targets a POSIX shell
  (bash/zsh), pasting into cmd.exe or PowerShell being out of contract —
  hazard `# note:` lines, golden-tested); manual
  per-item overrides are
  annotated in a comment, never compiled into filters. An opt-in rsync
  accelerator remains a documented v2 possibility, driven per-item from our
  own plan; it may never be needed. Full analysis: 05.
- **D7 — Hashing policy.** The managed-checkout/edit pipeline keeps
  Séance's mandatory streamed SHA-256 (it is the conflict authority). Bulk
  transfers and sync make hashing **opt-in** ("verify after transfer"
  setting; `contentHash` comparison mode), pending D8/D9 measurements.
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
  purges under the identical 30-day rule); sync deletions *and* the previous versions of files sync
  overwrites default to the same `.poltergeist-trash/<runId>/` rename-based
  trash — falling back to copy-then-delete when the rename fails
  cross-filesystem (EXDEV, mirroring D26's local rule; 05's rail 5 owns
  this fallback, including the interrupted-copy recovery it tests for) —
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

- **D8 — Isolate architecture.** Transfer workers, hashing, archive work,
  and sync scan/diff run off the UI isolate. The connection pool and its
  SSH/SFTP sockets live in a dedicated I/O isolate (or isolate group) with a
  message-port API; the UI isolate holds only view state. M0 validates the
  design empirically before it hardens.
- **D9 — M0 is a dartssh2 fitness spike, week one.** Measure throughput vs
  the OpenSSH `sftp` baseline on LAN and high-latency links; audit algorithm
  coverage against 2026-era sshd (rsa-sha2-256/512, ed25519, aes128/256-gcm
  and chacha20-poly1305 ciphers, curve25519-sha256 kex, and the
  mlkem768x25519-sha256 post-quantum hybrid kex OpenSSH 10.0 made its
  default — verified against openssh.org's own release notes; a sshd this
  spike measures against and dartssh2 doesn't speak leaves M0 blind to
  its most current-gen compatibility gap); verify concurrent/pipelined
  requests on one SFTP channel actually
  work in dartssh2. Fallback ladder if it underperforms: contribute upstream
  → multiple channels/connections to compensate → document the ceiling → FFI
  to **libssh2** (BSD-3-Clause — permissive; its one obligation,
  carrying the libssh2 notice in a THIRD-PARTY-NOTICES file D23's
  releases would ship anyway, is acceptable under D30. LGPL `libssh`
  is avoided because *static FFI embedding* — the form this fallback
  would take — triggers its heavier relinking/source-availability
  duties; note that dynamic linking via `DynamicLibrary.open` — the normal
  Dart FFI pattern on desktop, which keeps the library user-replaceable —
  is the lighter LGPL path if `libssh` is ever reconsidered) as a last
  resort. The connection-pool and sync-scan designs are
  not finalized until M0 reports.
- **D12 — Numeric performance budgets** (tracked as benchmarks in CI, 08):
  first paint of a 10k-entry local directory < 150 ms; 100k entries < 1 s
  (virtualized); remote listing = network time + < 50 ms overhead, always
  cancellable; tab switch < 100 ms; drop-to-transfer-start < 500 ms (no
  upfront full-tree stat); scrolling drops no more than one frame per 10 s;
  sync scan ≥ 1 000 remote entries/s on LAN (pipelined readdirs).
- **D26 — Local↔local operations are first-class.** v1: streamed copy with
  progress + cancellation + mtime preservation; cross-device moves as
  copy+delete — the source is deleted only after the streamed copy completes
  successfully, so cancellation or failure leaves the original intact;
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
  turning it on stops recording immediately and prompts to purge the
  already-stored entries too (mirroring `Clear History`'s own action),
  so "none of that persisted" holds retroactively, not just going
  forward.
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
  step**; FileZilla `sitemanager.xml`, WinSCP INI, and Cyberduck bookmarks
  follow in v1.x behind the same preview UI.
- **D27 — Archives.** v1.x, not v1: local zip create/extract via
  `package:archive` with zip-slip-safe extraction (validate every component
  — Séance's path-validation tradition). Remote-side extraction and
  browsable archives are later, consciously scheduled in 07.

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
  Stated in the README; treated as a feature (the category punishes
  rent-seeking and opacity).
- **D23 — Distribution mirrors Séance.** GitHub Releases via the existing
  `release.yml` publish, from every `v*` tag: the unsigned/ad-hoc macOS
  bundle, Windows zip, Linux `.deb` + AppImage + bundle, Android APK, and
  unsigned iOS IPA (all already scripted); the mobile product remains
  post-v1 (D29) — the artifacts merely exist. No paid signing
  in v1 (documented first-launch steps) — but every release from
  `v0.1.0` on publishes `SHA256SUMS` beside the assets **and**
  `SHA256SUMS.asc`, a detached maintainer-key signature over that list
  (07 §4): an unsigned checksum alone only catches accidental corruption
  — anyone who can swap a binary can recompute its sum — so the
  signature ships from the first tag rather than waiting for v1.0.0,
  since generating one costs nothing paid certificates would — and the
  signing key never lives in CI secrets: `release.yml`'s tag-triggered
  publish creates the release **as a draft** — Séance's own inherited
  workflow calls `softprops/action-gh-release` with no `draft:` flag, so
  a stock port of it would go public the instant the workflow finishes,
  with nothing pausing for a human; Poltergeist's copy of the step adds
  `draft: true` — producing the assets and the unsigned `SHA256SUMS`
  while still hidden, and
  `SHA256SUMS.asc` is attached by a separate, maintainer-approved step
  (signed locally or via a hardware token) that then publishes the draft
  — before the release goes
  public, since a CI-resident key reduces the whole provenance claim to
  "trust GitHub/the CI runner" — exactly the release-channel compromise
  the independent-fingerprint requirement below exists to survive; the
  maintainer key's fingerprint is published out-of-band — concretely, a
  personal domain unrelated to this repo and release site, or an
  email-verified keys.openpgp.org entry: a bare keyserver reference is
  not enough, since the old SKS pool is gone and a plain keyserver is an
  unauthenticated directory — if both the key and its expected
  fingerprint trace back to the same untrusted server, an attacker who
  can insert one can insert the other, and the comparison proves
  nothing; keyservers stay a convenience for *fetching* the key, never
  the source of the *expected* fingerprint (the app's
  About box is a convenience cross-check for an already-installed,
  previously-trusted binary only — it ships inside the very artifact a
  release-channel compromise would replace, so it cannot bootstrap
  first-install trust the way an independently hosted fingerprint can) — and
  INSTALL.md walks users through verifying that
  fingerprint rather than just fetching the key from the download page
  (07 §4), since a signature alone only proves internal consistency, not
  provenance, without that independent check; integrity
  and provenance are both verifiable without paid certificates;
  architecture stays sandbox-ready
  (a `ScopedPathAccess` service fronts all local file access; sidebar
  bookmarks double as future sandbox grants) but v1 desktop builds are
  unsandboxed. Auto-update stays link-only.
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
- **D25 — v2-and-beyond parking lot** (recorded so nobody "helpfully"
  builds them early): true two-way sync with baseline DB; resumable
  transfers (ranged read/write); rsync accelerator; S3/WebDAV behind a
  capability matrix; browsable archives; scheduled/watched sync;
  multi-window; Custom Tools (user scripts); content search on remotes;
  byte-preserving *operations* on non-UTF-8 remote filenames — v1's
  policy for them (strict-decode; lossy display with a warning badge;
  operations on the flagged name terminally skipped — no retry affordance,
  since retry can never succeed — until byte-preserving handling lands;
  itemized with a tallied count in the same per-file reporting a transfer
  or sync scan already uses for any skip, so a "complete" run can never
  silently omit one) is already specified, not
  deferred (02 §13).

## The one-sentence product

> WinSCP's sync checklist with Transmit's polish and ForkLift's sidebar, on
> all three desktops, with E2E-encrypted bookmark backup through the Séance
> you already run — and no account, no telemetry, no rent.
