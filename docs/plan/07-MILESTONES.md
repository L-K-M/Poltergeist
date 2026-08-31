# 07 — Milestones and workstreams

This chapter turns the design (01–06) into an ordered, checkable build plan:
eleven milestones M0–M10, a parallel distribution workstream (D23), the
mobile constraints memo (D29), and the risk register. It elaborates the
decision log; where a decision is cited as "(Dn)" the log in
[00-OVERVIEW.md](00-OVERVIEW.md) is the authority.

## 1. Posture

- **A milestone is a mergeable, demoable state of `main`.** Every milestone
  ends with the app (or, for M0, the report and harness) merged, CI green,
  and something a human can run and see. No milestone ends on a branch.
- **Exit criteria are checkable by the implementation model.** Each is a
  concrete artifact, passing test, or observable behavior — never "feels
  polished". A milestone is closed by ticking every box, updating
  [docs/STATUS.md](../STATUS.md), and running the milestone-close chores
  (§3.12).
- **Estimates are relative sizes, not weeks.** S = one substantial PR or a
  few small ones; M = several PRs across one package plus its UI surface;
  L = a full workstream of many PRs spanning engine and UI. Sizes compare
  milestones to each other only.
- **Order is fixed; parallelism is limited and named.** The upstream-PR
  track (04 §5) and the distribution workstream (§4) run alongside the
  milestones. Within the milestone sequence, M5 may proceed in parallel
  with the tail of M4, and M6 with M7, because they touch disjoint code.
  Any other reordering is a plan edit, not a judgment call.
- **Budgets gate from the milestone that introduces them.** A D12 budget
  becomes a CI benchmark (08) in the milestone where its surface first
  exists. Tier-A engine benchmarks (the pure-Dart engine budgets — P3, P5,
  P7) run enforced (`BENCH_ENFORCE_A`, a red benchmark fails the job) from
  the milestone that introduces each surface; tier-B UI benchmarks run
  trend-only in CI (soft mode inside `check.dart`, 08 §6 — never
  `continue-on-error`) until M9 flips `BENCH_ENFORCE_B` — M9 is the flip
  plus an audit, not a rescue.

## 2. The milestone table

| # | Name | Delivers | Size | Séance gate (04 §5) |
|---|---|---|---|---|
| M0 | Engine fitness spike | dartssh2 benchmark/audit report, isolate PoC; pool + scan designs finalized | M | none (file S0, S1 now) |
| M1 | App scaffold | `app/poltergeist_app` committed, icon, window, theme, CI matrix green | S | none (file S2 now) |
| M2 | Connection layer | ConnectionManager + pool, engine isolate, TOFU/auth UI, probe, ssh_config import | L | **S0 landed (LICENSE on Séance main — first D2 copies) + S2 merged or rev-bridged (§3.3) + pin bumped** |
| M3 | Panes v1 | Local + remote browsing, tabs, sort/filter/type-ahead, path bar, empty states | L | none |
| M4 | Transfers | Queue + activity panel, DnD-in, conflicts, recursive ops, trash | L | none |
| M5 | Sidebar, bookmarks, workspaces | 04 §2 schema persisted locally, sidebar UI, workspaces | M | none (04 §2.1 temp model copy) |
| M6 | Bookmark sync | Design B enrollment, Design A behind the gate, settings UI | M | **S1 released** (for A) |
| M7 | Editor, checkouts, preview | 06 in full: built-in editor, external editors, Quick Look/preview | L | none |
| M8 | Sync | 05 in full: scan/diff/plan/preview/execute, rsync exporter | L | **S3 merged + pin bumped** (remote) |
| M9 | Polish pass | Palette, budgets enforced, a11y/i18n audit, chrome QA | M | none |
| M10 | v1.0 release | Distribution checklist complete, docs, STATUS flip, tag | S | none |

Fast-follows after v1.0 (in order): agent auth + ProxyJump (D10, PR-S4),
OS drag-out (D14), archives (D27), more importers (D22) — §3.13. Everything
else deferred lives in the D25 parking lot and stays there.

## 3. Milestones in detail

### 3.1 M0 — dartssh2 fitness spike + isolate PoC (D8, D9) — size M

**Goal.** Replace the plan's two biggest assumptions with measurements
before any design hardens: that dartssh2 is fast and capable enough (D9),
and that the engine-isolate architecture works (D8).

**Scope.**

