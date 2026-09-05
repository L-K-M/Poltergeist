# 08 — Test strategy

This chapter defines how Poltergeist is tested: the layers, the fixtures
ported from Séance, the sshd-in-Docker integration matrix, the D12
performance benchmarks, and the accessibility checks. It elaborates the
decision log in [00-OVERVIEW.md](00-OVERVIEW.md) — D12 (budgets), D16
(honest transfer state), D18 (inherited security model), D20 (a11y), D21
(keyboard completeness) — and gives 02/03/05/06 the harnesses they refer
to. Séance paths cite the sibling repo, whose test suite is the reference
the same way its code is.

## 1. Principles

These are Séance's proven testing principles, adopted wholesale:

1. **Seams make tests possible.** Every service takes its collaborators
   through the constructor or a callback — Séance's
   `RemoteFilesController(openRemoteFileSystem, …, saveBookmarks: …)` and
   `BuiltInTextEditorScreen(initialText:, saveDocument:, onUpload:)` are
   the models. In Poltergeist the same rule shows up as: controllers reach
   filesystems only through `EngineClient` (03 §5), which is an abstract
   interface with an in-process test implementation (§3.1);
   `openAuthenticatedClient` has an injectable socket-connect seam
   (03 §3.1); stores persist behind callbacks. A class that cannot be
   constructed in a test without a network or a widget tree is a review
   defect.
2. **Pure logic lives in Flutter-free files and is tested without pumping
   widgets.** Séance tests `allocateAdaptivePaneWidths`, `groupServers`,
   and `filterServers` as plain functions; Poltergeist does the same for
   splitter allocation math, sort comparators, the fuzzy-match ranker,
   ignore-rule matching, the diff engine, reason strings, and the rsync
   exporter. Widget tests then cover only what genuinely needs a tree.
3. **Every safety property is pinned by a test.** The research notes'
   "do NOT re-implement differently" list (download double-stat, upload
   CAS + second preflight, quarantine-never-sweep, backup-rename replace,
   path validation at trust boundaries) plus this plan's own rails
   (mirror never deletes outside the destination, deletions only after a
   clean copy phase, TOFU changed-key hard block, restored queues start
   paused) each map to a named test. A safety behavior without a test is
   treated as absent.
4. **Analyze clean, always.** `dart analyze packages/poltergeist_core &&
   dart analyze packages/poltergeist_sync` — separate calls give per-package
   results; combined explicit roots also work — and
   `flutter analyze` in the app are
   zero-warning gates in CI and before every commit — with explicit paths,
   never bare at the repo root (AGENTS.md §4).
5. **String and structure goldens, not pixel goldens.** Golden tests
   assert exact strings (rsync commands, header sentences, toast copy,
   error messages) and semantics structures. Image goldens are banned in
   v1 — font rasterization differs per platform and turns CI red for
   nothing.
6. **Determinism.** Property tests use seeded generators and print the
   seed on failure; time-dependent logic (debounce, backoff, token
   bucket, keepalive) is tested with `package:fake_async` and
   `package:clock`, never real sleeps.

## 2. Test assets ported from Séance

Ported test files travel **in the same PR** as the code they cover, with a
PORTS.md entry each (03 §8.2). Temp-file suffixes and channel names in
assertions are renamed `.seance-*` → `.poltergeist-*` at port time; no
other divergence without a ledger entry.

| Asset | Séance source | Lands in Poltergeist as |
|---|---|---|
| `_FakeRemoteFileSystem` — a full in-memory `RemoteFileSystem` (the single most valuable fixture) | `app/seance_app/test/remote_files_controller_test.dart` | promoted to a **public** `InMemoryFileSystem` in `packages/poltergeist_core/lib/testing.dart` (§3.1), extended with fault injection per 05 §11 |
| `_FakeSftpClient` pattern — dartssh2 `SftpClient` faked via `noSuchMethod` | `packages/seance_core/test/remote_file_system_test.dart` | pattern reused in `poltergeist_core`'s connection-module tests (pool and lease logic without sockets, §3.2) |
| Adapter + path-helper tests (`remoteJoin`/`remoteBasename`/`remoteParent`, download/upload protocols, target-first symlink ordering) | `packages/seance_core/test/remote_file_system_test.dart` | **stay upstream** — `seance_core` is a git pin (D2), its tests run in the Séance repo; Poltergeist covers the interface via the contract suite (§3.1) instead of duplicating |
| Store lifecycle tests (9 tests: atomic index, corrupt-quarantine-never-sweep, path validation, rollback on flush failure) | `app/seance_app/test/managed_remote_file_store_test.dart` | ported with `ManagedRemoteFileStore` (06 §3) |
| Atomic-file tests | `app/seance_app/test/atomic_file_test.dart` | ported with `atomic_file.dart` |
| Editor I/O + widget tests (BOM/CRLF byte-for-byte round trip, conflict save leaves the external change intact, mid-save-edit race via two `Completer`s, find-bar walk `3/3 → case toggle → 2/2`, both chord variants) | `app/seance_app/test/built_in_text_editor_test.dart` | ported with the editor (06 §2.5) |
| Syntax engine tests | `app/seance_app/test/editor_syntax_test.dart` | ported; extended with the 06 §7 language additions (smoke + detection per language) |
| Allocation-math + shell layout tests (pure math first; keyed widget tests with `tester.view.physicalSize` + `addTearDown(tester.view.reset)`; boundary values; same-frame double drag; sibling preference after regrow) | `app/seance_app/test/adaptive_shell_test.dart` | math tests ported; layout widget tests rewritten for Poltergeist's splitter set (02 §1) in the same style |
| Toast tests (stacking geometry, single-fire action during fade, auto-dismiss timing) | `app/seance_app/test/top_toast_test.dart` | ported verbatim |
| External-editor + export tests (registry validation, launch never via shell, staged export) | `app/seance_app/test/external_editor_test.dart`, `file_export_service_test.dart` | ported with the services (06 §4) |
| Controller behavior tests (12 tests: navigation generation, transfers registry, recursive up/down safety, rename migrates checkouts) | `app/seance_app/test/remote_files_controller_test.dart` | **mined, not copied** — the controller is forked into `PaneController` + `CheckoutManager` (03 §6), so each Séance test is re-homed to the class that now owns the behavior |

## 3. Unit layer

Run with `dart test packages/poltergeist_core packages/poltergeist_sync`
(explicit paths, always) and `flutter test` in `app/poltergeist_app` for
Flutter-free logic that lives app-side.

### 3.1 poltergeist_core — VFS and fixtures

**`lib/testing.dart`** is a public barrel (separate from the main barrel)
exporting the test support other packages and the app import by path:

```dart
// packages/poltergeist_core/lib/testing.dart
export 'src/testing/in_memory_file_system.dart';   // InMemoryFileSystem +
                                                   // InMemoryEntry (they
                                                   // co-locate: snapshot()
                                                   // returns the entry type,
                                                   // so it must be public
                                                   // and exported too)
export 'src/testing/fault_plan.dart';              // fault injection
export 'src/testing/in_process_engine_client.dart';// EngineClient over any fs
```

```dart
/// The promoted _FakeRemoteFileSystem: a complete in-memory
/// RemoteFileSystem with directories, files, symlinks, modes, and
/// whole-second mtimes (SFTP v3 fidelity).
class InMemoryFileSystem implements RemoteFileSystem {
  InMemoryFileSystem({FaultPlan? faults, bool caseSensitive = true});
  // caseSensitive: false models default Windows volumes and macOS
  // APFS/HFS+, so caps-keyed behavior is testable on every host
  // Out-of-band mutation for precondition tests:
  void putFile(String path, List<int> bytes, {int? mtimeSecs, int? mode}); // copies bytes
  void deleteEntry(String path);
  Map<String, InMemoryEntry> snapshot();          // for convergence asserts
}

/// Fault injection per 05 §11. Immutable per test: the constructor
/// defensively copies set arguments via `Set.unmodifiable` (which returns
/// an unmodifiable copy, not a view of the caller's set), so
/// one test's faults can never leak into another. Deliberately not
/// const — `onOperation` closures capture mutable state by design, and
/// a const constructor cannot copy its arguments.
class FaultPlan {
  FaultPlan({
    Set<String> unlistableDirectories = const {},
    this.ignoreSetTimes = false,
    this.failSetTimes = false,
    Set<String> failRenameTargets = const {},
    this.onOperation,
  })  : unlistableDirectories = Set.unmodifiable(unlistableDirectories),
        failRenameTargets = Set.unmodifiable(failRenameTargets);
  final Set<String> unlistableDirectories; // listDirectory -> permissionDenied
  final bool ignoreSetTimes;               // setstat silently clamped
  final bool failSetTimes;                 // setstat -> permissionDenied
  final Set<String> failRenameTargets;     // EXDEV-style rename failure
  final void Function(String op, String path)? onOperation;
                      // observe/mutate mid-run — and it MAY THROW: the
                      // fake funnels the throw into a RemoteFileException
                      // (§3.1's error shape holds for injected failures
                      // too), which is what makes retry counting, .part
                      // cleanup, and executor-idempotence paths injectable
}
```

