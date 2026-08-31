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
  /// every server in separate-account mode (§4.1). Named `identity`, not
  /// `host`, so the union tag does not collide with `EmbeddedHostIdentity.host`
  /// (the hostname) — `ref.identity.host`, and `{"identity": {"host": …}}`
  /// on the wire.
  final EmbeddedHostIdentity? identity;
}

class EmbeddedHostIdentity {
  final String host;
  final int port;                 // default 22; 1–65535, else
                                  // FormatException at decode — an
                                  // out-of-range port would otherwise
                                  // fail only at connect time and mint
                                  // a malformed hostkey:<host:port> id
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
  final String path;              // server == null → local path, '~'-relative
                                  // when under home (matching localPath, §2.1)
                                  // so it survives differing home dirs across
                                  // devices; set → the remote path on `server`
}

/// Stored spec of a previewable sync pair (R6). Chapter 05 owns execution
/// semantics; this schema only carries the fields. Enum-like values are
/// strings so a newer Poltergeist can add values without a schema change;
/// a reader that does not recognize one refuses to run the sync ("created
/// by a newer Poltergeist") rather than guessing.
class SavedSyncSpec {
  final BookmarkLocation source;       // = SyncPair.left  (05 §6)
  final BookmarkLocation destination;  // = SyncPair.right (05 §6)
  final List<String> ignoreRules;      // = SyncRuleSet.excludeGlobs;
                                       // plain 05 §3 globs FOREVER —
                                       // new matching syntax must ride
                                       // inside `rules` behind a bumped
                                       // rulesVersion, or an older
                                       // device would interpret it
                                       // with old glob semantics and
                                       // sync files the newer device
                                       // meant to exclude

  /// The full 05 §6 SyncRuleSet, embedded and versioned. `rulesVersion`
  /// starts at 1; `rules` carries exactly these fields, with these JSON
  /// defaults applying when a field is absent. The map round-trips
  /// verbatim: unknown keys from a newer Poltergeist are retained
  /// through fromJson -> toJson — never thrown on (that would
  /// skip-preserve the whole bookmark on older devices) and never
  /// dropped (an older device's re-save must not strip newer sync
  /// settings) — the "refuse to run" tier (§2.1) applies at sync
  /// execution, not at decode. Known fields and defaults:
  ///   direction:           'leftToRight' | 'rightToLeft' |
  ///                        'bidirectional'       (default 'leftToRight';
  ///                        left = source, right = destination — the 05 §6
  ///                        mapping, restated here where the values live)
  ///   deletions:           'none' | 'trash' | 'permanent'      ('none')
  ///   backups:             'trash' | 'none'                    ('trash')
  ///   comparison:          'sizeAndMtime' | 'sizeOnly' | 'contentHash'
  ///                                                     ('sizeAndMtime')
  ///   mtimeToleranceSecs:  int                                 (2)
  ///   acceptedTimeShifts:  list of int                         ([])
  ///   conflictDefault:     'ask' | 'newerWins' | 'keepLeft' |
  ///                        'keepRight' | 'skip'                ('ask';
  ///                        left = source, right = destination)
  ///   symlinks:            'skip'   (default 'skip'; 'copyAsLink'/'follow'
  ///                        reserved — 05's symlink semantics)
  ///   trashPathLeft:       string | null — that side's out-of-root
  ///   trashPathRight:      string | null   trash, resolved on its own
  ///                        host (05 §8 rail 5)          (null, null)
  ///   includeHidden:       bool                                (true)
  ///   maxDelete:           int                                 (500)
  ///   deleteFractionWarn:  double                              (0.5)
  ///   preserveMtime:       bool                                (true)
  ///   transferConcurrency: int                                 (4)
  final int rulesVersion;              // readers REFUSE TO RUN the sync
                                       // when this exceeds the newest
                                       // version they understand — the
                                       // unrecognized-enum refuse tier
                                       // never fires on a semantic
                                       // change that keeps old keys, so
                                       // without this check the field
                                       // is decorative
  final Map<String, Object?> rules;
}

// Decode contract — fields are kind-gated: `server`/`remotePath` only
// for remotePath, `localPath` only for localFolder, `left`/`right` only
// for workspace, `sync` only for savedSync — and each gated field is
// REQUIRED non-null for its kind (`server`+`remotePath`; `localPath`;
// `left`+`right`; `sync`). `id`, `kind`, and `label` are always required;
// an absent `preferredPane` decodes as `either`. `fromJson` throws
// FormatException on any violation, and an *unknown* `kind` string leaves
// the record skip-preserved (never decoded or activated by guesswork —
// the one forward-compat case not already covered by icon→null and the
// rules policies).
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
  final DateTime updatedAt;     // UTC; stamped together with the envelope's
                                // updatedAt on every save — the envelope LWW
                                // tuple (§1.3) is authoritative; both move
                                // in one save op or displayed times and
                                // conflict resolution diverge
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