- Throughput benchmark: single-file download and upload of 1 MB / 100 MB /
  1 GB payloads through `DartSshRemoteFileSystem`
  (Séance's `lib/src/ssh/remote_file_system.dart`, reached via the
  rev-pinned `seance_core` git dependency — not an in-repo path; this
  repo's packages are `poltergeist_*` only), against an
  OpenSSH `sftp` baseline on the same links: LAN-class (Docker sshd on
  localhost) and high-latency (the same container behind `tc netem`
  targeting 100 ms RTT — 50 ms delay + 25 ms jitter shaped in **both**
  directions, since RTT ≈ 2× the per-direction delay — egress-only netem
  delays a single direction, halving the effective RTT and skewing the
  pipelining conclusions; in-container `tc` also needs `--cap-add=NET_ADMIN`;
  the report row records the **measured** RTT, not the configured delay).
  Record MB/s with hashing on and off
  (hashing-off requires a patch until PR-S3 — carried as a committed
  patch on a rev-pinned branch of a Séance fork, never an uncommitted
  working-tree or pub-cache edit, so CI and fresh clones reproduce the
  numbers; measure both anyway — the delta is the D7 evidence).
- Algorithm audit: connect the exact dartssh2 version resolved by Séance's
  committed lock — 2.22.0 at M0 from its `^2.9.0` constraint — against a
  current OpenSSH sshd in four configs — defaults,
  `rsa-sha2-256/512`-only,
  `chacha20-poly1305@openssh.com` + `curve25519`/post-quantum-preferring
  kex, and an ed25519-hostkey-only config. Record what negotiates, what
  fails, and the exact error text.
- Pipelining verification: on ONE SFTP channel, issue 8–32 concurrent
  `read`s of one file and 8 concurrent readdirs of sibling directories;
  verify correctness (byte-compare) and measure scaling. Then measure N
  channels over one `SSHClient` and N separate transports. This arbitrates
  the research notes' open question (gaps §3.9) and fixes the numbers in
  `PoolPolicy` (03 §3.2) and the scanner's readdir depth (05 §3).
- Isolate PoC (03 §5 lists the pass conditions): dartssh2 sockets and
  multiple SFTP channels inside a non-root isolate; cross-port cancellation
  latency < 100 ms; coalescing proven headlessly — coalesced progress
  events arrive on the UI-side port at ≤ 30/s per task under a
  10k-event/s synthetic flood, and a main-isolate timer probe records no
  event-loop stall > 16 ms during 4 concurrent transfers + one directory
  listing; throughput parity with the single-isolate baseline.
- Harness code lives at `tool/bench/` (Dart CLI, repo root); the sshd
  Docker fixture lives at `test/integration/` (08 §5's layout:
  `docker-compose.yml`, `sshd-modern/` and friends, `run.sh`) and lands in
  the M0 PR. The bench harness starts at `tool/bench/` and migrates into
  `packages/*/benchmark/` + `test/benchmarks/` at M3, so this chapter and
  08 describe one lifecycle. Sketch of the harness seam:

```dart
import 'dart:io'; // Platform.localHostname, stamped at row construction

// tool/bench/lib/harness.dart — every scenario returns one of these.
class BenchResult {
  final String scenario;      // 'download-1g-lan-hash-off'
  final int bytes;
  final Duration elapsed;
  // decimal MB (10^6 bytes)/s, DERIVED: bytes per microsecond is exactly
  // MB per second, so a row's rate can never disagree with its own
  // bytes/elapsedUs once rows merge across runs.
  double get mbPerSec => bytes / elapsed.inMicroseconds;
  final String? note;         // negotiation details, failure text
  final String dartssh2Version; // exact hosted version in the harness lock —
                                // structured so dependency drift cannot mix
                                // unlike rows in one report
  final String seanceRev;     // seance_core git-pin rev under test
  final int? rttMs;           // measured RTT for shaped links (null on
                              // LAN-class rows) — the MEASURED value, never
                              // the configured netem delay (§3.1)

  // Fixed when the row is built: the harness passes DateTime.now().toUtc()
  // and Platform.localHostname at capture, fromJson passes the stored
  // values, so toJson() stays pure and serializing one row twice can never
  // disagree.
  final DateTime timestampUtc;
  final String host;

  const BenchResult({
    required this.scenario,
    required this.bytes,
    required this.elapsed,
    this.note,
    required this.dartssh2Version,
    required this.seanceRev,
    this.rttMs,
    required this.timestampUtc,
    required this.host,
  });

  Map<String, Object?> toJson() => {
        'scenario': scenario,
        'bytes': bytes,
        'dartssh2Version': dartssh2Version,
        'seanceRev': seanceRev,
        'rttMs': rttMs,
        'elapsedUs': elapsed.inMicroseconds, // µs — LAN 1 MB runs finish
                                             // in single-digit ms; ms would
                                             // quantize the D7 hashing delta
        'note': note,           // mbPerSec is derived (getter), not stored
        // Rows from different days/machines must stay attributable once the
        // report merges them (and once M3 moves this to CI). The harness
        // stamps both at capture and fromJson reads them back, so toJson is
        // pure — serializing one row twice can never disagree, and the
        // in-memory row's timestamp is never a write-time fabrication.
        'timestampUtc': timestampUtc.toIso8601String(),
        'host': host,
      };

  // The report tooling merges rows across runs, so the row round-trips.
  factory BenchResult.fromJson(Map<String, Object?> json) => BenchResult(
        scenario: json['scenario']! as String,
        bytes: json['bytes']! as int,
        elapsed: Duration(microseconds: json['elapsedUs']! as int),
        note: json['note'] as String?,
        dartssh2Version: json['dartssh2Version']! as String,
        seanceRev: json['seanceRev']! as String,
        rttMs: json['rttMs'] as int?,
        timestampUtc: DateTime.parse(json['timestampUtc']! as String),
        host: json['host']! as String,
      );
}
```

**Deliverable.** A written report, `docs/M0-DARTSSH2-REPORT.md`, with the
tables above, a verdict per D9's fallback ladder (fine as-is → contribute
upstream → compensate with channels/transports → document the ceiling →
FFI to libssh as last resort), and the finalized `PoolPolicy` defaults and
scan pipelining depth. Rungs 3–5 of the ladder require editing the decision
log (00) in the same PR — the ladder pre-authorizes the discussion, not a
silent downgrade.

**Exit criteria.**

- [ ] `docs/M0-DARTSSH2-REPORT.md` merged with all four measurement
      sections filled in and a one-paragraph verdict.
- [ ] `PoolPolicy` defaults and 05 §3's readdir depth updated (or
      confirmed) from the report, in the same PR.
- [ ] Isolate PoC passes every 03 §5 pass condition, or the fallback and
      a 00 edit are in the PR.
- [ ] `tool/bench/` and `test/integration/` committed and runnable per
      their README lines.
- [ ] PR-S0 and PR-S1 are filed against Séance (04 §5 says "immediately";
      M0 is the calendar hook).

**Risks.** dartssh2 underperforms (the ladder exists for this); the spike
sprawls — timebox it to the scenarios listed, nothing exploratory.

### 3.2 M1 — app scaffold — size S

**Goal.** `app/poltergeist_app` exists, builds on all client platforms in
CI, and looks like the beginning of Poltergeist, not a counter demo.

**Scope.**

- `flutter create --org com.lkm app/poltergeist_app` — the `--org` is
  load-bearing: it yields Android id `com.lkm.poltergeist_app`, Apple
  bundle id `com.lkm.poltergeistApp`, and Linux `APPLICATION_ID`
  `com.lkm.poltergeist_app`; the `.desktop` `StartupWMClass`, however,
  must be the **binary name** `poltergeist_app` (X11 `WM_CLASS` follows
  CMake `BINARY_NAME`, not the dotted application id) — kept in sync in
  `scripts/package-linux.sh` (AGENTS.md §3). Commit the
  platform folders. The app is NOT added to the root workspace `members`;
  it path-depends on `packages/poltergeist_core` (AGENTS.md §4).
- Create the master icon `media-sources/poltergeist-icon.png` (1024×1024,
  the ghost — D24 personality) and generate all platform icons with
  `flutter_launcher_icons`; keep the generation config in the app pubspec
  so regeneration is one command. `scripts/package-linux.sh` requires the
  master file.
- `window_manager` (pin the exact version) for min/initial size, remembered
  geometry, and the prevent-close hook (wired to the queue in M4);
  `macos_window_utils` for the macOS titlebar treatment (D11).
- Theme scaffold: the "quiet chrome" `ColorScheme.fromSeed` setup per
  02 §11, light + dark. `gen-l10n`/ARB wiring with the first strings
  externalized (D20 — no hard-coded user-facing string ever lands).
- Delete the counter app; show an empty window with the two-pane layout
  skeleton (dead panes, real splitter) so the demo reads as Poltergeist.

**Exit criteria.**

- [ ] `flutter analyze` and `flutter test` pass in `app/poltergeist_app`.
- [ ] PR-S2 (`openAuthenticatedClient`, 04 §5.3) is filed against Séance —
      the milestone table's "file S2 now" gate; M2 then requires it merged
      or rev-bridged per §3.3 — and, unless it has already merged, at least
      in review — mirroring
      M0's "PR-S0 and PR-S1 are filed" box so the gate is checkable.
- [ ] `ci.yml`'s `detect` job activates the `flutter` and `client` jobs and
      the full matrix (android / linux / macos / ios / windows) is green,
      including the `.deb`/AppImage packaging step.
- [ ] Identifiers verified in-tree: grep shows the three ids above and no
      `com.example`; the `poltergeist_core` ASCII-name test still passes
      and a test (or CI grep) asserts the app's bundle/file names are
      ASCII.
- [ ] Rehearsal tag `v0.1.0` pushed via `scripts/release.sh`;
      `release.yml` publishes D23's full scripted asset set — APK, Linux
      `.deb`/AppImage/bundle, macOS bundle, Windows zip, and the
      **unsigned** iOS IPA (D23's script zips `Payload/` out of the
      `--no-codesign` `.xcarchive` — on current stable Flutter,
      `flutter build ipa --no-codesign` stops at the unsigned archive
      and emits no `.ipa` on its own, so without the explicit zip step
      the iOS asset would silently be missing; re-sign to sideload — no
      signing infrastructure involved) — marked as a pre-release. If D23
      lags, publish the assets that exist and record the gap in
      STATUS.md (the Risks fallback below) — that ticks this box too;
      the box never stalls M1 on the parallel workstream. The fallback
      has a floor: the APK and the Linux `.deb`/AppImage/bundle must
      publish — everything they need (icons, identifiers, the committed
      keystore — §4's M1 rows; §4's "Android signing & checksums"
      section owns that key's deliberately-public risk posture in full,
      including same-key update attacks and any pre-v1.0 key rotation)
      builds on `ubuntu-latest`, so
      their absence is a pipeline bug, not D23 lag, and the tag waits
      for the fix. A rehearsal that publishes nothing rehearses nothing.

