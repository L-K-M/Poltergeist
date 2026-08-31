# 09 — Implementation playbook

This chapter is the operating manual for the implementation model (or human)
executing chapters 01–08. It does not add design; it fixes *how* the work is
done: the loop for picking work, the repo conventions restated as operational
rules, the code idioms that review enforces, the rules for ported code, the
per-PR definition of done, the hard "never" list, the automated-review
policy, and what to do when stuck. Where a rule cites a decision as "(Dn)",
the decision log in [00-OVERVIEW.md](00-OVERVIEW.md) is the authority; this
chapter elaborates it and never reopens it.

## 1. How to work the plan

The loop, in order, for every unit of work:

1. **Pick the next milestone from 07 §2.** The order M0–M10 is fixed. The
   only permitted parallelism is named in 07 §1: M5 with the tail of M4, and
   M6 with M7. Anything else is a plan edit (a PR touching 07 with
   rationale), not a judgment call.
2. **Check the Séance gate before starting.** Never start work whose
   upstream dependency has not merged (07 §2, 04 §5):

   | Work | Gate |
   |---|---|
   | M2 D2 copies (the first Séance source copied into this repo) | PR-S0 landed (LICENSE on Séance `main`) |
   | M2 connection layer | PR-S2 merged upstream and pin bumped — tag preferred, rev permitted per 03 §8.1 |
   | M6 Design A (shared account) | PR-S1 **released**; its tag recorded in `kMinimumSharedAccountSeanceVersion` (04 §4.2) |
   | M8 remote sync execution | PR-S3 merged **and** pin bumped |

   If a gate is not met, work the ungated part of the milestone (M6's
   Design B, M8's local↔local engine) or the parallel track — never a
   local fork of `seance_core` to route around the gate (D2, risk 4 in
   07 §6 pre-authorizes pin-to-rev as the only stall mitigation).
3. **Read before writing.** 00 in full once per session; then the milestone's
   detail section in 07 §3; then the design chapters it cites (e.g. M4 reads
   02 §5–6 and 03 §4). Do not re-derive design from the research notes or
   from Séance's code beyond what the chapters cite.
4. **Implement in small PRs — one coherent feature slice each.** A slice is
   one behavior a reviewer can hold in their head: "recursive delete with
   progress and cancel", "conflict dialog + policy plumbing", "path bar
   breadcrumbs". Engine model + its tests + the minimal UI that exercises it
   may share a PR; two unrelated behaviors may not. Every PR leaves `main`
   green and demoable (07 §1 — no milestone, and no PR, ends on a broken
   `main`).
5. **Every PR updates [docs/STATUS.md](../STATUS.md)** — the done table, the
   next-steps list, or both. STATUS.md is the live progress record; the plan
   chapters are never edited to record progress (07 §3.12).
6. **Close the milestone with the 07 §3.12 chores**: STATUS.md sweep,
   PORTS.md sweep, Séance pin bump + re-diff, `v0.<milestone>.0` pre-release
   tag (M1 onward), mobile-invariant check (07 §5).

Conflict rules, restated from 00's header because they govern every step:
when a chapter conflicts with 00's decision log, the log wins; when code
reality conflicts with the plan, **stop and update the plan first** (§8).

## 2. Repo conventions, operationally

Restated from [AGENTS.md](../../AGENTS.md) as commands and review-blocking
rules — AGENTS.md remains the authority on toolchain setup (§1 there).

- **Explicit test/analyze paths, always.** A bare `dart test` or
  `dart analyze` at the repo root is never correct in this repo: the root
  package has no tests of its own, and the Flutter app is deliberately
  outside the root `workspace:` list (see below, 03 §9), so root commands
  cannot reach it either. The commands are:

  ```bash
  dart analyze packages/poltergeist_core
  dart analyze packages/poltergeist_sync   # one root per invocation —
                                           # `dart analyze` takes a single
                                           # analysis root (08 §3 Principle 4)
  dart test    packages/poltergeist_core packages/poltergeist_sync
                                           # `dart test` DOES accept several
                                           # paths, unlike analyze
  cd app/poltergeist_app && flutter analyze && flutter test
  ```

- **Analyze clean before every commit.** Zero analyzer diagnostics; no
  `// ignore:` without a comment explaining why on the same line's
  neighborhood.
- **Commit messages** end with the repo family's co-author trailer and the
  session link. **No model identifiers anywhere** — not in commits, code,
  comments, or docs (AGENTS.md §3). The one sanctioned exception is
  naming the repo's own review tooling where §7 documents working with
  it — the rule targets the *authoring* model's identity, and a rules
  file that flunked its own gate would invite inconsistent enforcement
  either way. This is a review blocker.
- **Docs wrap at ~80 columns**, sentence-case headings, tables where they
  clarify, no emoji — match the files in `docs/plan/`.
- **Doc comments explain *why*.** The Séance standard: a comment that
  restates the code is deleted in review; a comment that records the reason
  a guard exists (the race, the platform quirk, the finding id) is required
  wherever the code would otherwise look simplifiable.
- **Small focused files.** One concept per file; pure logic in Flutter-free
  files so it unit-tests without pumping widgets (the Séance
  `server_grouping.dart` pattern, 02 §2.5's pure sort/filter functions).
- **ASCII product name** in every file name and identifier — a tested
  invariant in `poltergeist_core`. Identifiers: `com.lkm.poltergeist_app`
  (Android + Linux GApplication), `com.lkm.poltergeistApp` (Apple), Linux
  binary `poltergeist` (AGENTS.md §3).
- **The Flutter app stays out of the root `workspace:` list** and
  path-depends on the members (03 §9). CI's `ci.yml` and `release.yml`
  build matrices stay in lockstep (AGENTS.md §2).
- **Kill by PID, never `pkill -f <name>`** — the pattern matches your own
  shell's command line and kills it (AGENTS.md §4).

## 3. Required idioms

These patterns are mandatory. 03 §6 makes the first two review-rejection
criteria for async controller code; the rest carry the same weight in their
domains. Each idiom exists because Séance's review history (SOL-038,
SOL-057, SEA-008 classes) shows what happens without it.

### 3.1 `identical()` recheck after every await

After any `await`, re-fetch the live object and compare with `identical`
before mutating; a stale winner disposes its result instead of applying it.
Pair with `_disposed` guards in every async callback and timer (03 §6).

```dart
Future<void> _connectTab(PaneTab tab) async {
  try {
    final session = await _engine.connect(tab.serverId);
    if (_disposed || !identical(_workspace.tabById(tab.id), tab)) {
      try {
        await session.close();      // don't leak the fresh session — but
      } on Object {
        // swallow: the tab is gone, nobody can surface this failure, and
        // §3.2's rule forbids unhandled async errors from controllers
      }
      return;                       // tab was closed/replaced mid-connect
    }
    tab.attach(session);
  } on RemoteFileException catch (e) {
    // A connect that throws (refused, auth, timeout) must route into the
    // tab's error state, never fall through as an unhandled async error
    // (§3.2's rule) — but only while the tab is still live; a failure on a
    // tab closed or replaced mid-connect is dropped like a stale listing.
    if (_disposed || !identical(_workspace.tabById(tab.id), tab)) return;
    _applyConnectError(tab, e);
  }
}
```

### 3.2 Navigation generation counters

Every navigation bumps `_navigationGeneration`; async completions compare
their captured generation and drop themselves if stale — a slow listing of
a directory the user already left must never repaint the pane (03 §6,
02 §2.8's latency-honesty rules depend on it).

```dart
Future<void> navigateTo(String path) async {
  // Cancel the superseded listing first: dropping its result is not
  // enough — the stale request keeps consuming the browse channel, and
  // §3.3 requires the cancel affordance to target the listing actually
  // in flight, so the token rotates per navigation.
  _listCancellation?.cancel();
  final cancellation = _listCancellation = RemoteTransferCancellation();
  final generation = ++_navigationGeneration;
  final List<RemoteFileEntry> entries;
  try {
    entries = await _engine.list(path, cancellation: cancellation);
  } on RemoteFileException catch (e) {
    // A cancelled call completes by THROWING RemoteFileException with
    // kind `cancelled` (seance_core funnels its internal cancellation
    // type into the one exception funnel — remote_file_system.dart's
    // guard; §3.3 pins this as the contract). The superseded listing
    // the token rotation above cancelled is expected — swallow exactly
    // that kind, or every fast double-navigation surfaces an unhandled
    // async error. This swallow also covers the user cancelling the
    // in-flight listing via §3.3's affordance: the pane keeps its current
    // entries, and the cancel wiring (not this catch) clears the pending
    // indicator. A non-cancel failure on a navigation the user has
    // already left is dropped too — a slow listing's timeout must not
    // repaint the abandoned directory (or throw unhandled); only the
    // CURRENT navigation's real errors reach the pane's error state.
    if (e.kind == RemoteFileErrorKind.cancelled) return;
    if (_disposed || generation != _navigationGeneration) return; // stale
    _applyError(path, e); // route the current navigation's real error into
                          // the pane's error state here — never rethrow from
                          // a UI-invoked async, or the contract would depend
                          // on every (fire-and-forget) call site catching.
    return; // terminal: the error path must not fall through, or `entries`
            // is read below while potentially unassigned (analyzer error)
  }
  if (_disposed || generation != _navigationGeneration) return; // stale
  _applyEntries(path, entries);
}
```

### 3.3 Cancellation tokens on all long operations

Every listing, transfer, recursive walk, scan, and hash accepts a
cancellation token (`RemoteTransferCancellation` from `seance_core` for VFS
calls; the engine protocol's cancel message across isolates, 03 §5). The
**completion contract is pinned**: a cancelled VFS call throws
`RemoteFileException` with kind `cancelled` — never a partial result —
(seance_core's funnel wraps its internal cancellation type;
`remote_file_system.dart`), so every call site handles cancellation
identically, per the §3.2 sample. The UI
wires the Cancel affordance **before** awaiting, never after. An operation
without a cancel path is a review blocker — D16 makes "visible, cancellable,
inspectable" the product's trust contract.

### 3.4 Split notifiers — no progress through a root notifier

State lives in the per-domain notifiers of 03 §6 (`WorkspaceController`,
`PaneController`, `TransferQueue` mirror, `BookmarkStore`,
`ConnectionStatus`). Transfer progress events are Poltergeist's version of
Séance's per-packet trace lines: they flow **only** through the queue's own
notifier (coalesced to the frame budget, 03 §5), never through
`WorkspaceController` or any ancestor that would repaint panes per event.
Adding a field to a root notifier because "it's convenient" recreates
Séance's SOL-057 and is rejected in review.

### 3.5 Validate every path component at trust boundaries

Any path assembled from external input — remote listings, sync plans,
archive entries (v1.x), drag payloads, deep links — validates each
component before it touches a filesystem: no empty component, no `.` or
`..`, no `/` inside a component and no `\` in one (`\` is legal POSIX
filename data, but a component carrying one is overwhelmingly an
escaping bug in the exports and previews these names also feed, so the
sample rejects it for EVERY destination), and the joined result must remain
inside the intended root — the helper below is the **lexical half only**;
root containment is enforced where the absolute destination path is
built (03 §2.3's `ensureSafeLocalDirectory` refuses symlink traversal on
the way there). This is Séance's path-validation tradition and
the zip-slip defense D27 pre-commits to. The checks are
**destination-aware**: characters that are legal on a POSIX remote can
be hazards on a Windows destination — a `:` in a component silently
writes an NTFS alternate data stream, a `\` is a **Win32 path
separator** so `a\..\..\b` (no `/`, one component to the split)
traverses out of the root once joined on Windows, and the Win32-invalid
`*` `?` `"` `<` `>` `|` and the C0 control characters (`\x00`–`\x1f`), a
trailing dot or space (which Win32 silently strips into a name the next
listing won't match), and a component matching a Win32 **reserved device
name** — `CON`, `PRN`, `AUX`, `NUL`, `CLOCK$`, `COM1`–`COM9` and superscript
`COM¹`–`COM³`, `LPT1`–`LPT9` and superscript `LPT¹`–`LPT³`, with or without
an extension, whose write "succeeds" into the device (`nul`
discards the file's bytes) — are **all rejected in the `windowsDestination`
branch** (the `_windowsHazard` char class plus `_isWindowsReservedName`
below), a clean boundary error beating a confusing mid-transfer failure or
silent loss. (Backslash is
not in that branch — the sample's shape check rejects it for every
destination; see its comment.) So the caller
says where the path is headed. The helper itself absorbs trailing
separators (`'a/b//'` → `'a/b'`, all of them, not one) before
validating — a directory entry's trailing `/` is shape, not a
component, and the **validator owns that shape** so no call site can
forget it: SFTP-style listings routinely carry the trailing slash, and
a caller-side precondition here would make the designated zip-slip
defense reject legitimate directory entries at whichever call site
missed a strip (`'/'` still rejects — stripping leaves the empty
string). Windows reserved device names (the exact set enumerated above,
`CLOCK$` and the superscript digit forms included, with or without an
extension, `PRN.txt` among them) are already rejected
by `validateLocalName` (03 §2.3), which runs on **every locally created
name — intermediate directories included**: each directory a recursive
walk materializes is itself a target name at its own creation, so
`pkg/CON/x.txt` fails at the `CON` mkdir, not only at the leaf. A code
path that creates a local directory without `validateLocalName` on its
name is the same review defect as skipping it on a file. This helper
stays shape-and-hazard only for POSIX destinations; on a Windows
destination it additionally owns the reserved-name check (above),
because its non-mkdir callers have no other guard.

```dart
void validateRelativeComponents(String relative,
    {required bool windowsDestination}) {
  // A directory entry's trailing '/' is shape, not a component; the
  // validator absorbs it (all of them) so no caller has to remember.
  // '/' itself reduces to '' and is rejected below like any root.
  final original = relative; // quote the input as received, not post-strip
  while (relative.endsWith('/')) {
    relative = relative.substring(0, relative.length - 1);
  }
  for (final part in relative.split('/')) {
    // POSIX NAME_MAX counts UTF-8 bytes; NTFS caps at 255 UTF-16 units.
    // UTF-8 byte length is never below UTF-16 code-unit length, so the
    // byte bound alone subsumes the NTFS unit cap — one check fails an
    // over-long component here with a clean FormatException, not later as
    // an opaque ENAMETOOLONG mid-transfer.
    final partBytes = utf8.encode(part).length;
    if (partBytes > 255) {
      throw FormatException('path component too long ($partBytes bytes) in '
          '${jsonEncode(original)}');
    }
    // Backslash is rejected for EVERY destination on purpose: these
    // components also feed Windows-rendered previews and exports, and a
    // '\' inside one is overwhelmingly an escaping bug, not a filename —
    // do not "simplify" this to windowsDestination-only.
    if (part.isEmpty || part == '.' || part == '..' || part.contains('\\') ||
        // '\n'/'\r' are line-format breakers on EVERY destination — the
        // same escaping-bug class as backslash: these components feed the
        // rsync-command exporter, journals, and rendered previews, where an
        // embedded line break corrupts line-oriented output or naive quoting.
        // ':' stays legal for POSIX destinations, so the exporter's side of
        // the bargain is pinned here too: rsync parses 'host:path' in any
        // bare relative operand, so a ':' in the FIRST component (e.g.
        // 'evil:x/y', legal on the POSIX remote) would aim the transfer at
        // host 'evil' — exfiltration. The rsync exporter (05 §2) MUST prefix
        // every generated operand with './' (a leading './' forces local);
        // a test pins 'a:b/c' → './a:b/c'.
        part.contains('\n') || part.contains('\r') ||
        // NUL is not a legal filename byte on any platform, and a POSIX
        // C string silently truncates at it — the same escaping-bug
        // class as backslash, rejected for every destination.
        part.contains('\x00')) {
      throw FormatException('unsafe path component ${jsonEncode(part)} in '
          '${jsonEncode(original)} (shape/traversal)');
    }
    // Destination-filesystem rules: fine on POSIX, hazardous on Windows —
    // ':' writes an alternate data stream, <>"|?* fail CreateFile, C0
    // control bytes are invalid, and Win32 strips trailing dots/spaces,
    // silently creating a different name than was validated.
    if (windowsDestination &&
        (_windowsHazard.hasMatch(part) ||
            // Reserved device names checked HERE too, not only in
            // validateLocalName: export, preview, and drag-payload
            // flows never mkdir, so nothing else would ever see these
            // components on a Windows-bound path.
            _isWindowsReservedName(part) ||
            part.endsWith('.') ||
            part.endsWith(' '))) {
      throw FormatException('unsafe path component ${jsonEncode(part)} in '
          '${jsonEncode(original)}'
          ' (windows: hazard char / reserved name / trailing dot or space)');
    }
    // Bidi override/isolate controls are rejected for EVERY destination:
    // they visually reorder a rendered name (the CVE-2021-42574 spoof
    // class — 'invoice.pdf' that is really an .exe), and these
    // components feed exports and external programs that 02 §13's
    // display-time LRI/PDI isolation cannot protect. Legitimate RTL
    // names carry directionality in their characters and never need
    // explicit override controls.
    if (_bidiControls.hasMatch(part)) {
      throw FormatException('unsafe path component ${jsonEncode(part)} in '
          '${jsonEncode(original)} (bidi control)');
    }
  }
}

final _windowsHazard =
    RegExp(r'[<>:"|?*\x00-\x1f]'); // char class — applied per component
                                   // via hasMatch in the loop above
final _bidiControls = // ALM/LRM/RLM, LRE..RLO+PDF, LRI..PDI — the full
    RegExp(                     // Bidi_Control set, as regex-level
        r'[\u061c'             // \uXXXX escapes so the
        r'\u200e\u200f'        // source stays visible ASCII (a
        r'\u202a-\u202e'       // literal bidi char in a validator
        r'\u2066-\u2069]');    // would be its own spoof hazard)
```

Pin `_isWindowsReservedName`'s contract in its tests, since the
export/preview/drag flows it guards never mkdir and so nothing else would
catch a divergent stem rule: bare names case-insensitively (`con`, `Aux`,
`NUL`), superscript-digit forms (`COM¹`, `com².tar`, `LPT³` — reserved
exactly like the ASCII digits), stem-plus-extension forms (`CON.txt`,
`lpt1.tar`), names that
collide only *after* Win32 trailing-dot/space stripping (`NUL.`,
`COM1 .log`), and `CLOCK$` — and record the chosen stem rule here so 02/05
cannot state a conflicting one.

Corollary on bidi: a string that has passed through 02 §13's display-time
LRI…PDI isolation is *rendered* text carrying the app's own isolation
marks, so it must never be persisted or fed back into
`validateRelativeComponents`. Rename and copy flows take user input
**pre**-isolation, and any isolate arriving in pasted input is stripped at
the field boundary rather than stored; a display→input round trip that
reaches the validator is a defect to record, not a reason to loosen it.

### 3.6 Atomic writes for every persisted file

Nothing the app persists — settings, bookmark store, queue journal, sync
journal, checkout metadata — is written in place. Use the ported
atomic-file helper (write to a uniquely named temp sibling, flush, rename
over the target; the editor's saver adds the backup + conflict dance,
06 §2). Bare `File.writeAsString` to a live path is a review blocker.
The helper makes each *write* atomic, not concurrent writes serialized:
every store using it must also be single-writer (route all saves for a
given path through one async chain or mutex), or overlapping saves race
the final rename and last-writer-wins silently.

```dart
// uuidV4() is the project's one thin helper over package:uuid
// (`const Uuid().v4()`) — several chapters' sketches call it by this
// name; do not invent a second helper or paste raw Uuid() calls.
// Sibling DIRECTORY, bounded-length NAME: the rename must stay on one
// volume (hence the same parent), but suffixing the full target name
// would push a legal-but-long basename (POSIX NAME_MAX is 255 bytes)
// past the limit and make exactly those files unsavable — so the temp
// name is the recognizable prefix plus the uuid, never the target's
// own name (crash sweeps match the same `.poltergeist-*.tmp` pattern).
final tmp = File(
    p.join(target.parent.path,                 // package:path as p —
        '.poltergeist-${uuidV4()}.tmp'));      // manual '/' yields mixed
                                               // separators on Windows and
                                               // '//' for a root parent
try {
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(target.path); // atomic on POSIX; best-effort
                                 // replace on Windows (MoveFileEx) —
                                 // journal recovery absorbs a torn one
} on Object {
  // A failed write must not leave temp siblings beside live stores —
  // and cleanup is best-effort only: it must never mask the original
  // failure with its own.
  try {
    if (await tmp.exists()) await tmp.delete();
  } on Object {
    // swallow: the rethrow below carries the failure that matters
  }
  rethrow;
}
```

(`flush: true` fsyncs the file, not the directory entry — the rename is
atomic but not crash-*durable*; the journals' recovery rules (03 §4.6)
are what absorb a lost-on-power-cut rename, so no store claims more than
that.)

### 3.7 Per-platform key chords bound doubly

Every shortcut in the 02 §8.3 table is registered through the command
registry (D21) and bound in **both** its macOS and its Windows/Linux form —
Séance's `AppMenus` lesson: on macOS the native menu owns the ⌘ chord, so
the in-app binding must also carry the Ctrl variant or the other desktops
get nothing. The registry expands one declaration into both activators;
hand-written one-platform bindings are rejected.

```dart
// One AppCommand declaration (02 §8.1's shape) is the whole registration:
// menu items, palette rows, and Shortcuts bindings all derive from it, and
// its activators callback expands the one chord into BOTH the
// SingleActivator(meta:) and the SingleActivator(control:) form.
AppCommand(
  id: 'tab.new',
  label: (l10n) => l10n.tabNew,
  scope: CommandScope.app,
  activators: (platform) => primaryChord(platform, LogicalKeyboardKey.keyT),
  enabled: (ctx) => true,
  run: (ctx) => ctx.workspace.newTab(),
);
```

## 4. Ported-code rules

The mechanics live in 03 §8; the porting-back flow in 04 §6. Operationally:

1. **Every file copied from Séance gets a `docs/PORTS.md` entry in the same
   PR** (source path, Séance commit + tag, date, divergences, port-back
   candidates — format in 03 §8.2), plus the one-line attribution header in
   the file. The source file's tests are ported in the same PR.
2. **Behavioral changes to ported files need a stated reason** recorded in
   the entry's `Divergences` line, and a note whether the change should flow
   back to Séance (`Port-back candidates`). An unrecorded divergence is a
   review blocker (03 §8.3). Bug fixes go upstream first when feasible.
3. **On every Séance pin bump**, re-diff each ported file against its source
   between the old and new pinned commits; apply relevant upstream fixes and
   refresh the recorded commit (03 §8.3, milestone chore 07 §3.12).
4. **Never "simplify away" the documented API constraints.** These shaped
   the Séance code being ported; each looks like dead weight and is
   load-bearing (Séance AGENTS.md §6, referenced by 04 §1.3 and §6):
   - `cryptography` 2.9's `Hkdf.deriveKey` has **no `info` parameter** —
     domain separation between vault key and auth verifier is done with the
     distinct HKDF salts `seance/v1/vault-encryption-key` /
     `seance/v1/auth-verifier`. Argon2 `memory` is in KiB. Sealed blobs are
     `nonce(24) || ciphertext || mac(16)`.
   - dartssh2's `onVerifyHostKey(type, fingerprint)` hands the **SHA-256
     fingerprint string as bytes, not the raw host key** — which is why
     `HostKey` is identified by `fingerprintSha256` and `publicKeyBase64`
     only exists after a known_hosts import.
   - dartssh2 does **not export `SSHUserInfoRequest`** from its barrel — the
     keyboard-interactive handler's lambda parameter type stays inferred;
     writing the type breaks the build.
   - Dart `RegExp` has **no inline `(?i)` flag** — use
     `caseSensitive: false`; a pattern ported with an inline flag throws
     `FormatException` at construction (never a quiet case-sensitive
     match — the pinned test asserts the throw, not a non-match).
5. **Never diverge on the shared safety protocols** — the
   `DartSshRemoteFileSystem` transfer/hash protocols (03 §2.1) and the
   crypto/wire contracts of 04 §1.3. A change there goes upstream or not at
   all (D18).

## 5. Definition of done — any PR

A PR merges only when all of these hold:

- [ ] **Tests cover the new behavior** — engine logic as pure `test()`s,
      UI behavior as widget tests with injected fakes, per 08's strategy.
      A bug fix includes the regression test that fails without it.
- [ ] **Budgets not regressed.** The D12 benchmarks that exist for the
      touched surface still pass in CI (08); a PR that introduces a new
      D12-budgeted surface adds its benchmark in the same milestone
      (07 §1 — M9 is an audit, not a rescue).
- [ ] **`dart analyze` clean** on the explicit paths of §2, and CI fully
      green (Dart job now; Flutter + client matrix once the app exists).
- [ ] **docs/STATUS.md updated** (§1 rule 5).
- [ ] **PORTS.md updated** if any ported file was added or edited (§4).
- [ ] **Screenshots in the PR description for any UI change** — the
      affected surface before/after, light theme at minimum, captured from
      a real run (`flutter run -d linux` in the dev container works).
      Reviewers of a polish-first product (R1) review pixels, not just
      code.
- [ ] **Plan consistency**: if the implementation deviated from the chapter,
      the same PR edits the chapter (and 00 if a decision changed — §8.3);
      silent drift is a defect.
- [ ] Commit hygiene per §2 (trailer, session link, no model identifiers).
- [ ] **If this PR bumps a dependency:** the pinned tests for the §4
      item-4 constraints still pass — one per testable constraint (HKDF
      salt domain separation, Argon2 `memory` in KiB, the
      `nonce(24) || ciphertext || mac(16)` sealed-blob layout, dartssh2
      fingerprint-bytes semantics, inline RegExp flags throwing at
      construction; the barrel-export constraint is compile-time and
      needs no test) — so an upgrade that silently invalidates an
      assumption fails CI instead of relying on review memory.

## 6. What never to do — hard rules

Each of these is a standing decision; violating one is not initiative, it
is a plan violation. Changing any requires a 00 edit with rationale first.

1. **No new filesystem abstractions** (D3). `RemoteFileSystem` is the one
   VFS for panes, queue, and sync. No `FileSystemLike`, no `SyncFileSystem`,
   no "small internal interface just for this feature".
2. **No second sync engine and no rsync execution** (D6). The native engine
   is the only executor; rsync exists solely as the "Copy as rsync command"
   clipboard exporter (05 §2). Never shell out to rsync, and never bypass
   the in-app auth/TOFU stack with an external transport.
3. **No crypto changes** (D18). No new algorithms, parameters, layouts, or
   per-attribute encryption; the Séance vault/sync crypto is inherited
   unchanged. There is no "small tweak" in this category.
4. **No telemetry, no crash reporting, no accounts, no phoning home**
   (D19). The update check stays link-only. Adding any network call that is
   not user-initiated file/sync traffic is out.
5. **No unguarded deletes.** Every delete path goes through the D15 trash
   story or an explicit confirmation that quantifies what is lost (02 §10);
   sync deletions ride the plan's safety rails (05 §8). No code path may
   remove user data as a side effect.
6. **No silent uploads on external-editor saves** (06 §4.4). The watcher
   prompts (`…changed locally. Upload it?`); the built-in editor's save
   shortcut (⌘S / Ctrl+S) is the only implicit save-and-upload. Do not add
   an "auto-upload on save" setting in v1.
7. **No blocking the UI isolate with hashing, scans, archive work, or
   transfer I/O** (D8). Sockets live in the engine isolate; CPU-heavy work
   runs in workers; the UI isolate holds view state only.
8. **Never push to a Séance shared account unless every install reading it
   meets `kMinimumSharedAccountSeanceVersion`** (D4; before PR-S1 ships this
   can never hold, so Design B is the default). PR-S1 *shipping* does not by
   itself make shared pushes safe — an un-patched install still on the
   account bricks its sync or spawns phantom servers when it reads a
   `bookmark` record — so the precondition is per-install version coverage,
   confirmed by the user (04 §4.2); the gate is code, not documentation.
9. **Never fork `seance_core`/`seance_protocol`** (D2). Depend on git pins
   only — normally an upstream tag; a stalled upstream PR means pinning to
   a specific rev instead (07 §6 risk 4, and the §1 gate table's "tag
   preferred, rev permitted"). Never a fork, and never a copied-in version
   of the source.
10. **Never build D25 parking-lot or fast-follow items before v1.0**
    (07 §3.13). Two-way sync with baseline DB, resume, drag-out, archives,
    S3/WebDAV, multi-window — building them early is a plan violation.

## 7. Working with the GLM review workflow

Every non-draft PR from a same-repo branch gets an automated GLM review
(`.github/workflows/zai-code-review.yml`). The full policy lives in
[CLAUDE.md](../../CLAUDE.md) and is binding; the operational summary:

- On opening a PR: subscribe with `subscribe_pr_activity` immediately and
  arm an hourly `send_later` self check-in (webhooks miss CI successes,
  new pushes, and merge-conflict transitions).
- Triage **every** finding into exactly one bucket (a single comment may
  bundle several): **apply** (real bug or
  improvement), **decline with recorded reasons** (commit message + chat),
  **refute with evidence** (official docs, actual CI runs, the code)
  when a claim is factually wrong, or **defer** (valid but out of the
  PR's scope — recorded as a follow-up suggestion, the CLAUDE.md
  steady-state rule's third condition). Verify factual claims against primary
  sources first; never apply a change just to appease the reviewer — this
  plan's decisions (00) outrank review suggestions, and a suggestion that
  contradicts a Dn is declined by citing it.
- Never flip-flop: keep a running list of declined items and reasons **in
  the PR description** (one line per item, updated as triage happens — chat
  is ephemeral and commit messages are scattered, so a later round can
  prove a re-raise is evidence-free against a durable, linkable list); a
  declined item is re-opened only on genuinely new evidence.
- Declare **steady-state** and stop when **either** (a) two consecutive
  rounds yield no valid actionable findings, **or** (b) a round's only
  content is the reviewer re-raising already-declined items **without new
  evidence**, contradicting itself, or leaving nothing but out-of-scope
  items — a re-raise that carries genuinely new evidence re-opens the item
  per the no-flip-flop rule and does not end the review. At
  steady-state: post the short scorecard (applied / declined / refuted /
  deferred — one line per bucket above), state
  merge-readiness, `unsubscribe_pr_activity`, delete the check-in triggers.
- Exceptions: human reviewers are never subject to the steady-state
  cutoff; on merge/close or when the user says stop, always run the **full
  teardown** — `unsubscribe_pr_activity` **and** deleting the check-in
  triggers (most PRs exit via merge rather than steady-state, so the merge
  path must not leave orphaned hourly check-ins firing after the PR is
  gone).
- A **stalled** PR (neither merged, closed, nor at steady-state, with the
  author gone quiet) gets the same teardown: after 7 days with no PR
  activity, run the full teardown — `unsubscribe_pr_activity` **and**
  delete the check-in triggers — and record the PR in STATUS.md's open
  items. A check-in must not outlive the work it was armed for.

## 8. When stuck

### 8.1 Record the question, take the least-blocking path

When something is genuinely unresolved — a plan gap, an upstream surprise,
a measurement contradicting an assumption — do not stall and do not guess
silently:

1. Add a dated entry to STATUS.md's open items: the question, what it
   blocks, the option chosen meanwhile.
2. Proceed on the **least-blocking path**: the option that is additive and
   reversible, keeps `main` green, and does not touch a shared contract.
   Prefer feature-flagging or leaving a seam (`// OPEN(status):` comment
   pointing at the STATUS entry) over inventing a design.
3. Resolve the entry in a later PR and delete it from STATUS.md.

### 8.2 When to update the plan instead of the code

Update the plan first — never bend the code quietly — when:

- code reality contradicts a chapter (00's header rule: stop, plan-edit PR,
  then implement);
- a measurement invalidates a stated number (M0's report already has this
  duty for `PoolPolicy` and scan depth — the same applies anywhere);
- a chapter is ambiguous enough that two readings produce different code —
  ambiguity is a defect in the plan, so fix the chapter in the same PR as
  the implementation it unblocked.

Chapter edits state what changed and why in the PR description.

### 8.3 Decision-log edits are exceptional

Changing anything in 00's decision log requires editing 00 **with explicit
written rationale in the same PR** as the change it enables. Pre-authorized
fallbacks (the D9 ladder rungs 3–5, the 07 §6 cut lines) still require the
00 edit — pre-authorization opens the discussion, it does not waive the
paper trail. A PR that needs a 00 edit is by definition one the user should
see clearly: title it as a decision change, not a feature.

## Definition of done

- [ ] This playbook is referenced from STATUS.md's next-steps note once
      implementation starts, and every implementation PR description links
      the milestone it serves (§1).
- [ ] The §3 idioms are enforced in review from the first controller PR:
      at least one review round has rejected or required changes citing
      §3.1–§3.7 rules, or the controller PR's description cites the §3
      idioms it applies — linkable, spot-checkable evidence, like every
      other item here; a bare "the code follows them" satisfies
      nothing.
- [ ] `docs/PORTS.md` exists from the first ported file, and every entry
      matches the 03 §8.2 format with `Divergences` and `Port-back
      candidates` lines (§4).
- [ ] Every merged PR since implementation start satisfies the §5
      checklist (spot-checkable: STATUS diffs, screenshots on UI PRs,
      green CI history).
- [ ] No violation of the §6 hard rules exists on `main` (spot-checkable:
      CI or a scripted check guards the mechanically-checkable rules — no
      `rsync` process spawn, no telemetry/crash-reporting dependency — and
      each merged PR's review confirms its touched surfaces against §6; a
      bare assertion satisfies nothing, like every other item here).
- [ ] The D4 shared-account gate is enforced in code before any sync
      feature ships (a temporal gate checked at shipping time — split
      from the standing invariant above so each is attestable on its
      own evidence).
- [ ] GLM review rounds on merged PRs show the §7 triage discipline
      (scorecards at steady-state; no flip-flops).

## Explicitly out of scope

| Item | Where it lives |
|---|---|
| Milestone contents, order, exit criteria | 07 (this chapter only tells you to follow them) |
| Test strategy, fakes, benchmark harness, sshd matrix | 08 (the §5 checklist consumes its gates) |
| Ported-file ledger format and pin mechanics | 03 §8 (restated operationally here) |
| Porting-back flow and upstream PR specs | 04 §5–6 |
| The decisions themselves | 00 — this chapter never overrides a Dn |
| CI/release workflow maintenance details | AGENTS.md §2 and the 07 §4 distribution track |