**The shared contract suite** —
`packages/poltergeist_core/test/support/remote_file_system_contract.dart`
defines one function:

```dart
void runRemoteFileSystemContract(
  String name,
  Future<FsHarness> Function() createHarness,
);

abstract class FsHarness {
  RemoteFileSystem get fs;
  String get root;                         // absolute working directory
  FsCapabilities get caps;                 // supportsMode, supportsSymlinks,
                                           // supportsOwner, caseSensitive
  Future<void> mutateOutOfBand(String path, List<int> bytes);
  Future<void> dispose();
}
```

It runs against **both** bundled implementations — `LocalFileSystem` on a
temp directory and `InMemoryFileSystem` registered **twice, in both case
modes** (`caseSensitive: true` and `false`, so the caps-keyed cases run on
every host, not only the macOS/Windows §8 legs) — always, and against a
third, SFTP-backed harness (`DartSshRemoteFileSystem` over the §5
sshd-in-Docker fixture, `mutateOutOfBand` applied through a second channel)
whenever Docker is present. Local runs without Docker print a loud
"SKIPPED (no Docker): SFTP contract" banner and pass; CI sets
`POLTERGEIST_REQUIRE_DOCKER=1`, under which a missing Docker daemon or zero
reported SFTP-contract tests fails the suite — so the fake is held to the
real SFTP v3 semantics the
queue and sync tests rely on — not only the local filesystem's (the
adapter's own unit tests stay upstream in `seance_core`, §2; this runs
Poltergeist's contract against the real adapter). Cases, at minimum:

- `listDirectory` filters `.`/`..`; entries carry name/size/mtime/mode.
- `stat` follows links by default; `followLinks: false` reports the link.
- `setMode` refuses symlinks (`unsupported`); skipped when
  `caps.supportsMode` is false (Windows local).
- `rename` preflight: existing destination without `overwrite` ⇒
  `conflict` before any change; case-only rename succeeds on
  case-insensitive filesystems (two-step, 03 §2.2).
- `delete` of a non-empty directory fails with Séance's wording
  (`Only an empty directory can be deleted.`); recursion is app-level.
- Download integrity: `mutateOutOfBand` between stat and read ⇒
  `conflict` — the fake interposes via `FaultPlan.onOperation`; the
  local harness (which has no mid-operation seam) fronts
  `LocalFileSystem` with a decorating `RemoteFileSystem` that applies
  the pending out-of-band mutation on the first read chunk, so the case
  is deterministic on both, never racy (Principle 6); short read ⇒
  `conflict`; returned entry carries the
  `contentSha256` of exactly the streamed bytes.
- Upload: exclusive sibling temp, declared-length mismatch error,
  `expectedTarget` CAS ⇒ `conflict` when the target changed, temp cleaned
  up on every failure path, `preserveMode` honored where supported.
- Cancellation: sticky, effective mid-stream, maps to `cancelled`.
- Error funnel: every failure is a `RemoteFileException` with message
  shaped `Could not <op> "<path>": <detail>`.
- `setTimes`/`setOwner`: local implements both from day one (03 §2.4);
  `setOwner` is skipped when `caps.supportsOwner` is false (Windows local
  has no chown, exactly like `setMode` above), while `setTimes` runs on
  every platform (Windows supports it); the in-memory fake honors
  `FaultPlan.ignoreSetTimes`/`failSetTimes`.

Windows- and macOS-specific expectations are keyed off `caps` and run for
real on the CI OS matrix (§8). The four public safety helpers in
`local_fs_safety.dart` keep their ported Séance tests (03 §2.3):
`replaceLocalFile` backup-rename dance incl. restore-on-failure,
`ensureSafeLocalDirectory` symlink refusal at every component,
`validateLocalName` (reserved names, trailing dot/space),
`validatePathComponent`.

**`InProcessEngineClient`** implements the same `EngineClient` interface
as the isolate-backed client but fronts injected filesystems directly on
the caller's isolate — controllers and widget tests use it; a separate
protocol test (§3.2) proves the real isolate path — and the
controller-level suites are parameterized over both `EngineClient`
implementations so behavioral drift (a dropped event, an unforwarded
request, a cancellation that never crosses the port) fails CI.

### 3.2 poltergeist_core — queue, pool, bookmarks, protocol

**Queue state machine** (`test/transfer/`), all over `InMemoryFileSystem`
pairs and `fake_async`:

- Legal `TransferTaskState` transitions only (03 §4.1); an illegal
  transition throws in debug builds and the test asserts it.
- Scan-then-execute: parents-first directory order, symlinks skipped and
  counted, `totalBytes` set only after scan, per-name validation at trust
  boundaries, plan-internal case-collision detection keyed to the
  destination's reported case sensitivity (`FsCapabilities.caseSensitive`,
  §3.1) — Windows local volumes **and** default macOS APFS/HFS+ are
  case-insensitive, so a Windows-only check misses real collisions — and
  the default assumed for SFTP destinations (SFTP v3 offers no
  case-sensitivity query) is pinned to its fail-safe value (assume
  case-insensitive, so `foo`/`FOO` are treated as a collision) by a named
  test, per Principle 3.
- Conflict policy matrix: replace / replace-if-newer / keep-both / skip,
  `merge` (folders), per-direction defaults — one parameterized test per
  cell asserting bytes moved (or not) and final names (`keepBoth` suffix).
- Pause semantics (03 §4.4): queue pause stops dispatch but in-flight
  files finish; per-task pause cancels the in-flight file, cleans its
  `.part`, marks `paused`; resume re-dispatches exactly the remaining
  plan items.
- Cancel is sticky and cleans temps; retry increments `retryCount` and the
  task fails permanently after `taskRetryLimit`.
- Journal replay (03 §4.6): kill-and-replay mid-task restores the queue
  **paused** with remaining items; a corrupt trailing JSONL line is
  dropped; compaction moves finished tasks to history; history caps at
  10 000 records; a crash injected mid-compaction leaves the previous
  journal intact and replayable (temp file + atomic rename).
- `BandwidthLimiter`: with a fake clock — no burst ever grants more
  than one second of tokens, N > L bytes at limit L take
  ≥ (N − L)/L seconds (a full initial bucket makes ≥ N/L unattainable
  by the intended bursting implementation), and throughput in any
  window of W seconds averages ≤ L·(1 + 1/W) bytes/s — 1.5·L at
  W = 2 s, converging to L as W grows (a flat "≤ L over any window"
  is unattainable by the same arithmetic: a full bucket at window
  start admits L + W·L bytes); plus the §4.3 hang guards — an
  `acquire` larger than bucket capacity drains in capacity-sized
  grants, a zero limit is rejected at the settings boundary, and a limit
  change mid-transfer clamps the bucket to the new capacity — subsequent
  grants respect the new L with no fresh burst, and pending acquires
  observe the change.
- Remote→remote piping over two fakes: bytes counted once, both leases
  released on success and on either side's failure, failing side named in
  the error message.
- `TransferProducer.produceLocalCopy` returns a priority download and is
  exercised by the preview-pane tests (06) so the D14 hook never rots.

**Pool growth rules** (`test/connection/`), with a fake
`openAuthenticatedClient` injected through the 03 §3.1 seam (recording
prompts, auth method, and connect count) and fake clocks:

- First connect serialized: two concurrent `openBrowseChannel` calls
  produce exactly one connect and one TOFU prompt (D5, D18).
- Interactive auth (keyboard-interactive or prompted password) caps the
  pool at one transport — a transfer-lease burst opens more channels,
  never a second transport, and never a second prompt.
- Non-interactive auth grows to `maxTransports` reusing the resolved
  credentials; credentials are wiped on `disconnectServer`.
- A `changed` TOFU verdict hard-blocks the server and aborts growth; no
  code path auto-repins (D18) — asserted by attempting every operation.