`fromJson` is strict: unknown `BookmarkKind`, an invalid `BookmarkServerRef`,
or a kind/field violation throws `FormatException` — a violation being any
"kind only" field non-null under another kind, any required field null for
its kind (`remotePath` requires `server` + `remotePath`; `localFolder`
requires `localPath`; `workspace` requires both `left` and `right`;
`savedSync` requires `sync`), or a blank `label` or `sortKey` — and the
same after-trim blank check covers every required string — `id` first
(a blank id would mint the record id `bookmark:` and collide every
such record), then `localPath`,
`remotePath`, each `BookmarkLocation.path`, `EmbeddedHostIdentity.host`
and `.username` — **and `serverConfigId`** (a structural ref: a
blank-but-non-null one decodes "successfully" and then sits
unresolved-pending forever with no fix-up, §2.2 — the same
crash-outside-the-try/catch class validating-at-decode exists to
prevent). Blank-but-present **cosmetic/optional** strings —
`group`, `secretRef`, `identityFilePath` — decode instead to **null**
per the cosmetic tier, because the graceful fallback is strictly
cheaper than hiding the record: blank `group` → ungrouped row, blank
`secretRef` → the normal connect-time prompt-and-save (identical to a
secret simply missing on this device), blank `identityFilePath` →
re-prompt; throwing on those would make the whole bookmark invisible
on strict clients, disproportionate by this section's own
cost-of-a-wrong-guess rule. Validating
at decode keeps malformed records inside the per-record try/catch (§3.2) —
skip-and-preserve — instead of crashing later at activation, outside it.
So a bookmark written by a newer Poltergeist
survives an older one untouched.

Forward-compatibility policy for future fields, so additions stay
consistent: **structural** values — the kind discriminator, enum values
like `BookmarkKind`, and ref shapes — throw when a *known* field carries
an unknown value → skip-and-preserve; unknown *field names* are always
ignored and dropped on re-push (§2.5), never thrown on; **behavior-affecting** values (sync rule
strings) refuse to run ("created by a newer Poltergeist"); **cosmetic**
values (`ServerIcon`/`ServerColor`) decode to null. Pick the tier by
asking what a wrong guess would cost.

### 2.2 Server references: when each form is used

- `serverConfigId` is written only in shared-account mode (§4.2), by the
  "Your Séance servers" picker. Connect-time resolution reads the read-only
  catalog; if the server was deleted in Séance (tombstoned serverConfig — a
  branch honestly marked **blocked-on-Séance**: per §3.1, production
  Séance never writes tombstones today, so until the §5.2 tombstone
  work lands upstream this state cannot arrive; the two states that
  *can* are (a) the record still live after a Séance-side delete —
  resolves normally, indistinguishable here, a Séance-side gap #54
  already tracks — and (b) the record absent, which is
  unresolved-pending below, surfaced as a persistent "waiting for
  sync" row rather than anything resembling a hang), the
  bookmark row shows "This server was removed in Séance" with a
  "Choose a server…" fix-up action. A reference whose record is merely
  **absent** — no tombstone, e.g. a freshly enrolled device whose initial
  pull has not completed — is *unresolved-pending*: no fix-up UI, retried
  after the next sync round. The distinction matters because acting on the
  fix-up rewrites the bookmark and LWW-propagates — a premature rewrite
  would permanently destroy a reference that was never broken.
  And because the catalog is LWW-merged, any device on the account can
  rewrite a server's endpoint — one compromised device could redirect a
  bookmark to an attacker host, which then collects a first-seen TOFU
  pin and the vault-resolved credential (§3.2's pin quarantine cannot
  catch this: the *new* host:port has no local pin to conflict with).
  Resolution is therefore **endpoint-pinned per device, checked at
  connect time, record-agnostically**: the device-local record (§2.3 —
  never synced) is written **only by a local user act** — creating the
  bookmark *on this device*, or confirming a connect; a device that
  received the bookmark through sync holds no record and prompts on
  its first connect — that prompt displays the full resolved endpoint
  (host, port, username) and precedes any connection, TOFU prompt, or
  credential resolution, matching the change-confirmation bar below,
  because on a sync-received bookmark it is the only endpoint check the
  endpoint ever gets (seeding from the synced-in record would let a
  fresh device capture an already-rewritten attacker endpoint and then
  connect silently) — and any later connect whose resolved endpoint
  differs —
  whether the change arrived through a `serverConfig` edit *or a
  rewritten `bookmark:` record*, a kind Poltergeist devices
  legitimately write and a compromised one could LWW-rewrite just as
  effectively — requires explicit confirmation naming the old and new
  endpoints **before any connection, TOFU prompt, or credential
  resolution**: a silently changed endpoint never sees a credential.
  The host-key side of the same attack — rewriting the `hostkey:`
  record for an *unchanged* endpoint — is already covered by the same
  device-local principle: §3.2's quarantine diffs pulled records
  against the **local TOFU store**, never against other synced records,
  so a rewritten pin for a host this device has connected to conflicts
  with the local pin and quarantines behind the MITM warning; only the
  first-seen case (a device that never connected) auto-applies, the
  disclosed residual §3.2 names.
  Confirming **replaces** the recorded endpoint — the pin is a single
  slot, never an accumulating allowlist, so flip-flopping between two
  previously confirmed endpoints re-triggers the check every time; a
  legitimate edit costs one
  confirmation per device, the same price the §3.2 quarantine already
  sets for a changed key.
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
| per-device endpoint pins for bookmarked servers (§2.2 — single slot, written only by a local user act) | the pin's entire value is that no synced record can write it: a synced pin would be LWW-rewritable by the compromised device it guards against |
| the local TOFU store §3.2's quarantine diffs against | same — the quarantine baseline must be state only local connects wrote, or the warning is cosmetic |
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
  "identity": {
    "host": "nas.local", "port": 22, "username": "alice",
    "authMethod": "privateKey",
    "identityFilePath": "~/.ssh/id_ed25519"
  }
}
```

### 2.5 Ordering, size, and payload forward compatibility

- **sortKey**: manual ordering within a group is lexicographic over
  `sortKey`, with the record `id` as the deterministic tiebreaker —
  `sortKeyBetween` is deterministic, so two devices inserting between
  the same neighbors mint *identical* keys by construction, and since a
  reorder touches only the moved record neither device ever rewrites
  the collision; without the tiebreaker that pair's order would differ
  per device and reshuffle across sync rounds (comparator unit test:
  same sortKey, different ids → one stable order everywhere).
  Keys come from `sortKeyBetween(String? before, String? after)` in
  `poltergeist_core` — fractional indexing over `a`–`z`: midpoint of the
  neighbors, append `m` when no midpoint exists, and the **all-`a`
  strings (`a`, `aa`, …) are reserved as the unreachable lower bound and
  never minted as keys**, which is what makes head insertion total:
  `before == null` takes the midpoint between that implicit floor and
  the current first key, so a key strictly before the first always
  exists (before `b` → `am`, before `am` → `ag`, and so on — repeated
  drag-to-top descends toward but never reaches the reserved floor, and
  §2.1's blank-`sortKey` rejection stays unreachable);
  `after == null` appends past the last key. A reorder touches only the
  moved bookmark's record — LWW-friendly by construction. Unit-tested,
  including repeated head and tail insertions and
  `sortKeyBetween(null, <first possible key>)`.
- **Size**: the server caps records at 1 MiB (`maxBlobBytes`). A sealed
  bookmark is a few hundred bytes; Poltergeist still enforces a 64 KiB **hard**
  cap on the encoded payload at save time with the copy "This bookmark is too
  large to save." — nothing legitimate approaches it, so no local-only,
  never-synced bookmark state ever exists (§2.3's synced/device-local split
  stays total; a save-time cap is a hard cap, not a warn-and-skip-sync).
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
  // tombstone (local deletes persist as tombstoned records so a later
  // delta pull can never resurrect them — the resurrection bug this
  // store exists to fix; tombstones are retained indefinitely per the
  // §3.2 lifecycle rule — no GC, since there is no device registry and
  // any GC window risks resurrecting a deletion through a long-offline
  // device) /
  // dirtyRecords / markSynced / highWaterSeq — the seance_core interface,
  // implemented for real.
}
```

