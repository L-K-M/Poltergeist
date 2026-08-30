# 06 — Editing and preview

This chapter elaborates D17: Séance's editor stack ported per D2 and kept
behaviorally identical; the managed-checkout pipeline as an app-wide
`CheckoutManager`; external editors through the reused `EditorRegistry`;
Quick Look on macOS and an in-app preview panel elsewhere. It covers
requirements R8 (built-in editor) and R9 (external editors). Architecture
placement (notifiers, channels, isolates) is 03's; UX chrome, shortcuts, and
dialogs are 02's; this chapter owns the behavior.

## 1. Scope: what "editor" means here

Poltergeist's built-in editor is a **config-file editor, not an IDE** — the
same deliberate scope cut Séance made and tested. It edits the class of file
an SFTP user actually round-trips: nginx configs, dotfiles, crontabs, YAML,
small scripts. Concretely:

- One document per editor screen, pushed as a full-window route (Séance's
  model). No editor tabs, no split editing, no line numbers, no soft-wrap
  toggle, no multiple cursors. The rendering body is a single Flutter
  `TextField` (`expands: true, maxLines: null`) with a custom controller —
  the I/O layer, find logic, and syntax engine are all independent of it, so
  a richer body can be swapped in later without touching them.
- **Limits kept exactly** (D17 — behaviorally identical):
  `builtInEditorMaximumBytes = 4 * 1024 * 1024` (4 MiB), UTF-8 only
  (strict decode, `allowMalformed: false`), NUL-byte scan rejects binary.