**Risks.** Toolchain drift in CI runners — fix versions in the workflow,
not in prose. And one real dependency the gate column does not show: the
rehearsal release requires `release.yml` to publish D23's full asset set,
which the parallel distribution workstream (§4) delivers — if D23 lags,
publish the assets that exist and record the gap in STATUS.md rather
than stalling M1, **subject to the exit criterion's floor**: the APK
and the Linux `.deb`/AppImage/bundle must publish, their absence is a
pipeline bug, and the tag waits for that fix — this fallback never
authorizes a rehearsal that publishes nothing. Keep this milestone
small on purpose.

### 3.3 M2 — connection layer — size L

**Goal.** Poltergeist can connect: pool, prompts, diagnostics, import.
Gates: **PR-S0 landed** (LICENSE on Séance `main` — M2 performs the first
D2 copies, which must not happen before it), and **PR-S2**
(`openAuthenticatedClient`, 04 §5.3) landed on Séance `main` — **or**
carried as a recorded branch-rev bridge per the next sentences — with the
Séance pin bumped accordingly; either state satisfies the gate, and the
bridged form must be recorded as a dated open item in STATUS.md (D2's
rev-pin rule). If upstream review is slow, pin to the rev of the PR
branch (the
git pin is by rev anyway) and re-pin to the landed commit on `main`
after — never
copy the code. If Séance squash-merges, rebase-merges, force-pushes the
branch during review, or deletes it, re-pin immediately: any of these
makes the branch-rev SHA unfetchable for fresh clones (a squash or rebase
never leaves the original SHA an ancestor of `main`, and a force-push
replaces the tip — the most likely breakage while the bridge is live).
If the PR is filed from a fork, resolve the rev through
`refs/pull/<n>/head` rather than a plain SHA fetch, which may not resolve
against `origin` at all.

**Scope.**

- Engine isolate + `EngineClient` + the typed port protocol (03 §5), with
  `ConnectionManager`, the per-server pool, `PoolPolicy` (M0 numbers), the
  growth rules — serialized first connect, interactive-auth cap, TOFU
  single-prompt — keepalive, idle teardown, and auto-reconnect with
  backoff + jitter (03 §3.2–3.3).
- The bookmark data model from 04 §2.1 (`BookmarkKind { localFolder,
  remotePath, workspace, savedSync }`, `EmbeddedHostIdentity`) lands in
  `poltergeist_core` now — as the temporary strict-`fromJson` copy until
  the pin includes PR-S1 (04 §2.1). M2 builds the connect flow on it; M5
  adds the sidebar UI on top. No second server model is ever introduced.
- Vault plumbing ported per D2 with PORTS.md entries (the ledger file is
  created by the first copy): `MasterKeyManager` pattern
  (`poltergeist.vault.masterKey.v1`, legacy login keychain on macOS),
  `SecretVault`, JSON file stores with atomic writes.
- Prompt UI: host-key dialog (first-use approve; changed-key hard block,
  never auto-repin — D18), keyboard-interactive dialog, credential prompt
  when the vault has no secret. Prompts round-trip from the engine isolate
  per 03 §5. The live `SshConnectionLog` transcript renders during connect
  and stays visible on failure with the summarized one-liner.
- `ProbeService` wired (03 §3.4); status dots render in the interim server
  list (the sidebar reuses them in M5).
- ssh_config import with **preview + dedupe** (D22): Séance's
  `SshConfigImporter` via the pin, a preview table (import/skip per row,
  dedupe against existing bookmarks by host+port+username), IdentityFile
  mapped to reference-style key auth.
- D10 seam prep only (no implementation): `jumpHostId` plumbed through
  untouched; pool growth reuses resolved `SshCredentials`; nothing assumes
  auth is non-recursive.
- Demo surface: a debug-only listing view proving connect → SFTP channel →
  `listDirectory` end to end. It is throwaway; M3 replaces it.

**Exit criteria.**

- [ ] Connects to the `test/integration/` matrix: key, password, and
      keyboard-interactive auth; TOFU first-use and changed-key flows
      exercised by widget/integration tests.
- [ ] Interactive-auth servers never see a second auth prompt from pool
      growth (test: pool capped at one transport).
- [ ] Kill the sshd container mid-session: the browse channel reconnects
      with backoff and re-canonicalizes; the event stream shows the state
      transitions.
- [ ] ssh_config import preview shows, dedupes, and imports; IdentityFile
      entries connect.
