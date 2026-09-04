# 03 — System architecture

This chapter fixes the technical skeleton: packages and dependency rules, the
single filesystem abstraction, the connection layer, the transfer queue, the
isolate split, app-state composition, the platform seams, and the mechanics of
sharing code with Séance. It elaborates the decision log in
[00-OVERVIEW.md](00-OVERVIEW.md); where a statement carries a decision number,
that decision is the authority. File references like
`packages/seance_core/lib/src/ssh/remote_file_system.dart` point into the
sibling Séance repo, the reference implementation for everything ported.

## 1. Package map and dependency rules (D2)

Repository tree after M1 (app scaffolded, core packages real):

```
pubspec.yaml                  pub workspace root — members are pure-Dart only
packages/
  poltergeist_core/           pure Dart: LocalFileSystem adapter, local-safety
                              helpers, ConnectionManager + per-server pool,
                              TransferQueue engine, bookmark model +
                              coordinator seam, engine-isolate protocol
  poltergeist_sync/           pure Dart: sync scan/diff/plan/executor/journal
                              + "Copy as rsync command" exporter (05)
app/
  poltergeist_app/            Flutter app — UI, controllers, platform channels,
                              ported Séance app-layer services (PORTS.md)
docs/plan/                    this plan
docs/PORTS.md                 ledger of code copied from Séance (§8.2)
docs/STATUS.md                live progress
scripts/                      build.sh, release.sh, package-linux.sh (exist)
```

`app/poltergeist_app` is **not** a workspace member (see §9 for the actual
tooling constraint — not a general pub rule, since Dart 3.6+/Flutter 3.27+
workspaces do allow Flutter-SDK members). It path-depends on `poltergeist_core`
and `poltergeist_sync`.

Dependency rules, enforced by a **CI import check** (fails on a `dartssh2`
import outside `poltergeist_core/lib/src/connection/`, on any Flutter/plugin
import in the pure-Dart packages, and on any direct `dartssh2` import in
`poltergeist_sync` or the app — the exact edges are enumerated below, so the
check is mechanical) and re-checked in review:

| Package | May depend on | Must never depend on |
|---|---|---|
| `poltergeist_core` | `seance_core` (git pin, §8.1), `seance_protocol` (via `seance_core`'s barrel re-export), `dartssh2` (connection module only), `crypto`, `meta`, `path` | Flutter, any plugin |
| `poltergeist_sync` | `poltergeist_core`, `seance_core` | Flutter, `dartssh2` directly |
| `app/poltergeist_app` | both local packages, `seance_core` neutral exports, Flutter plugins | `dartssh2` — **ever** |

The "UI never sees dartssh2" boundary is Séance's, kept intact (its barrel
`packages/seance_core/lib/seance_core.dart` deliberately hides
`DartSshRemoteFileSystem` behind a `show` list). Poltergeist extends the rule
one level: dartssh2 types stop inside `poltergeist_core`'s connection module.
`poltergeist_core`'s own barrel exports only neutral types — `RemoteFileSystem`
(re-exported), `LocalFileSystem`, `ConnectionManager`, `TransferQueue`, task
and bookmark models. The app and the sync package see paths, streams,
`RemoteFileEntry`, and typed `RemoteFileException`s, nothing lower. The CI
import check above enforces this containment mechanically — a stray
`import 'package:dartssh2/...'` anywhere outside
`poltergeist_core/lib/src/connection/` fails the build — because a
review-only rule on the single most load-bearing architectural invariant
reliably decays.

Ported Séance app-layer services (atomic-file helpers, checkout store, editor
stack, `EditorRegistry`, toast system, `MiddleEllipsisText`, adaptive layout
math — the D2 copy-with-attribution list) land under
`app/poltergeist_app/lib/services/` and `lib/ui/`, mirroring where they live
in Séance, each with a PORTS.md entry (§8.2).

## 2. The one VFS (D3)

### 2.1 RemoteFileSystem, kept as-is

`seance_core`'s `RemoteFileSystem` interface (from
`packages/seance_core/lib/src/ssh/remote_file_system.dart`) is the only
filesystem abstraction in Poltergeist: panes, the transfer queue, and the sync
engine all operate on it. Its companions come along unchanged:
`RemoteFileEntry`, `RemoteFileType`, `RemoteFileException` /
`RemoteFileErrorKind`, `RemoteTransferProgress`, `RemoteTransferCancellation`,
and the pure path helpers `remoteJoin` / `remoteBasename` / `remoteParent`.
No wrapper, no second interface, no "FileSystemLike" — D3 forbids it.

The dartssh2 adapter's safety protocols are inherited verbatim and must not be
re-implemented differently: download's double-stat + short-read check + final
re-stat; upload's exclusive sibling temp + second preflight +
compare-and-swap-with-hash via `expectedTarget`; sticky cancellation raced
against every stream pull. Séance's `docs/SFTP.md` records why each exists.

### 2.2 LocalFileSystem adapter

`poltergeist_core/lib/src/fs/local_file_system.dart` provides
`class LocalFileSystem implements RemoteFileSystem` over `dart:io`. The
interface is genuinely transport-neutral, so the mapping is direct:

| Method | dart:io implementation | Caveats |
|---|---|---|
| `canonicalize` | `resolveSymbolicLinks()` when the path exists; otherwise return the normalized absolute path | never throws just because the path is missing (matches realpath use for home resolution); "home" = the user home via the ported `expandHomePath` |
| `listDirectory` | `Directory(path).list(followLinks: false)`; classify each entry from the listed entity's own runtime type (`entry is Link`/`Directory`/`File` — `followLinks: false` already reports a symlink as a `Link` instance, so no extra per-entry `FileSystemEntity.type` lstat is needed) and stat only non-link entries — links report `type: symbolicLink` with `size`/`modifiedAt` null, matching the `stat` row below (a plain `FileStat.stat` would follow the link and report the target's identity) | `FileStat.mode` is synthetic on Windows — populate it best-effort, never render it as authoritative there |
| `stat` | `FileStat.stat` when `followLinks: true`; with `followLinks: false`, detect symlinks via `FileSystemEntity.type(path, followLinks: false)` | dart:io has no lstat: for a symlink itself, return `type: symbolicLink` with `size`/`modifiedAt` null — callers already treat those as optional; `FileStat.stat` and `FileSystemEntity.type` never throw for a missing path — they return `FileSystemEntityType.notFound` with null fields instead, so `stat` must translate that return value into a thrown `RemoteFileException(notFound)` itself (the funnel below only ever sees thrown exceptions, so a literal reading would return a phantom entry with null metadata instead) |
| `setMode` | refuse symlinks first (lstat-style type check, exactly like the adapter), then `Process.run('chmod', ['--', octal, path], environment: {...Platform.environment, 'LC_ALL': 'C'})` on macOS/Linux — `--` so a path beginning with `-` can never parse as an option, and `LC_ALL=C` (spread the inherited environment so `PATH` survives) so stderr is deterministic English regardless of the user's locale, since chmod localizes via `strerror`; a non-zero exit code routes through the §2.2 funnel (`Process.run` failures arrive as exit codes, or as a thrown `ProcessException` when the binary cannot be launched — the guard catches it and maps it to `other`; exit 1 maps by the trailing strerror segment after the final `': '` in the stderr line — **never a substring match across the whole line**, since chmod embeds the user-controlled path in that same line and a file legally named e.g. `Operation not permitted` would otherwise misclassify by matching its own name: `Operation not permitted`/`Permission denied` maps to `permissionDenied`, mirroring `setOwner`'s EPERM translation, and `No such file or directory` maps to `notFound` — the chown path uses the same `LC_ALL=C` environment and trailing-segment match) | Windows: throw `RemoteFileException(unsupported)` so the permissions UI hides itself for local Windows panes (D28) |
| `readSymbolicLink` | `Link(path).target()` | |
| `createSymbolicLink` | exists-preflight (conflict), then `Link(linkPath).create(targetPath)` | Windows needs Developer Mode or elevation — map the OS error to `permissionDenied` with a hint in the message |
| `createDirectory` | `Directory(path).create(recursive: false)` | parent must exist — same as SFTP mkdir |
| `rename` | preflight destination lstat; `overwrite: false` + existing ⇒ `conflict` before any change; then `rename()` | Windows rename-over-existing may fail: with `overwrite: true`, fall back to the `replaceLocalFile` backup-rename dance (§2.3) — target → sibling temp, source → target, restore on failure, delete temp only after success — **never delete-then-rename**, which strands the user with neither file when the second step fails; case-only renames on case-insensitive filesystems go through a temporary sibling name (two-step), per D26; dart:io `rename()` exposes no overwrite/CAS flag, so the lstat preflight is advisory — a destination appearing between the lstat and the rename is silently replaced on POSIX — accepted as deliberate parity with the SFTP adapter's own preflight, unlike `upload`'s `expectedTarget` CAS |
| `delete` | `File`/`Link.delete`, `Directory.delete(recursive: false)` | non-empty directory error keeps Séance's wording ("Only an empty directory can be deleted.") — matched explicitly by errno, since it is neither of the two codes the general funnel below maps: ENOTEMPTY (39) on macOS/Linux, `ERROR_DIR_NOT_EMPTY` (145) on Windows, plus EEXIST on any platform whose `rmdir` reports it that way for a non-empty directory (caught here before the funnel's global EEXIST→`conflict` rule below would misclassify it); recursion stays app-level |
| `download` | stream `File.openRead()` through the same cancellation racer, tee into chunked SHA-256; stat before and after, mismatch ⇒ `conflict` | keep the integrity protocol — it is cheap locally and makes local and remote sources behaviorally identical to the queue and sync engine |
| `upload` | create the exclusive sibling `.poltergeist-<8 hex>.tmp` via `File.create(exclusive: true)` (dart:io's own opened-for-writing `File.open`/`FileMode.write` has no `O_EXCL` semantics — it creates-or-truncates unconditionally; `exclusive: true` is the only dart:io primitive that actually refuses an existing path, completing with `PathExistsException` instead, so on that rare collision regenerate the random suffix and retry), then open it for writing, hash chunks, verify declared length, chmod `preserveMode` on Unix, then commit via `replaceLocalFile` (§2.3) | same preflight/`expectedTarget` CAS semantics as the adapter; temp always cleaned up on failure |

Every error is translated through one funnel (the `_guard` pattern from the
adapter): `PathNotFoundException` → `notFound`, and — since dart:io is
inconsistent about which operations raise that typed exception versus a
plain `FileSystemException` carrying the errno in `OSError.errorCode`
(`Directory.create` with a missing parent, `File.delete`/`Link.delete` on
a vanished path, and `rename` with a missing source all throw the plain
form) — `FileSystemException` with errno ENOENT (2) also → `notFound`,
and EEXIST (17) → `conflict` (closing the exists-preflight gap for
`createSymbolicLink`: a `Link.create` racing an external create throws
this plain form, not `PathNotFoundException`'s sibling), keyed off the
errno rather than the exception type; `FileSystemException` with
EACCES/EPERM → `permissionDenied` — on Windows, match the raw Windows
error codes instead (`OSError.errorCode` carries `GetLastError` values
there, never POSIX errnos: 2 `ERROR_FILE_NOT_FOUND` / 3
`ERROR_PATH_NOT_FOUND` → `notFound`, 183 `ERROR_ALREADY_EXISTS` →
`conflict`, 5 `ERROR_ACCESS_DENIED` → `permissionDenied`;
32 `ERROR_SHARING_VIOLATION` → `other` with an explicit "file is in use
by another process" message — a lock, not a permission denial, and the
`replaceLocalFile` rename dance hits it when the target is open in
another app). Windows error codes not in that map fall through to the
generic funnel — cancellation → `cancelled`, the rest →
`other`, message format `'Could not <op> "<path>": <detail>'`. Temp-file
prefixes are `.poltergeist-` everywhere Séance uses `.seance-` (the research
notes flag the prefix as the one thing to parameterize).

`LocalFileSystem` also implements the D3 additive methods from day one —
`setTimes` — gated on the same refuse-symlinks-first check as
`setMode`/`setOwner`, since `setLastModified` dereferences and would
write a synced tree's mtime through a link to its target — maps to
`File.setLastModified` (and `setLastAccessed`) for
**files**; a directory target succeeds on POSIX (`File.setLastModified`
bottoms out in `utimensat`, a path-based syscall with no regular-file
restriction) and fails on Windows, whose implementation opens the path and
cannot open a directory that way — surfacing as `ERROR_ACCESS_DENIED`,
which the funnel above would otherwise translate to `permissionDenied`,
not the promised `unsupported`, so `setTimes` pre-checks the entry type
(`FileSystemEntity.type(path, followLinks: false)`) and throws the typed
`unsupported` itself for a directory target on Windows, never relying on
the OS error translation to get there — which costs the sync engine
nothing either way: it compares directories by existence only and never sets their
times (05 §4). `setOwner`
maps to `Process.run('chown', ['--', spec, path], environment:
{...Platform.environment, 'LC_ALL': 'C'})` on Unix — **after
the same refuse-symlinks-first check as `setMode`**: a bare `chown`
dereferences a symlink and changes the *target's* owner, so an
attribute write inside a synced tree could otherwise escape it through
a link, breaking both the adapter parity rule and the refuse-first
convention one paragraph up (`-h` is reserved for if link ownership is
ever supported) — with EPERM (the normal non-root
outcome) translated to `permissionDenied` through the §2.2 funnel,
like every other non-zero exit code — and
`unsupported` on Windows. So the sync
engine's local half never waits on the upstream PR (§2.4). Like the
`rename` preflight, the refuse-symlinks-first check is advisory, not
atomic: a path swapped to a symlink between the check and the
`chmod`/`chown`/`setLastModified` exec is dereferenced. The decision:
re-stat (lstat-style, `followLinks: false`) after the operation and fail
the write — mapped to a distinct `pathTypeChanged` error (carrying the
dereferenced target path the write actually landed on, so the user can
inspect it), never `conflict`: by the time this re-stat fires, the
chmod/chown/setLastModified has already been applied through the
swapped-in symlink to *its* target, potentially outside the synced tree
entirely — a safety violation, not "both sides changed" the way §4.2's
content `conflict` means it, and automated conflict resolution must
never auto-accept this the way it may resolve a genuine `conflict` —
when the entry type no longer matches what
the refuse-first check saw; the residual window between the write and
that re-stat is what's accepted, as the `rename` row does, not the
whole check-then-act race.

### 2.3 Local-safety helpers become public utilities

Séance's `RemoteFilesController` holds four private statics that took real
care to get right (see the research verdict: "do NOT re-implement
differently"). Port them into
`poltergeist_core/lib/src/fs/local_fs_safety.dart` as **public** functions,
with their Séance tests carried over:

- `replaceLocalFile(File part, File target)` — the backup-rename dance:
  refuse replacing links/non-regular files — the check itself must not
  follow links (`FileSystemEntity.type(path, followLinks: false)`), or a
  symlink to a regular file passes a stat-based "is regular" test and the
  replace silently swaps the user's link for a plain file; rename target → a unique
  `<target>.poltergeist-<8 hex>.backup` sibling — the target's own name
  stays embedded in the backup name so a crash-recovery sweep can strip
  the suffix and find what to restore (never a fixed `.backup`, which the
  temp-prefix policy §2.2 states and which would clobber a pre-existing
  user `<target>.backup`; if the suffixed name would exceed the
  filesystem's NAME_MAX, fail the replace rather than silently truncate
  it into a collision), part →
  target, restore backup on failure, best-effort delete backup. A crash
  or power loss between the two renames strands the data in the hidden
  backup with the target missing — an orphaned
  `*.poltergeist-<8 hex>.backup`
  whose target (its own name with that suffix stripped) is absent means
  an interrupted replace, and the next
  touch of that directory (or a startup sweep) restores it before any
  new replace runs, rather than leaving the user's file looking deleted.
- `ensureSafeLocalDirectory(String path)` — create parents while refusing to
  traverse through symlinks or non-directories (`followLinks: false` at every
  component).
- `validateLocalName(String name)` — Windows reserved names (`CON`, `PRN`,
  `AUX`, `NUL`, `COM1`–`9`, `LPT1`–`9`, plus `CONIN$`/`CONOUT$`) matched
  by **base name** — the segment before the first dot — not exact match,
  since Windows reserves the name regardless of extension: `NUL.txt` and
  `Com1.tar.gz` are just as invalid as the bare names, forbidden
  characters, trailing dot/space.
- `validatePathComponent(String c)` — no empty, `.`, `..`, `/`, `\`,
  NUL. Backslash is rejected everywhere on purpose: it is a legal
  filename character on POSIX remotes but the path separator on a
  Windows client, so a server-reported name like `..\..\x` that passes
  a `/`-only check becomes traversal the moment a Windows build joins
  it into a local path (09 §3.5 applies the same rule for the same
  reason).

They are used by `LocalFileSystem.upload`, the transfer queue's download
executor, the checkout store, and the sync executor — one implementation, four
call sites.

### 2.4 Upstream additive methods and what blocks on them

D3 schedules one small additive Séance PR (sequenced in 04 §upstream) adding
to `RemoteFileSystem`:

| Addition | Signature sketch | What blocks on it |
|---|---|---|
| set timestamps | `Future<void> setTimes(String path, {DateTime? accessedAt, DateTime? modifiedAt})` | the **sync engine** (05) — hard prerequisite for convergence; also "preserve mtime on transfer" |
| set ownership | `Future<void> setOwner(String path, {int? uid, int? gid})` | the chown/chgrp UI (D28) — ships only after the pin containing it |
| optional hashing | `bool computeHash = true` parameter on `download`/`upload` | D7's opt-in "verify after transfer" policy for bulk work; pins before this addition necessarily retain always-on SHA-256 |

Ranged read is deliberately absent: D3 defers it to D25's
resumable-transfer work as its own upstream PR at that time — nothing in
v1 exercises it, and the pre-sync PR stays minimal.

Until the Séance pin is bumped past that PR, remote callers simply do not call
these methods; `poltergeist_sync`'s remote milestone (07) explicitly gates on
the pin bump. The checkout/edit pipeline keeps mandatory hashing regardless
(D7 — it is the conflict authority).

## 3. Connection layer (D5)

### 3.1 The `openAuthenticatedClient` extraction contract

One upstream Séance refactor (D5, sequenced in 04): extract from
`SshSessionManager.connect` (in
`packages/seance_core/lib/src/ssh/ssh_session.dart`) everything up to but
excluding `client.shell(pty:)`:

```dart
// Upstream, in seance_core. Behavior byte-identical to today's connect()
// through the authentication step.
// Returns the client plus how auth resolved — key, storedPassword,
// keyboardInteractive, or promptedPassword (AuthKind). Callers that pool
// connections can use it to cap or allow growth; Séance's recomposed
// connect() discards it.
Future<(SSHClient, AuthKind)> openAuthenticatedClient({
  required ServerConfig config,
  required SshCredentials credentials,
  required TofuVerifier tofu,
  required HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  Future<SSHSocket> Function(String, int, Duration)? connect, // test seam
  Duration timeout = const Duration(seconds: 15),
  SshConnectionLog? log,
});
```

It carries the agent-method rejection, PEM key loading with per-key
fingerprint logging, TCP connect, `SSHClient` construction (TOFU verify
callback, password request, keyboard-interactive responder, debug/trace into
the log), and on failure the `_summarizeFailure` machinery producing the
actionable one-liner. Séance recomposes `SshSessionManager.connect()` as
`openAuthenticatedClient` + shell/PTY/login-script — behavior unchanged, tests
unchanged. Poltergeist never opens a shell channel at all: `client.sftp()`
works without `client.shell()`.

### 3.2 ConnectionManager and the per-server pool

`poltergeist_core/lib/src/connection/connection_manager.dart`, living in the
engine isolate (§5). The `serverId` strings below are bookmark-derived
identities — their semantics are fixed in §3.5:

```dart
abstract interface class ConnectionManager {
  /// One dedicated SFTP browse channel per pane-tab. Listings stay snappy
  /// while transfers saturate other channels — except on
  /// interactive-auth servers, where the single-transport cap (growth
  /// rule 2) shares one TCP connection and saturation slows listings:
  /// the accepted D5 cost, stated here because this comment ships in
  /// the interface. `paneTabId` keys the
  /// channel, so two tabs browsing the same server each get their own;
  /// the tab closes its channel via PaneChannel.close() (below) when it
  /// closes or navigates off the server.
  ///
  /// Budget exhaustion (every transport at `maxChannelsPerTransport`):
  /// attempt transport growth first where growth rule 3 allows it; where
  /// it doesn't (interactive-auth pools capped at one transport by rule
  /// 2, or a non-interactive pool already at `maxTransports`), this
  /// never fails and never blocks the caller — it re-uses the channel of
  /// the least-recently-used backgrounded pane-tab on an existing
  /// transport, the same queue-don't-fail guarantee growth rule 4
  /// already makes for the interactive-auth case, generalized to every
  /// exhaustion path so a many-tab workload never surfaces a raw
  /// channel-open failure or a hang.
  Future<PaneChannel> openBrowseChannel(String serverId,
      {required String paneTabId});

  /// A transfer worker borrows a channel; releasing it returns it to the
  /// pool. Blocks while the pool is at capacity.
  Future<TransferChannelLease> leaseTransferChannel(String serverId);

  Stream<ServerConnectionState> watchServer(String serverId);
  Future<Set<String>> connectedServerIds();  // feeds ProbeService (§3.4);
                                             // served across the engine
                                             // isolate (§5) — the app-side
                                             // proxy keeps a cached replica
                                             // fed by watchServer for the
                                             // probe loop's sync reads
  Future<void> disconnectServer(String serverId);
}

abstract interface class PaneChannel {
  RemoteFileSystem get fs;     // its own DartSshRemoteFileSystem instance
  String get homePath;         // canonicalize('.') at open, Séance-style
  Future<void> close();
}

abstract interface class TransferChannelLease {
  RemoteFileSystem get fs;     // the leased transfer channel's adapter
  Future<void> release();      // returns the channel to the pool
}

enum ServerConnectionState {
  connecting, connected, reconnecting, disconnected, blocked,
}
```

Behind each `serverId` — via its endpoint-keyed pool (§3.5), shared by every
`serverId` at that endpoint — sits one or more authenticated `SSHClient`
transports, each carrying SFTP channels (`client.sftp()` opens a fresh channel
per call — Séance caches one per session as policy; Poltergeist opens
several). Pool policy constants live in one file,
`connection/pool_policy.dart`, with D9's defaults:

```dart
class PoolPolicy {
  final int maxTransports;                    // default 2
  final int maxTransferChannelsPerTransport;  // default 4
  final int maxChannelsPerTransport;          // default 8 — OpenSSH's
                                              // MaxSessions defaults to 10
                                              // session channels per TCP
                                              // connection, and every SFTP
                                              // channel (browse and transfer
                                              // alike) is one; browse +
                                              // transfer share this budget.
  final Duration keepAliveInterval;           // 30 s
  final Duration idleExtraTransportTimeout;   // 60 s
  final Duration reconnectBackoffCap;         // 30 s
  final int taskRetryLimit;                   // 5
}
```

The `2 / 4 / 8` defaults reflect the empirical gates. Four transfer channels
beat three by 23.9% on LAN and were the shaped-link maximum; eight regressed
there, so eight remains the total channel ceiling rather than the transfer
default. Two transports retain the near-linear LAN gain; at four channels
each they already expose eight transfer slots, above the global dispatch cap
of six. Four authenticated transports therefore cannot raise v1 dispatch
concurrency.

Growth rules (the part that must never be improvised):

1. **The first connect is serialized.** One `openAuthenticatedClient` runs per
   **pool** (the §3.5 endpoint key, not per serverId — two bookmarks at
   one endpoint connecting simultaneously must fold into a single
   first connect, or each would run its own and double the TOFU prompt
   and the transport) at a time; nothing else starts until it
   succeeds. This is the TOFU
   single-prompt rule — a `firstUse` host key prompts exactly once, and pool
   growth afterwards verifies silently against the pinned key
   (`TofuVerifier.check` returns `trusted`). A `changed` verdict at any point
   hard-blocks the **entire pool and every serverId referencing it** —
   `watchServer` fans `blocked` out to all of them, or one bookmark
   would show blocked while a sibling at the same endpoint kept
   operating (never auto-repin — D18) — and aborts growth. `blocked`
   clears only through explicit user action, never automatically: the
   next connect attempt after the user reviews and accepts the changed
   key at the TOFU prompt re-pins it and re-runs the first connect, or
   the user removes the bookmark; a `blocked` pool with no user action
   stays blocked indefinitely.
2. **Interactive auth caps the pool at one transport.** Record how the first
   connect authenticated. If keyboard-interactive ran or a password was
   prompted interactively, `maxTransports` is effectively 1 — additional
   parallelism comes only from extra SFTP channels on that transport,
   which all share one TCP connection: on interactive-auth servers,
   listings can slow while transfers saturate that connection — the
   accepted cost that qualifies `openBrowseChannel`'s "listings stay
   snappy" comment, because D5's no-second-prompt rule outranks
   throughput. Never N
   parallel 2FA prompts (D5).
3. **Non-interactive auth may grow the pool** (key auth, stored password): up
   to `maxTransports`, reusing the resolved in-memory `SshCredentials` from
   the first connect — the secret lives only as long as the pool does.
   Growth connects run with prompting disabled
   (`onKeyboardInteractive: null`, no password prompt): a server that
   requires keyboard-interactive on every new TCP connection (not just
   the first) would otherwise pop a second, concurrent 2FA prompt from a
   background growth attempt, violating rule 2's no-second-prompt
   guarantee at the moment it matters most. A growth attempt that hits
   an auth challenge requiring interaction fails that attempt, records
   the pool as interactive-capped (rule 2 applies from then on), and
   falls back to sharing the existing transport's channels.
   Credential references are dropped when the **last** serverId referencing
   the pool disconnects (§3.5) — Dart `String`s cannot be securely zeroized,
   so this clears references rather than wiping memory — and the next first
   connect re-resolves from the vault (the app-exit wipe is best-effort only
   — crash and SIGKILL paths skip exit hooks, so retention is minimized); a
   reconnect
   that fails auth re-resolves through the vault/prompt
   path — and if that re-resolve prompts interactively, the pool's
   recorded auth mode updates to interactive, capping growth per rule 2
   from then on, so a server that switched to 2FA mid-session can never
   trigger a second prompt through later pool growth.
4. Transports are created on demand (a transfer lease that cannot be served by
   existing channels) and torn down when idle (§3.3). The first transport —
   the one carrying browse channels — stays as long as any pane-tab shows the
   server. When a transport reaches `maxChannelsPerTransport` (the
   MaxSessions ceiling), the next browse or transfer channel opens on another
   transport where rule 3 allows growth; on an interactive-auth pool capped
   at one transport, browse requests queue on the existing channels rather
   than failing a channel open — a many-tab workload never surfaces a raw SSH
   channel-open failure.

The queue-don't-fail rule covers capacity exhaustion, not unavailable SFTP.
If every attempted channel open fails and no live channel, pending open, or
transport growth can supply capacity, fail affected requests with the typed
open error; never wait for a release that cannot occur. A newly bound browse
channel immediately serves queued browse requests through LRU sharing,
including those behind transfer waiters: sharing consumes no transfer slot.

### 3.3 Keepalive, idle, reconnect

- **Keepalive:** `client.ping()` every `keepAliveInterval` on transports with
  no in-flight operation; a ping that times out (30 s operation timeout, same
  as the adapter's) marks the transport disconnected and closes it, so the
  reconnect path below — which fires on transport closure — triggers.
- **Idle:** extra transports (beyond the first) close after
  `idleExtraTransportTimeout` holding no channels at all — no leased
  transfer channel and no open browse channel either, since §3.2 rule 4
  can park browse channels on an extra transport once the first hits
  `maxChannelsPerTransport`, and those channels are never "leased" (only
  `leaseTransferChannel` grants a lease). The first transport
  follows pane lifetime, not a timer — but never closes while any of its
  channels is leased: with the last pane-tab gone, a leased first transport
  stays until its leases are released, so closing tabs cannot park a
  running transfer.
- **Reconnect:** on `RemoteFileErrorKind.disconnected` or transport closure,
  browse channels auto-reconnect: probe first with `TcpBannerProber` (cheap,
  keeps sshd logs quiet), then `openAuthenticatedClient` with backoff
  1 s → 2 s → 4 s → … clamped to `reconnectBackoffCap` **first**, then
  jittered downward only (`delay = min(base, cap) * (1 - 0.3 * random())`)
  — jittering an upward-only ±30% before clamping would clip every
  jittered delay to exactly `cap` once `base` reaches it, re-synchronizing
  every client's retries at the cap and recreating the thundering-herd
  effect jitter exists to prevent; downward-only jitter after the clamp
  never exceeds `reconnectBackoffCap` while still de-synchronizing
  retries at the cap (the probe
  service's hygiene rules). After reconnect the pane re-canonicalizes its
  current path and refreshes. Running **or scanning** transfer tasks on
  that server flip to
  `queued` with a retry counter incremented once per reconnect cycle —
  never per affected file, which would burn the limit in one flap. The
  counter counts *consecutive* failed cycles and resets once the task
  makes progress after a successful reconnect (a completed file, or
  scan entries flowing again) — recoverable blips spread over a long
  transfer must never add up to a permanent failure; after
  `taskRetryLimit` consecutive reconnect failures the task
  fails with the summarized error. A task caught mid-scan restarts its
  scan from scratch with `plan`, `totalBytes`, **and the progress
  counters `completedFiles`/`transferredBytes`** reset then recomputed
  from the §4.6 journal (leaving them stale against a reset `totalBytes`
  would break 02 §5.3's growing-`+` form; the walker is
  not resumable, and a partial re-count would double-count progress),
  not re-dispatching files the §4.6 journal already records under any
  terminal outcome — `fileCompleted`, `fileFailed`, or `itemRemoved`
  alike, not `fileCompleted` alone, or a skipped/failed item would
  re-dispatch and re-prompt on every restart — **with one carve-out: a
  failure classified `RemoteFileErrorKind.disconnected` is never
  journaled `fileFailed` in the first place** — it leaves the file
  pending and un-journaled so the post-reconnect restart re-dispatches
  it, since only a failure that survives a healthy connection earns the
  terminal record; without this carve-out, an in-flight operation that
  fails with exactly the error this whole reconnect mechanism exists to
  recover from could race the task-level flip to `queued` and get
  written as a permanent terminal failure, silently and permanently
  skipping a file whose only problem was the disconnect itself — and folding those
  journaled terminal outcomes into the recomputed progress the same way
  §4.1 already requires PlannedFile identity to (subtracting a skipped or
  failed item's scanned size from `totalBytes`, or tracking it in a
  side `skippedBytes`/`failedBytes` counter) so a heavily-skipped task's
  progress still converges to 100 % rather than stalling below `total`
  forever; user-`paused` tasks stay paused through a reconnect — the
  flip to `queued` applies only to running/scanning tasks. Séance's model (reconnect is replacement,
  user-initiated) is deliberately upgraded here — a transfer app must
  self-heal.

### 3.4 Probe integration

The ported `ProbeService`
(`packages/seance_core/lib/src/probe/probe_service.dart`) drives sidebar
status dots. `ConnectionManager` feeds it
`connectedServerIds` so servers with live pools are skipped and reported
online for free — same fail2ban-friendly philosophy as Séance: jittered
sweeps, ≤ 6 concurrent probes, pause when the app is hidden, tri-state
`online/offline/unknown` (unknown is never rendered as offline).

### 3.5 Server identity

- **`serverId` is the id of the server-carrying bookmark** (04 §2.1).
  Quick Connect mints an ephemeral `adhoc:<uuid>` serverId, promoted to the
  bookmark id on "Save as favorite…" — promotion migrates **every**
  serverId-keyed mapping in one transaction, not just `CheckoutManager`'s
  key: the shared pool's reference-count entry (the bookmark id inherits
  the ad-hoc id's reference; the ad-hoc entry is removed, never left to
  outlive the session and hold the pool and its resolved
  `SshCredentials` open indefinitely) and the `serverId` of every
  queued/running task's `ServerFsLocation` referencing the ad-hoc id (so a task started
  before promotion isn't stranded against a serverId nothing will ever
  reconnect).
- **The connection pool key is separate**: the normalized endpoint tuple
  (host, port, username) **plus the connection-security context** — the
  resolved host-key verification decision (a pinned known_hosts entry
  vs. a TOFU-accepted key) and the jump-host/proxy configuration. Two
  bookmarks share a pool only when both the endpoint *and* the trust
  context match: keying on the endpoint alone would let a strictly
  pinned bookmark silently ride a transport another, more lenient
  bookmark at the same endpoint had TOFU-accepted, or let one bookmark's
  jump-host routing be silently bypassed by a sibling that connects
  direct. Two bookmarks matching on all of that
  keep distinct serverIds. Shared pools are reference-counted
  by serverId: `disconnectServer(serverId)` drops that id's reference —
  closing its browse channels and **releasing** its transfer leases:
  a running task whose lease is released this way flips to `queued`
  (a transient engine-internal state only: while the shared pool stays
  alive under a sibling serverId the re-lease is immediate and this flip
  is never fanned out to the §6 mirror — the task never renders in the
  UI as anything but running; this flip consumes no §3.3 reconnect retry — that counter counts
  failed reconnect cycles only, and this path can never fail the task; it is
  retryable **immediately** while the shared pool stays alive under a
  sibling serverId — the queue re-leases by the pool endpoint, not by
  the disconnected id, so a task never hangs `queued` against a
  demonstrably-connected endpoint — and otherwise when **any** serverId
  connects to the endpoint tuple the task carries (§4.1's TransferTask
  stores the resolved endpoint alongside serverId for exactly this
  revival, since an ad-hoc serverId itself never reconnects — a fresh
  Quick Connect mints a new uuid — and nothing else can match this task
  back to a future connection at the same endpoint; with no live
  serverId at that endpoint the task renders "waiting for server" in the
  §6 mirror, cancel always available, never a silent, unbounded `queued`
  with no visible reason), never `failed` — a user-initiated
  disconnect is not an error, and it is not a way to stop transfers either:
  while a sibling serverId keeps the pool alive the task keeps running
  (only cancel/pause stops it — surface that in the disconnect UI), and
  §3.3's auto-reconnect explicitly
  does **not** fire for it — and teardown checkpoints any in-flight
  write exactly as a §4.1 pause does (its per-attempt resumable offset
  into the §4.6 journal) rather than draining it to completion: the
  §4.1 pause machinery already makes mid-file checkpointing available,
  so there is no need to block a user-initiated disconnect for the
  remaining duration of a multi-gigabyte in-flight file — the transport
  closes promptly and no mid-file state is lost untracked. The transports are torn
  down and the resolved `SshCredentials` wiped only when the **last**
  referencing serverId disconnects; an earlier wipe would silently
  re-prompt the surviving bookmark's next pool growth, violating §3.2
  rule 2's single-prompt guarantee. `watchServer` fans the shared
  pool's state out to every referencing serverId.
- **`CheckoutManager` keys checkouts by serverId.** Checkouts for a deleted
  favorite (or a dead ad-hoc id) persist and surface in the recovered-edits
  UI (06 §3.7 — the Séance pattern); no checkout is ever orphaned by
  deleting the favorite that minted its id.

## 4. The transfer queue (D16)

`poltergeist_core/lib/src/transfer/` — the queue engine runs in the engine
isolate; the UI holds a mirror notifier (§6).

### 4.1 Task model

```dart
// Sealed rather than a {kind, serverId?} pair: the two-field shape lets
// FsLocation(kind: server, serverId: null) and FsLocation(kind: local,
// serverId: "x") both compile, pushing a defensive validity check onto
// every consumer. A sealed hierarchy makes the invalid states
// unrepresentable instead.
sealed class FsLocation {
  const FsLocation();
}

class LocalFsLocation extends FsLocation {
  const LocalFsLocation();
}

class ServerFsLocation extends FsLocation {
  final String serverId;           // non-null by construction
  const ServerFsLocation(this.serverId);
}

enum TransferTaskState {
  queued, scanning, running, paused, completed, failed, cancelled,
  // no task-level `skipped`: skips are per-item (the §4.2 conflict verb,
  // journaled as §4.6 `itemRemoved`); a task whose every item was
  // skipped ends `completed`
}

/// Per-task conflict policy, resolved from 02 §5.2's canonical settings
/// model. Uses the SAME ConflictResolution enum —
/// { ask, replace, replaceIfNewer, keepBoth, skip, merge } — including
/// `ask` and `merge` (merge is meaningful for folders only).
///
/// Folder semantics at the engine (02 §5.2 owns the user-facing story):
/// `merge` = the §4.2 default — stat-else-mkdir, recurse, per-file policy
/// applies to contents; `replace` = wholesale replacement — first sweep
/// §4.2's shared destination-key registry for in-flight entries under the
/// target subtree (any task's) and defer the removal until they reach a
/// terminal state — except a `paused` sibling entry, which surfaces a
/// prompt ("pause this replace too / cancel the paused entry / cancel
/// this replace") instead of waiting silently, since a resumable §4.1
/// pause can hold an entry non-terminal indefinitely and this `replace`
/// would otherwise never proceed — then remove the existing destination directory through
/// the D15 delete story (OS trash locally, the per-server trash opt-in
/// remotely), then recreate and copy; a commit that fails because another
/// task's `replace` removed its parent re-evaluates against the fresh
/// destination (a conflict, never a retryCount-burning generic failure);
/// `skip`/`ask` evaluate on the directory itself before recursing.
/// `replaceIfNewer` on a folder compares the two directory mtimes —
/// treating an unknown or equal mtime as *not newer*, since directory
/// mtimes are an unreliable freshness proxy (many SFTP servers never
/// update a directory's mtime when its contents change) and the
/// destructive `replace` verb this compares into must never fire on a
/// coin-flip signal — and
/// otherwise behaves as `merge`; `keepBoth` on a folder creates the source
/// under the first free auto-numbered name (02 §5.2's keep-both), leaving
/// the existing destination untouched; and a non-dir occupying a planned
/// directory path routes through the folder policy (`replace` removes it
/// via the D15 delete story, `skip` skips that subtree, `ask` prompts,
/// `merge` falls back to `ask` — it cannot recurse into a non-directory)
/// rather than surfacing as a bare item error — only an unresolvable
/// policy errors, and never merely "the mkdir found a non-dir", which
/// §4.2's executor treats identically.
class ResolvedConflictPolicy {
  final ConflictResolution files;
  final ConflictResolution folders;
}

/// One user gesture = one task: N roots from one source filesystem into one
/// destination directory. Recursive contents ride inside the task's plan.
class TransferTask {
  final String id;                 // uuidV4() from seance_protocol
  final FsLocation source;
  final FsLocation destination;
  final List<String> rootPaths;    // absolute at the source
  final String destinationDir;     // absolute at the destination
  final ResolvedConflictPolicy policy;
  final DateTime enqueuedAt;
  TransferTaskState state;
  TransferPlan plan;               // attached when scanning starts; the
                                   // scan appends to it concurrently (§4.2)
  bool scanComplete;               // flips when the source walk finishes
  int completedFiles; int transferredBytes; int? totalBytes;
                                   // running total while scanning (progress
                                   // shows the growing "+" form, 02 §5.3);
                                   // final at scanComplete
  int retryCount;                  // §3.3's reconnect-cycle counter ONLY:
                                   // +1 per failed reconnect cycle, reset
                                   // on post-reconnect progress, checked
                                   // against taskRetryLimit. A per-item
                                   // generic failure (§4.2's
                                   // "retryCount-burning generic failure"
                                   // phrase names what conflict handling
                                   // must NOT do) never reads or writes
                                   // this field — it fails that one item
                                   // via §4.6's fileFailed record and
                                   // leaves the task's reconnect count
                                   // untouched; there is no separate
                                   // per-item retry budget in v1.
  String? error;                   // user-facing RemoteFileException.message
  final RemoteTransferCancellation cancellation; // sticky — reserved for
                                   // **whole-task** cancel only (§4.4); each
                                   // file dispatch mints its own per-attempt
                                   // token so **pause** stays resumable, and
                                   // an **item** cancel mints a per-item
                                   // sticky token plus an `itemRemoved`
                                   // record (§4.6) without touching this
                                   // field — a consumed task token would
                                   // abort every later dispatch, the pause
                                   // hazard §4.4 documents
}

class TransferPlan {
  final List<String> directoriesInOrder;   // parents first — each entry's
                                           // planned parent sorts earlier;
                                           // the length sort is correct only
                                           // because a normalized child path
                                           // strictly extends its parent's
                                           // (enforced at APPEND time — a
                                           // directory is emitted to the
                                           // executor only after its parent
                                           // is already present, since §4.2
                                           // dispatches before scanComplete;
                                           // a cheap aggregate re-check runs
                                           // at finalization. O(path
                                           // components), negligible next to
                                           // the transfer; the mkdir loop
                                           // relies on it in every build mode)
  final List<PlannedFile> files;           // path pair + size + existing stat
  final int skippedSymlinks;               // symlinks are never transferred
}

class PlannedFile {
  // Identity: destinationPath is the item id **scoped to its task** —
  // TransferProgressEvent.itemId always rides with taskId, CancelRequest
  // (item form) resolves to (taskId, destinationPath), and §4.6's
  // fileCompleted / fileFailed / itemRemoved records live in the task's
  // own journal and key on the path there, because the mid-scan-crash
  // re-scan merge can only match journaled terminal outcomes by path,
  // never by a scan-minted uuid (fresh uuids would resurrect
  // removed/failed files). Enqueue rejects or dedups nested/duplicate
  // rootPaths so a task's destinationPaths are unique **within that task
  // only** — §4.2 lets two tasks share a destination tree, so no
  // engine-side map or request routing may key an item on the bare path.
  final String sourcePath;
  final String destinationPath;
  final int? size;                         // from the scan
  final DestinationStat? existing;         // destination stat AT SCAN TIME;
                                           // null = absent. A UI hint only —
                                           // §4.2's executor re-stats the
                                           // destination and decides on the
                                           // fresh stat, never this field.
                                           // DestinationStat is the shared
                                           // read-only view (kind, size,
                                           // modifiedAt) both a local
                                           // FileStat and a RemoteFileEntry
                                           // can populate — PlannedFile is
                                           // the plan record for all four
                                           // §4.1 direction pairs
                                           // (local→remote, remote→local,
                                           // local→local, remote→remote,
                                           // §4.2 running local→local as two
                                           // LocalFileSystem endpoints), and
                                           // a bare RemoteFileEntry cannot
                                           // represent a local destination's
                                           // scan-time stat
}
```

The app resolves 02 §5.2's per-direction/per-kind conflict matrix into the
per-task `ResolvedConflictPolicy` at enqueue time — one bucket pair per
task, mirroring 02 §5.2's dimensionality exactly: local→remote → the
`upload*` pair, remote→local → `download*`, local→local → `local*`,
remote→remote (cross-server piping and same-server server-side moves
alike) → `remoteToRemote*`. `merge` is valid only in the folder fields —
the resolver rejects it in file fields, falling back to `ask`,
mirroring 02 §5.2's constraint. An engine-side `ask` pauses
the item and round-trips an `EnginePromptEvent.conflict` to the UI (§5),
whose reply resolves that item (and, when the user asks, the task's
remaining conflicts) — a §3.3 disconnect that flips the task to `queued`
invalidates any outstanding prompt for it: the UI dismisses or marks the
dialog stale, a reply that arrives after invalidation is ignored (the
same debug-logged, never-erroring drop §5's `PromptReplyRequest` already
defines for a closed/unknown `promptId`), and the post-reconnect
re-dispatch re-stats the item and re-prompts fresh, never resolving a
conflict against a plan that may no longer match reality. A prompt-parked item holds **no** §4.3 global slot
and **no** leased channel: the decision point precedes any committed bytes,
so the per-attempt token is cancelled, the lease released, and the item
re-dispatched carrying the reply — prompt-wait never counts against §4.3's
caps, so unanswered `ask`s (a folder of ≥6 conflicts under the default
policy) cannot starve other tasks, other servers, or §4.7 produce reads.

The activity panel binds to this model with per-item rows, reorder, per-item
cancel/retry, queue pause, and the conflict verbs — the D16 mandates. Séance's
`RemoteTransferItem` maps onto `TransferTask` for single-file cases; the
per-item progress/cancel plumbing (`RemoteTransferCancellation`, progress
callbacks) is reused untouched.

### 4.2 Scan-then-execute

Every task runs in two phases, transplanted from Séance's
`uploadDirectory` and `downloadEntries` in
`app/seance_app/lib/services/remote_files_controller.dart` — those bodies are
"90 % of the worker body already" (research notes) and their safety rules are
non-negotiable:

- **Scan** walks the source (`followLinks: false`; symlinks skipped and
  counted), validates every name crossing a trust boundary
  (`validatePathComponent` for remote targets, `validateLocalName` for local
  targets, and case-insensitive collision detection within the plan
  whenever the **destination filesystem** is case-insensitive — Windows
  volumes, macOS default APFS/HFS+, and remotes that report or are marked
  case-insensitive — resolved per endpoint at scan time, never keyed to
  the client OS), emitting directories parents-first and files with sizes
  as it goes. There is **no full eager walk**: the first file starts as
  soon as its parent directory chain exists **and the scan has closed
  that directory** — a directory's entries (its own mkdir AND its file
  dispatches) become usable only once its own listing is complete, so its
  case-collision set — files and subdirectories alike — is final and a
  late-scanned case-variant sibling can never race an already-dispatched
  file (the execution-time re-stat is case-folding-aware on
  case-insensitive destinations as the second net — which only helps once
  the first variant has landed; two case-variant files in flight
  simultaneously from *different* tasks could still both pass an absent
  re-stat under §4.3's global cap, so the executor also consults a shared
  registry keyed on **(destination endpoint id, case-folded absolute
  path)** — never the bare folded path alone, per §4.1's own
  no-bare-path-keys rule (identical paths on two different servers, or a
  local destination sharing a path string with a remote one, must never
  alias in this registry) — of in-flight and committed targets
  (committed entries are evicted once their task reaches a terminal
  state — the case-folding-aware execution-time re-stat already covers
  anything already committed, so the registry only ever needs to hold
  the in-flight window it exists for, and never grows unbounded across a
  long session)
  and treats the hit as a conflict resolved through the task's policy,
  exactly like a fresh-stat conflict — `ask` prompts via
  `EnginePromptEvent.conflict`, and `skip`/`replace`/`replaceIfNewer`/
  `keepBoth` apply their verb once the registry entry commits (an item
  waiting on another entry's commit holds no §4.3 global slot and no
  leased channel while it waits, exactly like §4.1's ask-park below,
  since it cannot deadlock — a waiter only ever waits on an actively
  transferring item, never on another waiter) — every verb
  in the v1 `ConflictResolution` enum is evaluable this way, so the
  terminal-fail-with-`conflict` escape hatch is **empty in v1**; it exists
  only so a future non-evaluable policy has a defined, non-silent outcome,
  and any implementer reaching it must first name the verb it covers); the
  scan continues
  concurrently growing `plan`, `totalBytes` is a running total rendered
  as the growing `N+` form (02 §5.3), and both finalize when
  `scanComplete` flips.
- **Execute** creates directories in order (**mkdir-then-classify**:
  "already exists as a directory" — including one a concurrent task
  created between check and call — is success, so two of the app's own
  tasks sharing a destination tree never spuriously fail on a benign
  race; a non-dir occupying a planned directory path routes through the
  task's folder policy per §4.1 — `replace` removes it via the D15
  delete story, `skip` skips that subtree, `ask` prompts, `merge` falls
  back to `ask` — and only an unresolvable policy errors, never a bare
  item error), then per file
  **re-stats the destination at
  execution time** and applies the conflict policy against that fresh
  stat — the scanned `existing` is a hint for the UI, not the decision
  basis; on a long queue the destination has had time to change. No SFTP
  primitive supports a truly conditional commit keyed on the
  destination's current stat: SFTP v3 `SSH_FXP_RENAME` fails whenever
  *anything* already occupies the target (an absent-only CAS — sound for
  a fresh destination, useless for an overwrite), and the
  `posix-rename@openssh.com` extension overwrites unconditionally with no
  precondition at all. The commit contract is therefore two-shaped: an
  *absent* expected target commits through an atomic create-if-absent (a
  plain v3 rename remotely, a `link`-style exclusive create locally) — an
  appearance between the re-stat and the commit fails the commit outright,
  never silently wins; an *existing-stat* expected target has no atomic
  wire or POSIX primitive either, so the commit is stat-immediately-before
  the rename, then re-stat-immediately-after, and a mismatch on either
  side is classified as a conflict with the policy re-applied (`ask`
  prompts) — never a silent clobber, never a `retryCount`-burning generic
  failure. This `ask` parks exactly like §4.1's pre-dispatch `ask` (no
  §4.3 slot, no leased channel while it waits) with one difference §4.1's
  "precedes any committed bytes" rationale doesn't cover: this attempt's
  bytes already landed and were then clobbered or superseded by whoever
  won the race, so the superseded attempt is journaled first (as its own
  terminal outcome, never `fileCompleted`) before the follow-up decision
  parks slotless. Uploads commit through this contract, and a mismatch
  re-applies the policy exactly like the download guard
  below; downloads write an
  exclusive `.poltergeist-<uuid>.part` and commit via
  `replaceLocalFile(expected:)` under the same absent/existing-stat
  contract — a mismatch re-applies the policy (`ask` prompts) instead of clobbering
  a file that appeared mid-run. Local→local commits get the same guard
  through the shared code path. Uploads get the mirror of the download
  guarantee: either open a server-side `.poltergeist-<uuid>.part`
  **exclusively** (`SSH_FXF_EXCL`, the same guarantee the download temp
  gets locally) — a non-exclusive truncating open would write through a
  symlink another user planted at that predictable name on a shared
  server — stream to it, and commit via
  POSIX rename under the same absent/existing-stat
  contract (atomic for the absent case; server-side either way on this
  temp+rename path, so an interrupted attempt here never touches the real
  destination — the no-server-side-temp branch below is the one
  documented exception, and its abort-time partial-delete requirement is
  exactly how it upholds the same guarantee its own way) — and on the existing-stat/overwrite path specifically,
  when the server offers no `posix-rename@openssh.com` (common on
  embedded/appliance sftp-servers, where plain v3 `SSH_FXP_RENAME`
  simply fails whenever the target exists), the commit re-stats, then
  displaces the occupying target — a rename-aside where the server
  offers any rename-to-a-side-name primitive, otherwise removal through
  the D15 delete story **only when that delete is trash/journal-recoverable**
  (never a bare permanent delete here) — then commits via
  the same absent-only v3 rename; §4.6's journal recovery MUST restore
  the displaced original (from the trash/journal-recoverable copy) or
  report its loss explicitly if the window is interrupted before the
  commit lands — a wider, non-atomic window than the
  extension gives, but still closed by the mandatory post-commit re-stat
  and still a conflict (never a generic failure) on any mismatch — or —
  where a server-side temp is ruled out entirely — the
  per-attempt abort path MUST delete the partially overwritten remote
  file before the lease is released, and a re-stat matching a journaled
  non-`fileCompleted` partial (size short of the plan size) is treated as
  absent, never as a `replaceIfNewer` candidate; a fresh-mtime truncated
  file must never be classified as a final destination. Cancellation is
  checked between every
  entry; `.part` temps orphaned by a crash are cleaned at journal
  recovery (§4.6). Completed
  files stay in place on failure (documented Séance behavior, kept).

Local→local tasks run the same two phases over two `LocalFileSystem`
endpoints — D26's streamed copy with progress, cancellation, and mtime
preservation falls out of the one code path.

### 4.3 Concurrency and throttling

- **Per-server limit** = what `leaseTransferChannel` will grant:
  `effectiveTransports × maxTransferChannelsPerTransport`, where
  `effectiveTransports` is 1 for interactively-authenticated servers
  (§3.2 rule 2) and `maxTransports` otherwise (default capacity 2 × 4).
- **Global limit**: at most 6 files in flight across all tasks and servers
  (a compile-time constant next to `PoolPolicy`, not user-configurable —
  02's settings screen exposes the two directional bandwidth limits and
  nothing else from this section, matching §6's settings-home table). This
  deliberately stays below the default per-server pool capacity of 8: the
  two extra channel slots are headroom, not permission to raise process-wide
  work. One busy server may own all 6 global slots for that task's entire
  duration, and strict FIFO keeps behavior predictable — the user's reorder
  is the escape hatch. Cross-server
  round-robin dispatch is a recorded non-goal for v1 (revisit only with
  evidence of real starvation).
- Dispatch order: queue order (user-reorderable), one task's files dispatched
  before the next task's unless the user reorders; small-file batches from
  one task may run in parallel up to the limits.
- **Bandwidth throttle** (D16): one token bucket per direction, global,
  living in the engine isolate:

```dart
class BandwidthLimiter {
  final int maxChunkBytes;                // injected: the largest single
                                          // chunk any acquire() caller in
                                          // this app passes (today's fixed
                                          // stream-read chunk size) — the
                                          // sole input the capacity rule
                                          // below needs; a future larger
                                          // sink (D27 archive streaming)
                                          // updates this constant, not the
                                          // limiter
  int? bytesPerSecond;                    // null = unlimited; a hand-edited 0
                                          // maps to null ("off"/unlimited —
                                          // the widespread convention; a
                                          // silent clamp to a floor would read
                                          // as a bug, "I set 0 and it crawls").
                                          // A NEGATIVE value is invalid and
                                          // normalized to null at the
                                          // limiter's own constructor
                                          // (defense in depth) — the same
                                          // "off" sentinel as 0, never a
                                          // positive floor, which would
                                          // recreate the exact "I set [near]
                                          // 0 and it crawls" bug the 0→null
                                          // rule exists to avoid — but
                                          // unlike an intentional 0,
                                          // SettingsStore's load/parse of
                                          // settings.json LOGS a negative
                                          // value and surfaces a
                                          // settings-validation warning
                                          // instead of silently widening it
                                          // to unlimited: a hand-edited
                                          // "writeLimit": -1024 is invalid
                                          // input, not an "off" request, and
                                          // this design elsewhere (§4.6
                                          // quarantine, 06 §3.6) prefers
                                          // surfacing corruption over
                                          // silently picking a value for it.
                                          // No
                                          // rate <= 0 ever reaches the bucket,
                                          // so no rate-0 bucket is ever built,
                                          // acquire never hangs, and nothing
                                          // is ever silently clamped to a
                                          // crawl-inducing floor
  Future<void> acquire(int chunkBytes);   // awaits until tokens available;
                                          // returns immediately when
                                          // bytesPerSecond is null (unlimited
                                          // bypasses the bucket — and no
                                          // rate-0 bucket is ever built, since
                                          // <= 0 is clamped above); otherwise
                                          // internally splits a request larger
                                          // than the bucket's capacity into
                                          // capacity-sized grants, so no
                                          // caller — today's chunks or a
                                          // future larger sink (D27 archive
                                          // streaming) — can deadlock it
}
```

Every transfer stream awaits `acquire(chunk.length)` once per chunk before
forwarding it (upload: before `writeBytes`; download: before pushing to
the sink). A remote→remote pipe (§4.5) acquires from **both** buckets per
chunk — each piped byte genuinely traverses the local machine's downlink
and uplink, so charging both is the physically honest accounting, not
double-throttling; progress still counts the byte once.
A local→local stream (§4.2, D26) acquires from **neither** bucket: both
limits are network egress/ingress budgets (02) and a disk-to-disk copy
traverses no network interface — implemented as a no-op limiter instance,
not a bypass of the `acquire` call, so the shared stream path stays literal.
Bucket capacity is `max(bytesPerSecond, maxChunkBytes)` — one second of
tokens, but never less than one full chunk — so `acquire` can always
eventually be satisfied: a capacity below the chunk size would await
tokens the bucket can never hold and hang the transfer (pinning its
leased channels) at exactly the low limits the throttle exists for —
with the capacity-splitting `acquire` above as the belt to this
suspenders: even a request that somehow exceeds capacity drains in
capacity-sized grants rather than deadlocking (both the oversized-chunk
and zero-limit cases are pinned by 08's limiter tests).
Bursts stay bounded and the limit is honored within ±1 s granularity
(coarser only when a single chunk exceeds one second of tokens).

### 4.4 Pause and cancel semantics

- **Queue pause**: stop dispatching new files; in-flight files finish. This
  is the honest cheap pause.
- **Per-task pause**: cancel the in-flight file via a **per-attempt**
  cancellation token minted for that dispatch
  (its partial `.part`/temp is cleaned up by the existing plumbing), mark the
  task `paused`; resume re-dispatches the remaining plan items with fresh
  per-attempt tokens — the task's `final cancellation` (§4.1) is a **sticky**
  token reserved for **cancel** (below), and a sticky token consumed by pause
  could never be un-cancelled, so resuming against it would abort every
  re-dispatched file the instant it started. Bytes of the
  interrupted file are re-sent — true byte-level resume needs ranged
  read/write and is v2 (D25). The UI copy must not pretend otherwise
  ("Pausing restarts the current file when resumed").
- **Cancel** reuses `RemoteTransferCancellation`, sticky and instant,
  cleaning temps — but task and item cancel act on **different** tokens: a
  **task** cancel trips the task's sticky `cancellation` (§4.1), aborting
  every remaining dispatch; an **item** cancel mints a per-item sticky
  token, aborts only that item's in-flight attempt, and appends an
  `itemRemoved` record (§4.6) **without** touching the task token (a
  consumed task token would brick every later dispatch — the same hazard
  that keeps pause off the task token, above); a prompt-park abort (§4.1's
  `ask`-park) cancels only that item's per-attempt token and journals
  nothing, so replay never mistakes a parked item for a removed one.

### 4.5 Remote-to-remote piping

SFTP has no server-side copy, so cross-server remote→remote is a piping
task (D16) — with one carve-out from 02 §5.1: a **same-server move** is a
rename-class server-side operation on one leased channel, no data
through the local machine, still enqueued as a queue task for
visibility — and when the server rejects the rename as cross-device
(mount boundaries no SFTP rename can cross), the task
falls back to the piped copy-then-delete path below without re-asking
any conflict question already answered — but the trigger is classified
narrowly: SFTP v3 has **no EXDEV status code** (OpenSSH returns a plain
`SSH_FX_FAILURE` for a cross-device rename), so the fallback fires only
on a cross-device-class failure identified from the server's status
text, and an ambiguous `SSH_FX_FAILURE` — permission denied, or a target
that exists *unexpectedly* under a non-Overwrite policy — is treated as
**non-EXDEV** and surfaced as the rename's own
error rather than silently entering copy-then-delete. An **Overwrite**
policy's move expects the target to exist, so it never even attempts the
plain v3 rename that would fail on it: it renames via
`posix-rename@openssh.com` when the server offers the extension, else
falls straight to the piped copy-then-delete path below — "target
exists" only ever reaches the ambiguous-failure classification above
when the resolved policy did *not* expect it. **Known limit:**
OpenSSH's `sftp-server` sends an *empty* message string with
`SSH_FX_FAILURE` (`send_status`), so on it no status text is available
and a genuine same-server cross-device move surfaces as the rename's own
error — the user re-runs it as an explicit copy task; the text-keyed
fallback engages only on servers that embed errno/detail text in the
status message. The match stays conservative and is never widened to make
OpenSSH "work", since that would reintroduce the permission-denied/
target-exists misclassification the narrow rule prevents. The piped fallback
still commits under §4.2's fresh-stat/`expectedTarget` guard and deletes
the source only after a verified copy, so it can never clobber a
destination that changed since the conflict decision. The task row is
updated to name
the actual mechanism (02 §5.1's rule, mechanized here);
a same-server *copy* still pipes (no SFTP v3 copy primitive; the
`copy-file` extension is a D25-class acceleration). For the piping case
the
worker leases one channel on each server, then streams
`source.download(path, sink)` into `destination.upload(path, stream)` chunk
by chunk with a small buffer, counting bytes once. Scan phase runs against
the source as usual; conflict policy applies against the destination. Both
leases are released on completion, failure, **cancellation, or pause**
(§4.4's per-attempt token aborts both streams, so neither channel is left
leased); either side's typed error fails the file with that side named in
the message.

### 4.6 Persistence: journal and history (D16)

The queue and its history survive restarts. Store layout under the
app-provided support directory (`EngineConfig`, §5):

```
<app-support>/transfer_queue.jsonl     append-only journal of the live queue
<app-support>/transfer_history.jsonl   compacted, completed/failed task records
```

- **Journal**: one JSON object per line — `taskEnqueued` (full task spec),
  `planEntry` (one per scanned directory/file, appended as the scan produces
  it — the `plan` is runtime state per §4.1 and the `TransferTaskSpec` in
  `taskEnqueued` carries none of it, so without these records replay could
  not reconstruct the plan that the "remaining items" computation subtracts
  from; idempotent on replay — replay UPSERTS keyed on
  (taskId, itemId), where `itemId` is a uuid minted per plan item at scan
  time and journaled inside each `planEntry` record — **not**
  `destinationPath`: `TransferTaskSpec` carries `rootPaths` (plural), and
  nothing guarantees two items of one task never share a destination
  (overlapping roots, or two roots whose contents collide on a
  destination name), so a bare-path key would let distinct source files
  collapse onto one journal entry — undercounting `totalBytes`, letting
  one `fileCompleted` silently mark two different files done on replay,
  and routing an item cancel at both of them. `destinationPath` stays a
  secondary lookup index for UI display, never the record's identity, so a post-crash
  re-scan's re-appended entries collapse onto the journaled ones instead of
  duplicating plan items or inflating totalBytes),
  `taskState`, `fileCompleted`, `fileFailed` (terminal per-item outcome,
  with error text), `itemRemoved` (per-item cancel or skip, §4.4),
  `taskRemoved`. Appends are flushed
  per line and fsynced on a bounded interval (every ~64 records or
  ~250 ms, always before that task's history record is appended) — a
  flush alone survives process death, not power loss, and the compaction
  bullet's power-loss bar does not extend to this hot path: the accepted
  residue of an outage is re-transfer of files whose completion hadn't
  reached an fsync boundary yet, never a lost completion the UI already
  showed as done within that window; recovery distinguishes two failure shapes: a **torn** final
  record (no terminating newline — a crash mid-append) is dropped and the
  file is truncated to the end of the last complete record before the log
  reopens for append, so malformed bytes are never buried mid-log; a
  *complete* line that fails to parse quarantines the journal
  (timestamped, the 06 §3.6 pattern), replays the intact prefix, and
  **atomically rewrites the live journal to that prefix**
  (`writeStringAtomically`) before reopening for append — records after
  the malformed line survive in the quarantine copy and the banner
  counts them; without the rewrite, appends would land behind a
  still-malformed line and every later recovery would re-quarantine
  while the appended records stayed unreachable on replay — never a
  silent drop of a record that was fully written, never a quarantine
  loop. On
  startup
  the journal is replayed: unfinished tasks come back with their
  **journaled state** — a per-task `paused` survives restart; only
  `running`/`scanning` become `queued` — and their remaining plan
  items, defined as the plan (rebuilt from the journaled `planEntry`
  records) minus completed, failed, and removed items
  (`fileCompleted`, `fileFailed`, `itemRemoved`); a task that crashed
  mid-scan (no `scanComplete`) re-scans on resume, merging the partial
  `planEntry` set against journaled terminal outcomes: a file the user
  watched fail or deliberately removed must not silently resurrect on
  resume. The in-flight file restarts; ambiguous task state
  is reconciled against leftover `.part` files before resuming, and
  each restored item's destination directory is swept of its own stale
  `.poltergeist-*.part` temps — recovery is the cleanup point for
  crash-orphaned temps, scoped to paths the journal names, never a
  general directory sweep. The user
  is not asked —
  the panel simply shows the restored queue paused, with a "Resume" affordance
  (restored queues start paused so a reboot never silently re-transfers:
  restoration **forces §4.4's queue-level pause flag on** — the flag is
  not journaled, it is set unconditionally at restore — so even tasks
  mapped `running`→`queued` cannot dispatch before the user hits
  Resume; the state-mapping bullet above and this rule are one
  mechanism, not two). §4.7's head-inserted **produce** tasks are never
  journaled at all — their awaited Future dies with the calling process,
  so none exist for a restore to find or exempt — which makes the
  runtime-pause exemption the only one that matters in practice: a
  preview or Quick Look
  read issued while the queue is paused (restored-paused or
  user-paused) must still dispatch, or
  its awaited Future would hang with nothing telling the user why.
  Prompt state does not survive restart (promptIds are session-scoped):
  resuming a task whose policy is `ask` re-runs its remaining items'
  execution-time policy check, which re-emits the `conflict`
  `EnginePromptEvent` (§5) — never a remembered answer, never a default.
- **Compaction**: on clean shutdown, after startup replay, and whenever the
  live journal crosses a finished-task/size threshold within a long session
  (the same crash-safe ordering below — history append first, atomic rewrite
  second — so a session moving hundreds of thousands of files does not grow
  an unbounded journal and a post-crash replay stays short); first append
  finished tasks to the history file keyed by task id (idempotent —
  replay skips ids already present in history), then rewrite the
  journal to just the pending tasks **with their full record set**
  (`taskEnqueued`/`taskState` plus every already-journaled `planEntry`,
  `fileCompleted`, `fileFailed`, and `itemRemoved` belonging to them —
  "just the pending tasks" narrows *which tasks* survive the rewrite,
  never *which of their records*: dropping a still-pending task's own
  item-level terminal records here would let the next replay resurrect
  files it already completed or the user already removed, exactly the
  failure this whole mechanism exists to prevent) via the ported
  `writeStringAtomically`, hardened to fsync the temp file before the
  rename **and to fsync the containing directory after it** — fsyncing
  the file alone does not make the rename itself power-loss-durable on
  POSIX; only an fsync of the directory entry after the rename does —
  and the history
  append flushed and fsynced before the rewrite
  begins — so the ordering also survives power loss, not just process
  death; the torn-tail truncate and the quarantine rewrite above take
  the same fsync-the-directory-after-mutating-it discipline before
  reopening the log for append, or a second crash could resurrect a
  torn tail or a quarantined line at shifted offsets). The whole sequence — and every other append path, to **both**
  the journal and the history file — is funneled
  through one single-writer async mutex, so no append to either file can
  interleave with a rewrite of it: a `fileCompleted`/`taskState` record
  completing while compaction awaits its journal I/O is queued and
  appended to
  the rewritten journal *after* the rename, and a completion racing the
  history file's own 10 000-record trim rewrite (below) is queued the
  same way against *that* file's rewrite — neither append is ever
  written to a
  pre-rename file or a handle pointing at its now-unlinked inode, where
  it would silently vanish the moment the rename replaces the path it
  was targeting. A crash between the two steps loses nothing:
  the next replay re-reads the old journal and skips already-recorded
  ids. The reverse order would have a crash window that silently loses
  finished-task records.
- **History**: one record per finished task — id, endpoints, root names,
  byte and file counts, `startedAt`/`finishedAt` timestamps, duration,
  outcome, error text — **appended at task completion** (single-line
  append + flush, the journal's discipline, so the History tab is live
  mid-session; a torn final line is truncated at recovery and its
  dropped-record count surfaced — the journal's no-silent-drop rule, not a
  bare read-side drop), and separately
  migrated at startup replay / clean shutdown by the compaction step,
  which idempotently moves any crash-recovered finished tasks out of the
  journal (keyed by task id — replay skips ids already in history). Capped
  at 10 000 records; compaction drops the oldest — the cap is checked on
  each append and the drop runs once the file exceeds it by a 10 % slack
  margin, always via `writeStringAtomically` (so the completion hot path
  only appends a line — the trim rewrite runs at most once per ~1 000
  completions, when the 11 000-record slack margin is crossed — and a
  crash mid-trim never leaves a torn history file). This is the "working
  history log" FileZilla never had (D16); the activity panel's History tab
  reads it (02).

### 4.7 Produce-on-demand hook (D14)

OS drag-out with promised files is v1.x, but any promised-file backend needs
one thing from the queue on day one:

```dart
abstract interface class TransferProducer {
  /// Enqueue a download of [path] from [source], **inserted at the head
  /// of the queue** — the one programmatic exception to §4.3's
  /// strict-FIFO dispatch (Quick Look waits on it), stated in both
  /// places so they agree — and **exempt from §4.4's queue-level pause**
  /// (including the pause §4.6 forces on at restore), **from §4.3's
  /// in-flight caps, and from the token-bucket throttle — but capped by
  /// a small dedicated produce-slot limit (2)**: a foreground,
  /// user-initiated preview read must never hang behind a paused *or
  /// slot-saturated* queue, nor crawl at the background bandwidth limit
  /// (the awaited Future would otherwise never complete, or complete too
  /// late to matter) — and the per-server channel pool (§3.2) reserves
  /// capacity for these 2 produce slots on top of §4.3's own dispatch
  /// caps, or a pool fully leased by ordinary queue transfers would hang
  /// the produce Future behind them just the same, reopening under load
  /// the exact hang this exemption list exists to close; producers cancel superseded requests (06), so
  /// rapid preview paging cannot stampede the shared SSH connection. It emits **no** TransferProgressEvent to the queue
  /// mirror — its awaited Future is the completion signal, so the §6 mirror
  /// never sees a taskId with no queue row and §5's per-flush event bound
  /// (§4.3-capped queue tasks) is unaffected. Downloads [path] from [source] into
  /// [destinationPath] — the caller computes the destination (the preview
  /// cache path per 06 §5.3) — completing once produced. Used by future
  /// promised-file drag-out and by Quick Look / preview for remote files.
  /// A path String, not a `File`, crosses the isolate boundary here:
  /// `TransferProducer` is implemented engine-side but consumed through
  /// `EngineClient` (§5's "plain-data messages ... nothing non-sendable"
  /// rule), so a `ProduceLocalCopyRequest` (source, path,
  /// destinationPath — all plain data) belongs in §5's protocol
  /// inventory alongside the other `EngineRequest`s, with cancellation
  /// riding the existing `CancelRequest` machinery rather than an
  /// ad-hoc, unversioned handle.
  Future<void> produceLocalCopy(FsLocation source, String path,
      {required String destinationPath, RemoteTransferCancellation? cancellation});
}
```

`TransferQueue implements TransferProducer` from M4; Quick Look and the
preview pane (06) consume it from M7, which keeps the hook exercised and
tested long before drag-out exists.

## 5. Isolate model (D8)

| Isolate | Owns | Never touches |
|---|---|---|
| UI isolate | Flutter, all controllers/notifiers (§6), platform channels, stores for settings/bookmarks | sockets, `SftpClient`s, hashing loops |
| Engine isolate | `ConnectionManager` + pools + every SSH/SFTP socket, `LocalFileSystem` instances used by panes, `TransferQueue` execution, inline SHA-256 hashing, sync scan/diff execution (05) | widgets, plugins |
| Short-lived `Isolate.run` workers | archive work (v1.x, D27), any future CPU burst that is not stream-shaped | shared state |

Sockets cannot cross isolates, so everything that holds one lives in the
engine isolate; the UI isolate holds only view state. The two communicate
over send/receive ports with a typed, versioned protocol of plain-data
messages (no closures, no dartssh2 types, nothing non-sendable):

```dart
// poltergeist_core/lib/src/engine/protocol.dart
sealed class EngineRequest { final int requestId; }
class OpenBrowseChannelRequest extends EngineRequest { final String serverId; }
class ListDirectoryRequest extends EngineRequest {
  final int channelId; final String path;
}
/// TransferTaskSpec is the enqueue-time subset of TransferTask (§4.1):
/// source/destination/rootPaths/destinationDir/policy — no runtime state.
class EnqueueTransferRequest extends EngineRequest { final TransferTaskSpec spec; }
/// Cancels a whole task ([taskId] alone) or one in-flight item
/// ([itemId] non-null): typed as
/// two fields rather than one shape-sniffed `String`, since destination
/// paths are arbitrary strings and any single-string pair-encoding would
/// make "the two shapes are disjoint" an unproven, collision-prone
/// invariant in the most safety-critical control path (§4.4's sticky
/// task token bricks every later dispatch if tripped by a misrouted
/// cancel). [itemId] is the §4.6 journal's plan-item identity (a
/// scan-time uuid), not the destination path — §4.6 keys item records on
/// itemId precisely because two items of one task can share a
/// destination path, and a cancel routed by path would risk hitting the
/// wrong one of them. An unknown [taskId] is ignored at debug level (matching
/// prompt replies). Fixed here before M4 freezes the protocol.
class CancelRequest extends EngineRequest {
  final String taskId;      // uuid — trips the task token (§4.4)
  final String? itemId;     // non-null cancels one item only — the §4.6
                            // journal's plan-item uuid
}
/// Queue/connection control — the requests the EngineClient facade below
/// promises ("plus queue and connection control"): runtime bandwidth-limit
/// changes (§6 global settings) and queue pause/resume (§4.4). Left out of
/// the initial protocol they would become exactly the versioned protocol
/// change §5 warns against; server disconnect rides its own request too.
class SetBandwidthLimitsRequest extends EngineRequest {
  final int? readLimitBytesPerSecond;    // null = unlimited (§4.3)
  final int? writeLimitBytesPerSecond;
}
class SetQueuePausedRequest extends EngineRequest { final bool paused; }
/// Exactly one reply per promptId; a UI-side dismissal sends the
/// cancel/auth-failure reply for the prompt's kind. A reply whose
/// promptId is closed or unknown (an answer racing a dismissal, a task
/// removed mid-prompt) is ignored, logged at debug level with promptId
/// and kind only — never the reply payload, since credentialNeeded
/// replies carry secrets — never an engine error, and never applied to
/// any other prompt; a second reply to an answered promptId is dropped
/// the same way.
class PromptReplyRequest extends EngineRequest {
  final String promptId;
  final EnginePromptKind kind;   // engine validates against the open prompt
  final PromptReply reply;       // sealed: one plain-data subtype per kind
}

sealed class EngineEvent {}
/// payload is a sealed result type: the value, or a serialized
/// RemoteFileException — never a bare Object (the protocol stays typed).
class ResponseEvent extends EngineEvent {
  final int requestId;
  final EngineResult result;   // sealed: value | serialized RemoteFileException
}
class TransferProgressEvent extends EngineEvent {
  final String taskId;
  final String itemId;      // the §4.1 plan item — per-file sub-rows
                            // (02 §6) are unrenderable without it, and
                            // adding it after M4 would be a versioned
                            // protocol change
  final int transferred;    // bytes for THIS item
  final int? total;         // this item's size
  final int taskTransferredBytes; // §4.1 rollups, engine-computed — the
  final int? taskTotalBytes;      // growing "N+" total (02 §5.3) is
                                  // scan-time state: TransferTaskSpec
                                  // carries no plan/sizes and TransferTask
                                  // is not sendable, so the UI cannot
                                  // derive the rollup itself
}
class ServerStateEvent extends EngineEvent {
  final String serverId;
  final ServerConnectionState state;  // §3.2's enum
  final String? detail;               // e.g. the summarized failure line
}
/// Prompts round-trip as events, correlated by promptId: the engine
/// isolate wraps seance_core's HostKeyPrompter and
/// KeyboardInteractiveResponder callbacks by emitting one of these and
/// awaiting the reply — the callbacks cannot cross isolates.
enum EnginePromptKind {
  hostKeyFirstUse, hostKeyChanged, keyboardInteractive, credentialNeeded,
  conflict,                           // 02 §5.2 verbs, per §4.1's `ask`
}
class EnginePromptEvent extends EngineEvent {
  final String promptId;              // answered by one PromptReplyRequest
  final EnginePromptKind kind;
  // plus a kind-specific plain-data payload (fingerprint, prompt texts,
  // the conflicting item's stats)
}
```

The UI-side facade is `EngineClient` (in `poltergeist_core`), exposing
Future/Stream APIs that mirror `RemoteFileSystem` per channel plus queue and
connection control. Controllers talk only to `EngineClient`; the engine
isolate hosts prompts (TOFU first-use/changed, keyboard-interactive,
credential re-resolution, transfer conflicts) by emitting
`EnginePromptEvent`s to the UI, which renders the dialog and answers with
exactly one `PromptReplyRequest` per `promptId` — dismissing the dialog
maps to the cancel/auth-failure reply, and a `conflict` prompt's item stays
paused until its reply arrives — or, for a `promptId` that never gets a
reply at all (an orphaned dialog, a UI-side bug, a prompt emitted right
before window teardown), until task teardown or engine shutdown treats
the still-unanswered `promptId` as an implicit cancel and logs it as a
prompt leak, so a lost dialog can never wedge a paused item silently
forever with no timeout and no recovery short of restarting the engine. Progress events are coalesced engine-side
to ≤ 30 **flush windows** per second per task, each flush carrying only
the **latest event per item** that progressed in that window (loosely
bounded by §4.3's in-flight caps — a soft bound, not a hard one: a slot
freed by mid-window completion can rotate to a new item within the same
window, so a flush can carry more than 6 items — each flush is therefore
also hard-capped with oldest-event-drop coalescing so the loose bound
above can never translate into an unbounded flush; per-file sub-rows
stay live while the flood is capped) — so ports never
flood the UI.

The app resolves all storage directories via `path_provider` on the UI
isolate and hands them to the engine in a typed `EngineConfig` message —
support/journal directories, the `PoolPolicy`, initial bandwidth limits —
sent as the first message after spawn: the engine isolate must not
depend on plugins or platform channels. (Background isolates *can*
reach platform channels since Flutter 3.7 via
`BackgroundIsolateBinaryMessenger` — the constraint here is the design,
not an SDK impossibility: that plumbing, and the plugin coupling it
invites, is exactly what stays out of the engine.)

The v1 split is fixed by D8 and D9's empirical gates: dartssh2 sockets and
multiple SFTP channels function inside a non-root isolate; cross-port
cancellation is 40.938 ms; coalescing delivers 22.83 progress flushes/s under
a 17,564-event/s synthetic flood; the four-transfer-plus-listing workload's
UI-isolate timer stall is 4.401 ms; and the median of three warmed, interleaved
throughput samples gives 0.997 isolate/root parity. These values clear the
respective 100 ms, 30 flushes/s, 16 ms, and ±10% gates. The ownership table
and typed message-port boundary above are the v1 design.

## 6. App state architecture

Split notifiers per domain — never one monolithic app-state notifier
repainting the world (the lesson recorded in Séance's review history as
SOL-057; its single files-pane `ListenableBuilder` over one ChangeNotifier is
fine at one pane, and exactly what does not scale to two panes × tabs ×
queue). Composition, all `ChangeNotifier`s unless noted:

| Notifier | Scope | Owns |
|---|---|---|
| `WorkspaceController` | one per window (D13 — multi-window becomes mechanical later) | pane list, tabs per pane, active pane/tab, sidebar + activity panel visibility, layout ratios |
| `PaneController` | one per pane-tab | navigation, entries, sort/filter/hidden, selection, per-location view prefs — a fork of Séance's `RemoteFilesController` — a D2 port with divergences, so it gets a PORTS.md entry and recorded divergence lines per §8.2/§8.3 like any other ported file — with the terminal-follow inputs (`shellDirectory`, `terminalTitle`) deleted and the filesystem reached through `EngineClient` |
| `CheckoutManager` | app-wide, records keyed by server | the managed-checkout pipeline extracted from `RemoteFilesController`: checkout, watch, reconcile, upload-back, rename-migration. Wraps the ported `ManagedRemoteFileStore`; `editSessionId` is a per-server constant (D17 — checkout ownership is per server, never per pane/tab) |
| `TransferQueue` UI mirror | app-wide | queue rows, history, throttle state — rebuilt from engine events |
| `BookmarkStore` | app-wide | sidebar model, persistence, the sync-coordinator seam (04) — store-behind-callback like Séance, so the store stays sync-agnostic |
| `ConnectionStatus` | app-wide | per-server state from `watchServer` + `ProbeService` for sidebar dots |
| `SettingsStore` | app-wide | all app settings: one JSON file at `<app-support>/settings.json`, atomic writes (`writeStringAtomically`), quarantine-on-corrupt; immediate-persist with revert-on-failure — the idiom 06 §8 cross-references — with the immediate-persist path and the debounced-recents path (below) both funneled through one serialized async writer that always encodes the full current in-memory state, so an immediate persist triggered right after a debounced flush can never race it and serialize a stale pre-recents-update snapshot over a newer one |

Every setting this plan names has exactly one home (02 §10's settings
screen renders them; this table owns storage):

| Home | Settings |
|---|---|
| Global (`settings.json`) | density, the conflict matrix (02 §5.2), bandwidth limits, probe opt-out, "new tabs open", reconnect-restored-tabs, recents (capped at 100; persisted **debounced** — trailing ~1–2 s, with a quit-time flush that goes through the same serialized writer above — never a second, parallel write path, which could otherwise race an in-flight debounced flush and serialize a stale pre-recents-update snapshot over a newer one at exactly the highest-risk moment — awaited via a quit-deferring lifecycle hook (`AppLifecycleListener.onExitRequested` / window-close interception) so the trailing window is never dropped by quitting before the flush lands — so a burst of navigation does not rewrite the whole settings file per open, keeping the most-frequently-changing data off the immediate-persist path) |
| Per-server device-local map inside `settings.json`, keyed by serverId (§3.5) | remote-trash opt-in (D15), per-location view prefs (500-entry LRU, 02 §2.4) |
| Synced `Bookmark` fields | everything in 04 §2.1's synced list (04 §2.3 fixes the synced/device-local split) |

Two idioms from Séance are **required patterns** in every controller, and
review rejects async code without them:

- **Generation counter**: every navigation bumps `_navigationGeneration`;
  async completions compare their captured generation and drop themselves if
  stale (slow listing of a directory the user already left).
- **`identical()` recheck**: after any `await`, re-fetch the live object
  (tab, pane, task) and `identical(...)`-compare against the captured one
  before mutating state; a stale winner disposes its result instead of
  applying it (Séance's `app_state.dart` connect flow, ~lines 554–629).
  Plus `_disposed` guards in every async callback and timer.

## 7. Platform integration seams

All native code is small, in-repo, and owned — Séance's
`MainFlutterWindow.swift` model — never a third-party mega-plugin (the
flutter-desktop research's meta-risk finding).

### 7.1 Channel inventory

| Channel | Platform | Purpose |
|---|---|---|
| `poltergeist/menu` | macOS | Edit-menu retargeting + `setPaneFocused` push, reserved in case `PlatformMenuBar` cannot conditionally fall through to first-responder actions (02 decides in a spike; the Séance Swift approach is the proven fallback) |
| `poltergeist/files` | macOS (+ Android later) | `openWithApplication` / `pickApplication` for external editors (ported `seance/files` pattern); mounted-volume enumeration on macOS |
| `poltergeist/scoped_access` | macOS | security-scoped bookmarks: mint-while-grant-live, resolve with stale re-mint, token-balanced start/stop (ported `seance/secure_bookmarks` pattern) |
| `poltergeist/trash` | macOS | `FileManager.trashItem` returning the trashed URL for Put Back |
| `poltergeist/quicklook` | macOS | `QLPreviewPanel` data source + `makeKeyAndOrderFront` (~60–100 lines of Swift) |

Windows trash and volume enumeration go through the `win32` FFI package in
pure Dart (`IFileOperation` + `FOF_ALLOWUNDO | FOFX_ADDUNDORECORD` — the
FOFX flag, set via `SetOperationFlags`, is what records the delete on
Explorer's Ctrl+Z stack; `FOF_ALLOWUNDO` alone only routes to the
recycle bin; `GetLogicalDrives` /
`GetVolumeInformationW`) — possibly zero C++, with one eyes-open
caveat: `IFileOperation` requires COM initialized apartment-threaded
(`CoInitializeEx(COINIT_APARTMENTTHREADED)`) on its calling thread, and
a Dart FFI call runs on an arbitrary VM thread — so budget a dedicated
STA thread (and its spike) in the owning milestone, with a thin C++
helper as the recorded fallback if the apartment/pump proves unworkable
from pure Dart; an unpinned thread here means intermittent,
machine-dependent trash failures that surface late. Linux trash shells out to
`gio trash` (never through a shell — `Process.run` with an argument list).

### 7.2 ScopedPathAccess (D23)

Every local filesystem touch in the app flows through one service:

```dart
abstract interface class ScopedPathAccess {
  // Canonicalization is enforced HERE, not delegated to every call site:
  // a security invariant that depends on every caller getting it right
  // forever is a bug waiting for a new call site, and v1's unsandboxed
  // pass-through backend means a canonicalization mistake would stay
  // completely untested until the sandboxed backend swap enables it —
  // exactly when it starts to bite. acquire/mintBookmark below run every
  // path through this before keying token balancing and the
  // release/acquire serialization on the result: symlink-resolved, no
  // `.`/`..` segments, no trailing separator, case-normalized on a
  // case-insensitive volume. macOS in particular routes `/tmp`/`/var`
  // through `/private/...` symlinks, so two un-normalized spellings of
  // one directory would otherwise double-grant, double-balance, and
  // defeat mintBookmark/acquireBookmark round-tripping (a blob minted
  // under one spelling failing to resolve under another looks exactly
  // like a stale blob).
  Future<String> canonicalize(String localPath);
  Future<ScopedAccessToken> acquire(String localPath); // token.release()
  Future<Uint8List?> mintBookmark(String localPath);   // while grant is live
  // Resolve a stored blob (keyed by bookmark id) and begin scoped access;
  // returns null when the blob is stale/undecodable so callers re-prompt
  // and re-mint (§7.1). A sandboxed relaunch holds a blob, not a path,
  // so this — not acquire(localPath) — is the entry point there.
  Future<ScopedAccessToken?> acquireBookmark(String bookmarkId);
}
```

v1 desktop builds are unsandboxed, so the default backend is a pass-through —
but the calls exist from day one, security-scoped bookmark blobs are stored
device-locally in a dedicated `<app-support>/scoped-bookmarks.json` (never
inside `settings.json`, so that file's immediate-persist atomic rewrite
stays small and text-only — and itself written with §6's same
atomic-temp-write-and-rename discipline behind one serialized in-process
writer: a torn write or two concurrent mints racing here would drop
every stored blob at once, forcing a full re-prompt for every
previously granted path — their one home is this dedicated file,
deliberately outside §6's settings table, which reserves no row for these
binary blobs) keyed by bookmark id (never synced — 04 §2.3), and
turning on the macOS sandbox later is a backend swap, not a refactor: a
sandboxed launch begins from `acquireBookmark` (resolving a stored blob into
live access; a `null` return means the blob is stale, so the caller re-prompts
and re-mints per §7.1), with `acquire(localPath)` valid only after that
resolution, and `token.release()` serializes per path against any subsequent
`acquire` of the same path so a release never races the next grant. This is
also the mobile hook D29 requires.

### 7.3 Trash (D15)

One `Trash` service with per-platform backends (§7.1): local deletions from
panes go to the OS trash with undo where the platform gives it (macOS Put
Back; Windows Explorer undo; on Linux, `gio list trash://` to find the
item's `trash://` URI and `gio trash --restore <uri>` — the restore
option's availability is probed at runtime (`gio trash --help` lists
supported flags) rather than trusted from the GLib version, since
distros backport it; on absence the fallback is parsing
`$XDG_DATA_HOME/Trash/info/*.trashinfo` (default `~/.local/share/Trash`
when `XDG_DATA_HOME` is unset — hardcoding the default breaks restore on
systems that set it) (`Path=` **percent-decoded** per the FreeDesktop Trash
spec — raw `%20`-style escapes would silently break restore for any path
with spaces or non-ASCII — plus the RFC 3339 `DeletionDate=`, which is
also the disambiguator when several entries share one `Path=` — delete,
restore, delete again under the same name is the normal way this
happens — restore always picks the newest `DeletionDate=` and moves back
exactly one file — `DeletionDate=` is second-resolution, so an
exact-timestamp tie (quite possible on a rapid delete/restore/delete
cycle) tie-breaks on the `.trashinfo` file's own mtime, then on the
dedupe suffix below, keeping the pick deterministic rather than
arbitrary or ambiguous) and
moving the file back, Nautilus-style; and if the `gio` binary is absent
entirely (minimal/GNOME-less distros, some WSL setups), both trash and
restore fall back to the same spec directly — a home-filesystem path moves
into `$XDG_DATA_HOME/Trash/files/` (`~/.local/share/Trash/files/` when
`XDG_DATA_HOME` is unset, same rule as the read path above) with a
written `.trashinfo` whose filename mirrors a spec-style deduped name in
`files/` (`name`, `name.2`, … on collision, per the FreeDesktop spec —
trashing two same-named files must never let the second overwrite the
first trashed copy), while a
path on another mounted volume (§7.4) prefers that volume's
`<topdir>/.Trash/$UID` — only after verifying `.Trash` is a root-owned,
sticky-bit, non-symlink directory per the spec (a crafted volume could
otherwise plant it as a symlink and redirect trashed data) — then
`<topdir>/.Trash-$UID` (verified a non-symlink directory owned by the
current user, created 0700 otherwise), with a
cross-filesystem move into home trash only as a last resort (a blind copy
into home trash from a large removable volume is slow and can exhaust the
home disk) — so trash never silently degrades to
nothing). Remote
deletions from browsing default to confirm-then-permanent with the per-server
opt-in "move to `.poltergeist-trash/<runId>/` instead" (00's D15 — same
per-run layout as sync trash, so it ages and purges under the identical
30-day rule rather than an unretained flat folder); sync deletions use
`.poltergeist-trash/<runId>/` (05). One directory name everywhere; the
default ignore rules exclude `.poltergeist*`. `.poltergeist-trash/` and
each `<runId>/` subdirectory are created `0700` on the remote — matching
the local `.Trash-$UID` requirement above, and for the same reason: a
default `0022` umask would otherwise yield a world-readable `0755`
directory, widening exposure of files moved out of a possibly-`0700`
source directory on a shared multi-user server — and a pre-existing
looser-mode directory is `chmod`'ed `0700` (or the trash operation is
refused with a per-server error) before anything is moved into it.