- **A file that won't open inline says why**, with Séance's distinct error
  strings kept verbatim in the ported code (they are the English ARB values
  under D20's externalization): too large; "not valid UTF-8"; "appears to be
  binary"; "changed while being opened" (the read-stability check, §2.1).
  When the built-in editor refuses a file, the error surface offers `Open
  With ▸` as the next step — refusal is a router, not a dead end.
- Local files are first-class editor targets too: `file.editBuiltIn`
  (⌥⌘E / Ctrl+Alt+E, 02 §8.3) on a local selection opens the editor
  directly on that file with no checkout and no upload UI (the `onUpload`
  seam is null — the upload affordances disappear entirely, §2.3).

## 2. The ported editor stack (D2, D17)

Three layers, ported copy-with-attribution from Séance
(`app/seance_app/lib/ui/built_in_text_editor.dart`, 763 lines, and
`app/seance_app/lib/ui/editor_syntax.dart`, 761 lines) into
`app/poltergeist_app/lib/ui/` with PORTS.md entries (§2.5). The layering is
what makes the port safe: each layer is independently testable and Séance's
tests come along.

### 2.1 Layer 1 — document I/O (pure functions, no widget deps)

```dart
class BuiltInTextDocument {
  final String text;        // always LF, no BOM, in memory
  final bool hasUtf8Bom;
  final LineEnding lineEnding;   // lf | crlf, majority vote; ties and
                                 // break-free files resolve to lf (§ below)
  final String sha256;      // baseline for conflict detection
}
```

`loadBuiltInTextDocumentDetails(File, {maximumBytes})` — kept verbatim:

- 4 MiB cap checked on `file.length()` **and** on the bytes actually read.
- Read-stability check: SHA-256 streamed before and after `readAsBytes()`;
  mismatch throws "changed while being opened" (cheap TOCTOU insurance).
- Strict UTF-8 decode; NUL scan; BOM detected from the first three bytes;
  CRLF detection by majority vote (`\r\n` count vs lone-`\n` count via
  `(?<!\r)\n` — valid Dart: `RegExp` lookbehind has been supported since
  Dart 2.4 on the VM — a VM/desktop guarantee, not a dart2js/Flutter-web
  one, where the underlying JS engine decides — and this is Séance's
  shipped code at `built_in_text_editor.dart:70`). Ties and files with no line breaks
  resolve to LF — Séance's `crlfCount > lfCount` comparison — pinned by
  the round-trip tests (single-line files must never grow CRLF).

`saveBuiltInTextDocument(File, text, {hasUtf8Bom, lineEnding,
expectedSha256}) → savedSha256` — the atomic two-sibling save dance, kept
step for step (the research notes flag it "do NOT re-implement
differently"):

1. Exclusive-create a temp sibling and immediately chmod it to 0600 on
   POSIX **before any plaintext byte is written** — at umask default
   (typically 0644) the content would sit group/world-readable for the
   whole write/flush/close/SHA sequence, and a crash before step 4
   would strand a world-readable plaintext `.edit` sibling that the
   D15 ignore rules hide from the app's own listings (a deliberate
   divergence from the ported saver if Séance's lacks it — PORTS-noted,
   port-back candidate; step 4 still re-applies the *original* file's
   mode before the rename, so a 644 original saves back to 644; the
   §2.5 save test samples the temp's mode between create and first
   write and asserts group/other bits are clear); then
   write, flush, close, SHA it (that
   digest is the return value and the next baseline).
2. Verify the target is still a regular file
   (`FileSystemEntity.type(followLinks: false)`).
3. `rename(file → backup)`, then SHA the backup against `expectedSha256`;
   mismatch means another program wrote the local file — rename back and
   throw the "changed in another editor. Reopen it…" conflict.
4. Verify nothing re-created the target mid-save; re-apply the original
   file's mode to the temp sibling **before** the rename — the temp was
   created at umask default (typically 0644), and renaming it over a
   §3.1-hardened 600 checkout would silently make the plaintext
   group/world-readable on the very first save (PORTS-noted if Séance's
   saver lacks this; `CheckoutManager.reconcile` re-asserts 600 on
   POSIX when it re-hashes, catching external editors' atomic saves
   too — riding §3.3's existing triggers, which bound the exposure: the
   parent-directory watcher fires when the editor's save lands and
   reconcile runs after the ~600 ms debounce, so a 0644 file left by an
   external atomic save is re-asserted within roughly a second while
   watching works; when watching is degraded the bound degrades with
   it to §3.3's reconcile-on-resume/`reconcileAll`-on-foreground, and a
   test chmods a checkout to 644 and asserts the watcher-path reconcile
   restores 600 — and the §2.5 production-path save test asserts a 600
   checkout
   is still 600 after a save); then `rename(temp → file)`;
   restore the backup on any failure.
5. Delete the backup, **tolerating a failing delete** (a stray backup file
   beats reporting a false save failure). Tolerated strays must not
   accumulate invisibly **in app-owned space**: inside checkout dirs
   (§3.1), `CheckoutManager.reconcile` sweeps stale
   `*.poltergeist-*.edit`/`.backup` siblings matched by §3.3's exact
   generated patterns — skipping any modified within the current save
   window, tolerating and logging failures. Outside app-owned space
   (a plain local file edited in place) there is deliberately **no**
   sweep: deleting pattern-matched files from user-owned directories
   is a side-effect deletion the plan forbids everywhere else, and the
   stray there is the user's own content in its own directory at its
   original mode — the step-6 `finally` covers the normal path.
6. `finally`: close any open handle, delete leftover temp. The size cap is
   re-checked on the encoded output.

Line endings are re-normalized on save (fold to `\n`, expand to CRLF only
when the target ending is CRLF) and the BOM re-prepended — what the user
edits is always LF/no-BOM in memory; the disk form is reconstructed.
**Round-trip byte fidelity is a tested feature** for files with a single
dominant line ending, asserted byte-for-byte in the ported tests; a file
with mixed endings (or lone `\r`) is normalized to its majority ending on
first save, and that normalization is itself pinned by a test.

Sibling temp names change spelling only: `file.poltergeist-<uuid>.edit` and
`file.poltergeist-<uuid>.backup` (the `.seance-` → `.poltergeist-` rename
of 03 §2.2; the D15 ignore rules — `.poltergeist*` and `*.poltergeist-*` —
already exclude them).

### 2.2 Layer 2 — controller, syntax engine, find bar

`editor_syntax.dart` ports verbatim — it has zero app dependencies. The
behaviors that must survive review unchanged:

- `CodeEditingController extends TextEditingController`: tokens **memoized
  on the text instance** (`identical` check) so selection moves don't
  re-scan; falls back to the default span during IME composition
  (`value.isComposingRangeValid`) so highlighting never fights the input
  method; carries search matches + active index; `buildHighlightedSpans`
  zip-merges token and match ranges (a hit over a token keeps the token
  color and adds the hit background; the active match gets its own pair).
- Perf guards: `syntaxHighlightingMaxChars = 200_000` (above it, no
  highlighting and estimated scroll layout), `searchMatchLimit = 1000`
  (counter shows `1/1000+`).
- Find bar: opens with ⌘F/Ctrl+F, prefills from a non-empty single-line
  selection ≤ 200 chars; Enter/Shift+Enter and ⌘G/⇧⌘G (F3/⇧F3 on
  Windows/Linux) step with wrap-around; stepping parks the caret on the
  match so Escape or the case toggle resumes from there; case-insensitive
  by lowercasing with the length-change guard (fall back to case-sensitive
  rather than report misaligned ranges); active-match reveal scrolls the
  match to ~1/3 from the top by laying out only the prefix with a
  `TextPainter` under the highlight cap; search buttons in `ExcludeFocus`;
  document edits re-run the search without resetting the active index.
- `EditorSyntaxTheme` per brightness, swapped in `didChangeDependencies` —
  Poltergeist supplies its own values tuned to the 02 §11 theme (spectral
  teal seed), contrast-checked per D20; the token/search color *slots* stay
  identical.
- Mono stack: the shared list from 02 §11 (`JetBrains Mono, SF Mono, Menlo,
  Consolas, DejaVu Sans Mono, monospace`) — passed in as a parameter (§2.5).

### 2.3 Layer 3 — the editor screen and its seams

`BuiltInTextEditorScreen` keeps Séance's injectable seams exactly — **zero
session/SFTP coupling inside the editor**; all coupling lives in the caller:

```dart
BuiltInTextEditorScreen({
  required File file,           // local file or managed checkout
  String? remotePath,           // display + language detection only
  String? initialText,          // test seam: skips disk I/O
  // TEST-ONLY seam, as in Séance: overrides the atomic saver wholesale,
  // bypassing BOM/CRLF reconstruction and the expectedSha256 conflict
  // check. Production code never passes it — the screen always saves via
  // saveBuiltInTextDocument (§2.1), so the conflict-check path stays live.
  Future<String> Function(File, String)? saveDocument,
  Future<void> Function()? onSaved,     // post-save reconcile hook
  Future<bool> Function()? onUpload,    // save-and-upload; null = local-only
  // Poltergeist parameterization (Séance hardcodes these):
  required void Function(BuildContext, String) showToast,
  required List<String> monoFontFallback,
  required String Function(String) basenameOf,   // remoteBasename from core
                                                 // for remote paths; local
                                                 // callers pass a platform-
                                                 // aware basename (splits `\`
                                                 // too — a Windows local
                                                 // C:\… title must not
                                                 // render the whole path)
})
```

For a remote checkout, the caller wires
`onUpload: () => checkoutManager.uploadLocalCopy(copy, ...)` and
`onSaved: () => checkoutManager.reconcile(copy)` (the per-copy reconcile,
§3.1) — the pipeline of §3. For a local
file, `onUpload` is null and the upload UI disappears. The screen keeps
`PopScope(canPop: !dirty)` with the "Discard unsaved changes?" dialog, the
two-line AppBar title (basename over the full path in `labelSmall`), and
the status bar `N lines · M bytes · Unsaved`.

### 2.4 Save-and-upload semantics and toast copy

Kept exactly (02 §8.3 already reserves the editor-scope shortcuts):

- **⌘S / Ctrl+S = save locally, then upload immediately, no confirmation**
  when an upload target exists. **⇧⌘S / Ctrl+Shift+S = deliberate
  local-only save.** AppBar has separate "Save locally" (disabled when not
  dirty) and "Save and upload" (enabled whenever not saving, so the saved
  state can be re-pushed) buttons.
- Upload result contract, verbatim:

  ```dart
  var uploaded = false; // declared before the try — the finally must see
                        // false when onUpload throws (Séance line 486)
  try { uploaded = await widget.onUpload!(); }
  finally { if (!uploaded) await widget.onSaved?.call(); }
  ```

  The upload reconciles the copy itself; `onSaved` runs whenever the
  upload did not (returned false or threw — hence the `finally`) — and
  after every completed **local-only** save too (⇧⌘S, or ⌘S with
  `onUpload` null): Séance's `else` branch awaits `onSaved` right after
  the save (`built_in_text_editor.dart:497`), so the reconcile hook
  fires on every save that did not upload — pinned by a §2.5 widget
  test so the port cannot drift on the branch Séance's own SFTP-only
  usage never exercised with a null `onUpload`.
  `onSaved` implementations must not throw: an exception there would
  replace the original upload error (Dart `finally` semantics), so
  `reconcile` swallows and logs its own failures.
- Edits made during a save stay unsaved: `_savedText` is set to the value
  captured at save start so the dirty flag re-arms (the ported widget test
  with two `Completer`s guards this race).
- `_baselineSha256` updates from the saver's return and is passed back as
  `expectedSha256` next time — the editor can never silently clobber a
  local file another program touched.
- **Toast wording matrix, kept verbatim** (top toasts only, never
  SnackBars; the toast system is ported in 02 §10):

  | Outcome | Toast |
  |---|---|
  | uploaded, user typed during upload | `Uploaded the saved version; newer edits remain unsaved.` |
  | uploaded, clean | `Saved and uploaded.` |
  | upload returned false | `Saved locally; not uploaded.` — accompanied by the §3.4 conflict-escalation dialog when the cause was a remote change (false is also the result of cancelling that dialog); never a dead end |
  | upload threw | the local save stands and `onSaved` has reconciled the copy (the `finally`); no success toast — the exception propagates to the screen's normal error surface (Séance's behavior: the throw escapes the inner try) |
  | no upload requested (local-only) | `Saved locally.` |
  | the local save itself threw (§2.1's size re-check, or the `changed in another editor. Reopen it…` conflict) | no success toast — the thrown error's message shows as a toast (Séance's catch: `showTopToastIn(context, message: error.toString())`, `built_in_text_editor.dart:512`); the ported error types must override `toString()` to return the bare §1/ARB message so this toast renders those strings exactly — never a default `Exception: ` prefix, or D20's localization can never reach the editor's most safety-critical toast (recorded in the §2.5 divergence row if Séance's types lack the override); neither `onUpload` nor `onSaved` runs, and the document stays dirty |

### 2.5 Port mechanics: renames and PORTS.md entries

Every file below lands with a `docs/PORTS.md` entry (03 §8.2 format) and
its Séance tests in the same PR — plus one production-path save test the
Séance suite lacks: a `BuiltInTextEditorScreen` widget test with **no**
`saveDocument` override, saving through the real
`saveBuiltInTextDocument` onto a real temp file, asserting BOM/CRLF
reconstruction round-trips and that a modified-on-disk file throws the
"changed in another editor" conflict — so the TEST-ONLY seam (§2.3) can
never mask drift in the real save wiring. The only allowed divergences
at port time:

| Ported file (destination under `app/poltergeist_app/`) | Source (Séance) | Divergences |
|---|---|---|
| `lib/ui/built_in_text_editor.dart` | `lib/ui/built_in_text_editor.dart` | temp suffixes `.poltergeist-*`; toast/mono/basename injected as parameters (§2.3) |
| `lib/ui/editor_syntax.dart` | `lib/ui/editor_syntax.dart` | Poltergeist theme values; §7 language additions |
| `lib/services/managed_remote_file.dart` | `lib/services/managed_remote_file.dart` | none |
| `lib/services/managed_remote_file_store.dart` | `lib/services/managed_remote_file_store.dart` | checkout dir `checkouts/` (Séance: `sftp-checkouts/`); **epoch gate on the orphan sweep** — only current-epoch, marker-verified, abandoned-or-empty unindexed dirs may be removed; old-epoch dirs and markerless dirs holding any file never (§3.6 — fixes Séance issue #55, port-back candidate); filename sanitizer extended with Windows reserved-name handling if Séance's lacks it (§3.1) |
| `lib/services/atomic_file.dart` | `lib/services/atomic_file.dart` | temp suffix parameterized (03 §8.2's own example); `quarantineCorruptFile` gets a timestamp suffix (§3.6, port-back candidate) |
| `lib/services/external_file_opener.dart` | `lib/services/external_file_opener.dart` | channel `poltergeist/files`; reserved ids `poltergeist.system` / `poltergeist.builtin` |

`EditorRegistry`, `ExternalEditorDefinition`, `validateEditorDisplayName`,
and `normalizeEditorExtensions` live in Séance's **app layer**
(`app/seance_app/lib/services/external_file_opener.dart`), not
`seance_core` — they arrive as D2 copies with attribution, riding the
ported `external_file_opener.dart` and its PORTS.md entry (04 §1.2).

## 3. The managed-checkout pipeline (CheckoutManager)

The proven Séance design — checkout locally, watch, reconcile, upload back
with conflict escalation — extracted from `RemoteFilesController` into the
app-wide `CheckoutManager` notifier that 03 §6 places. Ownership is per
**server**, never per pane or tab (D17): two panes browsing the same server
see the same checkouts, and closing a tab never orphans an edit.

### 3.1 Placement and identity

```dart
abstract class CheckoutManager extends ChangeNotifier {
  CheckoutManager({
    required ManagedRemoteFileStore store,   // ported, §2.5
    required EngineClient engine,            // stat + transfer tasks (03 §5)
    required TransferProducer producer,      // priority downloads (03 §4.7)
  });

  /// Records for one server, keyed by remote path — an unmodifiable
  /// **snapshot copy per call** (Map.unmodifiable(Map.of(...))), safe to
  /// iterate across awaits and notifyListeners; callers re-fetch after a
  /// notification. A live Map.unmodifiable wrapper would throw
  /// ConcurrentModificationError the moment the watcher mutates mid-walk.
  /// Mutation goes through the APIs below, never around notifyListeners.
  Map<String, ManagedRemoteFile> copiesFor(String serverId);

  Future<ManagedRemoteFile> checkout(String serverId, RemoteFileEntry entry,
      {int? maximumBytes});
  Future<bool> uploadLocalCopy(ManagedRemoteFile copy,
      {bool overwriteRemoteChanges = false});
  Future<void> discard(ManagedRemoteFile copy);      // plaintext, then record
  Future<void> acceptLocal(ManagedRemoteFile copy);  // store.updateBaseline
  Future<void> reconcile(ManagedRemoteFile copy);    // one copy; never throws
  Future<void> reconcileAll();                       // resume/foreground hook
  Future<void> migrateRename(String serverId, String oldPath,
      String newPath);                               // §3.5 rename migration
}
```

- `editSessionId` — Séance's durable per-tab identity — becomes a
  **per-server constant: `editSessionId = serverId`** (the favorite's stable
  id). The store's uniqueness key `(serverId, editSessionId, remotePath)`
  therefore degenerates to `(serverId, remotePath)` with no store changes.
  Because the manager is app-wide, Séance's retained-copies handoff across
  disconnect/reconnect disappears entirely — records simply persist; a
  reconnect changes nothing about checkout identity. One consequence is
  pinned rather than left to surprise: two in-app editors on the same
  `(serverId, remotePath)` would now share one local file and baseline,
  so the second one's save would arm the first's
  `changed in another editor. Reopen it…` refusal (§2.4) — where
  Séance's per-tab identity gave each tab its own copy and surfaced the
  clash at upload time through §3.4's escalation. Poltergeist therefore
  enforces **one live built-in editor session per key**: opening a file
  that already has one focuses the existing editor tab instead of
  opening a second (the D17 divergence row records it; external
  editors are unaffected — the OS owns those windows, and their saves
  already route through §3.3's watch-and-prompt).
- Store layout: index at `<app-support>/managed_remote_files.json`,
  checkout files at `<app-support>/checkouts/<sha256(record id)>/
  <sanitized name>` — the record's `uuidV4()` id is **minted at §3.2
  step 1**, before any filesystem work, precisely so the directory can
  be keyed by it: a per-record dir means two remote files with the same
  basename on one server can never share a local path (hashing
  `serverId` alone would collide `/etc/nginx/nginx.conf` with
  `/home/me/nginx.conf` and fail the exclusive-create with a raw OS
  error), and — unlike a `serverId+remotePath` hash — the dir never has
  to move on a rename, which §3.5's live-external-editor rule forbids
  anyway (`migrateRename` rewrites the record, never the dir). The hash
  keeps external ids out of path
  components, while the file keeps a human-readable sanitized name for
  external editors — and the sanitizer's contract is pinned: it
  neutralizes separators, `.`/`..`, overlong names, trailing
  dots/spaces, and **Windows reserved device names** (`CON`, `PRN`,
  `AUX`, `NUL`, `CONIN$`, `CONOUT$`, `COM1`–`COM9`, `LPT1`–`LPT9`, and
  the superscript-digit variants `COM¹`–`COM³`/`LPT¹`–`LPT³` — matched
  **case-insensitively on the stem before the first dot**, so
  `Nul.conf`, `nul.tar.gz`, and `com3.log` are all caught, with or
  without an extension — prefixed, e.g. `file-nul.conf`), because a remote file
  legitimately named `nul.conf` would otherwise fail the §3.2
  exclusive-create with a raw OS error on Windows, outside every
  designed refusal path; a Windows checkout test for `nul.conf` pins
  it, and the §2.5 divergence row records it if Séance's helper lacks
  the handling. Linux **and macOS** checkout dirs/files get mode
  700/600 — and so do `managed_remote_files.json` and the atomic-write
  temp that replaces it: the index maps server ids to the remote paths
  the user edits (private keys, sensitive configs), a disclosure of its
  own at the umask default (plaintext secrets may pass through the
  checkouts; the macOS default umask
  would otherwise leave them group/world-readable). Séance's helper is
  Linux-only (`_restrictLinuxPermissions`) — the macOS extension is a
  deliberate, PORTS-noted divergence and port-back candidate. Windows
  needs no extra work in v1: the checkout root lives under the per-user
  app-support directory, whose default ACLs already scope it to the
  user — same-user processes and local admins can still read the
  plaintext, the same posture as Linux 600; at-rest encryption is out
  of scope for v1 on every platform.

### 3.2 Checkout

`checkout(serverId, entry, {maximumBytes})`:

1. Regular files only; symlinks and directories refuse with the typed
   `unsupported` error. The record's `uuidV4()` id is minted **here**,
   first — §3.1 keys the checkout directory by its hash, so the id must
   exist before step 2 touches the filesystem (a same-basename
   collision test pins it: two files named `nginx.conf` at different
   remote paths on one server check out into distinct dirs). In-flight de-dup per `(serverId, remotePath)` —
   the manager is app-wide, so a path-only key would collide across
   servers — via a `putIfAbsent`-style flight map; a caller joining an
   in-flight download **pre-refuses on its own `entry.size` when that is
   known and already over its `maximumBytes`** (fail fast — never wait
   out a minutes-long shared transfer just to refuse at the end); when
   the size is unknown and the shared flight is uncapped, the capped
   waiter **watches the shared transfer's running byte count and fails
   its own future the moment the count passes its cap** — the waiter
   never caps the shared sink, it only stops waiting (step 3's "never a
   full download to a certain refusal" guarantee, extended to joined
   waiters); and
   otherwise applies its `maximumBytes` to the awaited
   result (refusing with the too-large reason rather than returning it),
   so a built-in-editor waiter never inherits an uncapped
   external-editor checkout. A waiter's cap refusal — pre-refusal,
   byte-count abort, and end-of-flight refusal alike — **fails only
   that waiter's future, never the shared one**: it is not a failure of
   the download for step 4's cleanup, so it never deletes the file,
   removes the record, or drops the flight-map entry — the completed
   checkout belongs to the caller that started it. An existing checkout for the key is
   returned as-is **only when its local file still exists** (stat it — a
   `missing` copy is re-downloaded through the normal path below and its
   record replaced, so the editor never opens a dangling record; offline,
   the §3.7 `missing`/`Forget` flow applies instead) **and it satisfies
   the caller's `maximumBytes`**
   (checked against a fresh stat of `localPath`, since what opens is the
   local file and the stored `remoteSnapshot.size` goes stale the
   moment an external editor grows the copy — a unit test pins the
   refusal firing at checkout for a locally-grown file, not at editor
   open; otherwise refuse with the §1
   too-large reason string — the built-in editor's loader re-enforces the
   cap at open as the final guard, but the early refusal beats
   open-then-refuse). Flight-map entries are removed on failure or
   cancellation so concurrent waiters retry instead of observing a dead
   future. Checkouts and destructive mutations share **one per-key
   serialization**: `discard` (§3.7's Discard/Forget) and
   `migrateRename`'s record rewrite queue behind any in-flight
   `checkout` for the same key and vice versa — a `checkout` racing a
   `discard` either waits it out or starts fresh after it, and must
   never return a record whose local file is being removed underneath
   the caller (the step-1 stat check closes the dangling-record case
   only when the file is already gone, not mid-removal).
2. Create the checkout file `exclusive: true` after safe-parent creation
   (no symlink traversal — `ensureSafeLocalDirectory`, 03 §2.3). The
   §3.6 epoch marker is already on disk by this point — its rule is
   written **between mkdir and any download**, under the creation
   mutex — so a crash anywhere in steps 2–4 leaves a marker-verified
   dir the sweep can classify, never a markerless one holding a
   partial.
3. Download as a **priority task through the transfer queue** so it is
   visible and cancellable in the activity panel (D16); the checkout is
   never invisible I/O. When the destination is the built-in editor, the
   caller passes `maximumBytes: builtInEditorMaximumBytes` and the stream
   is capped by the ported `_MaximumByteSink` (pre-checked against
   `entry.size` too). External-editor checkouts pass no per-editor cap,
   but **every checkout preflights free space** on the app-support volume
   against `entry.size` (refusing with a clear message when it won't
   fit — checked **after** the cap refusals above, so an over-cap file
   refuses as too-large, never with a misleading won't-fit; a capped
   checkout that passes its cap check has `entry.size ≤ maximumBytes`,
   so `entry.size` is already the worst-case footprint and no separate
   `min()` is needed), and a checkout larger than the §8 large-download confirmation
   threshold (default 100 MiB, shared with preview) asks before queueing:
   `Download 240 MB to edit "access.log"?`. When the remote size is
   unknown (the SFTP size attribute is optional in a listing entry), the
   metadata-time refusals and preflights above cannot fire — the
   `_MaximumByteSink` stream cap is then the built-in-editor guard
   (abort and clean up the moment the cap is exceeded, never a full
   download to a certain refusal), and the free-space preflight degrades
   to surfacing the write failure if the volume fills.
4. Record `ManagedRemoteFile{id: /* minted in step 1 */, serverId,
   editSessionId:
   serverId, remotePath, localPath, remoteSnapshot (the download's entry
   with its streamed `contentSha256`), baselineSha256:
   streamedFileSha256(local)}` → `store.put` (atomic index write) → start
   watching. Any failure — from the moment the checkout file exists:
   stream error, disk-full mid-transfer on an uncapped external
   checkout, cancellation — deletes the partial file (and the
   flight-map entry per step 1), so no truncated payload is left on
   disk for the watcher to churn on and no record is ever written for
   an incomplete download.

Hashing on this pipeline is **mandatory** (D7): the SHA-256 pair —
`baselineSha256` for the local copy, `remoteSnapshot.contentSha256` for the
server — is the conflict authority on both directions.

### 3.3 Watching and the dirty prompt

Kept exactly from Séance (03 §7.5 already reserves this design):

- Watch the checkout's **parent directory**, not the file — editors that
  save via atomic replace change the inode. Debounce 600 ms per checkout
  id, then `store.reconcile(id)`: re-hash the local file; `dirty = digest
  != baselineSha256`; `missing` when the file vanished (missing ⇒ not
  dirty — a model invariant the store enforces). Watch errors fall back to
  reconcile-on-resume (`reconcileAll` on app foreground, Séance's
  `_Bootstrap` lifecycle pattern).
- A copy turning dirty queues a **12 s action toast**:
  `"nginx.conf" changed locally. Upload it?` with an `Upload` action —
  guarded by prompted/uploading sets so a built-in save-and-upload racing
  the watcher never shows a stale prompt. Because the toast is transient,
  dirty copies also raise a **persistent indicator**: a per-file badge on
  the entry in any pane showing it, plus a pane-header chip
  `2 local edits` that opens the §3.7 review dialog — both clear only on
  upload, accept, or discard, so unsaved edits are never invisible during
  a live session.
- Reconcile events for the pipeline's **own** temp files are ignored by
  the debouncer — matched by the exact generated patterns
  (`.poltergeist-<uuid>.upload`, §2.1's `.poltergeist-<uuid>.edit` /
  `.backup` siblings), never by a bare `.poltergeist-` prefix test: a
  remote file legitimately *named* `.poltergeist-notes` checks out
  under its sanitized name and must keep its dirty detection — so an
  upload cycle's own snapshot create/delete (§3.4 step 1) never
  triggers a needless full re-hash of the unchanged checkout (a small
  divergence from Séance, PORTS-noted, port-back candidate; the
  pattern-vs-prefix distinction is pinned by a test whose checkout is
  itself named with the prefix).
- **External saves are never auto-uploaded.** The built-in editor's ⌘S is
  the one explicit save-and-upload; everything else asks first.

### 3.4 Upload-back and conflict escalation

`uploadLocalCopy(copy, {overwriteRemoteChanges})` — the three-way scheme
(local baseline SHA + remote snapshot stat + explicit overwrite
escalation), lifted whole:

1. Copy the checkout to a private sibling snapshot
   `.poltergeist-<uuid>.upload` first (the external editor may keep
   writing mid-upload); hash and size the snapshot.
2. Conflict preflight: re-stat the remote path. Unless overwriting, it
   must still match the recorded `remoteSnapshot` (size + mtime + mode;
   Séance's controller deliberately omits type here — keep identical,
   D17); mismatch or deletion throws the typed `conflict` with the message
   `"nginx.conf" changed or was deleted on the server after it was opened
   locally.`
3. Upload with `overwrite: true`, `preserveMode:
   copy.remoteSnapshot.mode` — the recorded **remote** mode, exactly
   Séance's `remote_files_controller.dart` call; never the local snapshot
   file's mode, which §3.1 hardens to 600 and would strip execute bits
   and group/world readability from every uploaded file — and
   `expectedTarget: overwriteRemoteChanges ? null : copy.remoteSnapshot` —
   because the snapshot carries `contentSha256`, the ported adapter's CAS
   **re-reads and stream-hashes the remote target before commit** (SFTP
   has no server-side hash primitive, so verification is a full remote
   read, cost proportional to file size — small for checkout-class files,
   and the only way to close SFTP v3's 1-second mtime granularity hole;
   kept unconditional, matching Séance). The task runs on the queue as a
   priority upload.
4. After success: baseline := the snapshot's digest; `remoteSnapshot`
   refreshed from a post-upload re-stat of the remote path with
   `contentSha256` := the snapshot's digest — without this the next
   step-2 preflight compares against the pre-upload stat and every
   subsequent save of the same file false-conflicts. When that re-stat
   itself fails after an already-successful upload (a connection drop
   right behind the commit — routine on flaky links), the upload
   **still reports success**: baseline advances to the snapshot's
   digest, `remoteSnapshot` is synthesized from the snapshot (size +
   digest, no server mtime) with a needs-reconcile mark on the record,
   and the next connect's `reconcileAll` repairs the stat — a
   transient stat failure must never surface a succeeded upload as
   failed (inviting a duplicate upload) nor retain the pre-upload stat
   (guaranteeing a false conflict); `dirty` recomputed
   against the *current* local file (typing during upload keeps the copy
   dirty and the prompt machinery live); record updated in the store;
   temp snapshot deleted in a `finally` on **every** exit path —
   success, the step-2 conflict throw, and a step-3 upload failure
   alike, though this sentence sits in the success step: an aborted
   upload must not leave a `.poltergeist-<uuid>.upload` plaintext
   behind that no record references and §3.6/§3.7 can therefore never
   surface or clean (conflicts are a routine path, so the leak would
   accumulate; a test asserts both failure paths leave no sibling). On
   the `overwriteRemoteChanges` path the
   recorded pre-upload mode may itself be stale (a remote chmod after
   checkout is reverted by the upload) — a Séance-identical residual,
   accepted per D17.

The UI (pane or editor) catches **only** the `conflict` kind and escalates
with a dialog per 02 §10's verb rules — safe default first:

> **Remote file changed** — `"nginx.conf"` changed (or was deleted) on
> `prod-web-01` after it was opened locally. Overwrite the remote
> version?
> Buttons: `Cancel` (default) · `Overwrite Remote Version`

The neutral "(or was deleted)" matches step 2's typed message — a
deleted target has no "newer remote version" to overwrite; confirming
there recreates the file at its old path, which the copy must not
misdescribe. Confirming retries with `overwriteRemoteChanges: true`. Any other error
kind surfaces normally (toast + activity-panel row).

### 3.5 Rename migration and delete behavior

- **Rename migrates checkouts**: when a pane renames a remote file or
  directory, `CheckoutManager.migrateRename` rewrites the record (and
  every record under a renamed directory — `key ==` old path or
  `key.startsWith('$oldPath/')`) via `copyWith(remotePath, remoteSnapshot)`
  + `store.update`. Two hardenings on top of the mechanical rewrite:
  (1) an **occupied destination key** — *any* pre-existing record at
  the destination key: a delete-retained record (below), or a **live**
  checkout whose remote target the rename just overwrote (a pane
  rename onto an existing file goes through the confirmed-overwrite
  path, and posix-rename servers replace the target) — is never blind-
  overwritten: the occupying record is re-keyed out of the live
  `(serverId, remotePath)` namespace (unique suffix key; checkout dir
  and record intact) and surfaces through §3.7's review dialog like a
  recovered edit, while the migrated record takes the path key. The
  occupancy check runs **per migrated key** — a directory rename checks
  every destination path under the new prefix — because a blind
  `store.update` would leave the occupant's record overwritten and its
  checkout dir unreferenced. §3.6's hardened sweep does *not* delete
  such a dir (non-empty, no `abandoned` marker — never swept), but the
  occupant's edit is still demoted from a live, key-addressable record
  to an anonymous recovered file the user must stumble on via §3.7 —
  the occupancy check keeps the collision a first-class recoverable
  row instead of a silent demotion. Either record may hold the only copy of an edit (tested:
  checkout `b.conf`, delete remote `b.conf`, rename `a.conf` →
  `b.conf`, migrate — both records survive with distinct ids; and the
  live variant: dirty checkout of `b.conf`, confirmed-overwrite rename
  `a.conf` → `b.conf`, migrate, reload the store — both records
  survive and `b.conf`'s plaintext still exists). (2) `migrateRename` also re-keys
  **pending §3.2 flight-map entries**, and a completing checkout's
  `store.put` re-validates its key against the possibly-migrated record
  before writing — a rename landing during an in-flight checkout must
  not mint a record under the stale pre-rename path (tested: rename
  mid-download, the finished record and its uploads target the new
  path). That re-validation covers the inverse race too: a record
  **migrated onto the completing checkout's own path** while it was in
  flight (checkout of `b.conf` in flight; confirmed-overwrite rename
  `a.conf` → `b.conf`; migration finds no record occupant at `b.conf`
  and takes the key). The completing `store.put` treats *any* differing
  record at its key as an occupied destination and re-keys **itself**
  with a unique suffix exactly like the occupant rule — never a blind
  overwrite (tested: that scenario ends with both records surviving
  under distinct ids, the migrated one on the path key). The local checkout file keeps its pre-rename sanitized name
  (renaming it under a live external editor is unsafe — the editor
  holds the old inode), so every surface that names a managed copy
  (dirty badge, pane chip, §3.7 dialog) displays the record's current
  `remotePath`, never the local basename. Pane controllers must call
  `migrateRename` from their rename
  operation; a rename that skips migration is a review blocker.
- **Delete keeps the checkout**: deleting a remote file deliberately
  retains its managed local copy — it may hold the only copy of an edit.
  The copy then reports its upload preflight as a conflict (target gone),
  which routes the user through the explicit overwrite/discard choice.
- Deleting a **favorite** with unsaved managed edits quantifies them in
  the confirmation (02 §10, Séance's pattern): `Delete "prod-web-01"?
  2 files with unsaved local edits will be deleted with it.`

### 3.6 Store durability rules

The ported `ManagedRemoteFileStore` keeps every rule; the one that must
never regress is called out by name in review:

- **Quarantine, never sweep — hardened with epoch gating.** A corrupt
  index is quarantined via `quarantineCorruptFile` — with a timestamp
  suffix (`managed_remote_files.json.<utc-stamp>.corrupt`, the stamp at
  sub-second precision plus an incrementing `-N` when the target name
  already exists — a same-second relaunch loop must not overwrite the
  first quarantine) so a second
  corruption never destroys the first quarantined evidence (deliberate
  divergence from the ported helper; PORTS-noted) — and unindexed
  checkout directories are **not** swept: any of them may hold the only
  copy of an edit. The ported logic alone does not keep that promise
  past one launch — after quarantine the index file is gone, the next
  load looks "healthy empty", and Séance's sweep would delete every
  pre-quarantine checkout (filed upstream as
  [Séance #55](https://github.com/L-K-M/Seance/issues/55)). Poltergeist
  closes the hole with **epoch-gated sweeping**: the index carries a
  generation id, every checkout dir records its creation epoch in a
  marker file — written immediately after the directory is created and
  before any download lands in it, so no crash window leaves a payload
  without a marker — and the sweep removes only current-epoch,
  marker-verified dirs the parsed index does not reference **and** that
  are either empty or carry an explicit `abandoned` marker: `remove`
  and a cancelled/failed checkout write that marker (under the same
  mutex as the epoch marker) when they intentionally orphan a dir, so
  the sweep has a disposition trail — an unreferenced dir that still
  holds payload files *without* the marker is never swept but surfaces
  through §3.7's `Recovered files` like an old-epoch dir, because the
  paths that produce one (a record lost to a future bug, a partial
  index write, an unhandled migration collision) are exactly where
  deleting would amplify a bookkeeping mistake into data loss. A dir whose
  marker is missing or unreadable is classified **old-epoch** — never
  swept, surfaced through §3.7's `Recovered files` — because the failure
  modes that produce one (crash mid-create, manual tampering, a future
  format change) are exactly the cases where deleting is unsafe. One
  carve-out: a dir verified to contain **no files** — markerless *or*
  old-epoch — carries
  no payload to lose (a crash between mkdir and the marker write leaves
  the markerless kind; §3.7's per-file discards emptying an old-epoch
  dir leave the other), and the sweep may remove it — `Recovered files`
  lists
  only dirs that actually hold a file, so without this width the empty
  old-epoch dir would be never-swept *and* never-listed, accumulating
  invisibly forever; no unnamed dead rows
  accumulate. The sweep — the empty-dir check and its remove included —
  runs **only at store load, before the manager accepts any
  operation**, and holds the creation mutex while it does. The mutex
  alone would not be the guarantee: downloads and the record's
  `store.put` run outside the mkdir→marker-write mutex, and in the span
  between marker-write and the first payload byte a newborn checkout
  dir is current-epoch, marker-verified, unreferenced by the parsed
  index, *and empty* — indistinguishable from an abandoned dir — so a
  sweep allowed to run mid-session (say, hung off a foreground
  `reconcileAll`) could meet every deletion criterion against a live
  checkout. Load-time-only closes that window by construction: no
  checkout can be in flight before the manager accepts operations —
  and the DoD regression test attempts a sweep with a checkout parked
  between marker-write and first payload byte and asserts the dir
  survives. A fresh
  index (post-quarantine or first run) starts a new epoch — and the
  generation id is **minted fresh and unique per index lifecycle**: a
  UUIDv4 (or time-ordered UUIDv7, which additionally makes a rollback
  diagnosable in the audit trail), never a constant first-run value, a
  counter a fresh index resets, or anything derived from swept-able
  on-disk state — a generation that a later lifecycle can repeat would
  re-classify pre-quarantine dirs as current-epoch and resurrect the
  Séance #55 sweep this whole rule exists to kill. The sweep matches
  each dir marker against the current generation by **equality**; any
  mismatch — an older epoch, or one *newer* than the parsed index's
  generation (an older index restored over a newer one — the
  manual-tampering case above) — classifies the dir old-epoch, never
  swept. Older dirs persist until the user discards them
  through §3.7's review dialog, which lists old-epoch dirs as recovered
  files. Port-back candidate.
- All ops serialized through the promise-chain mutex; index written with
  `writeStringAtomically`; rollback-on-flush-failure for put/update/remove;
  `remove` deletes the plaintext before the index entry (never orphan a
  secret); every filesystem touch re-validates the stored relative path
  and refuses symlink traversal.

### 3.7 Recovered edits and offline behavior

Checkouts survive process death and disconnection; the UI must surface
them without a connection (Séance's `_RecoveredLocalEdits`, generalized):

- On connect (or app launch), `reconcileAll` runs for the server; if any
  copies are dirty or missing, panes browsing that server show a
  persistent banner (02 §10 banner component, not a toast):
  `2 files have local edits from a previous session.` with a `Review…`
  button.
- `Review…` — also reachable offline via the favorite's context menu item
  `Local Edits…` — opens a dialog listing each copy: name, remote path,
  last-modified time, `dirty` / `missing` badge, and per-row actions:
  `Open` (a checkout-specific chain, deliberately *not* §4.2's plain
  local `Open` row, which goes straight to the OS default:
  `effectiveDefaultFor(path)` first; when that resolves to the built-in
  editor and the checkout is > 4 MiB or non-UTF-8, fall back to the
  system default instead of dead-ending in a built-in refusal; every
  resolution works offline on the local plaintext), `Upload`
  (disabled while disconnected, tooltip `Connect to upload`), `Discard…`
  (confirms; deletes plaintext then record). A `missing` copy offers
  `Forget` instead of Open/Upload. Old-epoch checkout dirs (§3.6 — files
  recovered from before an index corruption, so no record metadata
  exists) appear in a `Recovered files` section — one row **per file
  the dir actually holds**, not one per dir: external editors leave
  siblings beside the plaintext (vim `.swp`/`~` backups, AppleDouble
  `._*` files), and collapsing a dir to one name would misname or bury
  a payload. Each row shows its file's name with `Open` / `Discard…`
  only; `Discard…` removes that row's file, and the dir itself is
  deleted when its last file goes.
- Nothing auto-uploads on reconnect — same rule as §3.3.

## 4. External editors (R9)

### 4.1 Registry reuse

`EditorRegistry` / `ExternalEditorDefinition` come with the ported
`external_file_opener.dart` (D2 copy-with-attribution, §2.5), behaviorally
unchanged: `{id, displayName, platform (macos/linux/windows),
launchTarget (bundle id on macOS, absolute executable path elsewhere),
acceptedExtensions}` with strict JSON validation (id regex, name
length/control chars, absolute path, `.exe` on Windows — and rejection
of the reserved ids and the whole reserved `poltergeist.` id prefix, so
neither a hand-edited definition nor one arriving through bookmark
backup sync (04) can shadow `poltergeist.builtin`'s §4.2 semantics),
maximum 64
editors and 64 extensions each. The reserved ids are the app-configurable
constants `poltergeist.system` and `poltergeist.builtin`.
`effectiveDefaultFor(path)` resolves the per-extension default;
`compatibleEditors(path)` builds each file's `Open With ▸` menu (02 §9),
which always ends with `Other… ` (pick an application) and
`Configure Editors…` (deep-link to Settings > Editing, §8).

### 4.2 Open resolution and the double-click setting

The `Double-click action` setting (02 §2.6) offers **Open (default) /
Edit in Poltergeist / Transfer to other pane / Do nothing** — Transmit's
default-behavior-as-preference. Resolution of the two editing verbs:

| Verb | Local file | Remote file |
|---|---|---|
| Open | OS default application | `effectiveDefaultFor(path)` first, then checkout: built-in → checkout with the 4 MiB cap, refused from the known remote size *before* any download is queued (§3.2's early-refusal rule — a 90 MiB file must not download in full only to be refused at open); if the downloaded copy then fails the built-in editor's own checks (non-UTF-8, binary), Open falls back to the system default on the checkout file — §3.7's rule, mirrored: a *default-resolution* chain never dead-ends in a built-in refusal; system default / configured editor → checkout (§3.2, no cap), then OS-open / launch on the checkout file |
| Edit in Poltergeist | built-in editor on the file directly | checkout with the 4 MiB cap — refused from the known remote size *before* any download is queued, same rule as the Open row's built-in branch — then built-in editor |
| Open With ▸ (context menu) | chosen editor on the file directly | checkout (no cap), then chosen editor — except a choice of `poltergeist.builtin`, which takes the 4 MiB cap with the early refusal from the known remote size before any download is queued (same rule as the Open row's built-in branch) |

Local files never go through a checkout — Poltergeist is their file
manager, not their custodian — and local Open deliberately bypasses
`effectiveDefaultFor` too: per-extension defaults bind only the
checkout chains (this table's remote rows and §3.7's), because a
double-clicked local file behaving differently from Finder/Explorer
would surprise more than a remote-scoped preference does. If real
usage disagrees, routing local Open through `effectiveDefaultFor(path)`
with a `poltergeist.system` fallback is the one-line unification —
noted here so a future change is a decision, not a drift.
Remote files always do; the checkout is what
makes the external round-trip (watch → prompt → conflict-guarded upload)
possible at all. Where the table says "refused from the known remote
size": a size-less listing entry (the SFTP size attribute is optional)
cannot early-refuse — §3.2's stream cap is then the shared guard for
all three built-in branches, aborting at 4 MiB instead of downloading
fully to a certain refusal. The Open row's system-default fallback is
deliberately *not* mirrored in `Edit in Poltergeist` or an
`Open With ▸` choice of `poltergeist.builtin`: there the user named
the built-in editor explicitly, so a silent hand-off to another
program would betray the choice — those branches refuse with the §1
reason and the `Open With ▸` router, per §1's refusal-is-a-router
rule. The Open row's own **pre-download** size refusal follows that
same router rule: it never auto-falls-back to the system default,
which would force exactly the full download the early refusal exists
to avoid — the system-default fallback applies only once a local copy
already exists.

### 4.3 Launch rules per platform

- **macOS** — via the `poltergeist/files` channel (03 §7.1), the ported
  `seance/files` Swift pattern: `pickApplication` (NSOpenPanel over
  /Applications, returns `{displayName, bundleIdentifier}` read from the
  bundle) and `openWithApplication` (`NSWorkspace.open(urls,
  withApplicationAt:)`, errors surfaced as `FlutterError`, results
  marshalled on the main queue).
- **Windows/Linux** — `Process.start(launchTarget, [path], runInShell:
  false, mode: detached)` after an existence check, plus a POSIX
  executable-bit check on Linux only (NTFS has no executable bit —
  Windows relies on existence plus the definition-time `.exe`
  validation, §4.1).
  **Never through a shell**, never string-concatenated — the argument list
  is the interface. Windows validates the `.exe` extension at definition
  time (registry validation, §4.1).
- Definitions synced from another platform (via bookmark backup, 04) show
  in menus disabled with the `(another platform)` suffix — Séance's
  settings behavior, kept.

### 4.4 External saves: watch and prompt, never auto-upload

The whole external-editor story rides §3.3: the parent-directory watcher
sees the external editor's save (including atomic-replace saves), the
600 ms debounce reconciles, and the dirty copy raises the 12 s
`…changed locally. Upload it?` toast. Upload runs the §3.4 pipeline with
the same conflict escalation. There is deliberately no "auto-upload on
save" setting in v1 — the one-keystroke path is the built-in editor's ⌘S;
for external editors the action toast *is* the fast path.

## 5. Preview

Preview is read-only and cheap; editing is §2–§4. Space (`file.preview`)
is the universal trigger; the per-platform surface follows 02 §11's table:
Quick Look panel on macOS, the in-app preview panel on Windows and Linux
(the panel also exists on macOS via `view.togglePreview` for users who
want a docked preview).

### 5.1 macOS Quick Look channel

`poltergeist/quicklook` (03 §7.1), ~60–100 lines of Swift in
`MainFlutterWindow.swift` — the Séance channel style, no plugin:

- Methods: `showPreview(paths: List<String>, index: int)`,
  `updatePreview(paths, index)` (selection changed while the panel is
  open), `hidePreview()`, `isVisible() → bool`.
- Swift side: the window overrides `acceptsPreviewPanelControl`,
  `beginPreviewPanelControl`, `endPreviewPanelControl`; a
  `QLPreviewPanelDataSource` serves the given file URLs;
  `QLPreviewPanel.shared().makeKeyAndOrderFront(nil)` shows it. Arrow keys
  inside the panel step through the items natively.
- Dart side: Space on a **local** selection sends the selected paths and
  the focused index immediately. On a **remote** selection, the focused
  item is first produced into the preview cache via
  `TransferProducer.produceLocalCopy` (03 §4.7 — this is the hook's
  day-one consumer) with visible progress and Esc-cancel (02 §2.6), then
  previewed; remote multi-selection previews the focused item only in v1.
  While the panel is open, a selection change (or arrow step) onto a
  remote item not yet in the preview cache keeps the current item
  visible until `produceLocalCopy` completes (progress per 02 §2.6, Esc
  cancels the production; the §8 large-download confirmation gates
  *every* production — the initial Space press and arrow-step
  continuations alike — presented as a non-blocking overlay card in the
  **Poltergeist window**, attached to the pane that owns the selection:
  the native `QLPreviewPanel` cannot host Flutter content, and a modal
  over it is forbidden. Arrow keys keep working while the card shows
  (the previous item stays visible in the panel), so arrowing past a
  huge file never queues surprise
  traffic and never traps navigation) — `updatePreview` is only ever
  called with produced local paths, never a path Quick Look cannot
  read. Every production and every confirmation card is tagged with
  the **selection generation** that requested it: a completion whose
  generation no longer matches the focused selection updates nothing
  (its produced file simply lands in the cache for later), and a card
  is dismissed or re-targeted by the focus change that staled it — a
  slow huge item can never yank the panel back off a newer selection,
  and a lingering card can never confirm a download for an item the
  user already left.
  Space again (or Esc in the panel) closes. Esc while a production is
  in flight cancels that production — and because the native
  `QLPreviewPanel` owns Esc and closes itself, cancel and close happen
  together; more generally, the panel closing by **any** route either
  cancels its in-flight production or lets it complete silently into
  the preview cache without ever calling `updatePreview` (the
  generation rule above already covers the landing), mirroring §5.2's
  Esc semantics — a production finishing after close must never call
  into, or reopen, a panel the user dismissed.

### 5.2 The in-app preview panel

`app/poltergeist_app/lib/ui/preview_panel.dart` (new code, not a port). A
window-level rightmost panel, sized by the adaptive-layout allocator
(02 §1), hidden by default, toggled by `view.togglePreview`
(⌥⌘P / Ctrl+Alt+P); on Windows/Linux, Space opens it focused on the
selection and Space again closes it — Quick Look cadence without Quick
Look — except while the §5.3 `Press Space to download a preview` card is
showing, where Space starts the download instead. Space is a
per-focused-item state machine: card with prompt → Space downloads —
through the same §8 large-download confirmation as §5.1 when the item
is over-threshold, with **confirmation-pending as its own state**
(Space is a no-op there; Esc dismisses the card's confirmation without
closing the panel); download in flight → Space is a no-op and Esc
cancels the download without closing the panel (never a second queued
task *for that item*); preview rendered (or a promptless card) → Space
closes; failed or cancelled → the prompt card returns, so Space
retries. A focus change re-evaluates
the new item's state — an uncached previewable remote item shows the
§5.3 prompt card (Space downloads), a cached or local item renders
immediately (Space closes) — while an in-flight production for the
item the user left **keeps running** as its visible queue task (§5.3):
its completion fills the cache under §5.1's generation rule, and
cancelling it belongs to the queue row's Cancel or a re-focused Esc,
never to the focus change itself. It tracks the focused pane's focused entry; on
multi-selection it
previews the focused item — matching §5.1's Quick Look behavior on every
platform — with the count + total size summary shown as a header above the
preview.

Extension matching throughout this table (and §7's detection map) is
**case-insensitive** — `IMG_0001.JPG` previews like `img_0001.jpg`.

| Kind (by extension) | v1 rendering | Guards |
|---|---|---|
| Text (anything §7's detection maps, plus unknown-but-UTF-8) | read-only viewer on the document layer + syntax engine (§2.1/§2.2) | first 1 MiB only, via a preview-specific partial read that truncates on a UTF-8 codepoint boundary (not the whole-file 4 MiB loader), with a `Preview truncated — Open in editor` bar; refusal reasons reuse the §1 strings. Remote text previews still transfer the whole file into the §5.3 cache (Quick Look and re-preview need it; the §8 large-download threshold confirms over-threshold downloads, and §5.3's cache-cap refusal still applies from metadata above the cap — two gates, not one) — a documented tradeoff, not an accident |
| Images: png, jpg/jpeg, gif, webp, bmp | Flutter image decode, fit-to-panel, dimensions caption | decode refused over 64 MiB file size — metadata card instead; for remote files the refusal is applied from the known remote size *before* any download is queued |
| PDF | rasterized pages behind a `PreviewRenderer` seam; the concrete rasterizer package is chosen at implementation time behind that seam, and any platform where it is unavailable shows the metadata card with `Open With ▸` | first 20 pages, headed `Page 1–20 of M` with the text row's `Preview truncated — Open in editor`-style bar when M > 20 (a bare total would hide that 180 pages are missing); decode refused over 64 MiB file size — the image row's guard mirrored, because rasterizing an unbounded PDF is memory exhaustion, not just jank: metadata card instead, with the remote refusal applied from the known remote size before any download is queued |
| Everything else | metadata card: big type icon, name, kind, size, dates + `Open` / `Open With ▸` buttons | — |

As in §4.2, a size-less remote listing entry cannot early-refuse
against the image/PDF rows' 64 MiB guard — §5.3's unknown-size rule
covers it (stream under the kind cap, abort at the limit), so the
worst case is confirmed-and-aborted bandwidth, never a surprise or an
overfull cache.

The panel never blocks the pane: rendering runs async with the standard
generation-counter/`identical()` idioms (03 §6). Selection changes
cancel in-flight **render/decode** work only — an explicitly requested
production is a visible queue task (§5.3) and keeps running;
`RemoteTransferCancellation` fires from the queue row's Cancel or the
Esc-while-focused state above, never from a selection change, or a
download the user deliberately confirmed would silently die the moment
they clicked another row.

### 5.3 Remote preview rules and cache

- **Remote preview is always an explicit action** — selecting a remote
  file of a *previewable* kind (a §5.2 text/image/PDF row, under that
  row's guard) shows the metadata card with `Press Space to download a
  preview` (button equivalent for the mouse). Kinds whose row refuses
  from metadata alone — the Everything-else card row, an over-64 MiB
  image or PDF, a file whose known remote size exceeds the preview-
  cache cap (below) — show the card **without** the prompt, and Space
  keeps its §5.2
  close role there: the prompt never appears where pressing it could do
  nothing or download pointlessly. No implicit downloads on selection;
  a latency-prone pane must never generate surprise traffic. (One
  consequence, accepted as a v1 gap: an extensionless remote file not
  caught by §7's basename/shebang detection always lands on the
  Everything-else card — the unknown-but-UTF-8 text kind is decidable
  only from bytes, and metadata is all a remote row has before a
  download.)
- Downloads go through the queue as priority tasks (visible,
  cancellable; "priority" means ahead of background sync traffic only —
  never preempting user-initiated transfers or checkouts, which would
  be the surprise traffic this section forbids)
  into `<app-support>/preview-cache/`, file name
  `<sha256(jsonEncode([serverId, remotePath, mtimeSeconds, size]))>` —
  `mtimeSeconds` being floored integer Unix seconds, so an int and a
  fractional double source can never encode the same file to two
  different keys — plus the
  original extension (Quick Look and image decoding both key type off the
  extension). JSON-encoding the fields keeps the key unambiguous — remote
  paths may legally contain `\n`. The mtime+size key self-invalidates on
  change, except a same-second, same-size rewrite (SFTP v3 mtime is
  second-granular) — a documented residual race, accepted in v1.
- A kind whose row above refuses from metadata alone (oversized image, the
  metadata-card row) never downloads at all — the guard runs against the
  known remote size before anything is queued. A file whose remote size
  is **unknown** (the SFTP size attribute is optional) streams under
  the tightest applicable cap instead — its kind's §5.2 byte cap where
  one exists (only the image/PDF 64 MiB caps qualify: the text row's
  1 MiB is a *render* truncation, not a download cap — the same row
  mandates whole-file transfer — so unknown-size text streams under
  the preview-cache cap), the preview-cache cap otherwise (§5.1 Quick
  Look
  productions have no kind cap) — and aborts at the limit: never
  fetched whole to a certain refusal, never past the cache cap (§6's
  rule, applied to every preview path; DoD covers the abort).
- Cache is LRU-capped at 512 MiB (setting, §8) with a `Clear Preview
  Cache` button — enforced on every insert, evicting
  least-recently-**used** first (a Quick Look production or re-preview
  hit refreshes recency — true LRU, not insertion-order FIFO, which
  would evict a hot entry while stale ones survive) until
  the new file fits; lowering the setting evicts now-over-cap entries
  at the next enforcement pass (the cache must never itself hold what
  it would refuse to admit), and concurrent completions may transiently
  exceed the cap by at most the in-flight batch. A file whose known
  remote size exceeds the cache cap
  is refused from metadata before anything is queued — the prompt never
  offers a download the cache cannot hold (the promptless-card class,
  first bullet), and lowering the cap setting below the confirmation
  threshold narrows what may download rather than ungoverning it; files
  over the §8 large-download threshold (default 100 MiB) but within
  the cap ask before downloading:
  `Download 40 MB to preview "panorama.pdf"?` → `Download` / `Cancel` —
  an example at a user-**lowered** threshold (say 32 MiB), deliberately:
  per the reachability note below, this panel path never prompts at the
  100 MiB default, and an over-100 MB example would be impossible here
  at *any* threshold (no panel-previewable kind passes the 64 MiB kind
  caps).
  Reachability, §6's analysis applied here: for the in-app panel this
  prompt fires only when the threshold is *lowered* below §5.2's
  64 MiB kind caps — no panel-previewable kind exceeds them, so the
  default never fires on this path (a test asserting it fires at
  defaults would be testing an impossible branch). The 100+ MB class
  stays real on the threshold's other surfaces: §5.1 Quick Look
  productions (Quick Look renders kinds the panel cannot — video,
  archives) and §3.2 external-editor checkouts.
- The cache directory is preview-only plumbing: never watched, never
  reconciled, never uploadable — editing goes through §3's checkouts
  exclusively.

## 6. Diff affordance for sync pairs

05 §7 specifies: double-clicking a changed pair in the sync plan opens the
two versions side by side; the computed text diff is a v1.x item. Both live
in `app/poltergeist_app/lib/ui/compare_view.dart`, built on the editor's
document layer (§2.1) — not on the preview panel, because line-accurate
text handling (BOM/CRLF, limits, mono rendering) is the editor stack's job.

**v1 — side-by-side view.** Two read-only viewer columns (document layer +
syntax engine + find bar each), headers showing side label, full path,
size, and mtime. Remote sides are produced into the preview cache (§5.3)
first — opening the compare view is itself the explicit download action
for each remote side (queue-visible, cancellable; no per-side Space
press, or 05 §7's double-click-opens-both promise would break) — though
the §8
large-download confirmation is unreachable here **at the default
threshold**: a side whose known remote size
exceeds the 4 MiB loader cap is refused *before* any download is
queued (a side whose remote size is unknown streams under §3.2's byte
cap instead — aborted at 4 MiB, never fetched whole to a certain
refusal), and 4 MiB is far below the 100 MiB default. If the user lowers the §8
threshold below the cap, the confirmation applies to compare sides as
usual — §8 lists them among the gated surfaces, and the pre-download
refusal still fires first for over-cap sides.
Each side loads through `loadBuiltInTextDocumentDetails` with the
4 MiB/UTF-8 limits; a side that refuses to load renders its §1 reason
string in place, leaving the other side readable. A notice chip surfaces differences the text view cannot
show: `Line endings differ: LF vs CRLF` and `BOM differs` (majority-vote
normalization would otherwise hide exactly those diffs). Scrolling is
independent in v1; no change detection is claimed.

**v1.x — the minimal diff view** (milestone in 07):

- Line-based Myers diff over the two in-memory texts (already
  LF-normalized by the loader), computed off the UI isolate.
- Rendering: side-by-side aligned rows — added/removed rows tinted with
  theme-aware, contrast-checked diff colors (new `EditorSyntaxTheme`-style
  slots, D20), gap rows on the opposite side — plus an inline/unified
  toggle. n/N change navigation via the find-bar chrome; a header count
  `12 changed regions`.
- Caps: each side ≤ 4 MiB (inherited) and ≤ 20 000 lines for diff
  computation; over the line cap the view degrades to the v1 side-by-side
  with a notice. No intra-line (word) diffing, no editing, no three-way
  merge — surfaced-not-resolved is the sync chapter's rule and this view
  inherits it.

## 7. Syntax additions for the file-manager audience

Séance's 12 declarative families target what an SSH terminal user edits.
Poltergeist's audience adds web-hosting file types. All additions are
**data-only** — new `SyntaxLanguage` declarations and detection-map
entries; the tokenizer and controller are untouched (that declarative shape
is the point of the engine). Each addition ships with a tokenizer smoke
test and a detection test, and is a port-back candidate recorded in
PORTS.md (R10).

| Addition | Kind | Detection | Declaration notes |
|---|---|---|---|
| css | new family | `.css`, `.scss`, `.less` | block comments `/* */`; strings; numbers on; meta pattern for property names (`[-a-zA-Z]+` before `:`), honoring the engine's documented meta-group invariant; `//` line comments in `.scss`/`.less` are an **accepted gap** — a `//` rule would tokenize unquoted `url(http://…)` values as comments |
| ruby | new family | `.rb`, `.rake`, `.gemspec`; basenames `Gemfile`, `Rakefile`, `config.ru`; shebang `ruby` | `#` line comments (boundary flag on), keywords, strings; `=begin/=end` deliberately omitted (BOL-anchored block comments are outside the engine's declarative shape — accept the gap, don't grow the engine) |
| perl | new family | `.pl`, `.pm`; shebang `perl` | `#` line comments, keywords, strings; POD omitted for the same reason |
| lua | new family | `.lua`; shebang `lua` | `--` line comments, `--[[ ]]` block comments — the block-comment rule declared before **both** the `--` line-comment rule and the `[[` multiline-string rule, so `--[[` is neither consumed as a comment-to-EOL (stranding `]]`) nor as a string — `[[ ]]` multiline strings, keywords — equality-level long brackets (`[==[ … ]==]`, `--[==[ … ]==]`) are an **accepted gap**, stated like ruby's `=begin` and perl's POD: `--[==[` falls through to the `--` line-comment rule and a bare `[==[` matches nothing; the smoke test must pin both `--[[ comment ]]` spanning lines and plain `[[ string ]]` |
| Apache dot-configs | mapping only | basenames `.htaccess`, `.htpasswd` → ini family | ini's `#`-after-boundary comments and `[section]` meta cover `.htaccess`; `.htpasswd` (`user:hash` lines) matches no ini rule and is mapped only so it opens as text rather than unknown — an accepted gap, stated so the detection tests don't imply coverage |

Already covered upstream, no change needed: `php` maps to the c-family
soup; nginx-style configs are covered by ini; `sql`, `xml/html`,
`markdown`, `json`, `yaml`, `dockerfile` all exist. The screen keeps
Séance's re-detection after load using the first line, so extensionless
scripts pick up their shebang.

## 8. Editor settings (Settings > Editing)

One settings tab, structured like Séance's Files tab (its
`settings_screen.dart` registry UI is the direct model — "80% reusable"
per the research), using the immediate-persist model with Séance's
reference idiom for toggles: capture requested value → save → newer
in-flight change owns the apply → revert field and memory on failure.
Sections (each with the `?` help-dialog affordance):

- **Opening files** — the `Double-click action` dropdown (§4.2; the
  authoritative option list is 02 §2.6).
- **Default editor** — dropdown: `Built-in editor` / `System default` /
  each configured external editor; other-platform definitions disabled
  with `(another platform)`. Removing the current default resets the
  default to `System default`. Removing an editor — or removing an
  extension from one via `Edit Extensions…` — also strips the matching
  per-extension default entries (§4.1's `effectiveDefaultFor` falls
  back to the global default for those extensions) — no dangling editor
  id, and no per-extension default pointing at an editor that has
  disclaimed the extension, survives either path.
- **External editors** — the registry list: per-editor row with display
  name, launch target, and accepted extensions rendered as `*.ext` chips;
  row actions Edit Extensions… and Remove; `Add Editor…` uses
  `pickApplication` on macOS and a native executable picker on
  Windows/Linux. Validation errors (bad path, non-`.exe` on Windows, too
  many extensions) render inline under the row.
- **Preview & downloads** — named for both things it owns, because the
  threshold below also gates external-editor checkouts, which nobody
  would hunt for under plain "Preview" — preview-cache size limit
  (default 512 MiB), `Clear
  Preview Cache` (shows reclaimed bytes in a toast), and the
  **large-download confirmation threshold** (default 100 MiB) — one
  setting shared by remote previews (§5.3), Quick Look productions
  (§5.1), compare sides (§6), and
  external-editor checkouts (§3.2).

`Open With ▸ Configure Editors…` and the §3.7 review dialog deep-link here
via `openSettings(initialTab:)` (Séance's deep-link pattern). Editor
*behavior* deliberately gets no settings in v1 — D17 pins the ported stack
to Séance's behavior; a divergence wants an upstreamable reason, not a
preference.

## Definition of done

- [ ] Editor stack ported per §2.5 with PORTS.md entries and Séance's test
      suites (I/O round-trip byte-for-byte, conflict save leaves external
      change intact, mid-save-edit race, find-bar walk, chord tests for
      both Ctrl and Meta) green under Poltergeist names; temp siblings are
      `.poltergeist-*`.
- [ ] ⌘S/⇧⌘S semantics, the upload `try/finally` contract, and the §2.4
      toast matrix verified by widget tests using injected
      `saveDocument`/`onUpload` fakes; toast strings match verbatim.
- [ ] `CheckoutManager` implements §3: per-server ownership
      (`editSessionId = serverId`), queue-visible checkouts with the
      dedup-hit size check and flight-map cleanup, free-space preflight +
      large-download confirmation, 600 ms parent-dir watch reconcile with
      the `.poltergeist-` event filter, dirty/missing invariant, 12 s
      prompt plus the persistent badge/chip indicator, snapshot-first
      upload with CAS + escalation dialog, rename migration (file and
      subtree, occupied-destination and in-flight cases),
      delete-keeps-checkout, and **epoch-gated quarantine-never-sweep**
      (regression tests cover corrupt → restart → no pre-quarantine dir
      deleted, generation uniqueness across index lifecycles, that
      an equality-mismatched marker — older *or* newer than the current
      generation — is never swept, that a live occupant survives a
      confirmed-overwrite rename with its plaintext intact, and the
      disposition trail: a cancelled checkout's abandoned-marked dir
      sweeps with no Recovered row, while a dir orphaned by a simulated
      index regression survives reload into Recovered files).
- [ ] Recovered-edits banner + review dialog work with the server
      disconnected (open/discard offline; upload disabled with reason).
- [ ] External editors: registry ported with `external_file_opener.dart`
      (D2 copy, §2.5), reserved ids
      `poltergeist.*`, `Open With ▸` from `compatibleEditors`, macOS
      launches via `poltergeist/files`, Windows/Linux via
      `Process.start(..., runInShell: false)` — verified by the ported
      external-editor tests plus a launch-arguments test.
- [ ] Double-click action resolves per the §4.2 table; local files never
      checkout; every remote built-in-editor path — `Open`'s built-in
      branch, `Edit in Poltergeist`, and an `Open With ▸` choice of
      `poltergeist.builtin` — refuses over-cap files from the known
      remote size before any download is queued, and streams under
      §3.2's byte cap when the size is unknown, aborting at the limit
      instead of fetching the whole file (both paths tested).
- [ ] Quick Look channel per §5.1 (show/update/hide/isVisible, panel
      control overrides); Space produces remote files through
      `TransferProducer` with progress and Esc-cancel.
- [ ] Preview panel per §5.2 with the kind table, caps, explicit remote
      action, keyed LRU cache, and **render/decode** cancellation on
      selection change (transfers keep running — only the queue row's
      Cancel or a re-focused Esc cancels a production, per §5.2).
- [ ] Sync-plan double-click opens the v1 side-by-side compare view with
      the line-ending/BOM notice chips; unloadable sides degrade to
      reason strings.
- [ ] §7 language additions land as data with smoke + detection tests and
      PORTS.md port-back notes.
- [ ] Settings > Editing implements §8, including deep-links and the
      immediate-persist revert idiom.
- [ ] All §1 refusal strings, dialog copy, and toasts live in ARB (D20)
      with the Séance-verbatim English values.

## Explicitly out of scope

| Deferred item | Where it lives |
|---|---|
| Computed text diff view (Myers, inline toggle) | v1.x, milestone in 07 (§6 specs it; 05's out-of-scope table defers it here) |
| Cross-pane "Compare selected items" entry point | v1.x, 07 (reuses §6's view) |
| Richer editor body (line numbers, gutter, multi-cursor, e.g. `re_editor`) | v2 parking (D25 spirit); the §2 layering keeps the swap cheap |
| Auto-upload-on-external-save option | not planned for v1; revisit only with a real demand signal (§4.4 rationale) |
| Editing non-UTF-8 or > 4 MiB files in-app | not planned; `Open With ▸` is the answer (§1) |
| Native thumbnails in preview/panes (QuickLookThumbnailing etc.) | v1.x channel behind the icon seam, 02 §11 / 03 §7 |
| Remote multi-item Quick Look prefetch | v1.x with the preview cache warmed by 07's polish milestone |
| Shared-package extraction of the editor stack (`ecto_editor`) | 04 §porting policy — welcome after the upstream PRs, never a blocker (D2) |
| Checkout-store sync/backup across devices | never — checkouts are device-local working state; only bookmarks sync (04) |