- [ ] `docs/PORTS.md` exists with an entry per copied file.
- [ ] Pin bump recorded; `dart test packages/poltergeist_core` green.
- [ ] If PR-S2 is carried as the branch-rev bridge, STATUS.md records it as
      a dated open item (the §3.3 gate's own requirement).

**Risks.** PR-S2 stalls (pin-to-rev mitigation above); isolate prompt
round-trips feel laggy (measure against the D12 budgets now, not in M9).

### 3.4 M3 — panes v1 — size L

**Goal.** Both panes browse local and remote through the one VFS (D3),
fast, keyboard-first, honest about latency.

**Scope.**

- `LocalFileSystem implements RemoteFileSystem` in `poltergeist_core`
  (03 §2.2), implementing all PR-S3 additions from day one — as concrete
  methods on the class until the pinned interface declares them, 03 §2.2's
  own bridge ("the sync engine's local half never waits on the upstream
  PR"): they become interface overrides at the PR-S3 pin bump, and a
  caller that needs one before then types against the concrete
  `LocalFileSystem` under §3.9's `// TODO(pin)` rule. Never an in-repo
  extension interface — D3 allows exactly one VFS.
- `PaneController` (03 §6) with the two required async idioms (generation
  counter, `identical()` recheck); tabs per pane (02 §3); the pane toggle.
- Virtualized views: fixed-`itemExtent` list view and the
  `two_dimensional_scrollables` `TableView` details view with our own
  sortable header (02 §2.2–2.3); sort/filter/hidden files; type-ahead and
  Quick Select (02 §2.5); row interactions incl. rename field with scoped
  single-key shortcuts (02 §8.2).
- Path bar with editable path (02 §2.1); navigation history (back/forward/
  up); latency honesty rules — cancellable navigations, spinner rules,
  stale-listing handling (02 §2.8); pane footer (02 §2.9).
- Empty states per 02 §2.7 — the empty-state-as-launcher (connect,
  import, open folder) becomes the default connect entry point; M2's
  interim server list coexists until M5 deletes it (§3.6 owns the
  removal — its probe dots stay live for the M3–M4 window).
- Sync Browsing (02 §7) — cheap once navigation is centralized; anchor
  pair, graceful suspension, link chips.
- Command registry (D21) lands NOW with every pane action registered;
  menus (`PlatformMenuBar` on macOS, `MenuBar` widget elsewhere) render
  from it. The palette UI itself waits for M9; the registry does not.
- Per-visible-directory non-recursive watching with debounce (03 §7.5).
- Local access flows through `ScopedPathAccess` from the first local pane
  (03 §7.2) — v1 desktop grants are pass-through, but the seam exists.
- Bench harness migrates from `tool/bench/` into `packages/*/benchmark/`
  + `test/benchmarks/` per the M0 commitment (08's layout) — this is what
  gives the CI benchmarks below a home (P1–P4 and P6 gate at M3; P5 gates
  at M4 and P7 at M8, the milestones that introduce their surfaces, §1);
  `tool/bench/` is deleted or
  reduced to a thin entrypoint.

**Exit criteria.**

- [ ] D12 browse budgets are CI benchmarks: the tier-A remote-listing-
      overhead benchmark (P3, < 50 ms, measured as the **median of ≥5 warm
      runs of the overhead over the local-listing baseline on the same
      runner** — never a single-run absolute wall-clock, which flakes on
      shared `ubuntu-latest`) is green **and enforced**
      (`BENCH_ENFORCE_A`, red = failed job); the tier-B UI benchmarks —
      10k-entry local paint < 150 ms (P1), 100k < 1 s (P2), tab switch
      < 100 ms (P4), scroll jank within budget (P6) — run trend-only and
      are green in the job summary.
- [ ] Keyboard completeness for browse commands: the 08 invariant test
      (every registered command reachable via menu/shortcut) passes for
      the `go.*`, `view.*`, `pane.*`, `tab.*`, `selection.*` groups that
      exist so far.
- [ ] Type-ahead, Quick Select, sort, filter, hidden toggle all covered by
      widget tests; rename field swallows single-key shortcuts.
- [ ] Sync Browsing suspends and resumes per the 02 §7 copy.
- [ ] A cancelled remote navigation leaves the pane on the old listing
      with no stale repaint (generation-counter test).

**Risks.** This is the milestone Spacedrive-class projects die in — slow
basics. Tier-A benchmarks are enforced — a red tier-A run is a failed
job; a tier-B regression is visible in the job summary — treat it like a
red test even before M9 makes it one.

### 3.5 M4 — transfers — size L

**Goal.** The transfer queue and activity panel — the trust organ (D16) —
plus every file operation a browser needs.

**Scope.**

- Engine-side `TransferQueue` per 03 §4: task model, scan-then-execute,
  concurrency via channel leases, token-bucket throttle, pause/cancel
  semantics, remote→remote piping, the produce-on-demand hook (D14 — hook
  only, no drag-out), and the persistence journal + history store that
  survives restart (D16).
- Activity panel UI per 02 §6: per-item rows always, reorder, per-item
  cancel/retry, queue pause, throttle control, history view that works.
- Drag & drop: in-app pane↔pane via `Draggable`/`DragTarget`; OS drop-in
  via `desktop_drop` with Séance's TickerMode/route gating pattern; drop
  position decides hovered-folder vs current directory (D14).
- Conflicts: the 5-verb model — Replace / Replace-if-newer / Keep Both /
  Skip, Merge for folders — with per-direction defaults (02 §5.2).
- Recursive operations: upload/download/delete with app-level walker,
  aggregate progress, cancellation; Windows-reserved-name and traversal
  safety ported from `RemoteFilesController`'s validation.
- Local↔local first-class ops (D26): streamed copy with progress +
  cancellation + mtime preservation, EXDEV move as copy+delete, case-only
  rename handling.
- Trash (D15): the in-repo Trash service and `poltergeist/trash` channel
  per 03 §7.1/§7.3 — macOS
  `FileManager.trashItem` (Finder's Put Back is best-effort OS-provided
  behavior, verified in the manual QA note, not something the app
  guarantees), Windows `IFileOperation` +
  `FOF_ALLOWUNDO` via `win32` FFI, Linux `gio trash`. Remote browse
  deletions: confirm-then-permanent, with the per-server
  `.poltergeist-trash/` opt-in instead.
- chmod UI (D28): octal + checkboxes, recursive apply over the walker.
  (chown waits for the PR-S3 pin bump; it ships with M8/M9.)
- `window_manager` prevent-close wired: quitting with active tasks warns
  and flushes the journal.

**Exit criteria.**

- [ ] Drop-to-transfer-start < 500 ms (no upfront full-tree stat) — the
      tier-A P5 benchmark green **and enforced** (`BENCH_ENFORCE_A`),
      measured as the median of ≥5 warm runs on the same runner, like P3.
- [ ] Kill the app mid-queue; relaunch restores queued/paused tasks from
      the journal and history shows completed ones.
- [ ] Conflict dialog covers all five verbs; per-direction defaults
      honored; folder Merge recurses correctly (tests).
- [ ] Recursive delete of a 10k-entry tree shows progress and cancels
      cleanly on both local and remote.
- [ ] Trash round-trip test per platform in CI where the runner allows;
      manual QA note recorded for the rest.
- [ ] Remote→remote pipes between two Docker sshds.

**Risks.** Three small native trash surfaces (medium risk in the research
notes) — fall back per-platform to confirm-permanent only if a platform
blocks, and record it; the queue journal format churns — version it from
the first write.

### 3.6 M5 — sidebar, bookmarks, workspaces — size M

**Goal.** The ForkLift-style sidebar (R4) over the 04 §2 schema, persisted
locally. Sync comes next milestone; nothing here depends on a server.

**Scope.**

- `BookmarkStore` (03 §6): JSON file store, atomic writes, device-local
  field split honored (secure-bookmark blobs, per-device view state never
  serialize into the synced payload — 04 §2.3).
- Sidebar UI per 02 §4: named groups, all four bookmark kinds render
  (workspace/savedSync open their features once those exist), drag to
  reorder/group, probe dots via `ConnectionStatus`, preferred-pane,
  context menus, keyboard navigation.
- Workspaces (02 §3): capture/restore both panes' tabs and paths as a
  `workspace` bookmark.
- The M2 interim server list is deleted; the sidebar and the empty-state
  launcher are the only entry points.

**Exit criteria.**

- [ ] Bookmark CRUD, grouping, reorder persist across restart.
- [ ] `localFolder` and `remotePath` bookmarks open in the chosen pane;
      `workspace` restores tab sets exactly.
- [ ] Device-local fields proven non-syncing by a serialization test
      (the `BookmarkStore` payload JSON contains no local-only keys **and
      no secure-bookmark blobs** — the exact shape M6's sync will consume,
      so a leak is caught here, not as an M6 sync bug).
- [ ] Sidebar fully keyboard-operable, with keyboard navigation and
      drag-to-reorder/group covered by widget tests; semantics per D20 on
      every row.

**Risks.** Schema drift versus PR-S1's upstream copy of the model — the
04 §2.1 rule stands: one authoritative schema, temporary copy deleted at
the pin bump.

### 3.7 M6 — bookmark sync (R5) — size M

**Goal.** Bookmark backup through Séance's sync server (D4): Design B
first (works against unmodified Séance today), Design A behind the PR-S1
release gate.

**Scope.**

- Persistent record store + tombstone deletions per 04 §3.1–3.2;
  `BookmarkCoordinator` with strict decode and skip-and-preserve (04
  §3.2).
- Design B (separate account, 04 §4.1): register/login, KDF-downgrade
  refusal, trial-decrypt before persisting, token in keystore.
- Design A (shared account, 04 §4.2): login-only, read-only Séance server
  catalog, host-key pin reuse, never-expose-account-deletion rule; gated
  on `kMinimumSharedAccountSeanceVersion` (the PR-S1 release tag) and the
  fleet-confirmation checkbox.
- Settings → Backup UI with the exact 04 §4.3 copy, **Design B
  preselected**; the B→A switch flow (04 §4.4).

**Séance-PR dependency.** Design B has no hard Séance dependency; its
one conditional is the 04 §5.6 sealing shim, required only when the pin
lags PR-S1's record model (04 §5.6 defines exactly when that state
holds). Design A needs PR-S1 **released and
its tag recorded**; until then the option renders with the gate copy and a
disabled Continue.

**Exit criteria.**

- [ ] Two-device convergence tests against `seance_sync_server` in Docker:
      create/edit/delete bookmarks on A, converge on B, tombstones win and
      stay won (04 §3 tests).
- [ ] A `flurb`-kind record survives rounds unmodified; a malformed known
      kind skips without aborting the round.
- [ ] The enrollment security behaviors are tested: KDF downgrade
      refused (`meetsMinimum()`), trial-decrypt before persisting (the
      04 §4.5 foreign-record rule and push hold included), sync token
      stored only in the OS keystore; the B→A switch flow (04 §4.4)
      works end to end; Design A renders gated — disabled Continue —
      until PR-S1's tag is recorded in
      `kMinimumSharedAccountSeanceVersion`.
- [ ] Design A against a patched Séance: catalog section renders, a
      Séance-pinned host connects with no TOFU prompt.
- [ ] All 04 §4.3 strings verbatim in ARB; 403 `registration_closed`
      shows its documented copy.

**Risks.** PR-S1's release lags — Design B ships regardless; the gate is
about Séance's decoder, not ours. Never work around the gate.

### 3.8 M7 — editor, checkouts, preview (R8, R9) — size L

**Goal.** Chapter 06 in full: the ported built-in editor, the managed
checkout pipeline, external editors, Quick Look and the preview pane.

**Scope.**

- D2 copies with PORTS.md entries: document I/O with BOM/CRLF fidelity,
  syntax engine, find bar, conflict-aware save-and-upload — behaviorally
  identical to Séance (D17).
- `CheckoutManager` per 03 §6: ported `ManagedRemoteFileStore`, per-server
  `editSessionId` (never pane/tab), watch + debounce + reconcile-on-resume,
  survive process death, never silently upload; SHA-256 stays mandatory on
  this path (D7 — it is the conflict authority).
- External editors: ported `EditorRegistry` + open-with/pick-application
  channels; upload-on-save loop.
- macOS Quick Look channel (spacebar); Windows/Linux in-app preview pane
  (text/images/PDF) per 06.

**Exit criteria.**

- [ ] Edit round-trip conflict test: remote changes under an open
      checkout → save is blocked with the conflict flow, never a silent
      overwrite.
- [ ] Kill the app with dirty checkouts; relaunch reconciles and offers
      resume per 06.
- [ ] External editor save triggers upload with progress in the activity
      panel.
- [ ] Spacebar previews local and (via the preview cache,
      `TransferProducer`) remote files on
      macOS; the preview pane covers text/images/PDF elsewhere.

**Risks.** Watcher edge cases (atomic-replace saves) — the ported
parent-directory watching pattern exists precisely for this; do not
re-derive it.

### 3.9 M8 — sync (R6) — size L

**Goal.** Chapter 05 in full — the flagship. Gate: **PR-S3 merged and the
pin bumped** before any remote sync work (`setTimes` is the convergence
prerequisite, D3). Local↔local sync may start earlier, and the seam is
named so nobody improvises: file PR-S3 early and pin Séance **by rev to
the filed PR-S3 branch** (the D2 stalled-PR exception) — the pinned
`RemoteFileSystem` then already carries `setTimes`, no shim and no second
interface (D3). Only if even that pin is unavailable may local-only work
call the concrete `LocalFileSystem.setTimes` directly behind a
`// TODO(pin)` marker, deleted at the bump. On that footing the engine,
plan model, and preview UX are built and tested against local pairs while
the upstream review lands.

**Scope.** `poltergeist_sync` per 05: pipelined scanner with the M0-tuned
depth, size+mtime comparison with the 2 s tolerance, the three v1 modes,
the `SyncPlan`-is-the-preview model with per-item override, safety rails
(mandatory preview, typed >50 % confirmation, `maxDelete`,
`.poltergeist-trash/<runId>/`, JSONL journal, Retry Failed / Restore
Trashed Files), the plan view with 05 §7's exact copy, saved syncs as
`savedSync` bookmarks, execution in the activity panel, and the
golden-tested "Copy as rsync command" exporter (D6).

**Exit criteria.** 05's Definition of done is the checklist; additionally:

- [ ] Sync scan ≥ 1 000 remote entries/s on LAN (P7 benchmark, D12).
- [ ] Docker matrix includes the setstat-ignoring server; the `sizeOnly`
      fallback notice appears.
- [ ] chown UI (D28) enabled if the **merged** PR-S3 pin carries
      `setOwner`; otherwise ship without it and record the deferral in
      STATUS.md.

**Remote-gated criteria.** All three checkboxes above read "the pin" as
the Goal's hard gate satisfied — PR-S3 **merged** and the pin bumped to
the merge. A branch-rev pin of the filed PR-S3 unblocks the
local↔local work only, never these criteria; if the merge has not
landed by milestone close, each is recorded as deferred in STATUS.md
(dated, with the branch rev noted), exactly like the M2 bridge record.

**Risks.** The category's cardinal sin is a sync that surprises (01 §5
trap 5). The executor runs exactly the reviewed plan and re-verifies per
item; any deviation found in review is a highest-severity defect (08).

### 3.10 M9 — polish pass — size M

**Goal.** Close the gap between "works" and "the point of the app" (R1).
Nothing new lands here that changes architecture.

**Scope.**

- Quick Open palette (02 §8.4) over the registry that has existed since
  M3; palette rows show and accept their shortcuts (D21).
- Import experience finished: first-run/empty-state offers ssh_config
  import; preview UI polished. v1 importer scope is confirmed as
  ssh_config only (D22); FileZilla/WinSCP/Cyberduck are v1.x behind the
  same preview.
- The tier-B enforcement flip (08 §6): `BENCH_ENFORCE_B` turns the tier-B
  UI benchmarks from trend-only to gating, and the audit confirms every
  D12 benchmark exists and is green — tier-A engine benchmarks have been
  enforced since the milestone that introduced each surface. M9 is the
  flip plus an audit, not a rescue.
- a11y audit per 02 §13: hand-built semantics on rows/tables (name–size–
  date, selection, sort state), focus-visible styling everywhere,
  contrast-checked status colors (the SEA-019 class fix), live regions on
  transfer/sync progress. Linux screen-reader breakage documented honestly
  (D20).
- i18n sweep: zero hard-coded user-facing strings (CI grep + l10n lint);
  reason strings and plurals verified.
- Per-platform chrome QA against 02 §9–11: menus, dialogs, shortcuts
  (meta vs control), scroll physics, titlebars; Windows IME behavior in
  rename fields tested and known issues documented (Flutter IMM32
  caveats).
- Local fast-path spike (D26): measure APFS `clonefile`, Linux `FICLONE`,
  Windows `CopyFileEx` against the streamed copy; adopt only what wins
  clearly and keeps progress/cancel semantics, else record the numbers
  and defer to v1.x.
- Link-only update check (D19): Séance's banner pattern against the
  GitHub latest-release tag; a link, never a download.

**Exit criteria.**

- [ ] Command-completeness invariant test green over the full registry.
- [ ] Palette opens, filters, executes, and teaches shortcuts.
- [ ] a11y checklist in 08 fully ticked; VoiceOver and NVDA walkthrough
      notes committed.
- [ ] Every D12 benchmark green and enforced (both tier flags on, on the
      bench job's schedule per 08 §6/§8) — the tier-B flip is done.
- [ ] Known-issues section (Linux a11y, Windows IME) written into README.

**Risks.** Polish squeezed by schedule — structurally mitigated: budgets
gated from M3, a11y semantics built with each surface. If M9 still
overflows, the §6 cut lines apply — never quiet scope-dropping.

### 3.11 M10 — v1.0 release — size S

**Goal.** Ship. The distribution workstream (§4) must be fully checked.

**Scope and exit criteria.**

- [ ] Distribution checklist (§4) complete, including first-launch docs.
- [ ] README carries the trust-stance copy (01 §6) and the version line;
      human release notes written (D24 — personality, no changelog dump).
- [ ] `docs/STATUS.md` flipped: v1.0 shipped, fast-follow list (§3.13) as
      the new next-steps.
- [ ] PORTS.md swept; port-back issues filed upstream per 04 §6.
- [ ] `scripts/release.sh 1.0.0 --push` (the script takes the bare
      version and tags `v1.0.0` itself — AGENTS.md's documented
      convention, matching `release.yml`'s `v*` trigger — the tag itself
      is `git tag -s`-signed with the maintainer's local key, never a CI
      secret, per §4); `release.yml`
      green; assets
      install-tested on macOS, Windows, and one GNOME + one KDE Linux
      (fresh machines/VMs, following only the first-launch docs).
- [ ] The mobile constraints memo (§5) reviewed once against the shipped
      architecture; deviations recorded.

### 3.12 Milestone-close chores (every milestone)

1. Update `docs/STATUS.md` (done table + next steps, exit criteria
   ticked there). This chapter stays stable — live progress never edits
   the plan.
2. Sweep `docs/PORTS.md`: batch small upstream fixes, refresh recorded
   commits (04 §6).
3. Bump the Séance pin if upstream merged anything; re-diff ported files
   (03 §8.1); grep for `// TODO(pin)` markers and delete every one the
   bump obsoletes (§3.9's rule).
4. Tag `v0.<milestone>.0` as a pre-release for M1 through M9 — every tag
   is a release-pipeline rehearsal, so `release.yml` never rots — via
   `scripts/release.sh 0.<milestone>.0 --push`, the identical path
   v1.0.0 uses; `release.yml`'s `softprops/action-gh-release` step keys
   `prerelease` off the leading `0.`, so every `v0.*` tag publishes as a
   pre-release automatically and a rehearsal tag can never become the
   repo's latest stable release. From `v0.1.0` on, the same step also treats
   any semver pre-release suffix (`v1.1.0-rc1`, betas) as a pre-release —
   e.g. `prerelease: startsWith(github.ref, 'refs/tags/v0.') ||
   contains(github.ref, '-')` — so an RC can never publish as Latest either
   (a one-expression change that closes the window now rather than at v1.x
   time). The leading-`0.` rule alone stops holding the moment any
   hyphenated `v1.*` tag exists; the tag grammar may instead forbid such
   tags — pick one, consistent with §4's versionCode suffix rule.
   M10 ships `v1.0.0` (§3.11) and no `v0.10.0` pre-release.
5. Re-check the §5 mobile invariant for the milestone (M0 predates the
   app and is exempt; every other milestone has a row in the §5 table).

### 3.13 Fast-follows after v1.0 (v1.x, in order)

1. **Agent auth + ProxyJump** (D10, PR-S4 in `seance_core`, 04 §5.5) —
   first, and explicitly not "eventually": `$SSH_AUTH_SOCK` / Windows
   named-pipe agent client with a custom `SSHKeyPair` signer; ProxyJump
   as recursive `openAuthenticatedClient` behind `jumpHostId`. The M2
   seams make this additive.
2. **OS drag-out** (D14): spike `super_drag_and_drop` 0.10.x on current
   Flutter; if it fights the queue or the engine, custom per-platform
   plugins, macOS `NSFilePromiseProvider` first. The produce-on-demand
   hook has existed since M4 (§3.5 scope, D14 — hook only, no drag-out).
3. **Archives** (D27): local zip create/extract via `package:archive` in
   `Isolate.run` workers, zip-slip-safe extraction (validate every
   component). Remote-side extraction and browsable archives stay later.
4. **Importers** (D22): FileZilla `sitemanager.xml`, WinSCP INI, Cyberduck
   bookmarks — same preview + dedupe UI.
5. **Deep links** (04 §7.1) and the text-diff view for sync pairs (05 →
   06 deferral), as demand dictates.

**v1.x backlog** — the smaller deferred items that 02/05/06 point here:
Sync Browsing, if risk 8's pre-authorized cut line is ever exercised
(the cut's destination must exist in a tracked list, or cutting would
be the quiet scope-dropping this chapter forbids);
batch/multi-rename UI; the named skip-rules engine (Transmit-style Rules);
custom keymap editing UI; the native file icons/thumbnails channel; the
cross-pane Compare entry point; Quick Look prefetch / preview-cache
warming. Scheduled opportunistically after the numbered fast-follows.

Everything else on anyone's wishlist is in the D25 parking lot; building
it early is a plan violation, not initiative.

## 4. The distribution workstream (D23)

A parallel track, not a milestone — it accretes alongside M1–M10 and must
be complete at M10. `release.yml` already exists and publishes per-platform
assets on `v*` tags; the work is everything around it.

| When | Item |
|---|---|
| M1 | Master icon `media-sources/poltergeist-icon.png`; `flutter_launcher_icons` config; per-platform icons committed |
| M1 | Identifier audit (org ids, `StartupWMClass`, ASCII names) |
| M1 (before `v0.1.0`) | Commit the public debug-grade keystore `android/app/ci-release.jks` **plus its public store/key passwords and alias** (a committed `android/key.properties`, equally public, headed by an in-file comment — *public debug-grade CI key; never place a production secret in this file*) **together, in the same commit, with secret-scanner coverage for both** (the repo's `.gitleaks.toml` `[allowlist]` gains a `paths` regex covering `android/app/ci-release.jks` and `android/key.properties` — `.gitleaksignore` fingerprints are per-commit/line and churn whenever the files are edited, so a path regex is the durable mechanism — and the committed password value is allowlisted once through the repo's GitHub secret-scanning alert — order of operations: the *first* push is blocked until an admin follows the bypass link in the push-protection message to let it through, which creates the alert, then closed as *used in tests* to allowlist the value for every later push (push protection exempts by secret *value*, an admin action, not by path, so there is no path-scoped entry to add) — and thus the mandated push is not permanently blocked; never "fixed" by deleting, moving, or rotating the files, which would break identical fork/PR signing and in-place upgrades — extend the allowlists instead, the same discipline 08 §5 applies to the committed host keys), so fork and PR builds sign identically with no CI secret; every build signs with it (policy: **Android signing & checksums**, below the table) |
| M1 | First rehearsal tag `v0.1.0`; verify all release assets appear, the APK is signed with the committed key, checksums are in the notes **and one downloaded asset's recomputed SHA-256 matches them**, `SHA256SUMS.asc` is attached and verifies against the maintainer key (§4 — signing starts at this first tag, not v1.0.0), and the release is marked **pre-release** — not promoted to "Latest" — proving the `prerelease` expression `release.yml` must carry (leading-`0.` plus §3.12's hyphen clause) actually holds. The APK is a **rehearsal artifact of the desktop codebase**: Android is not a supported v1 target — all Android-specific work and verification (D29, §5) stays post-v1 — **every release's notes label it as such from `v0.1.0` on** (not only the M10 INSTALL.md), since pre-release tags already publish a downloadable APK that upgrades an existing install in place |
| M1+ | Keep `ci.yml` and `release.yml` build matrices in lockstep (AGENTS.md §2) |
| M2 | macOS entitlements minimal and unsandboxed for v1 (D23); legacy login keychain option set (AGENTS.md §4 gotcha) |
| M2 (before the first tag whose build embeds Séance code — `v0.2.0`) | D30's fail-closed license gate lands in `release.yml`: after dependency resolution, resolve every Séance git pin from **every** `pubspec.lock`, fail on any declared-but-unresolved pin, and verify each pinned tree carries a license file matching the canonical SPDX text of D30's allowlist — anchored on the grep-able marker comment, with the PR-level CI backstop watching the marker bidirectionally. Full spec: 00 D30 |
| M4 | Prevent-close queue flush verified in packaged builds, not just `flutter run` |
| M9 | Link-only update banner (D19) points at the GitHub releases page |
| M10 | `docs/INSTALL.md` first-launch steps per platform: macOS ad-hoc build — right-click → Open, or `xattr -dr com.apple.quarantine Poltergeist.app`; Windows — SmartScreen "More info → Run anyway"; Linux — AppImage `chmod +x`, `.deb` install line, libsecret runtime dependency note |
| M10 | Fresh-machine install test on all three desktops using only INSTALL.md |
| from `v0.1.0`, every `v*` tag | `release.yml` writes SHA-256 checksums for all published assets into that release's notes (policy: **Android signing & checksums**, below the table) |
| M10 | INSTALL.md explains checksum verification: download artifacts **only from this repo's Releases page** and fetch checksums **only from the release notes** (policy: **Android signing & checksums**, below the table) |

**Android signing & checksums** (the policy the three rows above
schedule). The keystore is Séance's `ci-release.jks` pattern exactly:
a committed, deliberately public, debug-grade keystore (personal tool,
no Play Store — D23). No CI secret, no fallback path, no build-time
generation: every build — fork, PR, or `v*` tag — signs with the same
stable committed key, so each release's APK upgrades the installed app
in place and a missing-secret misconfiguration cannot exist. In-place
upgrade also requires a strictly increasing Android `versionCode`,
derived monotonically from `release.sh`'s version argument
(`v1.0.0` > … > `v0.2.0` > `v0.1.0`), with any pre-release suffix mapped
**below** its final — e.g. `major*1_000_000 + minor*10_000 + patch*100 +
pre`, `pre` = 99 for a final, 50–98 for `-rcN`, and 1–49 for `-betaN` (so
`v1.1.0-beta1` (1_010_001) < `v1.1.0-rc1` (1_010_050) < `v1.1.0`
(1_010_099) < `v1.1.1-beta1` (1_010_101)), with `N` above the family's
range rejected by `release.sh` as a tagging error rather than silently
wrapping past the final's 99; if the tag grammar
instead forbids suffixes (§3.12's alternative), a suffixed tag must never
ship an APK — pick one rule in writing before the first v1 RC. From
`v0.2.0` on, each rehearsal
installs the new APK over the previous pre-release to prove the upgrade
path, because a flat or mis-derived `versionCode` keeps every
signature/checksum rehearsal green while a real sideloaded APK refuses
to update. The flip
side, documented in INSTALL.md at M10: the key can never rotate without
breaking in-place upgrades — if it is ever replaced, existing installs
must uninstall and reinstall (Android rejects the signature change),
and that release's notes must say so. Because the key is public, a
matching Android signature proves nothing about origin — any fork can
build a correctly-signed APK that upgrades an install in place, which
is why the checksum channel must exist from the first tag that ships an
APK and for as long as the artifacts do, and why INSTALL.md tells users
to download only from this repo's Releases page, verify against the
notes, and treat any "update available" prompt as fake by definition — the
app never prompts for or auto-installs updates (D19), and a correctly-signed
APK offered anywhere other than Releases still installs cleanly over an
existing install precisely because the key is public. The release tag is
signed (`git tag -s`, the maintainer's local
key — never a CI secret); the signature attests the **source commit**,
not the CI-built artifacts. Absent reproducible builds, the
release-notes checksums are an **integrity** channel, not an origin
one — CI computes them alongside the artifacts it builds, so they
catch corrupted downloads and foreign mirrors but can never attest a
compromised pipeline; origin rests on the signed tag plus this repo's
CI being the thing that built from it — and INSTALL.md must not
overstate what either the tag signature or the checksums prove. From
`v0.1.0` on — an unsigned checksum alone only catches accidental
corruption, not a swapped binary, and signing costs nothing paid
certificates would, so there is no reason to wait for v1.0.0 — close the
loop on every tag: after CI publishes, the maintainer downloads
the assets, recomputes each SHA-256 against the notes, and attaches a
**detached signature over the checksum list** (`SHA256SUMS.asc`, signed
with the same local key that signs the tags) to the release — one
origin-bound checksum source that neither a CI compromise nor a
release-note edit can silently replace.

Explicitly not in this track for v1 (each would amend D23): paid
Developer ID signing + notarization, Windows code signing/MSIX, Flatpak,
Sparkle-style auto-update, app stores. The architecture stays
sandbox-ready (`ScopedPathAccess`, sidebar bookmarks double as future
grants) so none of these are foreclosed.

## 5. The mobile constraints memo (D29)

Mobile is post-v1, but v1 must never foreclose it. What iOS/Android will
demand, recorded now:

- **iOS kills background transfers.** A suspended app loses its sockets
  within seconds-to-minutes; `NSURLSession` background sessions are
  HTTP-only, so SFTP cannot ride them — this is what hurt Transmit iOS.
  Consequence for v1: every transfer must be interruptible and cheap to
  resume from the journal (M4's design); real byte-level resume needs the
  ranged read/write seam (D25/PR-S3's ranged read is the start). Whether
  dartssh2 sockets survive brief backgrounding is unverified — that spike
  belongs to the future mobile milestone, not v1.
- **Files.app / FileProvider** run file access out-of-process, possibly
  with no UI at all. The property to preserve: `poltergeist_core` and the
  engine protocol have no Flutter dependency and no assumption that a
  window exists (03 §1, §5).
- **Android scoped storage / SAF**: user folders are tree URIs, not
  paths. All local access already flows through `ScopedPathAccess` —
  grants, not raw paths, are the unit (03 §7.2). Séance precedents exist
  (SAF export channel, `BackgroundKeepAlive` foreground service).
- **Pane collapse**: phones show one pane with a switcher. Two-pane
  assumptions may live only in `WorkspaceController` layout code (D1),
  never in controllers, the queue, or `poltergeist_core`.

Per-milestone invariant check (item 5 of §3.12):

| Milestone | Invariant to re-verify at close |
|---|---|
| M1–M2 | `poltergeist_core` stays pure Dart; engine protocol messages are plain data |
| M3 | Layout collapses to one pane without touching controllers; local access only via `ScopedPathAccess` |
| M4 | Queue is suspendable: pause-all + journal restart is a working suspend primitive; no task assumes a long-lived socket |
| M5 | Device-local bookmark fields model per-device grants (sandbox blobs today, SAF tree URIs tomorrow) |
| M6 | Sync enrollment and the record store add no pane, watcher, or window coupling; every earlier row still holds |
| M7 | Checkouts live under `path_provider` dirs; reconcile-on-resume works without watchers |
| M8 | Scans are cancellable and runs resume from the journal; no watcher dependency |
| M9 | Polish surfaces (palette, ssh_config import, chrome) add no pane, watcher, or window coupling; every earlier row still holds |
| M10 | This memo re-read against the shipped code; deviations recorded in STATUS.md |

## 6. Risk register

| # | Risk | Mitigation | Pre-authorized fallback / cut line |
|---|---|---|---|
| 1 | dartssh2 throughput or algorithm ceiling (D9) | M0 measures before any design hardens | The D9 ladder: upstream fix → channels/transports compensate → document the ceiling (00 edit) → libssh FFI last resort (00 edit) |
| 2 | dartssh2 single-channel pipelining unsafe | M0 verifies with byte-compares | Compensate with N channels/transports; relax the scan budget with a 00 edit if even that fails |
| 3 | Isolate model blocker (sockets, latency) | M0 PoC with explicit pass conditions (03 §5) | Connections on UI isolate, transfers/hashing in engine isolate — a 00 edit, never quiet drift |
| 4 | Séance upstream PR stalls (S1–S3) | Same owner, sibling repos; file early per 04 §5 | Pin to the PR branch rev; S1 sealing shim (04 §5.6); Design B ships without S1; never fork `seance_core` |
| 5 | Plugin staleness (the ecosystem meta-risk) | Minimal plugin surface; exact-version pins with automated update PRs (Dependabot/Renovate) as a standing §3.12 chore so security/bug fixes don't freeze; first-party packages preferred; `super_*` family avoided in v1 | Replace a broken plugin with a small in-repo channel (Séance's proven pattern); Layer-1 Dart icon map if native icon work slips |
| 6 | Flutter desktop a11y (Linux broken upstream) and Windows IME (IMM32) | Test and document per D20; semantics built per-surface, never retrofit | Honest known-issues section; not release blockers; track upstream issues by number |
| 7 | Impeller-on-desktop regressions (new in 3.47) | Test both renderers while the Skia opt-out exists; bench on older GPUs | `--no-enable-impeller` covers dev/CI/bench only — a shipped build can't read a `flutter run` flag — so a user-facing regression needs a build-time renderer opt-out (Info.plist/manifest), decided if one appears while upstream keeps the opt-out; if upstream removes the opt-out first, an unresolved user-facing regression is a release blocker resolved by a 00 edit (pin/bisect/upstream fix), never a silent ship |
| 8 | Scope creep | D25 parking lot; this chapter's fixed order; 09's review guardrails | Pre-authorized cuts, each a one-line edit to 00/02 in the cutting PR: native icon/thumbnail layer → Dart icon map; Quick Look → open-with-default; preview pane → text+images only; Sync Browsing → v1.x; local fast-path → streamed copy only |
| 9 | Polish squeezed at the end | Budgets and a11y gate from the milestone that introduces each surface | M9 is defined as an audit; if it finds rescue work, the schedule slips, the bar does not |
| 10 | Trash plugin blocked on one platform | Three small native surfaces, built early in M4 | Confirm-then-permanent on that platform only, recorded in README and STATUS |

## Definition of done

- [ ] Milestones M0–M10 executed in order, each closed with its exit
      criteria ticked, STATUS.md updated, and the §3.12 chores run.
- [ ] M0's report exists at `docs/M0-DARTSSH2-REPORT.md` and the pool +
      scan designs reference its numbers.
- [ ] Every Séance gate honored: M2 waited for PR-S2, Design A for the
      PR-S1 release, M8's remote work for PR-S3 — verified by pin history.
- [ ] The distribution checklist (§4) fully ticked at M10, including
      fresh-machine installs from INSTALL.md alone — which carries the
      macOS Gatekeeper and Windows SmartScreen first-launch bypass steps
      (§4 M10), since signing and notarization are deferred (out of scope
      below): a default OS blocks an unsigned download without them — and
      §4 already publishes SHA-256 checksums beside every asset from
      `v0.1.0`, linked from INSTALL.md next to the bypass steps, so the
      download is verifiable before the OS gate is bypassed — with the
      limit stated: same-release checksums detect corruption, not a
      compromised release, so `SHA256SUMS.asc` from `v0.1.0` on (a
      detached maintainer-key signature over the checksum list, §4) is the
      origin-independent channel that a release-asset swap cannot forge —
      provided the maintainer key's fingerprint is published via at least
      one channel independent of this repo and its release site (e.g.,
      keyservers plus a fingerprint in the app's About box), and INSTALL.md
      tells users to verify the fingerprint, not just fetch the key from
      the same download page.
- [ ] Mobile invariants (07 §5) checked at every milestone close; no v1
      code forecloses single-pane, scoped-access, or suspendable-queue
      mobile.
- [ ] Pre-1.0 milestone tags `v0.<n>.0` exist for M1 through M9 — never a
      `v0.10.0`; M10 ships `v1.0.0` per §3.12, with every tag cut by the
      release pipeline itself (so the pipeline is exercised at every tagged
      milestone M1–M10, not first at v1.0.0 — M0 has no tag). Inter-milestone
      hotfixes may append patch tags (`v0.<n>.<patch>`) without advancing the
      minor, each cut from the `v0.<n>.0` tag's commit (or a hotfix branch off
      it), never from a `main` carrying in-flight milestone work.
- [ ] No fast-follow or D25 item was built before v1.0 — except the M4
      drag-out produce-on-demand hook (03 §4.7 / D14), the one
      pre-authorized seam, which ships inside v1 by design.

## Explicitly out of scope

| Deferred item | Where it lives |
|---|---|
| Agent auth + ProxyJump implementation | First v1.x fast-follow (§3.13, D10); PR-S4 spec in 04 §5.5 |
| OS drag-out (promised files) | v1.x (§3.13, D14); hook ships in M4 |
| Archives: local zip, then remote/browsable | v1.x then later (§3.13, D27) |
| FileZilla / WinSCP / Cyberduck importers | v1.x (§3.13, D22) |
| Deep links between the apps | v1.x (04 §7.1) |
| Signing, notarization, stores, Flatpak, auto-update | Post-v1, each requires amending D23/D19 (§4) |
| iOS/Android apps | Post-v1 (D29); constraints memo §5 keeps the door open |
| Two-way sync + baseline DB | v2+ (D25) |
| Byte-level transfer resume beyond journal restart | v2+ (D25) |
| rsync accelerator | v2+ (D25) |
| S3/WebDAV backends | v2+ (D25) |
| Multi-window | v2+ (D25) |
| Scheduled sync | v2+ (D25) |
| Custom tools | v2+ (D25) |
| Remote content search | v2+ (D25) |