### 7.4 Volumes

Own enumeration per the research notes — Windows via `win32` FFI, with
hot-plug from a hidden top-level `WM_DEVICECHANGE` window in the §7.1 C++
helper (never a message-only/`HWND_MESSAGE` window — top-level
`WM_DEVICECHANGE` broadcasts skip those — and a plain Dart FFI thread has
no message pump to receive the broadcast;
note that volumes need this helper **independently** of §7.1's trash/COM
spike outcome — only trash is conditional on that spike, so the helper's
go/no-go is also driven by volume hot-plug, and descoping it lands on the
polling fallback below, not on nothing)
or, failing that, `GetLogicalDrives` polling; macOS via
`/Volumes` + the `poltergeist/files` channel (`mountedVolumeURLs`, FSEvents
hot-plug), Linux by parsing `/proc/self/mounts` (whose mount-point field
octal-escapes space/tab/newline/backslash as `\040`/`\011`/`\012`/`\134` —
decode before matching, watching, or the periodic re-read compare, or
"SanDisk 64GB" enumerates as a literal `SanDisk\04064GB`) and showing `/`,
`/home`,
`/media/$USER/*`, `/run/media/$USER/*`, with inotify watches on those
directories **plus a periodic `/proc/self/mounts` re-read** — inotify
fires no parent event when a filesystem mounts over an already-existing
mountpoint directory, the classic gap that leaves fstab/automount
volumes invisible until an unrelated rescan. `disks_desktop` is reference code only, never a
dependency (3 years stale).

