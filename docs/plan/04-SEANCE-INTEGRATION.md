# 04 — Séance integration and porting back

This chapter specifies how Poltergeist rides Séance's sync stack for bookmark
backup (R4, R5): the exact integration surface, the `bookmark` record schema,
the sync mechanics, the two account modes and their setup UX, the upstream
Séance PR sequence that gates them, the porting-back policy (R10), and the
cross-app synergies. It elaborates D2, D3, D4, D5, D10, D18, and D30 from
[00-OVERVIEW.md](00-OVERVIEW.md); the decision log is the authority. Paths
like `packages/seance_core/lib/src/sync/sync_engine.dart` point into the
sibling Séance repo, the reference implementation.

## 1. Integration surface overview

### 1.1 Consumed via git pin — never forked, never copied (D2)

Poltergeist becomes the third consumer of `seance_protocol` (after Séance's
client and sync server) and the second consumer of `seance_core`, both as git
dependencies pinned to a Séance tag (mechanics: 03 §8.1).

| Séance asset | Package | Poltergeist use |
|---|---|---|
| `EncryptedRecord` / `DecryptedRecord` / `RecordKind`, `RecordCodec`, `Lww` | `seance_protocol` | bookmark records ride the identical envelope and conflict rules |
| `VaultCrypto`, `Argon2Params` | `seance_protocol` | enrollment key derivation, record sealing, KDF-downgrade refusal |
| `ServerConfig`, `HostKey`, `ServerColor`, `ServerIcon`, `AuthMethod` | `seance_protocol` | read-only Séance server catalog (§4.2), TOFU pins, appearance tags (§7.2) |
| sync DTOs, `kProtocolVersion` | `seance_protocol` | wire compatibility with deployed sync servers |
| `SyncApi`, `SyncEngine`, `LocalRecordStore`, `HttpSyncClient` | `seance_core` | the sync client, reused unchanged (§3) |
| `RemoteFileSystem` + entry/error/cancellation types | `seance_core` | the one VFS (D3; 03 §2) |
| `SshSessionManager` → `openAuthenticatedClient`, `TofuVerifier`, `HostKeyStore` | `seance_core` | connection layer (D5; 03 §3) |
| `SecretVault` + store interfaces | `seance_core` | local credential custody behind bookmark `secretRef`s (§2.2) |
| `SshConfigImporter` | `seance_core` | `~/.ssh/config` import (D22) |
| `ProbeService`, `TcpBannerProber` | `seance_core` | sidebar status dots, pre-reconnect probes (03 §3.4) |
| `remoteJoin`/`remoteBasename`/`remoteParent`, `expandHomePath` | `seance_core` | shared utilities |
| `uuidV4` | `seance_protocol` | id minting (re-exported through `seance_core`) |

Séance's `SyncCoordinator` is deliberately **not** consumed: it bridges
Séance's domain stores (configs, snippets, secrets) and re-collects everything
each round. Poltergeist writes its own thin `BookmarkCoordinator` (§3.2) over
the same `SyncEngine`.

### 1.2 Copied with attribution (D2)

App-layer assets — the managed-checkout pipeline (`ManagedRemoteFileStore`
and friends, including `streamedFileSha256`, which lives in
`managed_remote_file_store.dart`), atomic-file helpers, the editor stack,
the external-editor opener (`external_file_opener.dart` with
`EditorRegistry`, `ExternalEditorDefinition`, `validateEditorDisplayName`,
`normalizeEditorExtensions`), top toast system, `MiddleEllipsisText`,
adaptive layout math, the appearance/accent module, Swift channel patterns,
the settings Sync-tab structure — are copied into
`app/poltergeist_app` with a `docs/PORTS.md` ledger entry each. The ledger
format and the rules for editing ported files are fixed in 03 §8.2–8.3; this
chapter owns only the porting-back flow those rules feed (§6).

### 1.3 What Poltergeist must never touch

These are shared contracts; changing any of them breaks compatibility with
deployed sync servers, existing vaults, or Séance itself:

- **Crypto parameters**: Argon2id defaults and `Argon2Params.minimum`, the
  HKDF domain strings `seance/v1/vault-encryption-key` /
  `seance/v1/auth-verifier`, XChaCha20-Poly1305 sealing. No new crypto (D18).
- **Blob layout**: `nonce(24) || ciphertext || mac(16)`, base64 on the wire,
  empty for tombstones.
- **The LWW tuple** `(updatedAt, deviceId, seq)` and server-assigned `seq`
  semantics — client and server run identical `Lww.resolve` code.
- **The record envelope** `{id, updatedAt, deviceId, deleted, seq?, blob}`
  and `kProtocolVersion` semantics (bumped only for envelope/endpoint breaks;
  a payload-internal kind addition does not qualify).
- **Record-id plaintext conventions**: kind-prefixed ids (`hostkey:<host:port>`,
  `secret:<id>`, …) are followed (`bookmark:<uuid>`, §2.4), never re-schemed.
- **`DartSshRemoteFileSystem` safety protocols** (03 §2.1) — divergence there
  goes upstream or not at all.

## 2. The bookmark record schema (D4)

### 2.1 The `Bookmark` model