- Extra transports close after `idleExtraTransportTimeout`; the first
  transport follows pane lifetime.
- Reconnect backoff sequence 1 s → 2 s → 4 s … capped at
  `reconnectBackoffCap` with jitter inside ±30 %; tasks flip to `queued`
  with a retry counter.

**Bookmark model and coordinator** (`test/bookmarks/`): round-trip of the
04 schema; `BookmarkCoordinator`'s skip-and-preserve suite (04 §3.2 —
unknown kinds and undecodable records are never applied, re-encoded,
re-pushed, or tombstoned); deletions write real tombstones so remote
copies never resurrect; Lww merge behavior matches `seance_protocol`'s
conflict rules; the store persists behind callbacks and never blocks on a
failed save (revert + surfaced error, Séance's keep-alive-toggle pattern).

**Engine protocol** (`test/engine/`): every `EngineRequest`/`EngineEvent`
round-trips through a real spawned isolate pair (proving the payload is
isolate-sendable and reconstructs intact — **not** closure-freedom,
since Dart copies closures with sendable captures across isolates;
function-typed fields in the protocol classes are banned by the §3.3
AST walker instead); progress coalescing emits
≤ 30 events/s per task under a flood, and the merged queue stream stays
frame-bounded with many tasks transferring concurrently; a serialized
`RemoteFileException` reconstructs kind + message intact.

The existing product-identity test (ASCII name invariant) stays.

### 3.3 poltergeist_sync — property tests over the fake VFS

All sync-engine tests (05's diff/plan/execute engine) run against
`InMemoryFileSystem` pairs; the seeded
generator builds random trees (depth ≤ 6, mixed files/dirs/symlinks,
names including NFD forms, case twins, and Windows-invalid names) and the
failure output prints the seed. Invariants (05 §11), each its own test:

- **No-delete modes never delete**: Update and Additive plans contain no
  `deleteLeft`/`deleteRight` items, for every generated tree pair.
- **Mirror converges**: plan + execute, then re-scan + re-diff ⇒ a plan
  whose every item is `skip`/`equal` ("Both sides match"), under all
  three comparison modes, including trees where mtimes differ by exactly
  the 2 s tolerance boundary (both sides of the boundary tested).
- **Mirror never touches anything outside the destination root**: every
  path the executor deletes or renames is under the destination root and
  appeared in the reviewed plan; the fake records every operation to
  prove no unplanned writes occur anywhere.
- **Precondition change flips to conflict**: `FaultPlan.onOperation`
  mutates the target between plan and execution; the item ends
  `conflict`/`changed since preview`, no bytes are written, and the run
  continues (05 §8 rail 7).
- **Scan errors exclude on both sides**: an unlistable directory on one
  side yields zero delete items for the twin subtree on the other side —
  the mirror-wipes-destination disaster test (05 §3).
- **Ordering contract**: mkdirs shallowest-first, deletes last and
  deepest-first; after any copy-phase failure every deletion is `skipped`
  with `Skipped: earlier errors in this run`.
- **Executor idempotence**: kill after item k (throw injected), re-run the
  remaining plan ⇒ same converged result, no duplicate trash entries.
- **Undo restores**: after a Mirror run with trash, `Restore Trashed
  Files…` (05 §8 rail 9) restores every trashed path byte-identically
  (journal-driven), including pre-run versions of updated files.
- **setstat fallback**: with `ignoreSetTimes` (and separately
  `failSetTimes`), the journal records `setstatIgnored: true`, pair state
  records `mtimeUnreliable`, and the next plan compares `sizeOnly` with
  the visible notice (05 §4).

Deterministic unit tests beside the properties: the gitignore matcher
(one table test per rule class: `*`, `?`, `**`, trailing `/`, leading
`/`, `!`, comments, the non-removable `.poltergeist*` defaults);
comparison edge cases (whole-second truncation, `acceptedTimeShifts`,
type mismatch ⇒ `typeDiffers`); name-hazard detection (NFC/NFD pairing
keeps the destination's byte form; collisions become conflict-class items,
never silent fixes).

**Golden-string tests**: `buildRsyncCommand` output for every row of the
05 §2.1 flag table plus the quoting rule (`'` → `'\''`) and the caveat/
override comment lines; the plan-header sentence for each copy pattern in
05 §7. **Static invariants as tests**: a test walks
`packages/poltergeist_sync/lib/**` sources via an analyzer AST walk and
fails on any whole-identifier occurrence of `Process` in a **code
position** — comments and string literals excluded, so
`processedPlan`/`onProcess` and reason strings that merely say "process"
pass — or any `dart:ffi`, Flutter, or `dartssh2` import (05 §2's
never-executes promise and 03 §1's dependency rules, machine-checked).
A sibling walker covers `packages/poltergeist_core/lib/src/engine/**`
and fails on any function-typed field declared in **any** class under
that subtree — not just the `EngineRequest`/`EngineEvent` pair, so a
newly added protocol class cannot quietly escape the §3.2 closure ban
(the walker also fails if any `EngineRequest`/`EngineEvent` subtype is
declared outside the walked subtree, so relocation cannot dodge it
either) —
save for a short, **commented allowlist** of engine-internal classes that
legitimately hold callbacks (the isolate runner's hooks, the client's
event handlers, test seams): those carry no cross-port payload, so
allowlisting them removes the false positive without reopening the escape
a marker-interface-only rule would leave — a new protocol class is never
on the allowlist, so it is still caught.
A blanket `dart:io` import ban would be wrong — `journal.dart`
legitimately writes JSONL files through an **injected base directory** (a
unique temp dir per test, a `path_provider` dir in production), so
replay/idempotence/undo tests stay hermetic and parallel-safe — but the
walker still fails on any `dart:io` import **outside a short, commented
per-file allowlist (`journal.dart` only)**, so no other file can quietly
gain raw filesystem access that bypasses the recording fake. Those journal
writes are the local journal's own, deliberately *outside* the
`RemoteFileSystem` VFS whose operations the
mirror-never-writes-outside-the-root fake records — the promise is about
never *executing* anything, and never writing outside the destination
root through the VFS, not about banning file I/O in the journal writer.

## 4. Widget layer

`flutter test` in `app/poltergeist_app`. Séance's widget-test patterns
are mandatory: inject every seam (no platform channels in tests — the
`initOverride`-style bootstrap seam is ported), drive keyboards with
**real key events** via `tester.sendKeyDownEvent`/`sendKeyUpEvent`,
test **both chord variants** (meta and control) where 02 §8.3 defines
both, set window sizes with `tester.view.physicalSize` +
`addTearDown(tester.view.reset)`, and switch platforms with
`debugDefaultTargetPlatformOverride` — always restored with
`addTearDown(() => debugDefaultTargetPlatformOverride = null)`, exactly
like the window-size reset, or the override leaks into every later test
in the process — for per-platform expectations
(macOS ⏎ renames; Windows Enter opens, F2 renames).

Coverage commitments per surface:

- **Panes** (`PaneController` + listing widgets over
  `InProcessEngineClient`): navigation generation counter drops stale
  listings; sort/filter/hidden toggles; selection pruning on view change;
  type-ahead buffer with its ~1 s reset; latency honesty (no spinner
  before 150 ms, cancellable navigation — advance the binding's clock
  with `tester.pump(const Duration(...))`; `package:fake_async` is for the
  controller-level unit tests, not `testWidgets`); both empty
  states (onboarding vs filtered-to-nothing, 02 §2.7); right-click
  selects the row under the cursor before the menu opens; drop overlay
  gated on `TickerMode` and route currency (the Séance
  `files_pane.dart:213` pattern); path bar segment navigation.
- **Conflict dialogs**: the 5-verb model (02 §5.2) — every button label
  is a verb, never "OK"; Replace-if-newer compares whole-second mtimes;
  Merge appears only for directories; per-direction defaults honored;
  Esc means Skip, not Replace.
- **Activity panel**: per-item rows with cancel/retry (a summary-only
  bar is a failing test, D16); reorder; queue pause; restored-queue
  banner shows paused with Resume; failures render in the panel (not
  only as a toast); History tab reads the compacted history; the
  per-row rebuild rule — driving 1 000 progress events repaints only the
  affected row (widget rebuild counters).
- **Palette** (02 §8.4): ranking is a pure Flutter-free function with
  table tests (subsequence + word-boundary bonus); widget tests: rows
  show shortcuts right-aligned, pressing a command's bound shortcut
  while the palette is open executes it, ⌘⏎ opens a favorite in the
  other pane, disabled commands are greyed with a reason.
- **Editor screens**: the ported Séance suite as listed in §2 —
  the toast wording matrix via injected `saveDocument`/`onUpload` fakes,
  upload-throws still runs `onSaved`, mid-save-edit race, find-bar walk
  with case-toggle caret resume, PopScope dirty guard — plus the 06
  additions (checkout size gate copy, conflict escalation dialog).
- **Sync plan view** (05 §7): header sentence for each pattern; glyph
  click cycles only actions valid for the item's sides; bulk conflict
  bar; the >50 % typed confirmation keeps Run disabled until the word
  `DELETE` matches; `maxDelete` refusal dialog; Run button copy states
  its consequence.
- **Layout**: allocation math as pure tests first (ported style), then
  keyed widget tests over the Poltergeist splitter set — two-stage
  collapse boundaries, ratio persistence, keyboard-resizable splitters.

## 5. Integration layer — sshd in Docker

Real-server tests are the only honest way to cover TOFU, auth
summarization, algorithm coverage (D9), and sync convergence over real
SFTP. The fixture lives in **`test/integration/`** at the repo root:

```
test/integration/
  docker-compose.yml        the whole matrix; every port mapping is
                            loopback-only (`127.0.0.1:220N:22` — a bare
                            `220N:22` binds 0.0.0.0 and would expose
                            weak-credential sshds on the LAN). Enforced
                            mechanically, not by prose: run.sh and CI
                            render `docker compose config` (interpolated,
                            resolved) with **every profile activated**
                            (`COMPOSE_PROFILES=$(docker compose config
                            --profiles | paste -sd,)`), because a plain
                            render omits profiled services (`sshd-keyswap`,
                            a future `sshd-netem`) entirely, and fail
                            unless every published host IP is 127.0.0.1
                            and no service uses
                            `network_mode: host` (which bypasses the
                            port check and binds every interface) — a
                            raw YAML grep would
                            pass quoted (`"2201:22"`), interpolated
                            (`${PORT}:22`), and long-form
                            (`host_ip: 0.0.0.0`) entries that still bind
                            0.0.0.0, and the check's own test feeds it
                            those three shapes **plus the bare unquoted
                            `2201:22` short form**, treats a resolved
                            entry with no `host_ip` key (how `docker
                            compose config` commonly renders an unpinned
                            short form) as **non-loopback**, and asserts
                            red on every one of them —
                            Principle 3 applies to the fixture's own
                            most dangerous property too
  sshd-modern/Dockerfile    alpine pinned by version + digest — current
                            OpenSSH (9.x/10.x), bumped deliberately (a
                            floating latest would drift the D9 algorithm
                            audit)
  sshd-legacy/Dockerfile    Debian bullseye pinned by digest — OpenSSH 8.4p1,
                            the pre-decided ≤ 8.x candidate; once built, the
                            image is pushed to the
                            project's GHCR and CI pulls that
                            digest-pinned frozen artifact, so archive
                            outages never
                            redden the legacy leg for reasons unrelated
                            to the code under test)
  keys/                     committed test-only HOST keys only (incl.
                            the keyswap second host key) — generated
                            once, never by run.sh, never used anywhere
                            but this loopback fixture: host keys need
                            cross-run stability for TOFU determinism,
                            but the USER keypair does not — run.sh
                            generates it fresh per run (ssh-keygen) and
                            writes the public half to a gitignored runtime
                            dir bind-mounted read-only into every service
                            (keyswap included); each entrypoint appends it
                            to the user's authorized_keys at container
                            start (into the chroot-relative home for
                            sshd-chroot), so services a suite starts
                            later get the same per-run key, shrinking the
                            committed
                            secret surface to the keys that actually
                            need committing; a README in the
                            dir marks every key fake/test-only, and the
                            repo carries secret-scanner allowlist
                            entries **scoped to the exact blobs/paths
                            under `test/integration/keys/`** (never a
                            pattern-level or repo-wide exemption, which
                            would also admit a future real private key
                            committed elsewhere), plus a scheduled scan
                            asserting no private-key detection exists
                            anywhere outside that dir (GitHub push
                            protection
                            flags committed SSH private keys and would
                            otherwise block the push — the path-scoped
                            allowlist covers the scheduled scanner, while
                            push protection itself is cleared once via the
                            per-push "used in tests" bypass when the keys
                            land (or an org exemption), and never "fixed"
                            by deleting the keys, which
                            would break TOFU determinism); sshd
                            entrypoints chmod 0600 the mounted host
                            keys, because git stores only the
                            executable bit and OpenSSH refuses
                            group-readable host keys
  run.sh                    compose up -d, then wait for readiness —
                            a real SSH banner exchange against literal
                            `127.0.0.1:220N` per service (never
                            `localhost`, which can resolve to `::1`
                            while the publish is IPv4-only; and never a
                            bare TCP connect — Docker's userland proxy
                            accepts host-side TCP before sshd listens),
                            or per-service compose
                            healthchecks (`up` returns on container
                            start, not sshd listening: skipping the
                            wait is the classic first-test
                            connection-refused flake) — then dart test
                            --concurrency=1 -t integration with the
                            explicit package paths (prose below) →
                            compose down via
                            `trap … EXIT` (test exit code propagated)
```

Compose services (config variants run on the modern image):

| Service | Port | Purpose |
|---|---|---|
| `sshd-modern` | 2201 | baseline: key auth, full SFTP |
| `sshd-legacy` | 2202 | old algorithm defaults — D9 coverage audit |
| `sshd-chroot` | 2203 | `ForceCommand internal-sftp` + `ChrootDirectory` — the sftp-only world rsync cannot reach (D6) |
| `sshd-restricted` | 2204 | `Subsystem sftp /usr/lib/ssh/sftp-server -P setstat,fsetstat` (the Alpine path, matching `sshd-modern`'s pinned base — a Debian/Ubuntu base would need `/usr/lib/openssh/sftp-server`, so the path follows whatever image the compose spec pins) — forces the 05 §4 mtime-unreliable fallback (the executor must treat a failed setstat the same as a silently clamped one) |
| `sshd-authmatrix` | 2205 | password + keyboard-interactive users, `PermitRootLogin prohibit-password`, plus a user whose authorized_keys rejects the offered key — feeds the failure-summarizer tests |
| `sshd-keyswap` | 2201 (swapped in) | identical config to `sshd-modern`, different host key (a second pre-generated host key in `keys/`) — the changed-key fixture. The TOFU suite's runner stops `sshd-modern` and starts this service on the **same host port**, so the client re-contacts an unchanged host:port and sees a changed key (a different port would read as a new, unpinned server and merely prompt); the two services are never up at once. To make that structural, the service is declared under `profiles: [keyswap]` in the compose file — a bare `compose up` therefore never starts it (both services mapping host port 2201 would otherwise race to bind at startup and fail the stack); the TOFU runner starts it by name (`docker compose up -d sshd-keyswap`, which activates a profiled service explicitly targeted on the command line) after stopping `sshd-modern` |

The Dart tests live inside the packages (explicit-path rule):
`packages/poltergeist_core/test/integration/` and
`packages/poltergeist_sync/test/integration/`, each file tagged
`@Tags(['integration'])` and self-skipping with an explanatory message
unless **both** the umbrella host var (`POLTERGEIST_SSHD`) **and** its
own service port var (`POLTERGEIST_SSHD_MODERN`, `…_LEGACY`,
`…_AUTHMATRIX`, …) are set — keying on either alone lets a
partially-exported local environment enable a suite whose counterpart
var is absent and turn a named skip into a confusing connection error —
so plain
`dart test packages/…` stays green without Docker. `run.sh` starts the
compose stack, exports `POLTERGEIST_SSHD=127.0.0.1` plus one variable
per service (`POLTERGEIST_SSHD_MODERN=2201`, `…_LEGACY=2202`, and so on)
so tests never hardcode the port map, and runs
`dart test --concurrency=1 -t integration packages/poltergeist_core
packages/poltergeist_sync` (a multi-package invocation from the repo
root, which works because the root **is** a pub workspace whose shared
package config covers both members — AGENTS.md's layout; under any
per-package resolution instead, run.sh would loop the same command
inside each package in turn, preserving the serialization) —
serialized on purpose: the pool suite
docker-stops a shared service and the keyswap fixture swaps
`sshd-modern` out entirely, so concurrent suites would flake each other.
Every suite that stops or swaps a service **restores the original stack
in `tearDownAll`** — the keyswap suite in particular must stop
`sshd-keyswap` **before** starting `sshd-modern` — and then **wait
until host port 2201 is actually free** (poll the bind, or retry the
`up` on bind failure), and — after **every** in-suite `up`/`start` (the
keyswap `up`, `tearDownAll`'s `sshd-modern` restart, the pool suite's
`start`) — **repeat run.sh's banner-exchange readiness wait for that
service before the suite connects** (a shared helper keyed on the compose
service name, resolving that service's published host port via
`docker compose port <service> 22` — `sshd-keyswap` publishes no env var
of its own, it deliberately reuses host port 2201): waiting for the port
to be *free* is
not waiting for sshd to be *listening*, and Docker's userland proxy
publishes the host port as the container starts, so the very next
connect can be refused — the same first-connection flake run.sh's wait
closes, reopened at each in-suite restart. `docker stop` returning does not guarantee the
publish teardown has finished, and both publish host
port 2201, so starting `sshd-modern` while the port is still bound
makes the new container fail to bind and exit, leaving host port 2201
**unserved** — later suites then meet connection-refused. Skipping the
**stop** instead leaves `sshd-keyswap` itself serving, and every later
suite dialing `…_MODERN` meets the changed host key and hard-blocks
(D18). Both are deterministic order-dependent reds that masquerade as
flake; only the second carries the changed-key signature — so the
prescription is stop keyswap first, then wait for 2201 free. Teardown of the whole stack still runs from a
`trap … EXIT` so an interrupted run never leaks the
stack (the test exit code is preserved through the trap) — and the
trap tears down **with the profile enabled**: `docker compose
--profile keyswap down`, because a plain `down` ignores services whose
profiles are inactive in that invocation, so an interrupt during the
keyswap suite (after its `up`, before `tearDownAll`) would leak the
keyswap container still holding port 2201 and wedge every later run's
`sshd-modern` bind — a teardown bug that would masquerade as a fixture
flake.

Suites:

- **VFS contract against real SFTP**: `runRemoteFileSystemContract`
  (§3.1) runs a third time against `DartSshRemoteFileSystem` on
  `sshd-modern`, proving the `InMemoryFileSystem` fake against real
  SFTP v3 semantics (mtime granularity, symlink/mode, rename rules), not
  only the local filesystem's — the fixture already exists here, so the
  same cases cost one more harness.
- **Transfers end-to-end**: recursive upload/download of a generated
  tree against `sshd-modern` and `sshd-legacy`; conflict preflights fire
  against real concurrent modification; cancellation mid-transfer cleans
  the remote `.poltergeist-*.tmp`; mode preservation; the chroot service
  proves everything works with `internal-sftp` only.
- **Sync end-to-end**: Update/Mirror/Additive convergence on real trees
  (re-scan after execute shows "Both sides match"); `.poltergeist-trash/
  <runId>/` renames on the remote side; journal + Retry Failed + Undo;
  the `sshd-restricted` service drives the `sizeOnly` fallback end to
  end, remote `setTimes` tests gate on the Séance pin bump (03 §2.4) and
  are skipped with a named reason until then.
- **Pin-store isolation**: every non-TOFU integration suite (VFS contract,
  transfers, sync, pool) constructs its client with a fresh per-suite
  in-memory TOFU pin store **pre-seeded with the committed host key(s) of
  every service that suite dials** — all non-`sshd-keyswap` services present
  the same committed fixture host key (only the keyswap key differs), so the
  pre-seed is a single entry covering the whole baseline matrix
  (`sshd-modern`/`legacy`/`restricted`/`chroot`/`authmatrix`) — so it never
  sees a trust prompt; only the TOFU suite manages
  pin state deliberately, using a private store per test, so its "prompts
  exactly once and pins" assertion is order-independent and no pin leaks
  across suites (a leak after the keyswap swap-in would otherwise
  hard-block a later suite on the changed key, D18).
- **TOFU flows** (D18): first connect to `sshd-modern` prompts exactly
  once and pins; a second connect (and pool growth) verifies silently;
  pointing the same server identity at `sshd-keyswap` hard-blocks every
  operation with the changed-key error and no auto-repin path.
- **Auth failures produce the summarized messages** (D5): against
  `sshd-authmatrix`, a rejected key, a method-not-accepted user, and the
  root `prohibit-password` case each yield the actionable one-liner from
  the ported `_summarizeFailure` machinery (assert the summary names the
  cause — e.g. that the server accepted none of the offered methods —
  per the upstream Séance `seance_core` package's
  `lib/src/ssh/ssh_session.dart`, consumed via the git pin — the in-repo
  packages are `poltergeist_*` only), never a raw
  dartssh2 trace.
- **Pool against a real server**: growth to `maxTransports`, keepalive
  pings, and reconnect-with-backoff after `docker stop`/`start` of the
  service; a mid-transfer restart flips the task to `queued` and it
  completes after reconnect.

M0 reuses this fixture (D9): the throughput comparison against the
OpenSSH `sftp` CLI baseline and the concurrent-request verification run
against `sshd-modern` with `tc netem` latency injection for the
high-latency case. One bidirectional shaping profile, implemented by ingress
and egress netem qdiscs, is shared by the warmed, counterbalanced engine/CLI
trials so both see one deterministic profile; for an unsplit cell, deleting it
between variants would defeat interleaving. Under 07 §3.1's hosted-job-cap
exception, each isolated shaped 1 GB replicate instead owns a fresh profile
and records all seven raw SSH exchange probes, their UTC capture time, and
their derived median. Those replicates are reported as cross-runner evidence,
never as interleaved or same-link trials. Both shaping qdiscs and the ingress
redirect are deleted after their owning cell or replicate. `tc` runs inside
the container, so the image installs
`iproute2`, the compose service adds `cap_add: [NET_ADMIN]` (or the netem
leg uses a dedicated profiled `sshd-netem` service), and the qdisc is
deleted in teardown so injected latency never leaks into other suites
sharing `sshd-modern`. The fixture therefore lands in the M0 PR, before any
engine code.

## 6. Performance benchmarks as tests (D12)

The budget table is owned by 02 §12 (P1–P7); this section defines the
harness. Budgets apply to **release/profile mode** builds only — a debug
number is never compared against a budget.

Two tiers, because CI runners cannot honestly measure UI frames:

| Tier | Budgets | Harness | Environment | Enforcement |
|---|---|---|---|---|
| A — engine-side, absolute | P3 (listing overhead), P5 (drop→start), P7 (scan rate) | pure-Dart entrypoints in `packages/*/benchmark/`, compiled AOT (`dart compile exe`) in CI — `dart run` is local iteration only, per Mechanics — against the §5 Docker fixture on loopback (the bench job reuses §5's stack lifecycle verbatim — compose up, the banner-exchange readiness wait, `POLTERGEIST_SSHD*` exports, and the same `trap … EXIT` teardown with profiles enabled — factored into a helper shared with run.sh so the two cannot drift; loopback stands in for LAN; for P3 the overhead is computed as a same-connection difference — listing of the target tree minus a control listing of an empty/minimal directory over the identical connection — rather than subtracting a separately measured network baseline) | CI runner pinned to a specific image digest/tag (or tier A run inside a digest-pinned container), so image rotations are deliberate — paired with a recalibration PR — rather than ambient | enforced (`BENCH_ENFORCE_A`, red = failed job) from the milestone that introduces each surface |
| B — UI frames, hardware-honest | P1, P2 (first paint), P4 (tab switch), P6 (frame drops) | `integration_test` suites in `app/poltergeist_app/integration_test/perf/` capturing `FrameTiming`s via `SchedulerBinding.instance.addTimingsCallback` (the stable in-process mechanism; `traceAction` may be used only after verifying it produces summaries under `flutter test integration_test --profile` with the pinned `integration_test` — its Timeline plumbing has a deprecation history), run under xvfb on Linux in profile mode | CI: **trend only** vs a committed baseline (fail on > 25 % regression of the median of ≥ 3 in-job repetitions once enforced — Mechanics defines the source); absolute budgets verified on the reference machine — the maintainer's Apple-silicon macOS laptop — during release QA (§9) | trend-only until M9 flips to enforced (soft mode lives in `check.dart`, §6 — no blanket `continue-on-error`); absolute at release QA |

Mechanics:

- Every run writes `bench-results.json` (scenario id, **repetition index
  within the job**, value, unit, environment fingerprint — the repetition
  index is part of the aggregation key so `check.dart` can take the median
  of the ≥3 in-job repetitions per scenario without treating them as
  duplicate ids); `test/benchmarks/check.dart` compares results
  against `test/benchmarks/budgets.json` (the P1–P7 values, mirroring
  02 §12) and the committed tier-B baseline, prints the table, and exits
  non-zero whenever an expected scenario is **missing or errored** — in
  soft mode too; the enforcement flags additionally make budget/trend
  overruns fail. A declared tier whose baseline file is **absent** (the
  M3 spike window, before the spike PR commits it) prints a loud
  non-enforced notice and exits zero while soft, non-zero once that
  tier's enforcement flag is set. "Expected" is scoped two ways, or the rule reddens runs
  it should not: the invocation declares which tiers it ran
  (`--tiers a|b|ab` — a `packages/**` PR run executes tier A only and
  passes `--tiers a`, so absent tier-B scenarios are not "missing"), and
  the expected set is the scenarios `budgets.json` marks **landed** —
  the PR that introduces a surface flips its scenario to landed in the
  same PR (07 §1's gate-from-introduction rule), so a pre-M4 run is not
  failed for P5. Within that scope the rule stays absolute.
  Enforcement is **per tier** — `BENCH_ENFORCE_A` for the
  tier-A budgets, `BENCH_ENFORCE_B` (the M9 repository variable) for
  tier-B trends — because one job evaluates both tiers over one results
  file, and a single flag would either enforce tier B early on `main` or
  leave tier A unenforced. Soft mode softens overruns only, never a
  benchmark that
  failed to run — a silently skipped benchmark is how budgets die.
- **Two enforcement schedules** (07 §1 states the same policy): tier-A
  engine benchmarks (the pure-Dart engine budgets — P3, P5, P7) run
  enforced (`BENCH_ENFORCE_A`, a red benchmark fails the job) from the
  milestone that introduces each surface — schedule-consistent because
  the bench job itself arrives in the M3 PR and every tier-A surface
  lands at or after M3; a surface that ever landed earlier would stay
  **unlanded in `budgets.json`** until the job exists to gate it, so
  "enforced from introduction" can never name a job that is not there
  yet — and also run on PRs that
  touch `packages/**` (path-filtered), so a P3/P5/P7 regression is
  caught pre-merge instead of turning `main` red after the fact;
  tier-B UI benchmarks run
  trend-only in CI until M9 flips `BENCH_ENFORCE_B` to
  enforced — M9 is the flip plus an audit, not a rescue. "Trend-only"
  is implemented inside `check.dart` (overruns don't exit non-zero
  without the tier's flag), **never** as a blanket
  `continue-on-error: true` on the job step — that would also mask
  missing/errored scenarios, which fail in every mode (above). Once
  enforced, a tier-B comparison runs the tier-B suite ≥ 3 times
  **within the single bench job** and compares the median of those
  in-job repetitions against the baseline — in every mode, not only once
  enforced, so the M9 flip changes only exit-code semantics, never the
  measurement methodology behind the committed baseline (no cross-run orchestration;
  the results file carries per-repetition entries so `check.dart` can
  compute it). **The CI bench job's in-job runs are the authoritative
  tier-B comparison after the M9 flip** — the once-on-reference-macOS
  release run (DoD) is a human-readable release-note artifact, not the
  gate; the baseline is fingerprinted to the CI runner so the two are
  never compared across hardware. The fingerprint-mismatch **exit** is
  scoped to **tier-B** results compared against the tier-B baseline, but
  the fingerprint **check** is not: tier-A results carry the same
  fingerprint, and `check.dart` compares their controlled axes against the
  calibrated axes recorded alongside `budgets.json` — on mismatch the
  tier-A budget comparison is **skipped with the same loud, non-enforced
  "hardware drift — recalibrate" notice and refresh-PR printout as the
  tier-B CPU axis** (exit stays zero in every mode, never a silent
  cross-image comparison and never an auto-redden), so a runner-image
  rotation cannot silently compare tier-A AOT numbers against budgets
  calibrated on the old image and cannot redden the tier-A PR gate either
  — and the fingerprint splits
  into two axis classes, because `ubuntu-latest` is a heterogeneous pool
  that rotates CPU hardware over time: **controlled axes** (runner image
  digest/tag, arch, Dart/Flutter version, AOT/profile mode, scenario
  config), whose mismatch is a hard non-zero exit **once `BENCH_ENFORCE_B`
  is set** — while soft, a controlled-axis mismatch gets the identical
  loud "hardware drift — recalibrate" notice and exit-zero treatment as
  tier-A's controlled-axis skip below, so a routine pre-M9 runner rotation
  or Dart/Flutter bump never reddens a PR unrelated to the rotation
  (tier-A budget comparisons skip with that same notice and exit zero in
  every mode, per the tier-A paragraph above, so a runner-image rotation
  never reddens the tier-A PR gate either), cleared only by a dedicated
  baseline-refresh PR; and the
  **uncontrolled CPU-model axis**, whose
  mismatch instead skips the tier-B comparison with a loud non-enforced
  "hardware drift — refresh the baseline" notice on any lane and never
  auto-reddens, because CPU identity is not controllable on `ubuntu-latest`
  — keying the hard-fail on it would fire intermittently on unrelated
  pushes and train exactly the ignore-the-gate reflex this rule exists to
  prevent; a human clears the drift by opening the baseline-refresh PR.
  The drift is **time-boxed** so the skip can defer but never disable
  enforcement: `check.dart` persists drift state across runs in a small JSON
  file (the previous state fetched from the latest bench job's artifact via
  the Actions API, or an `actions/cache` entry keyed on the fingerprint —
  documented as the single state store, with retention), updates it each
  **main-branch run only** — the artifact fetch is filtered to
  `branch=main` (the state rides inside `bench-results.json` or its own
  always-uploaded artifact), PR tier-A runs never write drift state, and a
  missing/unfetchable state file (cache eviction, artifact expiry) means
  "count unknown — continue counting conservatively," never a reset — and
  once the same drift notice has fired on ≥ 7 consecutive
  main-branch runs (any intervening clean **main-branch** run resets the
  count) the job
  reddens with "baseline stale — refresh required", so a pool CPU rotation
  cannot leave tier-B enforcement dormant indefinitely. A mismatch of either class still never falls
  through to a cross-hardware comparison, and the refresh-PR procedure is
  printed on every mismatch.
  The tier-B flip
  is a one-line repository-variable change recorded in 07's M9 exit
  criteria.
- P5's "no upfront full-tree stat" is asserted structurally as well as
  temporally: the fake filesystem counts stat calls between drop and
  first byte, at **two tree sizes** (1k and 50k entries) — the count must
  stay flat as the tree grows; the two-size comparison is what makes
  "O(first file), not O(tree)" falsifiable rather than a fixed ceiling
  any constant-fraction scan could sneak under.
- Tier-A measurement mode: `dart run` is JIT, which is neither release
  nor profile. Tier-A scenarios run AOT via `dart compile exe` in CI
  (each scenario also discards a stated number of warmup iterations);
  02 §12's P3/P5/P7 values are quoted against that AOT mode (P3 included:
  its functional cancel-latency check runs inside the tier-A AOT harness, so
  the 100 ms reference below is an AOT number and only the `ubuntu-latest`
  assertion is scaled) — `dart run`
  is for local iteration only, never a number quoted against a budget.
  The **machine** is pinned like the mode: each tier-A budget is
  calibrated on the same runner image the bench job uses (recorded in the
  results-file fingerprint's controlled axes, above) and re-calibrated
  through the same dedicated-PR procedure when those axes change — an
  absolute number measured on a different image is treated like a debug
  number, never compared against a budget.
- Tier-B viability is spiked when the M3 PR adds the job, before any
  baseline is committed: the chosen invocation must demonstrably report
  **real rasterizer timings** — the plain `flutter test` device
  (`flutter-tester`) does not rasterize honestly, so timings can come
  back empty or synthetic. If they do, the fallback is driving the real
  desktop embedder under the same xvfb (`flutter drive -d linux
  --profile`, or `flutter test integration_test -d linux`); the spike's
  outcome (invocation + evidence) is recorded in the M3 PR description.
- P1/P2 anchors: in-process `FrameTiming` sees nothing before Dart
  `main()`, so each first-paint scenario anchors on an **in-app action**
  (the timestamp taken when the test triggers the navigation into the
  10k/100k directory) — never process launch; 02 §12's P1/P2 are defined
  as navigation-to-paint, so the anchor and the budget agree.
- P3's "always cancellable" is a functional test (cancel during a slow
  listing returns promptly — 100 ms on the reference machine, with a
  CI-scaled bound for shared-runner scheduling jitter, 1 s on
  `ubuntu-latest`; the assertion that matters is returning long before
  the listing would have completed), not a benchmark.
- Benchmark code never shares state with tests; a benchmark that fails
  to run is a CI failure even in soft mode (per the first bullet's
  check.dart rule).

## 7. Accessibility checks (D20)

Automated, in `flutter test` (semantics enabled via
`tester.ensureSemantics()`):

- **Semantics assertions on every custom row type** (02 §13), using
  `matchesSemantics`: the file row is one merged node announcing
  name–kind–size–date in that order regardless of visual column order,
  with selected state and open/rename actions; column headers expose
  button semantics + sort state (`"Size, sorted descending"`); sidebar
  group headers merge to one node with `expanded` and a spelled-out
  count (the Séance `server_list_pane.dart` standard); tabs carry tab
  semantics with selected state and a close action; activity rows
  announce completion/failure through a live region and do **not**
  announce continuous progress percentages; splitters are focusable with
  labels and value announcements.
- **Keyboard-completeness test** (D21, referenced by 02 §8.1): a test
  iterates the command registry and fails if any command is unreachable.
  Reachable means: it has activators for the current platform **or** a
  menu path — palette inclusion does **not** count toward reachability,
  because every registered command is palette-visible by construction
  and a universally-true disjunct would make the invariant unfailable
  (02 §8.1 states the same); universal palette visibility is asserted
  as its own separate check. A second, stronger pass pumps the workspace with a
  recording registry and sends the real key events for every row of the
  02 §8.3 table on both platform personalities, asserting each command's
  `run` fired — bindings are proven by dispatch, not by table
  inspection. The recording seam wraps the dispatch boundary **before**
  enablement gating, and the workspace is seeded per command class (a
  selection, an open tab, an active transfer), so state-gated commands
  fire without weakening the assertion. The same test fails on duplicate
  activators within
  overlapping scopes and on command ids that violate the dotted
  lowerCamel naming rule.
- **Contrast test**: a pure-Dart test computes WCAG relative-luminance
  contrast over the design-token set for both themes: normal-size text
  tokens ≥ 4.5:1, large-text tokens (≥ 18 pt regular / ≥ 14 pt bold —
  WCAG 1.4.3's tier; token metadata carries a size/role class so the
  test can tell) ≥ 3:1, and status/indicator colors (including the sync
  plan's action
  tints and the sidebar status dots) ≥ 3:1 against the surfaces they
  actually render on. This pins the fix for the Séance SEA-019 class —
  a status color that ignores brightness cannot pass.
- **Hardcoded-string test** (02 §13): walks `lib/**` (not just
  `lib/ui/**` — error and summary strings from non-UI layers are equally
  user-facing once shown in a dialog/snackbar) and fails on user-facing
  string literals outside the ARB/l10n pipeline (allowlist for genuinely
  non-UI literals: keys, ids, format patterns). Generated code is excluded
  by **path**, not by literal — the l10n output directory plus
  `*.g.dart`/`*.freezed.dart` and generated mocks, all dense with literals
  that are neither keys nor authored UI text — and the test guards that
  carve-out: it fails if an excluded path has vanished or the generated
  l10n files are absent, so the exclusion can never silently swallow the
  whole walk. Package-produced user-facing text (the D5 failure summaries)
  is asserted localized via its own suite rather than exempted by the path
  scope.

Manual screen-reader verification is §9's job; Linux screen-reader
support is broken upstream in Flutter and is documented, not tested.

## 8. CI mapping

The existing `.github/workflows/ci.yml` already has the right shape; this
section says what each job runs and what gets added when.

| Job | Exists? | Runs | Notes |
|---|---|---|---|
| `dart` | yes | `dart analyze` + `dart test` over `packages/*`, discovered dynamically | `poltergeist_sync` joins automatically when created. **Change at M3 with `LocalFileSystem`**: extend to an OS matrix (`ubuntu-latest`, `macos-latest`, `windows-latest`) — the platform-conditional contract cases (case-only rename, reserved names, mode unsupported) only mean something on the real OS. All three are required checks; they are cheap (pure Dart). |
| `detect` + `flutter` | yes | `flutter analyze` + `flutter test` (unit, widget, a11y suites of §4/§7) | self-activates when `app/poltergeist_app` appears; no workflow edit |
| `client` matrix | yes | release-parity compile of every platform + Linux packaging | unchanged; keep in step with `release.yml` |
| `integration` | **added in the M2 PR** that lands the connection module | `test/integration/run.sh` on `ubuntu-latest` (Docker available there): the job runs run.sh end to end — compose up, the §5 readiness wait, `dart test -t integration` with explicit package paths, and the `trap … EXIT` compose-down that fires on success and failure alike (the single-lifecycle-owner rule §5 centralizes; the bench job reuses only its `--lifecycle-only` half, without the `dart test`) | guarded like the Flutter jobs: a `detect`-style step checks `test/integration/docker-compose.yml` exists, so absence stays skipped-neutral only for PRs triggered by the `packages/**` source globs — a PR whose diff touches `.github/workflows/ci.yml` fails loudly on an absent fixture too, since that file is in the trigger filter precisely so job edits self-validate; on `main`/dispatch **and on any PR whose diff touches `test/integration/**`** (a deletion or rename of the fixture is exactly the case to catch pre-merge, not first on `main`) an absent fixture fails the job loudly instead, so a deleted fixture can never silently disable the suite — it lands with M0 (§5), before this job exists, so the guard is defensive, not a schedule. Timeout 35 min — the `dart test -t integration` suite alone is quoted at ~25 min (see the `bench` row); compose-up, the §5 readiness wait, and the trap teardown sit on top, and a hard timeout equal to the suite's own duration turns ordinary runner jitter into an ungraded cancellation rather than a graded failure. Runs on push to `main`, `workflow_dispatch`, and PRs touching `packages/**/lib/**`, `packages/**/test/**`, `packages/**/pubspec.yaml`, `test/integration/**`, or `.github/workflows/ci.yml` (source/test-scoped, not a bare `packages/**` that also matches a `README.md` — a 35-minute Docker job has no business on a docs-only PR; the workflow file is in the filter so job edits self-validate, and `workflow_dispatch` is the manual trigger the "on `main`/dispatch an absent fixture fails loudly" guard above names). |
| `bench` | **added in the M3 PR** (queue + panes exist) | tier-A benchmarks vs the Docker fixture — brought up through run.sh's own lifecycle via a `--lifecycle-only` mode run.sh grows for this job (compose up, the §5 SSH-banner readiness wait (an immediate benchmark after `up -d` hits the first-connection flake §5 exists to prevent), and the `--profile keyswap` trap teardown — but **no `dart test` invocation**, since reusing run.sh verbatim would run the whole ~25-min integration suite inside this 45-min job, while copying the lifecycle into the bench job would fork the trap/readiness logic §5 centralizes) — tier-B under xvfb in profile mode (main/dispatch runs only; skipped on PRs, see gating below), then `test/benchmarks/check.dart` (also `if: always()`, so partial results flushed by a soft-deadline exit are still graded, not skipped when the runner step exits non-zero) with the `--tiers` flag matching what ran (§6 — `ab` on main/dispatch, `a` on PR runs); uploads `bench-results.json` as an artifact via an `if: always()` upload step, so timed-out or failed runs still ship their partial results; because a hard `timeout-minutes` cancellation can kill the upload mid-flight, the runner and check.dart enforce their own soft deadlines below the 45-min cap (flush partial results, exit nonzero) so a slow run surfaces as an ordinary failure rather than a cancellation | tier A runs on push to `main`, `workflow_dispatch`, **and PRs touching `packages/**/lib/**`, `packages/**/test/**`, `packages/**/pubspec.yaml`, `test/benchmarks/**`, `test/integration/**` (the run.sh lifecycle and compose fixture this job reuses via `--lifecycle-only`), or `.github/workflows/ci.yml`** (source/test-scoped, so a docs-only PR under `packages/` does not spin up the 45-min job; a baseline-refresh, a check.dart/budgets.json-only PR, or a job edit is validated pre-merge, not first on `main`) with `BENCH_ENFORCE_A=1` (red = failed job) from the milestone that introduces each surface — absolute loopback budgets are stable enough to gate pre-merge; tier B runs on push to `main` and `workflow_dispatch` only (frame-timing noise on shared runners would train people to ignore a PR check), soft mode implemented in `check.dart` per tier (§6) — **no `continue-on-error`**, so a scenario that fails to run reddens the job in every mode (within the declared tiers and landed scenarios, §6) — until M9 flips `BENCH_ENFORCE_B` — at which point tier B (still `main`/dispatch-only, never PR-gating) gains the de-flaking policy enforcement requires: median across the >=3 repetitions, one automatic rerun before red, and a pinned/larger runner class so shared-runner contention cannot redden `main` — a controlled-axis change for the whole job (tier A shares the runner), so tier-A budgets are re-calibrated on the new class via the §6 dedicated-PR procedure before the flip lands. **Timeout 45 min** (Docker tier A + >=3 xvfb tier-B repetitions + check.dart). |

The GLM review workflow (`zai-code-review.yml`) is orthogonal and
unchanged. Rules that hold everywhere: explicit paths in every dart/
flutter invocation; jobs added to `ci.yml` must mirror into `release.yml`
only when they gate releases (integration does at M9+; bench never — its
enforcement already lives in the `main`-gating CI job via the M9
`BENCH_ENFORCE_B` flip, and the once-on-reference-macOS release-QA tier-B
run is informational hardware verification, not a gate, per §9).

## 9. Manual QA checklist per release

Automated tests cannot see native chrome, IMEs, or screen readers. The
checklist lives at `docs/qa/RELEASE-CHECKLIST.md` (created with the M9
PR); every release records a filled copy in the release PR. Per release:

**Per-platform chrome (D11)**
- macOS: unified toolbar look, traffic lights placed correctly at every
  window size, native menu bar complete and enabled-states correct,
  Edit-menu routing (Copy/Paste against file list vs rename field vs
  editor), no "Show Tab Bar" leakage, focus flag cleared after closing
  the last editor (the SEA-008 class).
- Windows: native titlebar, snap layouts work, Flutter-drawn `MenuBar`
  complete, Alt+F4 quits cleanly with a running queue (prevent-close
  flush prompt).
- Linux: server-side decorations, `.deb` and AppImage both launch,
  `StartupWMClass` maps the window to the desktop entry.

**IME smoke** (Flutter-desktop pitfall: Windows is IMM32, not TSF)
- Rename a file with Japanese and Korean input on Windows, macOS, and
  Linux (IBus/fcitx — Linux is a shipped platform, and IME composition is
  notoriously platform-divergent): composition renders in place, Enter
  commits, Esc cancels the
  composition without cancelling the rename.
- Type CJK in the editor and the filter field; verify highlighting never
  fights composition (the `CodeEditingController` IME guard).

**Screen reader smoke**
- macOS VoiceOver and Windows NVDA (Narrator as an optional secondary pass): traverse
  file rows (name–kind–size–date announced), column headers with sort
  state, tabs, sidebar groups (expanded state), activity rows
  (completion announced once); operate one full transfer
  keyboard-and-reader only.
- Linux: not tested (broken upstream — the README note links and dates
  the upstream issue); each release re-checks whether it is still broken
  and drops the exclusion when upstream fixes land.

**Trust and platform behaviors**
- First-launch unsigned-app paths (D23): Gatekeeper right-click-open on
  macOS, SmartScreen "More info → Run anyway" on Windows — both match
  the documented steps.
- Trash per platform (D15): macOS Put Back works; Windows Explorer undo
  restores; Linux restore-from-trash verified — `gio trash --restore`
  where the installed GLib supports the flag (it takes the trash-side
  suffixed name, not the original path), else `gio open trash://` + a
  file-manager restore; record which path the QA machine used.
- Drop-in from Finder/Explorer/Nautilus into each pane; in-app pane↔pane drag;
  confirm drag-out is absent (v1) and the "Download to…" path covers it.
- Theme flip (light/dark) live-restyles listing, plan view, and editor;
  HiDPI scaling at 100 %/150 %/200 % shows no clipped chrome.
- Tier-B benchmark suite run once on the reference macOS machine in
  release mode; results attached to the release PR as a readable
  artifact — the authoritative M9 gate is the CI bench job's in-job
  tier-B runs against the CI-fingerprinted baseline, not this run (§6) —
  budget/baseline entries are scoped by build mode + OS (CI profile/Linux
  vs QA release/macOS) so the two are never cross-compared.

## Definition of done

- [ ] `packages/poltergeist_core/lib/testing.dart` exists exporting
      `InMemoryFileSystem` (+ `FaultPlan`, `InProcessEngineClient`); the
      shared `runRemoteFileSystemContract` suite passes against both
      `LocalFileSystem` and the fake (and against the SFTP adapter over
      the §5 Docker fixture where present), with platform-conditional
      cases on the CI OS matrix.
- [ ] Every ported Séance test asset in the §2 table lands in the same PR
      as its code, renamed suffixes only, PORTS.md entries present.
- [ ] Queue, pool, bookmark/coordinator, and engine-protocol suites of
      §3.2 pass with fake clocks — no real sleeps anywhere in unit tests.
- [ ] `poltergeist_sync` property tests pin all §3.3 invariants with
      seeded generators; exporter and header-copy goldens exist; the
      static no-`Process`/no-Flutter/no-dartssh2 test guards the package.
- [ ] Widget suites cover the §4 commitments with injected seams, real
      key events, and both chord variants; per-platform expectations use
      `debugDefaultTargetPlatformOverride`.
- [ ] `test/integration/` fixture exists with the six-service matrix of
      §5; suites self-skip without `POLTERGEIST_SSHD`; TOFU changed-key,
      auth-summarizer, chroot, and setstat-fallback flows are covered
      end to end; the fixture lands with M0.
- [ ] Benchmark harness of §6 runs both tiers, writes `bench-results.json`,
      checks against `budgets.json` + baseline, and follows the §6
      enforcement schedules (tier A enforced via `BENCH_ENFORCE_A` from
      its **M3** introduction, on `packages/**/lib/**`,
      `packages/**/test/**`, `packages/**/pubspec.yaml`,
      `test/benchmarks/**`, **and `.github/workflows/ci.yml`**
      PRs too (matching §8's bench row); tier B soft-fails
      **overruns only** until M9 flips `BENCH_ENFORCE_B`. A missing or
      errored scenario is a CI failure in every mode; this applies only
      to the tiers the invocation declares and only to scenarios
      `budgets.json` marks landed — un-landed scenarios are not
      "missing" (§6).
- [ ] a11y suites of §7 pass: semantics on all custom rows, the
      keyboard-completeness + dispatch test over the full registry, the
      token contrast test, and the hardcoded-string test.
- [ ] `ci.yml` carries the §8 additions on schedule: dart-job OS matrix
      at M3 with `LocalFileSystem`, `integration` job at M2 (skip-neutral
      guarded), `bench` job
      at M3 (main + dispatch for both tiers; tier A additionally on
      `packages/**/lib/**`, `packages/**/test/**`, `packages/**/pubspec.yaml`,
      `test/benchmarks/**`, `test/integration/**`, **and
      `.github/workflows/ci.yml`**
      PRs with `BENCH_ENFORCE_A`, per §6/§8 — the harness's own PRs are the
      ones most likely to perturb timings, so they gate too).
- [ ] `docs/qa/RELEASE-CHECKLIST.md` exists (M9) and a filled copy is
      attached to every release PR from then on.

## Explicitly out of scope

| Deferred / owned elsewhere | Where it lives |
|---|---|
| The budget values themselves (P1–P7) | 02 §12 (D12) — this chapter only measures them |
| M0 spike protocol, milestone sequencing, and the M9 enforcement flip | 07 (D9) |
| Upstream Séance test changes (`openAuthenticatedClient` recomposition, PR-S1 `RecordKind` suite) | 04 §5 — they run in the Séance repo |
| Behavioral specs the ported suites assert (editor, checkout store, sync rails) | 06 and 05 — this chapter carries the tests, not the contracts |
| PR workflow, review policy, "what never to do" | 09 |
| Release build/packaging smoke | existing `ci.yml` client matrix + `release.yml` (AGENTS.md §2) |
| Tests for v2 features (resumable transfers, baseline-DB two-way, rsync accelerator, drag-out) | D25 parking lot; harness hooks (`FaultPlan`, journal fields) already anticipate them |
| Custom keymap testing | not a v1 feature (02 §8.3 note) |