### 7.5 Directory watching

Policy, fixed: watch **only the directory shown by each pane's active
tab**, non-recursively — one watcher per pane, retargeted on tab switch
and navigation, dropped when the pane shows a launcher or remote location;
background tabs are not watched (their listing refreshes on activation).
Debounced 300 ms into a refresh. Watcher failure is never silent: inotify
`IN_Q_OVERFLOW`, `IN_DELETE_SELF`/`IN_UNMOUNT`, or a backend
invalidated-watch error triggers an immediate rescan, and a watched path
that vanishes out from under its watcher retargets or drops the watcher
exactly as a navigation away would — a pane never shows a listing it
silently stopped watching. The macOS FSEvents stream reports the whole subtree rooted at the
watched path (there is no native directory-only mode), so that backend
must depth-filter events to the watched directory's direct children.
Otherwise non-recursive watches work natively on all three
platforms (Linux inotify does not do recursive — this policy sidesteps it).
The sync engine uses explicit scans, never watchers (05). The checkout
watcher keeps Séance's separate design untouched: parent-directory watch,
600 ms debounce, reconcile-on-resume fallback.

## 8. Code-sharing mechanics (D2)

### 8.1 Git-pinned Séance packages

`seance_protocol` and `seance_core` are consumed as git dependencies pinned
to a Séance **tag** — never forked, never copied. Per 00 D2, a temporarily
stalled upstream Séance PR may be pinned by commit rev, recorded as a dated
open item in STATUS.md and re-pinned to the next tag once released:

```yaml
# packages/poltergeist_core/pubspec.yaml
dependencies:
  seance_core:
    git:
      url: https://github.com/L-K-M/Seance.git
      ref: v0.9.3            # tag in steady state; rev only for a stalled
                             # upstream PR (00 D2) — re-pin at release
      path: packages/seance_core
```

`seance_core` depends on `seance_protocol` by relative path inside the Séance
repo; if pub's workspace resolution markers (`resolution: workspace`) block
resolving that from a git checkout, add an explicit twin git dependency on
`seance_protocol` (same `ref`, `path: packages/seance_protocol`) and, only if
still needed, a `dependency_overrides` entry. **M1's first task is verifying
this resolution** in CI before anything builds on it. Pin bumps are routine:
one PR, changelog note of what the bump brings, `dart test` on both local
packages, plus a re-diff of ported files (§8.3).

### 8.2 The PORTS.md ledger

Every Séance app-layer file copied under D2 gets an entry in `docs/PORTS.md`
in the same PR that adds it. Entry format:

```markdown
## app/poltergeist_app/lib/services/atomic_file.dart

- Source: app/seance_app/lib/services/atomic_file.dart
- Séance commit: 4f2a9c1d… (tag v0.9.3)
- Ported: 2026-09-12
- Divergences: none (temp suffix parameterized to `.poltergeist-`)
- Port-back candidates: none
```