The model lands upstream in `seance_protocol` next to `server_config.dart` as
part of PR-S1 (§5.2), so both apps share one authoritative schema and Séance
can later render bookmarks if it wants to. Until the pin includes PR-S1, a
temporary identical copy may live in `poltergeist_core` with a PORTS.md entry,
deleted at the pin bump (§5.6).

```dart
/// seance_protocol — models/bookmark.dart (added by PR-S1).

enum BookmarkKind { localFolder, remotePath, workspace, savedSync }

enum PreferredPane { left, right, either }

/// Which server a remote bookmark talks to. Exactly one field is non-null;
/// fromJson throws FormatException otherwise.
class BookmarkServerRef {
  /// The id of a Séance serverConfig record. Meaningful only in shared-
  /// account mode (§4.2): host/port/username/auth resolve from the read-only
  /// catalog at connect time, so edits made in Séance propagate.
  final String? serverConfigId;

  /// A self-contained identity for servers not managed in Séance, and for
  /// every server in separate-account mode (§4.1).
  final EmbeddedHostIdentity? host;
}

class EmbeddedHostIdentity {
  final String host;
  final int port;                 // default 22
  final String username;
  final AuthMethod authMethod;    // seance_protocol enum, reused
  /// Names an entry in Poltergeist's local SecretVault. The id travels; the
  /// secret itself never does (v1 syncs no secret records — §3.4). On a
  /// device without the entry, connect prompts and offers to save under the
  /// same id.
  final String? secretRef;
  final String? identityFilePath; // '~'-relative when under home
}

/// One endpoint of a workspace or saved-sync bookmark. server == null means
/// the local filesystem.
class BookmarkLocation {
  final BookmarkServerRef? server;
  final String path;
}

/// Stored spec of a previewable sync pair (R6). Chapter 05 owns execution
/// semantics; this schema only carries the fields. Enum-like values are
/// strings so a newer Poltergeist can add values without a schema change;
/// a reader that does not recognize one refuses to run the sync ("created
/// by a newer Poltergeist") rather than guessing.
class SavedSyncSpec {
  final BookmarkLocation source;       // = SyncPair.left  (05 §6)
  final BookmarkLocation destination;  // = SyncPair.right (05 §6)
  final List<String> ignoreRules;      // = SyncRuleSet.excludeGlobs

  /// The full 05 §6 SyncRuleSet, embedded and versioned. `rulesVersion`
  /// starts at 1; `rules` carries exactly these fields, with these JSON
  /// defaults applying when a field is absent:
  ///   direction:           'leftToRight' | 'rightToLeft' |
  ///                        'bidirectional'       (default 'leftToRight')
  ///   deletions:           'none' | 'trash' | 'permanent'      ('none')
  ///   backups:             'trash' | 'none'                    ('trash')
  ///   comparison:          'sizeAndMtime' | 'sizeOnly' | 'contentHash'
  ///                                                     ('sizeAndMtime')
  ///   mtimeToleranceSecs:  int                                 (2)
  ///   acceptedTimeShifts:  list of int                         ([])
  ///   conflictDefault:     'ask' | 'newerWins' | 'keepLeft' |
  ///                        'keepRight' | 'skip'                ('ask')
  ///   symlinks:            'skip' ('copyAsLink'/'follow' reserved)
  ///   trashPath:           string | null — out-of-root trash   (null)
  ///   includeHidden:       bool                                (true)
  ///   maxDelete:           int                                 (500)
  ///   deleteFractionWarn:  double                              (0.5)
  ///   preserveMtime:       bool                                (true)
  ///   transferConcurrency: int                                 (4)
  final int rulesVersion;
  final Map<String, Object?> rules;
}

class Bookmark {
  final String id;              // uuidV4; record id is 'bookmark:$id'
  final BookmarkKind kind;
  final String label;
  final String? group;          // carried by the member, Séance-style: no
                                // group records, LWW-safe, cannot dangle
  final ServerColor? color;     // the Séance enums, never re-declared (§7.2)
  final ServerIcon? icon;       // unknown names decode to null, Séance-style
  final BookmarkServerRef? server;  // remotePath only
  final String? localPath;      // localFolder only; '~'-relative under home
  final String? remotePath;     // remotePath only; absolute remote path
  final BookmarkLocation? left; // workspace only
  final BookmarkLocation? right;// workspace only
  final SavedSyncSpec? sync;    // savedSync only
  final PreferredPane preferredPane;  // ignored by workspace/savedSync
  final String sortKey;         // manual order within group, §2.5
  final DateTime createdAt;     // UTC
  final DateTime updatedAt;     // UTC; bumped on every save; drives LWW
}
```

The exact `SyncPair` (05 §6) ↔ `SavedSyncSpec` mapping: pair `id` = the
bookmark's `id`; pair `name` = the bookmark's `label`; the pair's
`left`/`right` endpoints = the two `BookmarkLocation`s
(`source`/`destination`); `rules` + `ignoreRules` materialize the
`SyncRuleSet` (`ignoreRules` becomes `excludeGlobs`).

Kind semantics:

| Kind | Activation behavior |
|---|---|
| `localFolder` | open `localPath` in the preferred pane (`either` = active pane) |
| `remotePath` | connect via `server`, open `remotePath` in the preferred pane |
| `workspace` | set both panes: `left` and `right` locations |
| `savedSync` | open the sync sheet (05) pre-filled from `sync` |