Consequences:

- Pulls are deltas (`since = highWaterSeq`), not full downloads — with
  a **one-time full-resync fallback** when the cursor is rejected or
  expired (events pruned past `highWaterSeq`, a stream reset): re-pull
  full (`since = 0`), then reset `highWaterSeq` to the fresh head.
  `highWaterSeq` is persisted only *after* a delta is successfully
  applied, so a crash mid-apply re-pulls rather than skips.
- Only actually-edited records are dirty; Poltergeist never re-pushes an
  unchanged dataset (better than Séance's re-collect-everything, and safe:
  server-side LWW made Séance's habit a no-op, not a requirement).
- Offline edits persist as dirty and push on the next round.
- A corrupt store file is quarantined under a unique per-occurrence name
  (`sync_records.json.corrupt-<timestamp>`, never overwritten by a later
  quarantine — a second corruption must not destroy the first rescue copy,
  which may hold the only copy of unpushed dirty edits), the
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
  ///
  /// Tombstone lifecycle: tombstones are retained indefinitely — there is
  /// no device registry, so any GC window risks resurrecting a deletion
  /// through a long-offline device. A tombstone's updatedAt is the
  /// deletion time; a delete that loses server-side LWW to a newer
  /// concurrent edit resolves to the edit (the bookmark reappears) —
  /// intended behavior, covered by a two-device test and a line in the
  /// §4.3 help copy, never a bug to "fix" with tombstone priority.
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
the same defense PR-S1 adds to Séance). Because the record id mirrors
the kind in plaintext (§2.4), the switch happens **before decryption**:
`bookmark:` and `hostkey:` prefixes are decrypted, plus — in shared
mode only — ids carrying **no** kind prefix, which is Séance's actual
serverConfig convention: `sync_coordinator.dart` seals server records
under the bare `server.id` (a UUID — no `serverConfig:` prefix exists
on the wire, and a dispatch that matched one would skip every catalog
record with zero diagnostics, since skipping is silent by design; a
shared-mode test that materializes the catalog from a Séance-written
record pins the real convention). `secret:`, `snippet:`, and
unrecognized `<prefix>:` ids are skip-preserved without ever being
decrypted — prefixless ids too in separate mode, where no catalog
exists —
in shared mode this keeps the user's Séance password vault out of
Poltergeist's memory entirely instead of decrypting it every round only
to discard it (the §3.4 trust stance made mechanical). The dispatch on
the decrypted kinds:

| Pulled kind | Action |
|---|---|
| `bookmark` | upsert into `BookmarkStore`; tombstone → remove. Delta events are applied in seq order, and a pulled record is applied only when its LWW tuple (`updatedAt`, `deviceId`) beats the local record for the same id — a record that does not beat a dirty, not-yet-pushed local tombstone or edit is left for the next round (after the pending dirty record pushes) rather than blindly upserted, so a just-deleted bookmark never transiently resurrects and a pending offline edit is never clobbered at the apply layer |
| `hostKey` | `hostKeys.put` — pins flow in (both modes) **unless the pulled key conflicts with a locally known pin for that host:port**: a conflicting pin is quarantined unapplied behind a durable MITM warning until the user resolves it — durable meaning the quarantine survives restarts and dismissed dialogs: it is **re-derived on every `applyPulled` by diffing the stored `hostkey:` records against the local TOFU store**, never held only in memory, because the §3.1 store's delta pulls advance past the merged record and never re-deliver it to re-arm a dropped warning (the record store still LWW-merges — only *trusting* the key is gated; an LWW auto-install would let one compromised device displace every device's trusted key, making the warning cosmetic — D4). Poltergeist's own new pins are pushed back as standard `hostkey:<host:port>` records, so a key verified in either app is trusted by both — and a local **untrust** ("forget host") tombstones the matching record **and records a durable local negative pin**: auto-apply requires a present record with no local pin *and no negative pin*. The tombstone alone cannot hold — patched Séance treats prefixed-id tombstones as no-ops (§5.2 item 4) yet re-collects and re-pushes its pins with fresh LWW timestamps every round (§3.1/§4.2), so any *still-trusting* Séance device resurrects the record and the diff would auto-apply the key the user just removed under MITM suspicion; that habitual re-seal is not the "genuinely newer pin edit" the LWW carve-out means. The negative pin holds the untrust verdict until the user explicitly re-trusts (accepting the key at connect time). Negative pins persist in **app settings**, never inside the §3.1 record store — so the corrupt-store quarantine (store restarts empty) cannot erase an untrust verdict and let the very next `applyPulled` diff auto-apply a key the user removed under MITM suspicion. PR-S1 item 4 additionally routes `hostkey:`-prefixed tombstones to Séance's pin-store deletion so the two apps' untrust stays symmetric; an acceptance test pins that a Séance round re-pushing the pin does not restore auto-trust |
| `serverConfig` | shared mode: update the read-only `SeanceServerCatalog`; separate mode: unreachable (the account has none) |
| anything that throws mid-decrypt/decode (malformed payload of a decrypted prefix) | skip-and-preserve: never applied, never re-encoded, never re-pushed, never tombstoned. The encrypted record simply stays in the store — like the never-decrypted `secret:`/`snippet:`/unrecognized prefixes above |
| decrypted `kind` ≠ the kind the id prefix implied (e.g. a `bookmark:`-prefixed id whose payload decodes as `secret`, or a prefixless id decoding as anything but `serverConfig`) | skip-and-preserve, identical to malformed: the id prefix gates *which key decrypts*, the decrypted kind gates *what is applied*. The plaintext id is peer-writable on a shared account, so a relabeled blob — a `secret:` ciphertext re-uploaded under a `bookmark:` id — must never be applied (nor even upserted), or the "keeps the vault out of Poltergeist's memory" guarantee is bypassed by relabeling. (Longer term, binding the record id as AEAD associated data in `RecordCodec` makes relabeling fail at decrypt outright.) |

The prefix/kind split above is a two-gate rule, stated once: the
pre-decryption **prefix** decides whether (and with which key) a record is
decrypted at all, and the decrypted **kind** decides whether it is applied.
A shared-account peer can relabel the plaintext id but cannot forge the
sealed kind, so the second gate is what actually protects application. A
§3.2 test pins the relabel case (a `secret:` ciphertext re-uploaded under a
`bookmark:` id is decrypted under the bookmark path yet never applied).

The symmetric skip rule is tested explicitly: a record of kind `flurb`
planted in the account survives many Poltergeist sync rounds byte-identical
on the server — the pre-decryption skip preserves bytes by construction,
no decrypt needed to leave a record alone.

Poltergeist **never writes** `serverConfig`, `secret`, or `snippet` records.
Editing a Séance server happens in Séance.

Pin-conflict resolution always converges (mirroring the Séance-side
doc, `docs/POLTERGEIST.md`): **accept** installs the quarantined key
from the record store — no re-push; the record already won LWW.
**Keep local** re-pushes the kept pin under a fresh LWW tuple, so the
reaffirmed pin wins fleet-wide and the quarantine clears on every
device that never applied the conflicting key (a device that already
accepted it sees one more warning, and opposite answers ping-pong until
the affected devices agree — one resolution per affected device is the
convergence cost). A key rotation the user accepts at connect time
(`TofuVerifier` changed-key verdict, resolved through 02's changed-key
flow) pushes the new pin the same way. Without the keep-local re-push,
one rejected conflict would re-quarantine on every later pull, forever
— warning fatigue against the exact MITM signal the quarantine exists
to keep loud.

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