The header of the ported file itself carries one attribution line
(`// Ported from Séance <path> @ <short sha>; see docs/PORTS.md.`). Tests
that came with the source file are ported in the same PR (the research notes
list the carry-over set, including the `_FakeRemoteFileSystem` fixture and
`_FakeSftpClient` pattern — the single most valuable test assets).

### 8.3 Rules for editing ported files

1. Fix bugs upstream first when feasible (R10, 04's porting policy); a
   Poltergeist-local fix to ported code must have a reason recorded in
   PORTS.md's `Divergences` line.
2. Every divergence — rename, behavior change, deletion — updates the ledger
   entry in the same PR. An unrecorded divergence is a review blocker.
3. On every Séance pin bump, diff each ported file's source between the old
   and new pinned commits; apply relevant upstream fixes and refresh the
   recorded commit.
4. Never diverge on the safety protocols named in §2.1/§2.3 — those are the
   shared security story; a change there goes upstream or not at all —
   with one escape hatch: a security fix may land locally first if
   PORTS.md records it as a dated divergence, an upstream PR opens in the
   same change, and a re-diff is scheduled on the next pin bump (§8.1's
   stalled-PR mechanism, applied to an edit instead of a ref) — a stalled
   upstream must never be the reason a known vulnerability ships.

## 9. Séance gotchas inherited

Restated from [AGENTS.md](../../AGENTS.md) §4 because each one will bite
during M1–M3:

- **Workspace/app split.** `app/poltergeist_app` stays out of the root
  `workspace:` list and path-depends on the members (resolves fine even
  though members declare `resolution: workspace` — verified in Séance).
- **Explicit test paths, always.** `dart test packages/poltergeist_core
  packages/poltergeist_sync` — a bare `dart test` at the repo root tries to
  build the Flutter app and fails. Same for `dart analyze`. CI already does
  this correctly; humans and agents must too.
- **file_picker ≥ 11 breaks APK builds on AGP 9+** unless Kotlin is
  re-applied to that subproject — copy Séance's `android/build.gradle.kts`
  workaround when the app scaffold adds file_picker.
- **macOS keychain entitlement.** The restricted `keychain-access-groups`
  entitlement blocks ad-hoc-signed builds from launching; use the legacy
  login keychain (`MacOsOptions(usesDataProtectionKeychain: false)`) exactly
  like Séance (D23 ships unsigned/ad-hoc macOS bundles).
- **ASCII product name** everywhere a file name or identifier appears —
  already a tested invariant in `poltergeist_core`; identifiers are
  `com.lkm.poltergeist_app` / `com.lkm.poltergeistApp` / Linux binary
  `poltergeist` (AGENTS.md §3).

## Definition of done

- [ ] `poltergeist_core` and `poltergeist_sync` exist with the module layout
      of §1; the app depends on them by path; dependency rules of §1 hold (no
      `dartssh2` import outside `poltergeist_core`'s connection module,
      none in the app).
- [ ] Séance packages resolve as git dependencies pinned to a tag in CI
      (§8.1), including `seance_protocol` transitively.
- [ ] `LocalFileSystem implements RemoteFileSystem` passes a shared
      conformance test suite run against both it and the
      `_FakeRemoteFileSystem` fixture; Windows caveats of §2.2 are encoded as
      platform-conditional tests.
- [ ] The four local-safety helpers are public in
      `poltergeist_core/lib/src/fs/local_fs_safety.dart` with Séance's tests
      ported.
- [ ] `openAuthenticatedClient` exists upstream in Séance (PR sequenced per
      04) and `ConnectionManager` builds on it with the §3.2 growth rules,
      §3.3 keepalive/reconnect policy, and pool constants in one file.
- [ ] `TransferQueue` implements the §4 task model, scan-then-execute,
      concurrency limits, token-bucket throttle, pause semantics,
      remote→remote piping, JSONL journal + compacted history at the §4.6
      paths, and `TransferProducer`.
- [ ] The engine isolate owns all sockets; `EngineClient` is the only path
      from controllers to filesystems; its protocol preserves the
      cancellation, coalescing, timer-stall, and throughput gates (§5).
- [ ] Controllers follow §6: split notifiers, generation counters,
      `identical()` rechecks — enforced in review.
- [ ] The five channel names of §7.1 are the only platform channels;
      `ScopedPathAccess` fronts all local access with a pass-through backend;
      trash, volumes, and watching follow §7.3–§7.5.
- [ ] `docs/PORTS.md` exists and every ported file has an entry (§8.2).

## Explicitly out of scope

- **Bookmark schema, sync record design, upstream PR sequencing** — 04
  (D4; this chapter only consumes the `BookmarkStore` seam).
- **Sync engine internals** (scan/diff/plan/executor, rsync exporter) — 05
  (D6); this chapter provides its VFS and isolate home only.
- **Editor and checkout pipeline behavior** (built-in editor, external
  editors via `EditorRegistry`, Quick Look UX) — 06 (D17); this chapter
  places `CheckoutManager` and the channels only.
- **UX specification** of panes, sidebar, activity panel, menus, dialogs —
  02 (D11, D16, D21).
- **M0 spike protocol and milestone sequencing** — 07 (D9); this chapter
  consumes D9's pool constants and D8's isolate split.
- **Test strategy details** (conformance suites, sshd-in-Docker matrix,
  benchmarks for D12) — 08.
- **Deferred features touching this architecture** (all D25's parked
  list, plus archives, which are D27's own decision): resumable transfers
  via ranged read, OS drag-out promised files, rsync accelerator,
  multi-window, and archives — the seams exist: `TransferProducer`,
  ranged-read upstream method, `WorkspaceController`-per-window.
- **Agent auth and ProxyJump transport work** — 07 fast-follow (D10), landing
  in `seance_core` for both apps.