`fromJson` is strict: unknown `BookmarkKind` or an invalid `BookmarkServerRef`
throws `FormatException`. The coordinator's per-record try/catch (§3.2) turns
that into skip-and-preserve, so a bookmark written by a newer Poltergeist
survives an older one untouched.

### 2.2 Server references: when each form is used

- `serverConfigId` is written only in shared-account mode (§4.2), by the
  "Your Séance servers" picker. Connect-time resolution reads the read-only
  catalog; if the server was deleted in Séance (tombstoned serverConfig), the
  bookmark row shows "This server was removed in Séance" with a
  "Choose a server…" fix-up action.
- `EmbeddedHostIdentity` is written for servers created inside Poltergeist,
  and for **all** servers in separate-account mode.
- Passwords and key passphrases never appear in any record. `secretRef`
  points into the local vault (the ported `SecretVault` over the OS
  keystore-held master key); credentials are resolved in-memory at connect
  (D18).
- Local and identity-file paths under the user home are stored `~`-relative
  and expanded per device via the ported `expandHomePath`, so a bookmark made
  on macOS resolves on Linux.

### 2.3 Synced record vs device-local settings

The split is a hard rule. Synced: everything in the `Bookmark` model above.
Device-local (in Poltergeist's settings/aux files, **never** in records):

| Device-local datum | Why it must not sync |
|---|---|
| macOS security-scoped bookmark blobs (keyed by bookmark id, minted by `ScopedPathAccess` — 03 §7.2) | opaque, machine-specific tokens; meaningless and possibly sensitive elsewhere |
| group collapsed state (stored in the device-local settings store, `settings.json` — 03 §6) | view state; syncing it makes two machines fight |
| sidebar hidden-per-favorite flags (same `settings.json` store) | same |
| window geometry, pane ratios, active tab | same |
| per-device "path missing" cache (a localFolder that does not exist here) | device fact, not user intent |
| sync `deviceId`, bearer token, keystore entries | identity/credentials, per-install by design |

### 2.4 Record id, payload, and JSON examples

Record id: `bookmark:<uuid>` — following Séance's kind-prefix convention. The
prefix is plaintext on the server (the same accepted privacy nit as
`hostkey:`). Sealed payload, exactly like every other kind:
`{'kind': 'bookmark', 'data': bookmark.toJson()}`.

A remotePath bookmark referencing a Séance server (shared mode), shown as the
full sealed JSON before encryption:

```json
{
  "kind": "bookmark",
  "data": {
    "id": "5f0c2a7e-3c1b-4b8e-9a51-2f6f0e7d1c22",
    "kind": "remotePath",
    "label": "www logs",
    "group": "Work",
    "color": "violet",
    "icon": "database",
    "server": { "serverConfigId": "9c41d2aa-77e0-4bfa-b1d0-0a3f5f4e9b10" },
    "remotePath": "/var/log/nginx",
    "preferredPane": "right",
    "sortKey": "hm",
    "createdAt": "2026-08-30T10:12:00.000Z",
    "updatedAt": "2026-08-30T10:12:00.000Z"
  }
}
```

(The outer `kind` is the record kind; the inner `kind` is the bookmark's own
variant. They are different objects; the nesting is intentional.)

A localFolder bookmark, `data` only:

```json
{
  "id": "e2b9d6c1-08a4-4d2f-8f37-6f5f2f7ce301",
  "kind": "localFolder",
  "label": "Downloads",
  "color": "amber",
  "icon": "folder",
  "localPath": "~/Downloads",
  "preferredPane": "either",
  "sortKey": "q",
  "createdAt": "2026-08-30T10:15:00.000Z",
  "updatedAt": "2026-08-30T10:15:00.000Z"
}
```

An embedded identity (separate mode or non-Séance server), `server` only:

```json
"server": {
  "host": {
    "host": "nas.local", "port": 22, "username": "alice",
    "authMethod": "privateKey",
    "identityFilePath": "~/.ssh/id_ed25519"
  }
}
```

### 2.5 Ordering, size, and payload forward compatibility

- **sortKey**: manual ordering within a group is lexicographic over `sortKey`.
  Keys come from `sortKeyBetween(String? before, String? after)` in
  `poltergeist_core` (fractional indexing over `a`–`z`; midpoint of the
  neighbors, append `m` when no midpoint exists). A reorder touches only the
  moved bookmark's record — LWW-friendly by construction. Unit-tested.
- **Size**: the server caps records at 1 MiB (`maxBlobBytes`). A sealed
  bookmark is a few hundred bytes; Poltergeist still enforces a 64 KiB soft
  cap on the encoded payload at save time with the copy "This bookmark is too
  large to back up." — nothing legitimate approaches it.
- **Lossy re-push**: like Séance, `fromJson` → `toJson` drops fields it does
  not know, and a re-push from another device replaces the blob. That is the
  accepted lossy-downgrade posture *between Poltergeist versions* for fields;
  for new *kinds* the strict-decode + skip-and-preserve rule (§2.1, §3.2)
  prevents any loss. New optional fields must always default sanely.

## 3. Sync mechanics for bookmarks

### 3.1 `PersistentLocalRecordStore` — real dirty tracking and delta pulls

Séance's app constructs a fresh `InMemoryLocalRecordStore` per sync round, so
every round is a full pull and its dataset is re-pushed wholesale; deletions
never tombstone and get resurrected by the next pull (verified in the research
notes — `tombstone()` is used only in Séance's tests). Poltergeist does this
properly from day one, in new code that is directly portable back (§6):

```dart
/// poltergeist_core/lib/src/sync/persistent_record_store.dart
///
/// A LocalRecordStore backed by one JSON file:
///   { "highWaterSeq": 41,
///     "records": [ { ...EncryptedRecord json..., "dirty": false }, ... ] }
/// Written atomically (ported writeStringAtomically) after every mutation.
class PersistentLocalRecordStore implements LocalRecordStore {
  PersistentLocalRecordStore(this.file);   // app passes
                                           // <app-support>/sync_records.json
  // allRecords / getRecord / putLocal (marks dirty) / putRemote /
  // dirtyRecords / markSynced / highWaterSeq — the seance_core interface,
  // implemented for real.
}
```

Consequences:

- Pulls are deltas (`since = highWaterSeq`), not full downloads.
- Only actually-edited records are dirty; Poltergeist never re-pushes an
  unchanged dataset (better than Séance's re-collect-everything, and safe:
  server-side LWW made Séance's habit a no-op, not a requirement).
- Offline edits persist as dirty and push on the next round.
- A corrupt store file is quarantined (`sync_records.json.corrupt`), the
  store restarts empty, and a **durable** notice appears in Settings → Backup
  (never a toast alone — Séance's SEA-039 lesson). Losing the store loses
  only unpushed dirty edits, which the quarantine file preserves for rescue;
  everything else re-pulls.
- The `deviceId` (uuidV4, minted on first run, stored in app settings) is
  LWW authorship — persist it with the same care Séance's `salvageSettings`
  shows; never regenerate it casually.

### 3.2 `BookmarkCoordinator` — thin, kind-aware, skip-and-preserve

`poltergeist_core/lib/src/bookmarks/bookmark_coordinator.dart`. It is
change-driven, not collect-everything:

```dart
class BookmarkCoordinator {
  BookmarkCoordinator({
    required LocalRecordStore records,      // §3.1 instance
    required HostKeyStore hostKeys,         // TOFU pin continuity
    SeanceServerCatalog? catalog,           // non-null in shared mode (§4.2)
    required RecordCrypto crypto,           // vault key + RecordCodec wrapper
  });

  /// Called by BookmarkStore on every save: seal and mark dirty.
  Future<void> onBookmarkSaved(Bookmark b);
  //   putLocal(encrypt(DecryptedRecord(id: 'bookmark:${b.id}',
  //     kind: RecordKind.bookmark, updatedAt: b.updatedAt,
  //     deviceId: deviceId, data: b.toJson())))

  /// Called on every delete: write a real tombstone (empty blob,
  /// deleted: true) via the codec's tombstone helper — fixing, in new code,
  /// the delete-resurrection gap Séance has today.
  Future<void> onBookmarkDeleted(String bookmarkId);

  /// After each engine run: decrypt and materialize pulled records.
  Future<ApplyReport> applyPulled();
}
```

Two collaborator types are defined here. `RecordCrypto` wraps `RecordCodec`
plus the vault key — encrypt/decrypt/tombstone methods — so the coordinator
never touches key material directly. `SeanceServerCatalog` is an in-memory,
read-only materialization of pulled `serverConfig` records, rebuilt from
the persistent record store on each `applyPulled`; it has no file of its
own, and its API is `List<CatalogServer> servers`.

`applyPulled` iterates the store's records, each wrapped in a per-record
try/catch (one malformed payload skips that record, never aborts the loop —
the same defense PR-S1 adds to Séance), and switches on kind:

| Pulled kind | Action |
|---|---|
| `bookmark` | upsert into `BookmarkStore`; tombstone → remove |
| `hostKey` | `hostKeys.put` — pins flow in (both modes); Poltergeist's own new pins are pushed back as standard `hostkey:<host:port>` records, so a key verified in either app is trusted by both |
| `serverConfig` | shared mode: update the read-only `SeanceServerCatalog`; separate mode: unreachable (the account has none) |
| `secret`, `snippet`, `unknown`, anything that throws | skip-and-preserve: never applied, never re-encoded, never re-pushed, never tombstoned. The encrypted record simply stays in the store |

The symmetric skip rule is tested explicitly: a record of kind `flurb`
planted in the account survives many Poltergeist sync rounds byte-identical
on the server.

Poltergeist **never writes** `serverConfig`, `secret`, or `snippet` records.
Editing a Séance server happens in Séance.

### 3.3 Scheduling and status

`app/poltergeist_app/lib/services/bookmark_backup_service.dart` owns the
lifecycle, reusing Séance's `AppState` machinery verbatim (ported per D2):

- Sync on startup, debounced 2 s after every bookmark change, periodic every
  5 min, and a manual "Back up now" button.
- A round already running sets a queued flag and loops — a mid-sync edit is
  never lost.
- Each round: `SyncEngine` (over `HttpSyncClient` + the persistent store,
  exactly as Séance's `runSync` wires it, minus the ephemeral store), then
  `coordinator.applyPulled()`.
- Status (`syncing` / `lastSyncAt` / `lastSyncError`) drives an indicator
  that is hidden when idle and healthy; "Last backed up 3 min ago" and error
  text live in Settings → Backup. Failures toast only on manual sync.

### 3.4 What is never pushed

No secrets (v1 syncs zero `secret` records — passwords live only in the
local vault), no device-local settings (§2.3), no records of kinds Poltergeist
does not own (§3.2), and nothing when backup is not configured — bookmark
backup is strictly opt-in, matching the trust stance (D19).

## 4. Account modes (D4)

### 4.1 Design B — separate account: the default

Poltergeist registers its own username (suggest `<seance-user>-poltergeist`)
on the same deployed sync server binary, or any other instance. Zero Séance
changes required; works against today's servers and clients; total isolation
(own vault key, own records).

Exact behaviors:

- Enrollment mirrors Séance's `registerSync`: random 16-byte salt → derive →
  `POST /v1/register` → token to keystore → re-key the local vault to the
  passphrase-derived key. Registration may be closed (403
  `registration_closed`); the UI must explain the documented server posture
  (§4.3 copy) instead of failing cryptically.
- Every bookmark server reference is an `EmbeddedHostIdentity` (§2.2). No
  Séance server catalog, no shared host-key pins.
- "Delete backup account…" may exist here (it deletes only Poltergeist's
  data), guarded by typed confirmation of the account name.

### 4.2 Design A — shared account: the headline, gated

Poltergeist logs into the user's **existing Séance account**: same server,
same username, same account password and encryption passphrase (two Argon2
runs over the same account salt), hence the same vault key. Bookmarks travel
as `bookmark` records inside the same encrypted stream; the server cannot
tell (kind is inside the ciphertext) and needs zero changes.

**The gate (D4):** un-patched Séance decodes unknown kinds as `serverConfig`
— sync rounds brick, or a plausibly-shaped bookmark materializes as a phantom
server and propagates. Shared mode therefore requires the PR-S1 fix (§5.2)
shipped in a tagged Séance release **and running on every device the user
syncs with Séance**. There is no in-band way to detect old clients (no device
registry), so this stays a documented, user-confirmed gate. The minimum
version is recorded once, in
`kMinimumSharedAccountSeanceVersion` (app constants), filled with the literal
tag of the first Séance release containing PR-S1; all setup copy interpolates
it.

What shared mode unlocks:

- **Read-only Séance server catalog.** Pulled `serverConfig` records
  materialize a "Your Séance servers" section in the bookmark picker and
  sidebar — ready-made SFTP targets (same host/port/username/auth; SFTP rides
  SSH). Bookmarks reference them by `serverConfigId`, so edits in Séance
  propagate.
- **Host-key pin reuse.** Pulled `hostkey:` records feed `TofuVerifier` —
  a host verified in Séance connects silently in Poltergeist, and vice versa.
- One passphrase, one server, zero re-enrollment friction.

Hard rules in shared mode:

- **Never expose account deletion.** `DELETE /v1/account` nukes both apps'
  data. Settings show only "Sign out on this device" (forgets the local
  token and keys; server data untouched).
- Poltergeist writes only `bookmark` and `hostkey` records (§3.2).
- Enrollment is login-only (the account exists); registration UI is hidden.

### 4.3 Setup screen copy (Settings → Backup)

Exact strings; the implementer copies them verbatim (interpolations in
angle brackets):

- Title: **Bookmark backup**
- Intro: "Back up bookmarks, end-to-end encrypted, through a Séance sync
  server. Nothing readable ever leaves this device."
- Mode radio, **Design B preselected**:
  1. "Separate backup account — a new account just for Poltergeist, on the
     same server. Works with every Séance version."
  2. "Shared Séance account — bookmarks live alongside your Séance data, and
     your Séance servers appear as bookmark sources. Requires Séance
     <version> or newer on all devices."
- Under option 2, a checkbox that gates the Continue button:
  "Every device that runs Séance with this account has version <version> or
  newer." Helper line: "Older Séance versions misread Poltergeist's records
  — update them everywhere before turning this on."
- On 403 `registration_closed` (Design B register): "This server has
  registration closed. On the server, temporarily set
  SEANCE_OPEN_REGISTRATION=1, create the account, then close it again."
- Passphrase callout (ported errorContainer style): "The encryption
  passphrase never leaves your devices and cannot be recovered. Losing it
  means losing the backup."

The tab reuses Séance's settings Sync-tab structure (segmented Login /
Register, `validateSyncEnrollment`-style pure validator, live-region status
line) per the D2 copy list.

### 4.4 Switching from B to A

Offered as "Switch to shared account…" once the user confirms the fleet gate
(same checkbox). Flow: sign out of the separate account (local forget only) →
log into the Séance account (§4.5) → mark every local bookmark dirty →
next round pushes them under their existing `bookmark:<uuid>` ids (ids are
namespaced per account; no collision). The old account is left untouched —
Poltergeist never auto-deletes it; the UI notes it can be removed later.
Switching away from shared mode first converts every `serverConfigId`
reference to an `EmbeddedHostIdentity` snapshot taken from the catalog, so
no bookmark dangles.

### 4.5 Enrollment implementation notes

Mirror Séance's `loginSync` exactly (`app/seance_app/lib/services/
app_services.dart`): `POST /v1/prelogin` → **refuse any KDF downgrade** below
`Argon2Params.minimum` (`meetsMinimum()`) → derive both keys → `POST
/v1/login` → **trial-decrypt the first non-tombstone pulled record** before
persisting anything (auth success cannot prove the E2E passphrase; the check
is kind-agnostic and works when that record is a bookmark or a Séance
record). Then: bearer token to the OS keystore under
`poltergeist.apikey.sync.token`; vault master key under
`poltergeist.vault.masterKey.v1` (legacy login keychain on macOS, like
Séance — AGENTS.md §4); re-key the local vault to the passphrase-derived key;
mint `deviceId` if absent. Locked-keystore degradation is non-fatal
everywhere, per the ported `MasterKeyManager` pattern.

## 5. The Séance upstream PR sequence

Bookmark backup itself never blocks on upstream work — Design B works against
unmodified Séance today, and §5.6 gives the shim for a stalled PR-S1. The
sequence gates *features*, not the product:

| PR | Gates in Poltergeist | File when |
|---|---|---|
| S0 LICENSE (D30) | D2 copies landing | immediately |
| S1 forward-compat + bookmark kind | shared-account mode (§4.2) | immediately; Séance release right after |
| S2 `openAuthenticatedClient` | M2 remote browsing (03 §3.1) | alongside M1 |
| S3 VFS additions | 05's remote sync work; chown UI (D28); D7 opt-in hashing | before 05's remote milestone |
| S4 agent auth + ProxyJump (D10) | post-v1.0 fast-follow (07) | after v1.0 |

After each merge, bumping the Séance pin is the routine chore of 03 §8.1
(including the ported-file re-diff).

### 5.1 PR-S0 — a LICENSE for Séance (D30)

Séance currently has no LICENSE file; Poltergeist is Unlicense. Scope: ask
upstream (same owner, sibling repos) to add one — suggest Unlicense to match.
Acceptance: LICENSE on Séance `main`. Interim rule, matching D30 and 01 §9:
git-pin consumption may proceed anytime — the packages are consumed, not
redistributed in source form by this repo — but **no Séance source is
copied into Poltergeist until the LICENSE lands on Séance `main`**
(PR-S0). PR-S0 therefore gates every D2 copy; M2, the first milestone that
performs one, carries the gate (07).

### 5.2 PR-S1 — `RecordKind` forward compatibility + the `bookmark` kind (THE gate)

Scope, all in Séance:

1. `packages/seance_protocol/lib/src/records/record.dart`:

```dart
-enum RecordKind { serverConfig, hostKey, secret, snippet }
+enum RecordKind { serverConfig, hostKey, secret, snippet, bookmark, unknown }

 RecordKind recordKindFromName(String name) =>
     RecordKind.values.firstWhere((k) => k.name == name,
-        orElse: () => RecordKind.serverConfig);
+        orElse: () => RecordKind.unknown);
```

2. `record_codec.dart`: use `RecordKind.unknown` (not `serverConfig`) as the
   tombstone placeholder in `decrypt`; make `encrypt` throw `ArgumentError`
   on `kind == RecordKind.unknown` (the placeholder must never be encoded).
3. `packages/seance_protocol/lib/src/models/bookmark.dart`: the §2.1 model
   with JSON round-trip, strict `fromJson`, unknown color/icon → null
   (existing convention).
4. `packages/seance_core/lib/src/sync/sync_coordinator.dart`
   (`applyToStores`): wrap each record's apply in a per-record try/catch
   (collect skipped ids, report once per round, continue the loop), and add
   `case RecordKind.bookmark: case RecordKind.unknown: break;` — Séance has
   no bookmark store; skip-and-preserve. Because Séance's coordinator only
   re-pushes what it collects from its own domain stores, skipped records are
   never modified or tombstoned (verified in the research notes).

Acceptance criteria:

- A regression test seals `{'kind': 'bookmark', 'data': {...id/label/host/
  username strings...}}` and shows the old behavior would have produced a
  phantom `ServerConfig`; with the fix, domain stores are untouched and the
  round completes.
- A truly unknown kind (`'flurb'`) decodes as `unknown`, is skipped, and
  survives rounds unmodified on the fake server.
- A malformed payload of a *known* kind no longer aborts the apply loop;
  subsequent records still apply.
- `encrypt(unknown)` throws; tombstone placeholder is `unknown`.
- Existing `sync_coordinator_test.dart` and `sync_test.dart` pass unchanged.
- A Séance release is tagged; that tag becomes
  `kMinimumSharedAccountSeanceVersion` (§4.2).

### 5.3 PR-S2 — `openAuthenticatedClient` extraction (D5)

Scope: split `SshSessionManager.connect` (in
`packages/seance_core/lib/src/ssh/ssh_session.dart`) into
`openAuthenticatedClient(...)` — socket + TOFU + auth + connection log +
failure summarizer, everything up to but excluding `client.shell(pty:)` — and
recompose `connect()` on top; export the new function from the barrel. The
exact signature is fixed in 03 §3.1. Pure refactor; this is also what
Séance's own "dedicated transfer connection" future item needs.

Acceptance: byte-identical `connect()` behavior; the entire
`ssh_diagnostics_test.dart` suite passes **unchanged**; new tests drive
`openAuthenticatedClient` directly through the injected socket seam (success,
TOFU first-use/changed, every failure-summary branch reachable).

### 5.4 PR-S3 — `RemoteFileSystem` additions (D3)

Scope: the four additive members of 03 §2.4 on the interface and
`DartSshRemoteFileSystem`:

- `setTimes(String path, {DateTime? accessedAt, DateTime? modifiedAt})` via
  `SftpFileAttrs` — the sync-convergence prerequisite;
- `setOwner(String path, {int? uid, int? gid})`;
- `bool computeHash = true` on `download`/`upload` (skips the inline SHA-256;
  `contentSha256` stays null);
- ranged read (offset/length) for future resume — dartssh2 already supports
  `file.read(offset:)`.

Acceptance: fake-`SftpClient` tests for each; servers rejecting an operation
map to `RemoteFileErrorKind.unsupported` with the standard message format;
existing behavior with defaults untouched (hashing still on by default —
Séance's managed edits keep their conflict authority, D7). Poltergeist's
`LocalFileSystem` implements all four from day one (03 §2.2), so only remote
callers wait on the pin bump.

### 5.5 PR-S4 — agent auth + ProxyJump in `seance_core` (D10, later)

Post-v1.0 fast-follow, serving both apps. Scope: an ssh-agent client speaking
`$SSH_AUTH_SOCK` / `\\.\pipe\openssh-ssh-agent` signing via a custom
`SSHKeyPair`, so `SshCredentials.agent()` stops throwing; ProxyJump execution
behind the already-modeled `jumpHostId` (recursive
`openAuthenticatedClient` through the jump host, port-forward as the inner
socket). Séance's STATUS #1 documents the agent options. Acceptance is
specified when filed (07 owns the fast-follow milestone); the transport seams
are prepared during M2 (D10).

### 5.6 The PR-S1 shim (only if it stalls)

The sealed payload shape is trivial JSON; if the pin cannot include PR-S1 in
time for Design-B work, `poltergeist_core` may temporarily seal
`{'kind': 'bookmark', 'data': ...}` via `VaultCrypto.sealJson` directly,
bypassing `RecordCodec`'s enum, with a PORTS.md-recorded shim deleted at the
pin bump. Shared mode still waits for the real PR-S1 release — the gate is
about *Séance's* decoder, not Poltergeist's.

## 6. Porting-back policy (R10)

Improvements flow back to Séance; Poltergeist never blocks on them landing.

What flows back, in priority order:

1. **Bug fixes in ported files** — upstream first when feasible; a
   Poltergeist-local fix needs a recorded reason in PORTS.md (03 §8.3).
2. **The persistent record store + tombstone deletions** (§3.1–3.2) — offered
   upstream once proven; it fixes Séance's delete-resurrection gap for
   servers and snippets too, and the `LocalRecordStore` interface was
   designed for exactly this backing.
3. **UX patterns and fixes** Séance's own review history already wants:
   theme-aware status colors (SEA-019 class, fixed in Poltergeist per D20),
   import preview + dedupe (SEA-007/027), two-stage adaptive collapse,
   persisted pane ratios — filed as Séance issues referencing its ANALYSIS.md
   ids, with Poltergeist's implementation linked as the reference.
4. **Shared-package extractions** (the `ectoplasm`/`ecto_editor` idea from
   the research notes: theme scaffold, toasts, `MiddleEllipsisText`, layout
   math; editor I/O + syntax + find): welcome, proposed only after PR-S1–S3
   build trust, and **never a blocker** — the D2 copies with the PORTS.md
   ledger are the steady state until upstream wants the split.
5. Smaller candidates recorded as found — e.g. a token-revocation endpoint
   for the sync server (§7.3), synced remote-path bookmarks subsuming
   Séance's device-local `remotePathBookmarks`.

Process and cadence:

- PORTS.md drives it: every entry carries a `Port-back candidates` line;
  divergences that fix bugs are candidates by definition.
- At each milestone close (07) and each Séance pin bump, sweep the ledger:
  batch small fixes into one upstream PR, file issues for pattern-level
  items, refresh recorded commits.
- Upstream etiquette follows Séance's AGENTS.md: doc comments explain *why*,
  small focused files, `analyze` clean, **no model identifiers** in commits,
  code, or docs; never "simplify away" the documented constraints (HKDF-salt
  domain separation, fingerprint-as-bytes host-key callback, and the rest of
  the §1.3 list).

## 7. Cross-app synergies

### 7.1 Deep links: "Open in Séance" / "Open in Poltergeist" (v1.x)

- Poltergeist registers the `poltergeist://` URL scheme: `CFBundleURLTypes`
  in the macOS Info.plist, `MimeType=x-scheme-handler/poltergeist` in the
  Linux desktop entry (`scripts/package-linux.sh` writes it), HKCU
  `Software\Classes\poltergeist` on Windows at first run.
- Link forms (no secrets ever in URLs):
  `poltergeist://browse?serverId=<uuid>&path=<url-encoded>` (shared mode —
  the Séance config id is meaningful in both apps) and
  `poltergeist://browse?host=<h>&port=<p>&username=<u>&path=<pth>`.
- "Open Terminal in Séance" in a server bookmark's context menu launches
  `seance://connect?serverId=<uuid>` (falling back to the host/port/username
  form). The Séance-side counterpart — registering `seance://` and handling
  connect, plus its own "Browse Files in Poltergeist" item — is a proposed
  upstream app-layer item, tracked in the porting ledger, **not** in the
  gating PR sequence. Each app hides its item when the OS reports no handler
  for the sibling scheme.

### 7.2 Shared appearance vocabulary

`ServerColor` and `ServerIcon` come from `seance_protocol` and are never
re-declared: a host tagged violet + database in one app renders identically
in the other, because both store names, not values, and both run the same
accent math (the ported appearance module). Poltergeist may propose new enum
values upstream; until a value ships in the pinned tag it must not be
written, since older readers decode it to null (the accepted lossy rule).

### 7.3 Shared sync server: operational notes

- **Token coexistence**: tokens are opaque, one row per login, no expiry;
  multiple tokens coexist per account. Séance and Poltergeist each hold their
  own token in their own keystore entry and never interfere. "Sign out"
  forgets the token locally only — the server keeps it until account
  deletion (inherited Séance behavior; a revocation endpoint is a recorded
  port-back candidate, §6).
- **Rate limits**: only `/v1/login` is limited (default 10 attempts / 60 s
  per username). Poltergeist logs in at enrollment only; sync rounds use the
  stored bearer token and are unlimited. In shared mode both apps' logins
  share the window — negligible in practice.
- **Size caps**: 8 MiB request body, 1000 records per push, 1 MiB per record
  — orders of magnitude above bookmark sizes (§2.5); no cap is ever in play.
  Poltergeist still keeps pushes under `maxRecordsPerPush` defensively.
- **Protocol version**: Poltergeist sends the pinned `kProtocolVersion`
  (currently 1). A future bump is coordinated through the pin, never
  improvised.
- In shared mode, Séance's re-collect-everything habit means Poltergeist
  pulls fresh re-encodes of Séance's records regularly; they are applied
  read-only (catalog, pins) or skipped, and cost nothing at this scale.
- A possible v1.x enhancement, deliberately not in v1: honoring Séance's
  opt-in synced `secret` records read-only at connect time in shared mode.
  It would need its own decision-log entry before anyone builds it.

## Definition of done

- [ ] The `Bookmark` model exists per §2.1 (upstream in `seance_protocol`
      via PR-S1, or the recorded temporary copy) with strict `fromJson`,
      JSON round-trip tests, and `sortKeyBetween` unit tests.
- [ ] The synced/device-local split of §2.3 holds: no scoped-bookmark blob,
      collapse state, or window state ever appears in a record (tested by
      asserting the serialized schema's key set).
- [ ] `PersistentLocalRecordStore` implements `LocalRecordStore` with dirty
      flags, tombstones, `highWaterSeq` delta pulls, atomic writes, and
      quarantine-on-corrupt; two-device tests prove a deleted bookmark stays
      deleted (no resurrection).
- [ ] `BookmarkCoordinator` passes the skip-and-preserve suite: unknown and
      malformed records survive rounds byte-identical; hostkey pins flow
      both ways; `serverConfig` is read-only; per-record try/catch keeps one
      bad payload from aborting a round.
- [ ] Backup scheduling matches §3.3 (startup + 2 s debounce + 5 min +
      manual, queued-round loop) and status surfaces per the copy rules.
- [ ] The setup screen defaults to Design B, gates Design A behind the
      version checkbox with the §4.3 strings, hides account deletion in
      shared mode, and handles `registration_closed` with the documented
      guidance.
- [ ] Enrollment refuses KDF downgrades and trial-decrypts before persisting
      (§4.5); keystore entry names match §4.5.
- [ ] PR-S0 and PR-S1 are filed upstream; PR-S1's release tag is recorded in
      `kMinimumSharedAccountSeanceVersion` before shared mode is enabled;
      PR-S2/S3 are filed per the §5 schedule and the pin bumped after each.
- [ ] `docs/PORTS.md` carries `Port-back candidates` lines and the §6 sweep
      is on the milestone checklist in 07.

## Explicitly out of scope

- **The file-sync engine** consuming `SavedSyncSpec` (scan/diff/plan/executor,
  rsync exporter) — 05 (D6); this chapter only stores the spec.
- **Editor and checkout behavior** behind `EditorRegistry` /
  `ManagedRemoteFileStore` — 06 (D17).
- **Connection pool details** built on `openAuthenticatedClient` — 03 §3
  (D5); this chapter only sequences the upstream PR.
- **Agent auth and ProxyJump implementation** — 07 fast-follow (D10); PR-S4
  is only sequenced here.
- **Deep-link implementation** (§7.1) — v1.x, scheduled in 07; the Séance
  side is an upstream proposal.
- **Import of FileZilla/WinSCP/Cyberduck bookmarks** — v1.x behind the D22
  preview UI (02/07); v1 ships only the `~/.ssh/config` importer.
- **Recovery-key enrollment UX** (`RecoveryKey` exists upstream, unused) —
  later, if adopted at all; would need a decision-log entry.
- **Read-only use of Séance's synced secrets** (§7.3) — v1.x at the
  earliest, gated on a decision-log entry.
- **Moving Séance's device-local `remotePathBookmarks` into synced records**
  — a Séance-side follow-up recorded in the porting ledger (§6), not
  Poltergeist work.
