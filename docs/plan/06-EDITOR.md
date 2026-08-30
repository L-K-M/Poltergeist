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
  Dart 2.3, and this is Séance's shipped code at
  `built_in_text_editor.dart:70`). Ties and files with no line breaks
  resolve to LF — Séance's `crlfCount > lfCount` comparison — pinned by
  the round-trip tests (single-line files must never grow CRLF).

`saveBuiltInTextDocument(File, text, {hasUtf8Bom, lineEnding,
expectedSha256}) → savedSha256` — the atomic two-sibling save dance, kept
step for step (the research notes flag it "do NOT re-implement
differently"):

1. Exclusive-create a temp sibling, write, flush, close, SHA it (that
   digest is the return value and the next baseline).
2. Verify the target is still a regular file
   (`FileSystemEntity.type(followLinks: false)`).
3. `rename(file → backup)`, then SHA the backup against `expectedSha256`;
   mismatch means another program wrote the local file — rename back and
   throw the "changed in another editor. Reopen it…" conflict.
4. Verify nothing re-created the target mid-save; `rename(temp → file)`;
   restore the backup on any failure.
5. Delete the backup, **tolerating a failing delete** (a stray backup file
   beats reporting a false save failure).
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

  The upload reconciles the copy itself; `onSaved` runs only when the
  upload did not (returned false or threw — hence the `finally`).
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

### 2.5 Port mechanics: renames and PORTS.md entries

Every file below lands with a `docs/PORTS.md` entry (03 §8.2 format) and
its Séance tests in the same PR. The only allowed divergences at port time:

| Ported file (destination under `app/poltergeist_app/`) | Source (Séance) | Divergences |
|---|---|---|
| `lib/ui/built_in_text_editor.dart` | `lib/ui/built_in_text_editor.dart` | temp suffixes `.poltergeist-*`; toast/mono/basename injected as parameters (§2.3) |
| `lib/ui/editor_syntax.dart` | `lib/ui/editor_syntax.dart` | Poltergeist theme values; §7 language additions |
| `lib/services/managed_remote_file.dart` | `lib/services/managed_remote_file.dart` | none |
| `lib/services/managed_remote_file_store.dart` | `lib/services/managed_remote_file_store.dart` | checkout dir `checkouts/` (Séance: `sftp-checkouts/`); **epoch-gated orphan sweep** (§3.6 — fixes Séance issue #55, port-back candidate) |
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
class CheckoutManager extends ChangeNotifier {
  CheckoutManager({
    required ManagedRemoteFileStore store,   // ported, §2.5
    required EngineClient engine,            // stat + transfer tasks (03 §5)
    required TransferProducer producer,      // priority downloads (03 §4.7)
  });

  /// Live records for one server, keyed by remote path — an unmodifiable
  /// view (Map.unmodifiable): mutation goes through the APIs below, never
  /// around notifyListeners.
  Map<String, ManagedRemoteFile> copiesFor(String serverId);

  Future<ManagedRemoteFile> checkout(String serverId, RemoteFileEntry entry,
      {int? maximumBytes});
  Future<bool> uploadLocalCopy(ManagedRemoteFile copy,
      {bool overwriteRemoteChanges = false});
  Future<void> discard(ManagedRemoteFile copy);      // plaintext, then record
  Future<void> acceptLocal(ManagedRemoteFile copy);  // store.updateBaseline
  Future<void> reconcile(ManagedRemoteFile copy);    // one copy; never throws
  Future<void> reconcileAll();                       // resume/foreground hook
}
```

- `editSessionId` — Séance's durable per-tab identity — becomes a
  **per-server constant: `editSessionId = serverId`** (the favorite's stable
  id). The store's uniqueness key `(serverId, editSessionId, remotePath)`
  therefore degenerates to `(serverId, remotePath)` with no store changes.
  Because the manager is app-wide, Séance's retained-copies handoff across
  disconnect/reconnect disappears entirely — records simply persist; a
  reconnect changes nothing about checkout identity.
- Store layout: index at `<app-support>/managed_remote_files.json`,
  checkout files at `<app-support>/checkouts/<sha256(id)>/<sanitized
  name>` — the directory name is a hash so external ids never become path
  components, while the file keeps a human-readable sanitized name for
  external editors. Linux **and macOS** checkout dirs/files get mode
  700/600 (plaintext secrets may pass through; the macOS default umask
  would otherwise leave them group/world-readable). Séance's helper is
  Linux-only (`_restrictLinuxPermissions`) — the macOS extension is a
  deliberate, PORTS-noted divergence and port-back candidate. Windows
  needs no extra work in v1: the checkout root lives under the per-user
  app-support directory, whose default ACLs already scope it to the
  user.

### 3.2 Checkout

`checkout(serverId, entry, {maximumBytes})`:

1. Regular files only; symlinks and directories refuse with the typed
   `unsupported` error. In-flight de-dup per `(serverId, remotePath)` —
   the manager is app-wide, so a path-only key would collide across
   servers — via a `putIfAbsent`-style flight map; a caller joining an
   in-flight download applies its own `maximumBytes` to the awaited
   result (refusing with the too-large reason rather than returning it),
   so a built-in-editor waiter never inherits an uncapped
   external-editor checkout. An existing checkout for the key is
   returned as-is **only when its local file still exists** (stat it — a
   `missing` copy is re-downloaded through the normal path below and its
   record replaced, so the editor never opens a dangling record; offline,
   the §3.7 `missing`/`Forget` flow applies instead) **and it satisfies
   the caller's `maximumBytes`**
   (checked against `remoteSnapshot.size`; otherwise refuse with the §1
   too-large reason string — the built-in editor's loader re-enforces the
   cap at open as the final guard, but the early refusal beats
   open-then-refuse). Flight-map entries are removed on failure or
   cancellation so concurrent waiters retry instead of observing a dead
   future.
2. Create the checkout file `exclusive: true` after safe-parent creation
   (no symlink traversal — `ensureSafeLocalDirectory`, 03 §2.3).
3. Download as a **priority task through the transfer queue** so it is
   visible and cancellable in the activity panel (D16); the checkout is
   never invisible I/O. When the destination is the built-in editor, the
   caller passes `maximumBytes: builtInEditorMaximumBytes` and the stream
   is capped by the ported `_MaximumByteSink` (pre-checked against
   `entry.size` too). External-editor checkouts pass no per-editor cap,
   but **every checkout preflights free space** on the app-support volume
   against `entry.size` (refusing with a clear message when it won't
   fit), and a checkout larger than the §8 large-download confirmation
   threshold (default 100 MiB, shared with preview) asks before queueing:
   `Download 240 MB to edit "access.log"?`.
4. Record `ManagedRemoteFile{id: uuidV4(), serverId, editSessionId:
   serverId, remotePath, localPath, remoteSnapshot (the download's entry
   with its streamed `contentSha256`), baselineSha256:
   streamedFileSha256(local)}` → `store.put` (atomic index write) → start
   watching. Any failure deletes the checkout file.

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
- Reconcile events for basenames matching the `.poltergeist-` temp
  convention are ignored by the debouncer, so an upload cycle's own
  snapshot create/delete (§3.4 step 1) never triggers a needless full
  re-hash of the unchanged checkout (a small divergence from Séance,
  PORTS-noted, port-back candidate).
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
   subsequent save of the same file false-conflicts; `dirty` recomputed
   against the *current* local file (typing during upload keeps the copy
   dirty and the prompt machinery live); record updated in the store;
   temp snapshot always deleted. On the `overwriteRemoteChanges` path the
   recorded pre-upload mode may itself be stale (a remote chmod after
   checkout is reverted by the upload) — a Séance-identical residual,
   accepted per D17.

The UI (pane or editor) catches **only** the `conflict` kind and escalates
with a dialog per 02 §10's verb rules — safe default first:

> **Remote file changed** — `"nginx.conf"` changed on `prod-web-01` after
> it was opened locally. Overwrite the newer remote version?
> Buttons: `Cancel` (default) · `Overwrite Remote Version`

Confirming retries with `overwriteRemoteChanges: true`. Any other error
kind surfaces normally (toast + activity-panel row).

### 3.5 Rename migration and delete behavior

- **Rename migrates checkouts**: when a pane renames a remote file or
  directory, `CheckoutManager.migrateRename` rewrites the record (and
  every record under a renamed directory — `key ==` old path or
  `key.startsWith('$oldPath/')`) via `copyWith(remotePath, remoteSnapshot)`
  + `store.update`. Pane controllers must call it from their rename
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
  suffix (`managed_remote_files.json.<utc-stamp>.corrupt`) so a second
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
  marker-verified dirs the parsed index does not reference. A dir whose
  marker is missing or unreadable is classified **old-epoch** — never
  swept, surfaced through §3.7's `Recovered files` — because the failure
  modes that produce one (crash mid-create, manual tampering, a future
  format change) are exactly the cases where deleting is unsafe. A fresh
  index (post-quarantine or first run)
  starts a new epoch, so older dirs persist until the user discards them
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
  `Open` (built-in editor on the checkout, works offline), `Upload`
  (disabled while disconnected, tooltip `Connect to upload`), `Discard…`
  (confirms; deletes plaintext then record). A `missing` copy offers
  `Forget` instead of Open/Upload. Old-epoch checkout dirs (§3.6 — files
  recovered from before an index corruption, so no record metadata
  exists) appear in a `Recovered files` section with the file name and
  `Open` / `Discard…` only.
- Nothing auto-uploads on reconnect — same rule as §3.3.

## 4. External editors (R9)

### 4.1 Registry reuse

`EditorRegistry` / `ExternalEditorDefinition` come with the ported
`external_file_opener.dart` (D2 copy-with-attribution, §2.5), behaviorally
unchanged: `{id, displayName, platform (macos/linux/windows),
launchTarget (bundle id on macOS, absolute executable path elsewhere),
acceptedExtensions}` with strict JSON validation (id regex, name
length/control chars, absolute path, `.exe` on Windows), maximum 64
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
| Open | OS default application | `effectiveDefaultFor(path)` first, then checkout: built-in → checkout with the 4 MiB cap, refused from the known remote size *before* any download is queued (§3.2's early-refusal rule — a 90 MiB file must not download in full only to be refused at open); system default / configured editor → checkout (§3.2, no cap), then OS-open / launch on the checkout file |
| Edit in Poltergeist | built-in editor on the file directly | checkout with the 4 MiB cap, then built-in editor |
| Open With ▸ (context menu) | chosen editor on the file directly | checkout (no cap), then chosen editor |

Local files never go through a checkout — Poltergeist is their file
manager, not their custodian. Remote files always do; the checkout is what
makes the external round-trip (watch → prompt → conflict-guarded upload)
possible at all.

### 4.3 Launch rules per platform

- **macOS** — via the `poltergeist/files` channel (03 §7.1), the ported
  `seance/files` Swift pattern: `pickApplication` (NSOpenPanel over
  /Applications, returns `{displayName, bundleIdentifier}` read from the
  bundle) and `openWithApplication` (`NSWorkspace.open(urls,
  withApplicationAt:)`, errors surfaced as `FlutterError`, results
  marshalled on the main queue).
- **Windows/Linux** — `Process.start(launchTarget, [path], runInShell:
  false, mode: detached)` after existence and executable-bit checks.
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
  cancels the production) — `updatePreview` is only ever called with
  produced local paths, never a path Quick Look cannot read.
  Space again (or Esc in the panel) closes.

### 5.2 The in-app preview panel

`app/poltergeist_app/lib/ui/preview_panel.dart` (new code, not a port). A
window-level rightmost panel, sized by the adaptive-layout allocator
(02 §1), hidden by default, toggled by `view.togglePreview`
(⌥⌘P / Ctrl+Alt+P); on Windows/Linux, Space opens it focused on the
selection and Space again closes it — Quick Look cadence without Quick
Look — except while the §5.3 `Press Space to download a preview` card is
showing, where Space starts the download instead (Esc still closes the
panel, and Space resumes its close role once a preview is rendered or
the item changes). It tracks the focused pane's focused entry; on
multi-selection it
previews the focused item — matching §5.1's Quick Look behavior on every
platform — with the count + total size summary shown as a header above the
preview.

Extension matching throughout this table (and §7's detection map) is
**case-insensitive** — `IMG_0001.JPG` previews like `img_0001.jpg`.

| Kind (by extension) | v1 rendering | Guards |
|---|---|---|
| Text (anything §7's detection maps, plus unknown-but-UTF-8) | read-only viewer on the document layer + syntax engine (§2.1/§2.2) | first 1 MiB only, via a preview-specific partial read that truncates on a UTF-8 codepoint boundary (not the whole-file 4 MiB loader), with a `Preview truncated — Open in editor` bar; refusal reasons reuse the §1 strings. Remote text previews still transfer the whole file into the §5.3 cache (Quick Look and re-preview need it; only the large-download threshold gates it) — a documented tradeoff, not an accident |
| Images: png, jpg/jpeg, gif, webp, bmp | Flutter image decode, fit-to-panel, dimensions caption | decode refused over 64 MiB file size — metadata card instead; for remote files the refusal is applied from the known remote size *before* any download is queued |
| PDF | rasterized pages behind a `PreviewRenderer` seam; the concrete rasterizer package is chosen at implementation time behind that seam, and any platform where it is unavailable shows the metadata card with `Open With ▸` | first 20 pages; page count shown |
| Everything else | metadata card: big type icon, name, kind, size, dates + `Open` / `Open With ▸` buttons | — |

The panel never blocks the pane: rendering runs async with the standard
generation-counter/`identical()` idioms (03 §6); selection changes cancel
in-flight preview work via `RemoteTransferCancellation`.

### 5.3 Remote preview rules and cache

- **Remote preview is always an explicit action** — selecting a remote
  file shows the metadata card with `Press Space to download a preview`
  (button equivalent for the mouse). No implicit downloads on selection;
  a latency-prone pane must never generate surprise traffic.
- Downloads go through the queue as priority tasks (visible, cancellable)
  into `<app-support>/preview-cache/`, file name
  `<sha256(jsonEncode([serverId, remotePath, mtime, size]))>` plus the
  original extension (Quick Look and image decoding both key type off the
  extension). JSON-encoding the fields keeps the key unambiguous — remote
  paths may legally contain `\n`. The mtime+size key self-invalidates on
  change, except a same-second, same-size rewrite (SFTP v3 mtime is
  second-granular) — a documented residual race, accepted in v1.
- A kind whose row above refuses from metadata alone (oversized image, the
  metadata-card row) never downloads at all — the guard runs against the
  known remote size before anything is queued.
- Cache is LRU-capped at 512 MiB (setting, §8) with a `Clear Preview
  Cache` button; files over the §8 large-download threshold (default
  100 MiB) ask before downloading:
  `Download 240 MB to preview "panorama.pdf"?` → `Download` / `Cancel`.
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
first, with the same explicit-progress rules — including the §8
large-download confirmation — and a side whose known remote size already
exceeds the 4 MiB loader cap is refused *before* any download is queued.
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
| lua | new family | `.lua`; shebang `lua` | `--` line comments, `--[[ ]]` block comments — the block-comment rule declared before **both** the `--` line-comment rule and the `[[` multiline-string rule, so `--[[` is neither consumed as a comment-to-EOL (stranding `]]`) nor as a string — `[[ ]]` multiline strings, keywords; the smoke test must pin both `--[[ comment ]]` spanning lines and plain `[[ string ]]` |
| Apache dot-configs | mapping only | basenames `.htaccess`, `.htpasswd` → ini family | ini's `#`-after-boundary comments and `[section]` meta cover it |

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
  default to `System default`. Removing an editor also strips its
  per-extension default entries (§4.1's `effectiveDefaultFor` falls back
  to the global default for those extensions) — no dangling editor id
  ever survives a removal.
- **External editors** — the registry list: per-editor row with display
  name, launch target, and accepted extensions rendered as `*.ext` chips;
  row actions Edit Extensions… and Remove; `Add Editor…` uses
  `pickApplication` on macOS and a native executable picker on
  Windows/Linux. Validation errors (bad path, non-`.exe` on Windows, too
  many extensions) render inline under the row.
- **Preview** — preview-cache size limit (default 512 MiB), `Clear
  Preview Cache` (shows reclaimed bytes in a toast), and the
  **large-download confirmation threshold** (default 100 MiB) — one
  setting shared by remote previews (§5.3), compare sides (§6), and
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
      subtree), delete-keeps-checkout, and **epoch-gated
      quarantine-never-sweep** (a regression test covers
      corrupt → restart → no pre-quarantine dir deleted).
- [ ] Recovered-edits banner + review dialog work with the server
      disconnected (open/discard offline; upload disabled with reason).
- [ ] External editors: registry ported with `external_file_opener.dart`
      (D2 copy, §2.5), reserved ids
      `poltergeist.*`, `Open With ▸` from `compatibleEditors`, macOS
      launches via `poltergeist/files`, Windows/Linux via
      `Process.start(..., runInShell: false)` — verified by the ported
      external-editor tests plus a launch-arguments test.
- [ ] Double-click action resolves per the §4.2 table; local files never
      checkout; remote Open resolves the default first and the built-in
      branch refuses over-cap files from the known remote size before
      any download is queued (tested).
- [ ] Quick Look channel per §5.1 (show/update/hide/isVisible, panel
      control overrides); Space produces remote files through
      `TransferProducer` with progress and Esc-cancel.
- [ ] Preview panel per §5.2 with the kind table, caps, explicit remote
      action, keyed LRU cache, and cancellation on selection change.
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