Poltergeist registers its own username (default: a user-chosen name; the
suggestion placeholder is a random-suffix form like `ghost-<8 hex>` —
eight hex digits, because a 16-bit suffix would make `ghost-*` accounts
trivially enumerable on a server whose registration errors reveal taken
names — never
derived from the Séance username — Design B allows "any other instance",
and a derived name would leak the user's Séance identity to an unrelated
server operator) on the same deployed sync server binary, or any other
instance. Zero Séance
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
— and because Séance re-collects and re-pushes its whole dataset every
round (§3.1), one stale device does not merely mis-render a bookmark: it
re-seals the half-parsed data as a genuine `serverConfig` record and
overwrites the bookmark server-side via LWW — **active, permanent,
fleet-wide corruption** from a single forgotten device, which
skip-and-preserve on the patched side cannot undo. Shared mode therefore
requires the PR-S1 fix (§5.2)
shipped in a tagged Séance release **and running on every device the user
syncs with Séance**. There is no in-band way to detect old clients up
front (no device
registry), so this stays a documented, user-confirmed gate — a gate the
user must keep honoring: the assertion covers devices present at unlock,
and adding (or rolling back to) a pre-PR-S1 Séance later re-opens the
same corruption path, which the §4.3 helper copy says outright — with one
after-the-fact tripwire: a pulled record that decrypts but fails
strict decode on **any id Poltergeist decodes** — a prefixless id (the
serverConfig path, §3.2) *or* a `bookmark:` id, because the primary
trigger corrupts **in place**: a stale client re-seals the bookmark
under its phantom-serverConfig reading and LWW-pushes it back under
the same `bookmark:` id, so a prefixless-only tripwire would watch the
wrong door while §3.2's catch-all silently skip-preserved the very
corruption this gate exists to catch (an acceptance test pins the
`bookmark:`-id case raising the warning) — raises a **durable
warning** in Settings → Backup naming
the record id — as a stale-client, corrupt-record, *or*
newer-Séance-schema signature (never wrong-passphrase: a record that
**decrypts** proves the passphrase that sealed it, so a wrong passphrase
yields a decrypt *failure*, not the decrypt-success + decode-failure this
tripwire fires on — naming it would send a user with a provably-correct
passphrase to reset it): the copy names all three candidate
causes, because blaming only a stale client sends the user hunting a
device that may not exist — never just
skip-preserved silently. The minimum
version is recorded once, in
`kMinimumSharedAccountSeanceVersion` (app constants), filled with the literal
tag of the first Séance release containing PR-S1 — and, recommended, the
[Séance #56](https://github.com/L-K-M/Seance/issues/56) pin-conflict fix
in the same tag, so the one version assertion covers record integrity and
pin trust together; if the tag lacks #56, the §4.3 copy must disclose
that Séance devices auto-trust synced pins without a conflict warning
(their pre-existing behavior, extended to Poltergeist's pushes). All
setup copy interpolates
it.

One disclosure sits above all the narrower ones: any app signed into
the shared account derives the account key and **can decrypt every
synced record** — `secret` records included, not only the kinds it
writes. §3.2's never-decrypt dispatch for `secret:`/`snippet:` ids is
an implementation courtesy that keeps the vault out of Poltergeist's
memory, never a cryptographic boundary, and the §4.3 option-2 copy
states the exposure plainly so the pin-trust warnings cannot imply the
key is scoped.

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
     your Séance servers appear as bookmark sources. This app will hold
     your Séance encryption passphrase and could read everything in the
     account, including saved passwords. Requires Séance
     <version> or newer on all devices."
- Under option 2, a checkbox that gates the Continue button:
  "Every device that runs Séance with this account has version <version> or
  newer." Helper line: "Older Séance versions misread Poltergeist's records
  — update them everywhere before turning this on, and never add an older
  Séance to this account afterwards: the risk does not end at setup."
- Conditional, rendered under option 2 only while the recorded
  `kMinimumSharedAccountSeanceVersion` tag predates the Séance #56 fix
  (§4.2's disclosure duty — without this string here, §4.3's
  copy-verbatim rule would guarantee the mandated disclosure never
  ships): "Séance devices accept synced host-key pins without a
  conflict warning — including pins this app pushes." A test asserts it
  renders exactly when the recorded tag lacks the fix.
- On 403 `registration_closed` (Design B register): "This server has
  registration closed. If you run it: temporarily set
  SEANCE_OPEN_REGISTRATION=1, create the account, then close it again —
  while it is open, anyone who can reach the server can register, so
  close it as soon as you are done. If someone else runs it, ask them to
  create an account for you."
- Passphrase callout (ported errorContainer style): "The encryption
  passphrase never leaves your devices and cannot be recovered. Losing it
  means losing the backup."

The tab reuses Séance's settings Sync-tab structure (segmented Login /
Register, `validateSyncEnrollment`-style pure validator, live-region status
line) per the D2 copy list.

### 4.4 Switching from B to A

Offered as "Switch to shared account…" once the user confirms the fleet gate
(same checkbox). Flow: while the separate account's token is still
held, offer an **optional** "Also delete the separate backup account…"
step (typed confirmation per §4.1 — this is the one cheap moment:
after sign-out, deletion needs a full re-enrollment with that account's
passphrase, and §7.3's tokens never expire server-side, so a declined
orphan account persists indefinitely, its tokens never expiring
server-side — not a token Poltergeist still holds, since the sign-out
below is local-forget only) → sign out of
the separate account (local forget only) → **wipe and re-create the §3.1
record store and reset `highWaterSeq`** (its records are sealed under the
separate account's key and are undecryptable after the re-key — permanent
skip-preserve residue otherwise — and its same-id `hostkey:` records
would LWW-shadow the shared account's live pins during the enrollment
pull, silently dropping pins the shared account should install;
enrollment's full pull, `since = 0`, re-seeds everything so nothing is
lost) →
log into the Séance account (§4.5) → mark every local bookmark dirty →
the next round pushes them — pushes held while `passphraseUnverified`
is set (§4.5) — under their existing `bookmark:<uuid>` ids (each id is
a random per-bookmark UUID and the shared account's store has never
seen them, so collision is negligible by construction — no id is
re-derived or re-prefixed at switch time; "namespacing" is not a
mechanism that exists here). Declining the delete leaves the
old account untouched — Poltergeist never auto-deletes it; the UI notes
that removing it later requires re-enrolling into it first.
Switching away from shared mode first converts every `serverConfigId`
reference to an `EmbeddedHostIdentity` snapshot taken from the catalog, so
no bookmark dangles. The rest mirrors the B→A sequence, since every hazard
applies symmetrically after re-keying to the separate account: local
sign-out only (the shared account is the user's Séance account — deletion
is never offered, §4.2), then **wipe and re-create the §3.1 record store
and reset `highWaterSeq`** (the same undecryptable-shared-key-residue and
same-id `hostkey:` LWW-shadow hazards the B→A flow cites), enroll into the
separate account (§4.5, full pull, `since = 0`), and **mark every local
bookmark dirty** so the first round re-pushes them under their existing
`bookmark:<uuid>` ids — without the dirty-marking the fresh separate
account would stay permanently empty.

### 4.5 Enrollment implementation notes

Mirror Séance's `loginSync` exactly (`app/seance_app/lib/services/
app_services.dart`): `POST /v1/prelogin` → **refuse any KDF downgrade** below
`Argon2Params.minimum` (`meetsMinimum()`) → derive both keys → `POST
/v1/login` → **trial-decrypt the first non-tombstone pulled record on a
decryptable id — prefixless or `bookmark:`-prefixed, never a
`secret:`/`snippet:`/unrecognized-prefixed id (§3.2's never-decrypt
dispatch binds enrollment too: selecting a vault entry as the trial
candidate would pull the user's Séance password into Poltergeist's
memory, the exact thing §3.2 promises never happens)** before
persisting anything (auth success cannot prove the E2E passphrase; the
check is kind-agnostic *across those ids* — a bookmark or a Séance
serverConfig both qualify. An **immediate** trial-decrypt failure
surfaces the **decrypt-failure** three-cause copy — wrong passphrase, corrupt record,
or newer schema (a genuinely different set from §4.2's decrypt-success
tripwire, which cannot blame the passphrase) — never a definitive
wrong-passphrase verdict. An
immediate failure **warns with the three-cause copy and proceeds**
(`passphraseUnverified: true`, pushes held), never aborts — a corrupt
first candidate must not block enrollment on an account whose passphrase
is right, the same reason §4.2 gives; pinned by a test whose first
decryptable record is corrupt and whose enrollment completes with the
flag set and pushes held). The same id restriction
binds the **deferred** foreign-record check below. Enrollment always
pulls **full** (`since = 0`), never a delta, so
a retained `highWaterSeq` can never produce an empty pull that skips the
check. When the account genuinely holds no decryptable record (fresh
account, tombstone-only history) enrollment proceeds — the hold below
is the protection, not the empty store: the first push under a wrong
key would itself *be* the corruption (records no correct-passphrase
device could ever read), which is exactly why proceeding is safe only
with pushes held — and records
`passphraseUnverified: true`. While that flag is set the round loop
**holds all pushes** — nothing is ever sealed under an unverified key —
and the deferred trial-decrypt is satisfied only by a **foreign**
non-tombstone record (`deviceId != ours`): this device's own output
decrypts under whatever key sealed it, so a self-pushed record would
vacuously clear the flag and silently bless a wrong passphrase whose
records no other device could read. A failed deferred check raises the
durable Settings → Backup error and keeps pushes held; while held,
Settings → Backup shows a visible "backup paused until the passphrase
is verified against the account's existing data" status rather than a
silent stall — and the status names the way out, because a
single-writer account (Séance set up, shared backup enabled, nothing
ever added elsewhere) would otherwise stay paused forever: "Open
Séance on any device signed into this account and add or edit a
server, then sync — backup resumes automatically." — with mode-matched
copy in a separate-mode account (no Séance is ever signed into a B
account, and B accounts hold no serverConfig records, §3.2): "Open
Poltergeist on another device signed into this account and add or edit
a bookmark, then sync." A foreign `bookmark:`-id record satisfies the
deferred check in both modes. (A Design B fresh *registration* never sets the flag —
the passphrase is minted there, so there is nothing to verify against.)
Deferred, never silently skipped, never self-satisfied — pinned by
tests: a wrong passphrase against an empty shared account pushes
nothing; a self-pushed record does not clear the flag; a failing
foreign record raises the durable error with pushes still held. Then: bearer token to the OS keystore under
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
Pre-check: audit Séance's commit history for non-owner copyright (external
contributions, vendored or borrowed snippets, `git shortlog -sne`); the
single-rights-holder rationale below holds only if none exist, and any
third-party code found waits for the LICENSE like any other third party.
Acceptance: LICENSE on Séance `main`. Interim rule, matching D30 and 01 §9:
git-pin consumption may proceed anytime — release binaries embedding the
pinned code included, because both repos share one rights holder, who
needs no license from themselves; the LICENSE is what any third party
needs to consume, fork, or redistribute either repo — but **no Séance
source is
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
   Sweep every `RecordKind.values` iteration and `switch` in Séance (UI kind
   selectors, name↔kind maps, debug dumps) so the new `bookmark`/`unknown`
   members cannot surface in any generic path — a plain non-exhaustive
   `switch` silently misses them, undermining the "skip-and-preserve is
   invisible" story the PR sells upstream.
3. `packages/seance_protocol/lib/src/models/bookmark.dart`: the §2.1 model
   with JSON round-trip, strict `fromJson`, unknown color/icon → null
   (existing convention).
4. `packages/seance_core/lib/src/sync/sync_coordinator.dart`
   (`applyToStores`): **dispatch tombstones before the kind switch.** A
   tombstone's blob is empty, so its decoded kind is item 2's
   placeholder — today that placeholder is `serverConfig`, which is the
   only reason server deletions currently work (`case serverConfig: if
   (dec.deleted) deleteServer(dec.id)`); flipping the placeholder to
   `unknown` without re-homing that path would route every tombstone to
   the new skip branch and silently regress serverConfig deletion.
   Deletion needs only the plaintext id: before the switch, a
   `deleted` record with a prefixless id calls
   `configStore.deleteServer(dec.id)` (today's live behavior,
   preserved), and prefixed-id tombstones are consumed as explicit
   no-ops (`continue`) in that same pre-switch dispatch, so **no
   tombstone of any kind ever reaches the kind switch** (satisfying the
   acceptance bullet below, and keeping the skip branch from ever having
   to reason about deleted records) — nothing in Séance mints them; the
   persistent-store flow-back revisits per-kind deletion together with
   [#54](https://github.com/L-K-M/Seance/issues/54). Then wrap each
   record's apply in a per-record try/catch
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
- The `orElse` flip is observable: `recordKindFromName` (or its caller)
  emits a debug-level log whenever the `unknown` fallback fires, so any
  legacy record the old `serverConfig` fallback was silently absorbing
  becomes visible after the release instead of just vanishing from the
  UI. Record-id prefixes are plaintext, so a client-side sweep of an
  account's prefixes against the known set is the cheap pre-release
  audit for accounts that matter.
- A malformed payload of a *known* kind no longer aborts the apply loop;
  subsequent records still apply.
- `encrypt(unknown)` throws; tombstone placeholder is `unknown`.
- A serverConfig tombstone (prefixless id, `deleted: true`, empty blob)
  still deletes the server after the placeholder flip — the regression
  the flip most easily introduces — and no tombstone of any kind
  reaches the `RecordKind.unknown` skip branch.
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

Scope: the three additive members of 03 §2.4 on the interface and
`DartSshRemoteFileSystem`:

- `setTimes(String path, {DateTime? accessedAt, DateTime? modifiedAt})` via
  `SftpFileAttrs` — the sync-convergence prerequisite;
- `setOwner(String path, {int? uid, int? gid})`;
- `bool computeHash = true` on `download`/`upload` (skips the inline SHA-256;
  `contentSha256` stays null).

Ranged read is **not** in PR-S3: D3 defers it to D25's resumable-transfer
work as its own upstream PR when that work actually starts (dartssh2
already supports `file.read(offset:)`, so it stays cheap to add) — the
pre-sync PR carries only surface v1 exercises.

Acceptance: fake-`SftpClient` tests for each; servers rejecting an operation
map to `RemoteFileErrorKind.unsupported` with the standard message format;
existing behavior with defaults untouched (hashing still on by default —
Séance's managed edits keep their conflict authority, D7). Poltergeist's
`LocalFileSystem` implements them from day one (03 §2.2), so only remote
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
pin bump. Two hard requirements before that deletion, so no record's
readability ever depends on deleted shim code: (a) a round-trip test
proving the post-bump `RecordCodec.decrypt` accepts the shim's output
verbatim — identical envelope, version header, HKDF
info/domain-separation inputs, **and the plaintext record-id prefix**
(the enum bypass hand-writes the prefix too; a wrong or missing one
routes the record through the wrong kind — straight into the
phantom-`serverConfig` fallback PR-S1 exists to eliminate — exactly the
constraint class §6's etiquette forbids "simplifying away"); and (b) if that proof fails, the
shim's removal re-seals every shim-written record through the real codec
(or asserts none exist) as a one-time migration. Shared mode still waits
for the real PR-S1 release — the gate is
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
5. Smaller candidates recorded as found — e.g. synced remote-path
   bookmarks subsuming Séance's device-local `remotePathBookmarks`. The
   token-revocation endpoint (§7.3) is deliberately **not** in this
   bucket: §7.3 calls it urgent (a leaked token has no remediation
   today), so it is filed upstream ahead of the sweep cadence, never
   batched with milestone-close small fixes.

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
  `poltergeist://browse?host=<url-encoded>&port=<p>&username=<url-encoded>&path=<url-encoded>`
  (all three free-text parameters percent-encoded, exactly as the
  serverId form's `path` already is — usernames and paths routinely
  carry `&`, `#`, `%`, spaces, and IPv6 host literals carry `%`
  zone-ids like `fe80::1%en0`).
  "No secrets in URLs" does not cover the *induced* prompt: any web page
  can launch the host form at an attacker-chosen endpoint, staging a
  TOFU-pin-and-credential phish that appears to come from the user's own
  app. The host-form handler therefore always shows an interstitial
  naming host, port, and username and requires explicit confirmation
  before any connection, TOFU prompt, or credential prompt; only
  `serverId` links that resolve to an existing catalog entry (an
  already-established trust) may skip it. A `serverId` that does
  **not** resolve is a dead end: show an error, never fall back to the
  host form or to any connect, TOFU, or credential prompt — a
  serverId link carries no endpoint to confirm, so a "helpful"
  fallback would reopen the exact induced-prompt phish the
  interstitial closes.
- "Open Terminal in Séance" in a server bookmark's context menu launches
  `seance://connect?serverId=<uuid>` when the bookmark carries a synced
  serverId, falling back to the host/port/username form only for bookmarks
  that have none (Design B) — never as a retry after a `serverId` link
  fails to resolve, which would reopen the induced-prompt phish the
  dead-end rule above closes. The Séance-side counterpart — registering `seance://` and handling
  connect, plus its own "Browse Files in Poltergeist" item — is a proposed
  upstream app-layer item, tracked in the porting ledger, **not** in the
  gating PR sequence — and that proposal must carry §7.1's host-form
  rules with it (always-interstitial for host/port/username links, no
  fallback when a `serverId` fails to resolve), or `seance://connect?host=…`
  reopens against a terminal session the exact induced-prompt phish this
  section closes for `poltergeist://`. Each app hides its item when the OS
  reports no handler for the sibling scheme.

### 7.2 Shared appearance vocabulary

`ServerColor` and `ServerIcon` come from `seance_protocol` and are never
re-declared: a host tagged violet + database in one app renders identically
in the other, because both store names, not values, and both run the same
accent math (the ported appearance module). Poltergeist may propose new enum
values upstream; until a value ships in the pinned tag it must not be
written, since older readers decode it to null — and the loss is
**not display-only**: a pre-pin Séance client re-collects and
re-pushes everything it pulled (§7.3), so it re-encodes that null and
destroys the value server-side for every device; skip-and-preserve
does not apply, because the record parses — only the enum field dies.
The pin floor bounds what Poltergeist may write, and writing a
*newly shipped* value still deserves a broad-adoption delay while
pre-pin clients share the account (the accepted lossy rule, stated at
its full cost so nobody "simplifies" the delay away).

### 7.3 Shared sync server: operational notes

- **Token coexistence**: tokens are opaque, one row per login, no expiry;
  multiple tokens coexist per account. Séance and Poltergeist each hold their
  own token in their own keystore entry and never interfere. "Sign out"
  forgets the token locally only — the server keeps it until account
  deletion (inherited Séance behavior; a revocation endpoint is a recorded
  port-back candidate, §6 — and an urgent one: tokens never expire and
  shared mode hides account deletion by design, so a leaked token
  currently has no clean remediation at all. Until revocation ships,
  the documented interim response to a suspected leak is **full
  account deletion performed from Séance itself** — that guidance goes
  into the shared-mode security copy so support answers are
  consistent, and the copy (plus the M6 decision-log entry) spells out
  the Poltergeist aftermath: the local record store survives the
  deletion, the next round detects the dead account (auth failure) and
  drops Poltergeist to local-only with a clear notice, and
  re-enrollment on a fresh account offers to re-push the retained
  records — and whether shared mode may ship before the endpoint
  exists is an explicit 00-decision-log entry at the M6 gate, not a
  silent default).
- **Rate limits**: only `/v1/login` is limited (default 10 attempts / 60 s
  per username). Poltergeist logs in at enrollment only; sync rounds use the
  stored bearer token and are unlimited. In shared mode both apps' logins
  share the window — negligible in practice.
- **Size caps**: 8 MiB request body, 1000 records per push, 1 MiB per record
  — orders of magnitude above bookmark sizes (§2.5); no cap is in play
  for this chapter's record kinds. Poltergeist still bounds each request
  body against the 8 MiB cap defensively, so a future larger record kind
  cannot trip a 413 that nothing chunks around.
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
- [ ] Enrollment refuses KDF downgrades and trial-decrypts before
      persisting — full pull at enrollment, deferred-verification flag on
      a genuinely empty account (§4.5); keystore entry names match §4.5.
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
