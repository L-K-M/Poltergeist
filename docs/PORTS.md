# Séance ports and pin audits

## M2 probe lifecycle prerequisite (2026-09-08)

The periodic `ProbeService` repair merged in
[Séance #79](https://github.com/L-K-M/Seance/pull/79) (D2).
No source copy or local scheduler is introduced. STATUS item 3 records the
required containing pin before wiring and optional upstream test follow-ups.
The containing pin (`2e6d1f1`, 2026-09-08) is now in place — see the pin
findings below. Engine-side consumption landed on 2026-09-09: the pinned
service owns scheduling and sockets; Poltergeist adds target grouping,
activity control, and port events. No source copy or pin change. The
remainder landed 2026-09-10: persisted eligibility/settings, lifecycle
forwarding, the interim list dots, and the coordinator composition in
[PR #62](https://github.com/L-K-M/Poltergeist/pull/62), then the live
connection-state composition (the Connections surface and the composed
indicator) in [PR #67](https://github.com/L-K-M/Poltergeist/pull/67).
The startup composition rode item 6's engine spawn: its incident/pin
bridging landed in
[PR #66](https://github.com/L-K-M/Poltergeist/pull/66) (task 6, merge
`d853aa8`), and the composition itself landed in
[PR #69](https://github.com/L-K-M/Poltergeist/pull/69) (merge `43396c5`,
2026-09-10): the production engine spawns at app startup seeded from both
stores.

The app-side eligibility controller (2026-09-09) consumes the engine's
`ProbeBridge`; scheduling and sockets remain in the pinned service. Its
device-local policy and isolate orchestration are new Poltergeist code,
with no copied source or upstream port candidate. Persistence, lifecycle
forwarding, and the rendered status composition landed 2026-09-10 in
[PR #62](https://github.com/L-K-M/Poltergeist/pull/62); the composed
indicator landed in
[PR #67](https://github.com/L-K-M/Poltergeist/pull/67).

## M2 real-sshd pool and TOFU coverage (2026-09-08)

Exercises the existing pinned opener, VFS, and TCP prober through Poltergeist's
pool. TOFU tests also exercise first-use decisions and same-port key swaps
through the pinned verifier. No copied sources, pin changes, or upstream
port candidates.

## app/poltergeist_app/lib/services/atomic_file.dart

- Source: app/seance_app/lib/services/atomic_file.dart
- Séance commit: e11206a94b5672225432fcd9990750a2ab1002c2 (tag v0.3.0); re-diffed unchanged at a9add158015fc15d805cecd2754ac40bc7860a23 (2026-09-07); source moved at 2e6d1f138f1704e683870f75e11262bf50e37379 with Séance #80's optional `privacy` parameter (2026-09-08) — see divergences
- Ported: 2026-09-02
- Divergences: unique `.poltergeist-<uuid>.tmp` siblings prevent collisions
  and basename overflow; failed writes remove their temporary sibling without
  masking the original failure; optional owner-only writes restrict an empty
  temporary before sensitive content; the source's delete-target Windows
  fallback is omitted per 09 §3.6; corrupt quarantine is store-owned,
  UTC-stamped, and reports move failures. Séance #80's re-diff at the new
  pin: the source gained `AtomicFilePrivacy` (create-empty-then-restrict via
  the new `file_permissions.dart`) while keeping its fixed `.tmp` name and
  no failure cleanup — the recorded divergences stand unchanged; no port
  edit is required.
- Port-back candidates: unique bounded temp names, best-effort cleanup,
  and timestamped quarantine. Owner-only writes landed upstream in
  [Séance #80](https://github.com/L-K-M/Seance/pull/80) as an optional
  `privacy` parameter whose default preserves ordinary callers; upstream
  keeps its fixed `.tmp` name and no failure cleanup.

## app/poltergeist_app/test/atomic_file_test.dart

- Source: app/seance_app/test/atomic_file_test.dart
- Séance commit: e11206a94b5672225432fcd9990750a2ab1002c2 (tag v0.3.0); re-diffed unchanged at a9add158015fc15d805cecd2754ac40bc7860a23 (2026-09-07) and at 2e6d1f138f1704e683870f75e11262bf50e37379 (2026-09-08)
- Ported: 2026-09-02
- Divergences: uses the Poltergeist temp-file contract, adds failed-rename
  cleanup, and maps source store round-trip/quarantine cases to
  `settings_store_test.dart`.
- Port-back candidates: none.

## Connection cleanup dependency

- Consumes `packages/seance_core/lib/src/ssh/sequential_cleanup.dart` at the
  then-current `2f99f4e` pin; no source copy or pin change (2026-09-05).
- 2026-09-10 re-diff sweep: the pin moved to `a9add15`
  ([PR #35](https://github.com/L-K-M/Poltergeist/pull/35)) and then
  `2e6d1f1` ([PR #53](https://github.com/L-K-M/Poltergeist/pull/53)); the
  consumed file is byte-identical between `2f99f4e` and `2e6d1f1`, so the
  consumption note stands unchanged at the current pin.
- `ssh_cleanup.dart` selects the session's five-second grace period and
  best-effort failure mode. Pool regressions cover stalled and late-error
  cleanup. No port-back change: Séance already uses this primitive.

## app/poltergeist_app/lib/services/secure_master_key.dart

- Source: app/seance_app/lib/services/secure_master_key.dart
- Séance commit: 30963c0c31f55e649b4b29487cf4c07b706b3056 (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: keystore entry renamed `poltergeist.vault.masterKey.v1`
  (07 §3.3) so the two apps never share an entry;
  `putApiKey`/`getApiKey` restored 2026-09-19 for the sync bearer token
  (04 §4.5: `poltergeist.apikey.sync.token`) — still no provider API keys
  (D19 scope) — plus `deleteApiKey` for sign-out (no Séance counterpart;
  tolerant like the reads, the orphaned entry is harmless); Séance types
  imported via the poltergeist_core barrel, never seance_core directly.
  The ported exception messages are frozen port text allowlisted in the
  localization contract; the D20 ARB rule applies where the UI renders
  them (prompt-UI slice).
- Port-back candidates: corrupt-entry misreport — a stored entry that is
  not valid base64 is conflated with keystore unavailability (review round
  1, PR #32); and concurrent probes can race the create-on-first-run
  read-check-write (review round 1). Both are source defects; upstream
  first per 04 §6, not local divergences.

## app/poltergeist_app/lib/services/file_stores.dart

- Source: app/seance_app/lib/services/file_stores.dart
- Séance commit: e11206a94b5672225432fcd9990750a2ab1002c2 (tag v0.3.0; re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- 2026-09-21 at the `v0.9.1` pin (`035b0d8`): upstream reworked the file
  around a vault re-key journal (`VaultRekeyJournal`) and a serialized
  mutation queue — none of that architecture is consumed here — and added
  `putSecretBlobs` to the `VaultStore` interface the port implements. The
  port gained `putSecretBlobs` only: load once, encode every blob, one
  atomic flush (the interface's all-or-none batch contract). The journal
  and queue stay upstream; adopting them is their own decision, not pin
  fallout. Semantics verified against upstream at `035b0d8`
  (`file_stores.dart:426-430`): upstream MERGES the batch into the
  existing map — ids absent from the batch survive — so the port's merge
  matches; it is not a wholesale replace. The accepted divergence is the
  missing serialized mutation queue: a `putSecret`/`deleteSecret`
  racing the batch can interleave flushes (the port-back candidate
  below already records that gap).
- 2026-09-24: the re-key journal IS adopted — bidirectional server sync
  (04 §4.2 amendment) makes `SecureSyncCredentialStore.writeVaultKey` a
  real re-key path, and swapping the OS-keystore key without the
  two-generation journal would orphan every credential on any crash or
  refusal between the vault rewrite and the keystore write. `FileVaultStore`
  now implements `VaultRekeyJournal` verbatim from upstream: staged
  old/new encrypted snapshots in `vault.json.rekey`, settle-on-next-open,
  keystore-probe-driven generation choice on failure, mutation lockout
  while staged. The serialized mutation queue still stays upstream — the
  journal serializes against itself and the vault has no concurrent
  writers beyond it yet. `LockedSecretVault` also picked up upstream's
  `readableSecret`/`putSecrets` overrides in the same pass (still
  throw-on-touch; the pulled-`secret` apply path calls `readableSecret`).
- Divergences: only `FileVaultStore` and `FileHostKeyStore` are ported —
  `FileConfigStore`/`FileSnippetStore` have no Poltergeist counterpart
  (bookmark identities carry connections per 04 §2.1–2.2; the synced record
  store lands in M6 per 04 §3.1); corrupt quarantine is store-owned and
  UTC-stamped per this repo's atomic-file port instead of the source's
  shared `.corrupt` helper; types imported via the poltergeist_core barrel.
- Port-back candidates: UTC-stamped quarantine names (shared with the
  atomic_file entry); serialized load/flush (concurrent mutations can
  interleave full-file flushes and lose one write — review round 1,
  PR #32). Both upstream first per 04 §6.

## app/poltergeist_app/lib/services/locked_secret_vault.dart

- Source: app/seance_app/lib/services/app_services.dart (LockedSecretVault)
- Séance commit: 99a35850a59e741b3e542447508dda2ef9424252 (ported class re-diffed unchanged at a9add15, 2026-09-07; re-diffed unchanged as a class at 2e6d1f1, 2026-09-08 — the surrounding `app_services.dart` moved with assistant/sync work outside the ported block)
- Ported: 2026-09-07
- Divergences: extracted into its own file — Poltergeist has no AppServices
  composition yet (it lands with the engine/prompt slices that consume the
  vault); behavior identical.
- Port-back candidates: none.

## app/poltergeist_app/test/keystore_resilience_test.dart

- Source: app/seance_app/test/keystore_resilience_test.dart
- Séance commit: 30963c0c31f55e649b4b29487cf4c07b706b3056 (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: the dropped API-key methods' tests map to `setKeystoreKey`
  write-failure coverage plus a master-key entry-name assertion; imports via
  the poltergeist_core barrel.
- Port-back candidates: none.

## app/poltergeist_app/test/vault_rekey_journal_test.dart

- Source: app/seance_app/test/vault_rekey_journal_test.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (tag v0.9.1)
- Ported: 2026-09-24
- Divergences: the `AppServices`-driven groups are replaced by
  `SecureSyncCredentialStore.writeVaultKey` coverage over a fake keystore
  (Poltergeist has no AppServices — the re-key path lives in the sync
  credential store per 04 §4.5); quarantine assertions match this repo's
  UTC-stamped `.corrupt-<stamp>` names instead of upstream's `.corrupt`;
  a `failWrite` keystore mode covers refusal-without-storing, which
  upstream's file-level fakes did not exercise.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/prompts/host_key_dialog.dart

- Source: app/seance_app/lib/ui/host_key_dialog.dart
- Séance commit: 27552b2 (re-diffed unchanged at a9add15, 2026-09-07;
  re-diffed at 5cadb18, 2026-09-09 — upstream gained the route-guard
  port-back below, nothing else changed; re-diffed at b8fc111, 2026-09-09
  — upstream gained the scrollable-content port-back below, nothing else
  changed)
- Ported: 2026-09-07
- Divergences: strings localize through ARB (D20); the decision payload is
  the engine protocol's `HostKeyPromptData` (plain data crossing the
  isolate, 03 §5) instead of seance_core's `HostKeyDecision`; a `changed`
  verdict still renders the alarming two-fingerprint review with the
  destructive-styled trust button (D18 hard block, never auto-repin).
  Coordinator-owned route identity prevents a withdrawal from popping
  another route. The current-route action guards were ported back to
  Séance as [Séance #82](https://github.com/L-K-M/Seance/pull/82) (head
  `5d9da5195a3a9a4d8110d0b2425d55e5cb3fddde`, merge
  `5cadb18e823ca1ae089b9fdd940432876e93fd9c`, 2026-09-09) with the same
  `ModalRoute.isCurrent` semantics, and the scrollable content was
  ported back as
  [Séance #83](https://github.com/L-K-M/Seance/pull/83) (head
  `2f6c49ce6a4af424003261dae3ec116eeb80fa74`, merge
  `b8fc1111119cd6c0744b9de9bc35d16c07ae3e9d`, 2026-09-09) — upstream now
  sets `AlertDialog.scrollable` with its own reachability regressions, so
  both divergences are closed.
- Port-back candidates: none.

## app/poltergeist_app/test/ui/prompts/host_key_dialog_test.dart

- Source: app/seance_app/test/host_key_dialog_test.dart
- Séance commit: 27552b2 (re-diffed unchanged at a9add15, 2026-09-07;
  re-diffed at 5cadb18, 2026-09-09 — upstream gained the three
  route-guard regressions from Séance #82, nothing else changed;
  re-diffed at b8fc111, 2026-09-09 — upstream gained the two
  constrained-layout reachability regressions from Séance #83, nothing
  else changed)
- Ported: 2026-09-07
- Divergences: adapted to the protocol payload; adds ARB-string and
  non-dismissible coverage beyond the source's cases; the async test
  harness checks `mounted` before rebuilding. The scrollable coverage
  diverged in form only: upstream's #83 regressions assert reachability
  behavior (constrained layout, viewport-clipped visibility, scroll into
  view, pinned buttons); this port retains its property-level check
  (`AlertDialog.scrollable`) that the behavior assertions subsume, so the
  candidate is closed, not merged back.
- Port-back candidates: mounted harness guard.

## app/poltergeist_app/lib/ui/prompts/keyboard_interactive_dialog.dart

- Source: app/seance_app/lib/ui/keyboard_interactive_dialog.dart
- Séance commit: d1a98f1 (re-diffed unchanged at a9add15, 2026-09-07;
  re-diffed at 5cadb18, 2026-09-09 — upstream gained the route-guard
  port-back below, nothing else changed)
- Ported: 2026-09-07
- Divergences: strings localize through ARB (D20); the payload is the
  engine protocol's `KeyboardInteractivePromptData` (03 §5);
  coordinator-owned route identity and Enter focus navigation/final
  submission are local. Masked-by-default fields with explicit per-field
  reveal, scrollable content, empty-name title fallback, first-field
  autofocus, and the controller-dispose-in-State lifecycle (with its IME
  use-after-dispose lesson) all exist upstream at the recorded commits —
  they are ported behavior, not local additions. The current-route action
  guards were ported back to Séance as
  [Séance #82](https://github.com/L-K-M/Seance/pull/82) (head
  `5d9da5195a3a9a4d8110d0b2425d55e5cb3fddde`, merge
  `5cadb18e823ca1ae089b9fdd940432876e93fd9c`, 2026-09-09) with the same
  `ModalRoute.isCurrent` semantics, so that divergence is closed.
- Port-back candidates: Enter focus navigation/final submission; preserve
  RFC 4256's per-prompt echo bit once the upstream responder exposes it.

## app/poltergeist_app/test/ui/prompts/keyboard_interactive_dialog_test.dart

- Source: app/seance_app/test/keyboard_interactive_dialog_test.dart
- Séance commit: fd01515 (re-diffed unchanged at a9add15, 2026-09-07;
  re-diffed at 5cadb18, 2026-09-09 — upstream gained the three
  route-guard regressions from Séance #82, nothing else changed)
- Ported: 2026-09-07
- Divergences: adapted to the protocol payload; adds empty-name title
  fallback, Enter-navigation, autofocus, and IME/regression-harness
  coverage beyond the source's cases. Reveal-toggle and submit/cancel
  coverage exist upstream at the recorded commit — the earlier
  "adds reveal-toggle" wording was corrected against that re-diff
  (2026-09-09); the original dated port provenance stands.
- Port-back candidates: Enter-navigation and autofocus tests (upstream has
  no autofocus test); the repeated-submit route-safety regression went
  upstream with Séance #82 in its double-activation form.

## app/poltergeist_app/lib/services/identity_audit_log.dart

- Source: app/seance_app/lib/services/identity_audit_log.dart
- Séance commit: 82507ec (re-diffed unchanged at a9add15, 2026-09-07;
  re-diffed with the Séance #80/#81 changes at cb4b010, 2026-09-08;
  identical between cb4b010 and the 2e6d1f1 pin, 2026-09-08)
- Ported: 2026-09-07
- Divergences: `viaBookmark` docs note Poltergeist is unsandboxed at v1
  (D23). The PR #38 security/reliability repairs (wrong-typed optional
  JSON fields skip as malformed; desktop POSIX logs repaired/created
  mode 0600, including atomic rotation, because they contain
  private-key paths) landed upstream in
  [Séance #80](https://github.com/L-K-M/Seance/pull/80) (merge
  `bc534136fa427ca9605babd47e44555e5dbfd4d1`, 2026-09-08), so the
  behaviors now match. Upstream's review also gates `readAll`'s repair
  on group/other bits (`_groupOtherBits`) — an already-private log
  skips the chmod and stays readable on chmod-incapable mounts, while
  a permissive log that cannot be restricted still fails the read
  closed — mirrored here 2026-09-08 from
  [Séance #81](https://github.com/L-K-M/Seance/pull/81) head
  `cb4b010075bd0519914de27bc0a2231c449e204d` (merge
  `2e6d1f138f1704e683870f75e11262bf50e37379`), whose durable rootless
  Linux procfs regressions are ported alongside it. The record shape
  stays frozen identical.
- Port-back candidates: none — the read-side repair gate's mirror and
  its procfs regressions close the last recorded divergence; both
  sides now behave identically.

## app/poltergeist_app/test/services/identity_audit_log_test.dart

- Source: app/seance_app/test/identity_audit_log_test.dart
- Séance commit: 82507ec (re-diffed unchanged at a9add15, 2026-09-07;
  refreshed with the Séance #80/#81 coverage at cb4b010, 2026-09-08;
  identical between cb4b010 and the 2e6d1f1 pin, 2026-09-08)
- Ported: 2026-09-07
- Divergences: adds wrong-typed-field and owner-only-mode regressions for
  the local hardening; record/rotate/serialize behavior remains identical.
  2026-09-08: ported Séance #81's audit coverage — fresh-file mode,
  existing-file write repair, read repair, absent-field defaults, and
  both rootless Linux procfs regressions (owner-only `/proc/self/io`
  reads without a repair chmod and with its mode untouched; a
  world-readable `/proc/self/status` whose chmod fails EPERM fails
  `readAll` closed with that errno pinned), mirroring the lib entry's
  read-side repair gate. Temp prefix and home paths carry Poltergeist
  names (`poltergeist-audit-`, `/home/...`) per the 08 §2 rename rule.
- Port-back candidates: none — the procfs regressions landed upstream in
  [Séance #81](https://github.com/L-K-M/Seance/pull/81) (merge
  `2e6d1f138f1704e683870f75e11262bf50e37379`) and are now ported here
  with the gate, closing the recorded candidate.

## app/poltergeist_app/lib/services/identity_file_reader.dart

- Source: app/seance_app/lib/services/app_services.dart
  (`_readIdentityFile`/`_auditIdentityRead`) plus `IdentityFileException`
- Séance commit: 99a3585 (re-diffed unchanged at a9add15, 2026-09-07; re-diffed at 2e6d1f1, 2026-09-08 — upstream's `_readIdentityFile` gained an optional `bookmarkOverride` parameter for Séance's sandboxed draft-connection-test grants, a path this port dropped wholesale per D23, so the change does not apply; `_auditIdentityRead` is unchanged)
- Ported: 2026-09-07
- Divergences: extracted as a standalone service; no security-scoped-bookmark
  grant path (Poltergeist is unsandboxed at v1, D23 — plain expanded reads
  only); `IdentityFileReadException` drops Séance's macOS EPERM sandbox
  hint; non-filesystem read failures are normalized and audited locally so
  arbitrary exception text cannot reach the prompt (D18/D20); audit writes
  stop delaying a connect after two seconds. `~` expansion and semantic key
  validation downstream of a successful text read remain source-identical.
- Port-back candidates: normalize non-filesystem read failures and bound audit
  writes; the grant path remains Séance-specific.

## app/poltergeist_app/test/services/identity_file_reader_test.dart

- Source: app/seance_app/test/identity_file_exception_test.dart
  (exception cases)
- Séance commit: ffac90f (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: sandbox-hint cases dropped (no hint exists here); adds the
  reader's success, failed-read, throwing-audit, and stalled-audit coverage.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/connection_status_panel.dart

- Source: app/seance_app/lib/ui/terminal_pane.dart (the connecting view,
  `_ConnectionError`, and `_ConnectionLogView`)
- Séance commit: d18f1ac (re-diffed unchanged at a9add15, 2026-09-07; source moved at 2e6d1f1, 2026-09-08 — upstream extracted `_ConnectionLogView`'s body into a shared `connection_log_view.dart` while keeping the session-notifier wiring and behavior, so the ported block's semantics are unchanged)
- Ported: 2026-09-07
- Divergences: driven by the engine protocol's streams (03 §5) instead of
  an app-side session object; strings localize through ARB (D20); states
  cover the pool's full lifecycle (reconnecting, blocked) beyond the
  source's terminal states; replacement streams resubscribe and reset stale
  server state/transcript; the transcript starts collapsed exactly as the
  source's does and anchors expanded live output to its newest lines.
- Port-back candidates: anchor live transcript output to its newest lines.

## app/poltergeist_app/test/ui/connection_status_panel_test.dart

- Source: none (no Séance test file covers these views directly)
- Séance commit: n/a
- Ported: 2026-09-07 (new coverage for the stream-driven panel)
- Divergences: per-state rendering, live/bounded transcript, copy via a
  mocked clipboard channel, per-server filtering, retry wiring, initial
  pending state, and stream/server replacement lifecycle.
- Port-back candidates: none.

## packages/poltergeist_core/lib/src/fs/local_fs_safety.dart

- Source: app/seance_app/lib/services/remote_files_controller.dart (the
  four private statics `_validatePathComponent`, `_validateLocalName`,
  `_ensureSafeLocalDirectory`, `_replaceLocalFile`)
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (rev pin, no
  tag — open item 2's bridge)
- Ported: 2026-09-11
- Divergences: public top-level functions split out of the controller
  (03 §2.3); they throw raw `FormatException`/`FileSystemException` and
  each caller funnels them through its own guard instead of the
  controller's transfer-failure path. `ensureSafeLocalDirectory` takes
  one absolute path (the plan's signature) instead of Séance's
  `(Directory root, String relativePath)` pair: the walk shape-checks
  every component (lexical `.`/`..`/separators refused), validates only
  the components it creates, and collapses Séance's two root messages
  ('Download destination is not a directory' plus the traversal
  refusal) into the one 'Refusing to follow a non-directory or symbolic
  link' refusal. Backup siblings rename `.seance-<uuid4>.backup` →
  `.poltergeist-<8 hex>.backup` (08 §2's sanctioned prefix rename; the 8-hex
  shape is 03 §2.3's documented pattern, matching the pinned adapter's
  temp suffixes). The NAME_MAX-255 backup-name guard (fail the replace
  rather than truncate into a collision), the crash-recovery sweep
  (`restoreOrphanedLocalBackups`, run by `replaceLocalFile` before its
  dance and callable as a startup sweep — Séance strands crashed
  replaces with no repair), `validatePathComponent`'s backslash
  rejection (09 §3.5: `\` is the Win32 separator; a `..\..\x`
  component must not become traversal once joined on Windows), and the
  extended reserved-name set (CLOCK$, CONIN$/CONOUT$, superscript
  COM¹–³/LPT¹–³, base-segment trailing dot/space stripping — 09 §3.5's
  full list) are plan-mandated additions Séance lacks. Fixed the
  pre-port original's dead regex branches: `\$` in the non-raw pattern
  string decoded to a bare `$` anchor, so `CLOCK$`/`CONIN$`/
  `CONOUT$` were never rejected; the raw-string pattern now matches
  them (regressions failed before, pass after). Review rounds 2–7
  added (per-round records in STATUS and the PR description):
  the commit point validates the target's basename (`validateLocalName`,
  09 §3.5's every-materialized-name rule — Séance validates only in
  the controller's scan), the pre-dance repair is scoped to the
  replace's own target (a directory-wide repair could consume a
  concurrent dance's live backup and fail its transfer on Windows;
  Séance has no sweep at all), the backup pattern is derived from
  the same constants that build backup names, the validators
  reject components over NAME_MAX bytes (255 UTF-8 bytes; Séance
  relies on the OS's ENAMETOOLONG mid-transfer instead of the clean
  boundary error 09 §3.5 specifies), the dance refuses a non-regular
  part symmetrically with its target refusal (rename moves a
  swapped-in symlink without following it), and `validateLocalName`
  refuses names matching the reserved
  `<name>.poltergeist-<8 hex>.backup` shape (Séance has no sweep to
  collide with, so no reservation exists there).
- Port-back candidates: the raw-string reserved-name fix, the NAME_MAX
  guard (and its validator-side twin), the orphaned-backup sweep, backslash
  rejection in the component validator, the extended reserved list
  (09 §3.5), and the commit-point leaf validation — all applicable to
  Séance's own statics.

## M3 native contract repairs (2026-09-12)

PR #81's native matrix exposed local source cleanup returning before the
file handle closed. `LocalFileSystem` now awaits iterator cancellation;
a held-cleanup regression pins completion ownership. This changes only
the local VFS, not the pinned remote adapter. No source copy or pin change.
The incident store's orphan sweep now matches basenames within its listed
parent, accepting Windows paths with mixed separators. No upstream store
counterpart is ported here.

## packages/poltergeist_core/test/fs/local_fs_safety_test.dart

- Source: app/seance_app/test/remote_files_controller_test.dart (the
  download half of 'recursively uploads and downloads directories with
  aggregate transfer' — the only upstream coverage of the statics:
  Séance has no dedicated unit tests for them)
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (rev pin, no
  tag — open item 2's bridge)
- Ported: 2026-09-11
- Divergences: re-homed per 08 §2 to the public helpers that now own
  the behavior (the controller-level aggregate-transfer bookkeeping
  rides M4's transfer queue); the remaining suites are new local
  coverage (validators, containment walk, dance refusals/restore,
  NAME_MAX, and the sweep — Séance tests none of these directly).
  2026-09-12: native Windows execution replaces the library-wide skip;
  only POSIX-mode and unavailable-link fixtures skip. Cleanup precedes
  setup writes; device-name assertions inspect directory entries.
- Port-back candidates: the validator and sweep suites, once Séance
  exposes the statics for testing.

## app/poltergeist_app/lib/ui/server_appearance.dart

- Source: app/seance_app/lib/ui/server_appearance.dart
- Séance commit: ded9228aaf8aa45fe2a5fb7df9559db8c820ec4d (main, ahead of
  the `v0.9.1` pin — the file's mark/tint rework landed upstream after
  the tag; the protocol types it consumes are all in the pin)
- Ported: 2026-09-15; re-diffed and expanded 2026-09-24 for the synced
  Séance-server catalog surface
- 2026-09-24: the port now carries the full module — `ServerTint`
  (named + custom colour), the memoized custom-accent derivation,
  `ServerBadge` over the protocol's resolved `ServerMark` (glyph, emoji,
  image), `ServerAccentBar`, the glyph table with labels/keywords, and
  the picker helpers (`serverIconLabel`, `serverIconMatches`,
  `serverIconGroups`, `serverColorSeed`, `serverColorLabel`,
  `formatServerCustomColor`, `parseServerCustomColor`,
  `nearestServerColor`). Identical records draw identical badges in
  both apps, which is the point of carrying the whole mapping rather
  than the earlier subset.
- 2026-09-21 at the `v0.9.1` pin (`035b0d8`): upstream reworked the file
  for custom colours/SVG marks and row accents (#101/#102) and widened
  the `ServerIcon` enum to ~45 values. The port's `serverIconData`
  switch was extended exhaustively over the widened enum using the
  upstream glyph choices; the rest of the rework stayed unported until
  the 2026-09-24 expansion above.
- Divergences: `ServerAvatar`/`_SessionRing` (badge + connected-session
  ring keyed on Séance's `TerminalStatus`/`StatusColors`) is not ported
  — Poltergeist's surfaces compose `ServerBadge` with their own
  connection indicators per 02 §3–4, and the catalog rows keep that
  contract. Label vocabulary (`serverIconLabel`, `serverColorLabel`,
  the group headings) stays upstream English: it is glyph vocabulary,
  not product copy; any picker that lands with the server editor can
  ARB-wrap it then. Doc references re-pointed from `SeanceTheme` to the
  app theme.
- Port-back candidates: none — Séance owns the source.

## app/poltergeist_app/test/ui/server_appearance_test.dart

- Source: app/seance_app/test/server_appearance_test.dart
- Séance commit: ded9228aaf8aa45fe2a5fb7df9559db8c820ec4d
- Ported: 2026-09-15; expanded 2026-09-24 to the full file minus the
  `ServerAvatar` group
- Divergences: the `ServerAvatar` group is dropped with the widget it
  covers; the two cases that used the avatar as the badge's host ('a
  config draws the mark its fields resolve to', 'a server's colour
  fills its badge, unframed') are adapted to `ServerBadge` directly —
  the resolution and fill under test are unchanged.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/server_grouping.dart

- Source: app/seance_app/lib/ui/server_grouping.dart
- Séance commit: ded9228aaf8aa45fe2a5fb7df9559db8c820ec4d
- Ported: 2026-09-24
- Divergences: none — carried verbatim (imports re-pointed). The file is
  deliberately Flutter-free upstream; the catalog section renders pulled
  `ServerConfig`s through the same sectioning Séance uses, so identical
  data produces identical placement.
- Port-back candidates: none — Séance owns the source.

## app/poltergeist_app/lib/ui/server_filter.dart

- Source: app/seance_app/lib/ui/server_filter.dart
- Séance commit: ded9228aaf8aa45fe2a5fb7df9559db8c820ec4d
- Ported: 2026-09-24
- Divergences: none — carried verbatim (imports re-pointed). Operates on
  `ServerConfig`, so the catalog's filter matches Séance's haystack
  term-for-term.
- Port-back candidates: none — Séance owns the source.

## app/poltergeist_app/test/ui/server_grouping_test.dart

- Source: app/seance_app/test/server_grouping_test.dart
- Séance commit: ded9228aaf8aa45fe2a5fb7df9559db8c820ec4d
- Ported: 2026-09-24
- Divergences: none — carried verbatim (imports re-pointed).
- Port-back candidates: none.

## app/poltergeist_app/test/ui/server_filter_test.dart

- Source: app/seance_app/test/server_filter_test.dart
- Séance commit: ded9228aaf8aa45fe2a5fb7df9559db8c820ec4d
- Ported: 2026-09-24
- Divergences: none — carried verbatim (imports re-pointed).
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/middle_ellipsis_text.dart

- Source: app/seance_app/lib/ui/middle_ellipsis_text.dart
- Séance commit: 15d0fdddccde6507156ce84ed31a254d0b9d5b13 (the file is
  byte-identical at Séance `367e4ea`, 2026-09-24)
- Ported: 2026-09-24
- Divergences: `Characters` comes through `package:flutter/widgets.dart`'s
  re-export instead of a direct `package:characters` import (Poltergeist
  does not list `characters` as a direct dependency, and adding one for a
  re-exported type would be a second version constraint on the same
  package). Behavior is unchanged. The widget sits at the same relative
  path in both apps so the shared sidebar kit
  (`lib/ui/sidebar/sidebar_kit.dart`, D32 §10) imports it verbatim.
- Port-back candidates: none — Séance owns the source.

## app/poltergeist_app/test/ui/middle_ellipsis_text_test.dart

- Source: app/seance_app/test/middle_ellipsis_text_test.dart
- Séance commit: 15d0fdddccde6507156ce84ed31a254d0b9d5b13
- Ported: 2026-09-24
- Divergences: the same `Characters` import re-point as the widget;
  otherwise verbatim (imports re-pointed).
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/sidebar/sidebar_kit.dart (port-out)

- Direction: Poltergeist → Séance (D32 §10's shared sidebar anatomy). New
  Poltergeist code written to be copied into Séance verbatim; no Séance
  source was copied in.
- Written: 2026-09-24
- Contract: imports only Flutter, the chrome tokens (through the file's
  one `_chrome()` function — Séance points it at its own ThemeExtension
  with the same token names), and `../middle_ellipsis_text.dart` (above,
  same path in both apps). Every string arrives through
  `SidebarKitStrings`; every behavior through callbacks. No store,
  service, or model type is referenced.
- Port-back candidates: the whole file, when Séance adopts the D32 rail.
- Port-back from Séance: 2026-09-24, from Séance
  `153fd657dda8d98908e08d53108c81742f390046` (branch
  `claude/poltergeist-ui-redesign-albp0m`; rationale in Séance's
  docs/POLTERGEIST.md, "The sidebar kit"). Séance adopted the kit from
  `58605fa` and improved it, and Poltergeist takes its copy back so the
  two files differ only in the chrome import, `_chrome()`, and Séance's
  provenance header. Taken over:
  - Bug: Shift+F10 or the Menu key opened a row menu, but the row's key
    handler still took the arrows and Enter. The row now ignores keys
    unless it has primary focus, the menu gets `childFocusNode`, a
    keyboard-opened menu focuses its first enabled verb, and Esc closes
    and an arrow steps into a right-clicked menu.
  - Bug: the touch verb sheet was capped at 9/16 of the screen. It is
    now `isScrollControlled` with `useSafeArea`.
  - Bug: the focus ring was a decoration border that shifted content
    2 px. It is a `foregroundDecoration` now.
  - The touch posture: chevrons and "+" stay drawn, and headers, the
    filter, icon buttons, the bottom bar, the mark and the dot take
    touch sizes (`sidebarMarkExtent()`).
  - `SidebarKitScope.background` for rows on a non-rail surface.
  - Row `subtitle`, `trailingIcon` and `showMenuButton`, with the new
    required `SidebarKitStrings.rowMenu` (Poltergeist's
    `sidebarRowMenu`, "More actions").
  - The kit test's additions, with the theme and chrome re-pointed.
- Divergence kept, to port back to Séance: the status dot is one value,
  `SidebarRow.status: SidebarStatusDot?` (colour plus
  `SidebarDotStyle`), where Séance passes `statusColor` and
  `statusStyle` separately. A style without a colour cannot be
  expressed this way. The ring's rendering, `_hollowStroke`, and the
  enum are Séance's.
- D33 extension, 2026-09-25: written once and committed to both repos
  on the same day (Poltergeist `4c166a8`, `60b2b63` and `396b568`;
  Séance `663ceae`, `ec6439f` and `183b24f`), so the two files still
  differ only in the
  header comment, the chrome import and `_chrome()`. Added:
  - `SidebarKitDensity {compact, comfortable}` on `SidebarKitScope`
    (`densityOf`, comfortable by default), `sidebarHomeLayout()`,
    density-aware `sidebarMarkExtent()` and the new
    `sidebarGlyphSize()`: compact keeps D32's 26 px rail, comfortable
    is 52 px (56 dp touch) with a 32 px mark.
  - `SidebarRow.subtitle` drawn only when comfortable (the host always
    passes it; the long-press sheet shows it under its title in either
    density), `showMenuButton` defaulting to comfortable-or-touch,
    `accent` (the 4 px colour line) and `markRing` (the connected ring).
  - `SidebarDotStyle.blocked`, `SidebarSectionHeader.status` for a
    header's live dot, comfortable headers keeping chevron, count and
    "+" in view, and ← / → swallowed on headers and rows so focus stays
    in the sidebar.
  - `SidebarDensitySwitch`, `SidebarBottomBar.onDensityChanged`, and
    the `compactRows` / `comfortableRows` strings. The filter's count
    reads on a line under the field.

## app/poltergeist_app/lib/services/badge_image.dart

- Source: app/seance_app/lib/services/badge_image.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: none — carried verbatim (imports re-pointed). SVG
  rasterization adds the `flutter_svg` direct dependency, the same use
  upstream makes of it.
- Port-back candidates: none — Séance owns the source.

## app/poltergeist_app/lib/services/server_duplication.dart

- Source: app/seance_app/lib/services/server_duplication.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: the macOS security-scoped bookmark machinery is dropped —
  Poltergeist is not sandboxed, so identity files travel as plain paths
  and the duplicate simply carries `identityFilePath` over. The label
  grammar, stale-source check (`SourceServerChanged`), and credential
  copy shape are upstream's.
- Port-back candidates: none — the omission is sandbox-specific.

## app/poltergeist_app/lib/services/server_editor_backend.dart

- Source: adapted from app/seance_app (the `AppState.testServerConnection`
  composition and the editor's credential-resolution rules)
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: this is the production implementation of the ported
  editor's `ServerEditorDelegate` seam, not a file-for-file port —
  upstream's editor reaches into `AppState` directly. Credential
  precedence (draft over vault over identity-file), trial-only host-key
  approval, and the no-login-script test posture mirror upstream.
- Port-back candidates: the delegate seam itself, if Séance ever wants
  the editor testable without a full `AppState`.

## app/poltergeist_app/lib/ui/connection_log_view.dart

- Source: app/seance_app/lib/ui/connection_log_view.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: user-facing strings moved to ARB (Poltergeist's
  localization contract); layout and log rendering verbatim.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/connection_test_report.dart

- Source: app/seance_app/lib/ui/connection_test_report.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: user-facing strings moved to ARB; report structure and
  the connection-log embedding verbatim.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/server_color_picker.dart

- Source: app/seance_app/lib/ui/server_color_picker.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: strings moved to ARB; preview badges pass the picked
  `ServerTint` because Poltergeist's `ServerBadge` requires one
  (upstream's defaults to a neutral badge).
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/server_mark_picker.dart

- Source: app/seance_app/lib/ui/server_mark_picker.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: strings moved to ARB; the curated emoji table keeps
  upstream's `\u{...}` escapes for re-diffability. Same `ServerBadge`
  tint adaptation as the color picker.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/server_editor.dart

- Source: app/seance_app/lib/ui/server_editor.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: `AppState` is replaced by the narrow `ServerEditorDelegate`
  seam (servers, syncConfigured, themeSeed, pickIdentityFile, readSecret,
  save, testConnection) — Poltergeist composes services rather than a
  monolithic state. Strings moved to ARB. The macOS security-scoped
  identity bookmark becomes a plain path field (not sandboxed). Field
  set, credential planning, exclusion confirmation, monotonic
  `updatedAt`, and the vault-first save order are upstream's.
- Port-back candidates: the delegate seam (see the backend entry).

## app/poltergeist_app/test/services/server_duplication_test.dart

- Source: app/seance_app/test/server_duplication_test.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: the security-bookmark and `ServerTile` cases are dropped
  with the machinery they exercise; label grammar and stale-source
  coverage carried verbatim.
- Port-back candidates: none.

## app/poltergeist_app/test/ui/server_editor_test.dart

- Source: adapted from app/seance_app/test/server_editor_test.dart
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (v0.9.1 pin)
- Ported: 2026-09-24
- Divergences: upstream boots real services around `AppState`; the port
  drives the same editor surface through a fake `ServerEditorDelegate`,
  so cases about vault plumbing collapse into delegate assertions.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/top_toast.dart

- Source: app/seance_app/lib/ui/top_toast.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (rev pin, no
  tag — the live pin this task shipped against)
- Ported: 2026-09-16
- Divergences: none — carried verbatim (02 §3's workspace-open toast:
  top-center card, 12 s duration for the Undo affordance). String
  arguments stay caller-supplied so labels come from ARB.
- Port-back candidates: none — Séance already owns the source.

## M5 bookmark store (2026-09-19)

03 §6's `BookmarkStore` landed in `poltergeist_core` (`src/bookmarks/`).
No Séance source was copied: the `Bookmark` model is consumed through the
`2e6d1f1` pin (PR-S1 is in its ancestry, so 04 §2.1's temporary-copy
clause does not apply), `sortKeyBetween` is new code — the pinned rev
carries no fractional-index helper — and `groupBookmarks` is a fresh
implementation of `server_grouping.dart`'s rules for the `Bookmark`
shape, not a port (02 §4 names it the pattern to mirror; the Séance
source's collapse-state side stays a UI concern and was not carried).
The app's interim `FileBookmarkStore` was Poltergeist-authored, so its
move to core is a relocation, not a port. Port-back candidate: the
sortKey/grouping pair is written to the upstream `Bookmark` struct and
could ride a future Séance PR if Séance adopts §2.5 ordering.

## app/poltergeist_app/lib/services/sync_enrollment_validation.dart

- Source: app/seance_app/lib/ui/sync_enrollment_validation.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: the validator reports a typed `SyncEnrollmentIssue` enum
  the render site maps to ARB copy (D20 — no user-facing English in Dart)
  instead of returning the source's English strings; the rules themselves
  (URL shape, embedded-credentials refusal, required fields, the
  register-only confirmation pair) are byte-identical. Poltergeist's
  field labels say "encryption passphrase" per 04 §4.3, so the issue
  enum carries no "vault" wording either.
- Port-back candidates: none — the typed-issue reporting is D20-local;
  the rules did not change.

## packages/poltergeist_core/lib/src/checkout/managed_remote_file.dart

- Source: app/seance_app/lib/services/managed_remote_file.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: two persisted fields Séance's record lacks —
  `needsReconcile` (06 §3.4's degraded-snapshot mark: a post-upload
  remote re-stat failure synthesizes size+digest and must not be
  laundered into an authoritative snapshot across a restart) and
  `displaced` (06 §3.5: a rename arrival onto a record's remotePath
  displaces the standing record instead of overwriting it — the
  record keeps its original path as the CAS-guarded upload target).
  Both decode as absent → false so a Séance-shaped index stays
  readable. The strict codec (required-field types, digest shape,
  remotePath==snapshot.path, no dirty+missing) is ported semantics.
- Port-back candidates: the two marks, if Séance adopts the
  synthesized-snapshot repair and rename-displacement rails.

## packages/poltergeist_core/lib/src/checkout/managed_remote_file_store.dart

- Source: app/seance_app/lib/services/managed_remote_file_store.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: the Poltergeist lifecycle rails 06 §3.2/§3.7 add —
  generation epoch markers, the `.poltergeist-abandoned` in-flight
  marker dropped at checkout creation and cleared at commit (a
  marker-bearing unindexed dir is swept wholesale; a payload-bearing
  unindexed dir is preserved), the recovered-payload listing
  (`listRecovered`) with explicit-only `deleteRecovered` plus the §3.7
  per-row `deleteRecoveredFile` (drops one payload file, never a
  record-owned dir, deletes the dir when its last payload goes), the
  cross-process `fcntl` lock plus a same-process held-paths guard
  (POSIX fcntl locks are per-process — Séance's OS lock alone cannot
  stop a second in-process store), symlink-safe create/delete, the
  frozen `.poltergeist-<uuid>.upload` sibling snapshot, and streamed
  SHA-256 hashing. Sanitizer divergences per 06 §3.1's pinned
  contract: a Windows reserved device name keeps its extension under
  a `file-` prefix (`nul.conf` → `file-nul.conf`, stem matched
  case-insensitively against the full 09 §3.5 reserved list —
  CONIN$/CONOUT$/CLOCK$/superscripts included) instead of Séance's
  fixed `remote-file` replacement, and overlong names truncate to the
  255-byte NAME_MAX floor on a codepoint boundary rather than failing
  at the OS. Owner-only modes extend Séance's Linux-only helper: the
  index, its atomic-write temp, quarantine destinations, checkout
  dirs/files, and `.upload` snapshots are chmod 600/700 on Linux and
  macOS (Windows relies on the per-user app-support ACLs).
- Port-back candidates: the device-name prefix contract, the
  NAME_MAX truncation, the epoch/abandoned markers, the
  recovered-payload surface, and the in-process lock guard.

## packages/poltergeist_core/lib/src/checkout/checkout_manager.dart

- Source: app/seance_app/lib/services/remote_files_controller.dart (the
  managed-checkout pipeline extracted from the controller per 03 §6:
  `checkoutRemoteFile`/`uploadLocalCopy`, the checkout watcher and
  debounce, `_restoreLocalCopies`, renameEntry's local-copy re-keying,
  `_sameSnapshot`)
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: extracted from the per-pane controller into an
  app-wide core manager — `editSessionId` is the per-server constant
  (D17: checkout ownership is per server, never per pane/tab — Séance
  keyed checkouts per tab). Every byte rides the composed
  `TransferQueue` through `enqueueManagedCheckout` (journaled,
  panel-visible, priority-dispatched) instead of the controller's
  direct adapter calls; the upload carries the record snapshot as
  `expectedTarget` so the destination adapter's mandatory
  contentSha256 CAS is the conflict authority (D7) — Séance relied on
  the preflight stat alone for the same-size/same-mtime case.
  Post-upload re-stat failure degrades to a synthesized snapshot plus
  `needsReconcile` rather than failing the committed save. Directory
  renames re-key descendants prefix-wise (06 §3.5) and an arrival onto
  an occupied path displaces the occupant rather than dropping it.
  Watch events filter only the exact generated temp shapes and
  lifecycle markers — never the record's own basename, so a checkout
  named `.poltergeist-<hex>.upload` keeps dirty detection. The §3.7
  review surface adds `forgetRecoveredFile`/`recoveredFile` (per-row
  discard/open for preserved recordless payloads — Séance's surface
  deletes whole dirs).
- Port-back candidates: the CAS-carrying upload spec, the
  synthesized-snapshot repair, and prefix-wise rename migration.

## packages/poltergeist_core/test/checkout/

- Source: app/seance_app/test/managed_remote_file_store_test.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: the store suite keeps the ported cases (sanitizing,
  validation, persisted round-trips, quarantine, serialization) and
  adds the Poltergeist rails (epoch sweep, abandoned markers, the lock,
  recovered listings, needsReconcile/displaced persistence, the
  device-name prefix and NAME_MAX truncation). `checkout_manager_test`
  is new: round-trip through a scripted remote, per-server
  editSessionId stability, watch debounce and the exact-temp-shape
  filter, reconcile-on-resume and relaunch recovery, the
  remote-change/deletion/tamper conflict blocks, explicit overwrite,
  rename migration, and queue-visibility of both directions.
- Port-back candidates: none — the new suites cover Poltergeist
  semantics upstream lacks.

## app/poltergeist_app/lib/services/checkout_session.dart

- Source: none — new Poltergeist composition (03 §6's app seam).
- Ported: 2026-09-20
- Notes: the `ChangeNotifier` session wraps the core
  `CheckoutManager`, exposes the record surface and verbs to the
  future editor UI, drives uploads through the composed
  `TransferQueue` (the activity panel's instance), and reconciles on
  `AppLifecycleState.resumed`. It shares the queue's
  `LocalOnlyConnectionManager`, so remote verbs fail with the typed
  `unsupported` error until STATUS item 23 (engine transfer verbs)
  lands — honest refusal, never a simulated success.

## packages/poltergeist_core/lib/src/editor/built_in_text_document.dart

- Source: app/seance_app/lib/ui/built_in_text_editor.dart (the pure
  document-I/O layer — load, the atomic temp+rename save, and the size
  cap — extracted per 06 §2.1)
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: the document carries 06 §2.1's fidelity contract Séance
  leaves implicit — LF/no-BOM in-memory invariants with the original
  BOM and per-line endings reconstructed exactly on save (mixed-EOL
  files round-trip byte-identical), a `LineEnding` enum, and typed
  `BuiltInEditorException`s. The save writes a
  `.poltergeist-<uuid>.tmp` sibling at owner-only 0600 through
  `restrictLocalPathPermissions` before rename (Séance's temp is
  fixed-name, default-mode), and the `expectedSha256` guard is the
  modified-on-disk conflict check the editor's conflict flow hangs on.
- Port-back candidates: the BOM/EOL reconstruction contract and the
  expected-digest save guard.

## app/poltergeist_app/lib/ui/editor_syntax.dart

- Source: app/seance_app/lib/ui/editor_syntax.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: tokenizer, controller, and engine semantics are
  verbatim; the `EditorSyntaxTheme` values are Poltergeist's teal-seed
  palette (06 §2.2), and §7's data-only additions extend the language
  table (css, ruby, perl, lua, the Apache dot-config mappings,
  env-aware shebangs) without touching the engine.
- Port-back candidates: none — palette and table entries are
  Poltergeist data.

## app/poltergeist_app/lib/ui/built_in_text_editor.dart

- Source: app/seance_app/lib/ui/built_in_text_editor.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences per 06 §2.3/§2.5: document I/O lives in
  `poltergeist_core` (`BuiltInTextDocument`); the toast presenter,
  mono-font stack, and basename resolver are injected seams instead of
  `SeanceTheme`/`remoteBasename` hardcodes; all user-visible copy
  resolves through `AppLocalizations` (D20). The save callback returns
  the new baseline digest so the next save's `expectedSha256` stays
  armed. `onSaved`/`onUpload` carry the checkout session's reconcile
  and upload verbs — save-and-upload on a managed checkout rides the
  composed queue and surfaces the typed `conflict` as 06 §3.4's
  overwrite dialog; cancel keeps the local save and uploads nothing.
- Port-back candidates: none — the seams exist so Poltergeist's
  checkout pipeline owns the conflict authority.

## Editor tests and captures (M7)

- Sources: app/seance_app/test/built_in_text_editor_test.dart and
  app/seance_app/test/editor_syntax_test.dart
- Séance commit: 2e6d1f138f1704e683870f75e11262bf50e37379 (the live pin)
- Ported: 2026-09-20
- Divergences: the Séance suite splits along the seam —
  `packages/poltergeist_core/test/editor/built_in_text_document_test.dart`
  takes the document half (BOM-present/BOM-less/CRLF/mixed-EOL
  round-trips, size cap, atomic-temp window) and
  `app/poltergeist_app/test/ui/built_in_text_editor_test.dart` keeps
  the widget half plus §2.5 production-path saves through the real
  document saver. New Poltergeist-only suites:
  `test/ui/workspace/built_in_editor_checkout_test.dart` drives the
  shell-level path — `file.editBuiltIn` → checkout → edit →
  save-and-upload through the composed queue, the conflict-blocked
  save that never uploads, and overwrite — and
  `test/ui/built_in_editor_capture_test.dart` produces the §-required
  PNGs (find bar, conflict dialog) under `POLTERGEIST_CAPTURE=1`.
- Port-back candidates: none.

## External editors (M7)

- Sources: app/seance_app/lib/services/external_file_opener.dart,
  the `seance/files` channel block in
  app/seance_app/macos/Runner/MainFlutterWindow.swift, and
  app/seance_app/test/external_editor_test.dart
- Séance commit: bb3fa4bfa4e1c0345afbd95093f2cb02eff11e3f (in the live
  pin's ancestry — the channel block postdates nothing in the pin)
- Ported: 2026-09-20
- Local files:
  `app/poltergeist_app/lib/services/external_file_opener.dart` (the
  registry, opener, and picker seams) and
  `app/poltergeist_app/test/services/external_editor_test.dart` (the
  registry/persistence port). The `poltergeist/files` channel block in
  `macos/Runner/MainFlutterWindow.swift` mirrors the Séance handler
  under the renamed channel. New Poltergeist compositions:
  `lib/services/editor_registry_controller.dart` (SettingsStore
  persistence — Séance persists through its own prefs path),
  `lib/ui/panes/open_with_commands.dart` (D21's `open-with-external`
  command, the chooser, and the remember-choice dialog),
  `lib/ui/settings/editor_settings.dart` (the §8 bounded mount),
  `test/ui/workspace/external_editor_checkout_test.dart` (the
  shell-level drive), and `test/ui/workspace/external_editor_capture_test.dart`
  (the §-required PNGs under `POLTERGEIST_CAPTURE=1`, in
  `tasks/run3-task85/`).
- Divergences: the reserved selector prefix is `poltergeist.` (the
  whole prefix, not just the two sentinels, so synced definitions can
  never shadow `poltergeist.system`/`poltergeist.builtin`). Launch-target
  validation is platform-aware rather than host-aware — Séance's
  `File.isAbsolute` check fails to DECODE a Windows definition on a
  Linux/macOS host, yet §8 requires other-platform rows to render
  disabled, so Poltergeist validates the target against the definition's
  own `platform` field. `Other…` carries §4.1's remember-choice prompt
  (the per-extension binding write) — Séance has no such flow.
  User-visible copy resolves through `AppLocalizations` (D20); the
  dirty→toast→upload loop rides `CheckoutSession`'s watcher and the
  composed `TransferQueue` rather than Séance's files-pane plumbing,
  and `WorkspaceShell` schedules a frame beside its post-frame re-check
  because a watcher-driven prompt on an idle window would otherwise
  wait for an unrelated repaint.
- Port-back candidates: the platform-aware launch-target validation —
  Séance's `File.isAbsolute` decode fails the same synced-Windows case
  upstream.

## Preview and Quick Look (M7)

- Sources: none — 06 §5.2 names `preview_panel.dart` new code, and
  Séance ships no preview cache, Quick Look channel, or produce-task
  plumbing to port.
- Ported: nothing; recorded 2026-09-21.
- Local files (all new Poltergeist compositions):
  `packages/poltergeist_core/lib/src/preview/` (kind classifier, cache,
  produce spec/byte gate, queue producer),
  `app/poltergeist_app/lib/services/preview_session.dart`,
  `lib/services/quick_look_channel.dart`, `lib/ui/preview_panel.dart`,
  `lib/ui/pdf_preview.dart`, `lib/ui/settings/preview_settings.dart`,
  the `poltergeist/quicklook` channel block in
  `macos/Runner/MainFlutterWindow.swift`, and the suites under
  `test/` (`services/preview_session_test.dart`,
  `ui/panes/preview_panel_test.dart`,
  `ui/panes/preview_panel_capture_test.dart` — the §-required PNGs under
  `POLTERGEIST_CAPTURE=1`, in `tasks/run3-task86/` —
  `ui/settings/preview_settings_test.dart`).
- Divergences: produce tasks get the queue-side exemption set the spec
  requires (head insertion; pause/cap/throttle bypass; two-task in-flight
  cap; never journaled), but the connection-pool reservation 03 §4.6
  contemplates is not landed — it needs a `ConnectionManager` surface
  change and is recorded as a bounded follow-up rather than hacked in.
  The PDF row rasterizes through `pdfrx` (new dependency) behind the
  `PreviewPdfBuilder` seam.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/update_banner.dart

- Source: app/seance_app/lib/ui/server_list_pane.dart (`_UpdateBanner`)
- Séance commit: 035b0d880b47639e390af8cbbd6d316cb5edc86d (`v0.9.1`, the
  live pin)
- Ported: 2026-09-22 (M9 polish pass 2, PR #185; PORTS entry added by the
  M9 closure audit — the entry was missed in the landing PR)
- Divergences: mounts inside the workspace shell between toolbar and
  panes rather than Séance's server list; strings are ARB (D20); the
  release-page hand-off goes through an injectable `launch` seam
  (url_launcher `LaunchMode.externalApplication` by default) so tests
  observe it without the platform channel, and a failed launch routes to
  `ApplicationErrorReporter`. The checker's repo constant lives in
  `poltergeist_core`'s `src/update/update_check.dart`
  (`poltergeistUpdateRepo`); `UpdateChecker`/`UpdateInfo` themselves are
  consumed from the pin, not ported (D2).
- Port-back candidates: none — the divergences are Poltergeist-local
  (shell mount point, D20 localization, test seam).
- Retired: 2026-09-24. D32 moved update availability into the
  inspector's Alerts tab, and nothing mounted the banner after that.
  The widget, its test and its three ARB keys (`updateBannerText`,
  `updateViewRelease`, `updateDismissTooltip`) are removed. The checker
  and `UpdateInfo` stay, feeding the alert.

## M10 milestone-close sweep (2026-09-22)

The 07 §3.12 close sweep re-verified every entry against the `v0.9.1`
pin (`035b0d8`) and re-diffed the recorded sources against upstream HEAD
(`15d0fdd`, 2026-09-22). The pin does not move: v0.9.1 remains the
containing tag, and the drift below is upstream-HEAD churn for the next
pin-bump window, not pin fallout. `dartssh2` stays exactly 3.0.2.

Upstream drift since the pin touches six recorded sources. Dispositions:

- `remote_files_controller.dart` — upstream grew managed-checkout
  freshness tracking (#105: `latestRemoteSnapshots`, refresh-on-reopen).
  Complementary to the ported `CheckoutManager` rails; no port edit. The
  four safety statics are unchanged — the recorded `local_fs_safety`
  candidates below still apply at HEAD.
- `built_in_text_editor.dart` — upstream gained the `expectedSha256`
  save guard (returns the new baseline digest, same shape as the port's)
  plus BOM tracking and dominant-ending CRLF normalization. The
  `built_in_text_document` candidate narrows to per-line EOL
  reconstruction for mixed-EOL files (upstream collapses to the dominant
  ending; Poltergeist round-trips mixed endings byte-identical) — minor,
  left open.
- `server_list_pane.dart`, `server_appearance.dart`,
  `terminal_pane.dart`, `connection_log_view.dart` — tab/session and
  appearance churn in surface area Poltergeist does not port (list rows,
  tab chrome); the `connection_status_panel` transcript-anchor candidate
  is still upstream-absent at HEAD.
- `seance_core`/`seance_protocol` — additive only (remote-git surface);
  nothing consumed here changes shape.

Port-back issues filed this sweep (all on `L-K-M/Seance`):

- [#114](https://github.com/L-K-M/Seance/issues/114) — sync-token
  revocation endpoint (04 §7.3's urgent item: self-revocation plus a
  password-authenticated revoke-all; leaked tokens currently have no
  remediation short of account deletion).
- [#115](https://github.com/L-K-M/Seance/issues/115) — the
  `local_fs_safety` validator batch: extended reserved names, backslash
  rejection, NAME_MAX guards, orphaned-backup sweep, commit-point leaf
  validation.
- [#116](https://github.com/L-K-M/Seance/issues/116) —
  `secure_master_key`: corrupt-entry misreport and the create-on-first-run
  race.
- [#117](https://github.com/L-K-M/Seance/issues/117) — identity-file
  read: normalize non-filesystem failures, bound audit writes.
- [#118](https://github.com/L-K-M/Seance/issues/118) — `seance_core` VFS
  additions Poltergeist needs: `pathTypeChanged` kind, cancellable
  `listDirectory`, raw-name metadata (STATUS items 10/12/13).
- [#119](https://github.com/L-K-M/Seance/issues/119) — managed-checkout
  lifecycle hardening: prefix-wise rename migration, displaced-on-arrival,
  synthesized snapshot + `needsReconcile`, epoch/abandoned markers,
  recovered-payload surface, in-process lock guard, sanitizer contract,
  CAS-carrying upload.
- [#120](https://github.com/L-K-M/Seance/issues/120) — 04 §6 priority 2,
  now proven: `PersistentLocalRecordStore` with durable tombstones (fixes
  delete-resurrection and the wholesale re-push habit).
- [#121](https://github.com/L-K-M/Seance/issues/121) — UX patterns per
  04 §6 priority 3: theme-aware status colors (SEA-019), ssh_config
  import preview + dedupe (SEA-007/027), two-stage collapse, persisted
  pane ratios.
- [#122](https://github.com/L-K-M/Seance/issues/122) — small polish
  batch: transcript newest-line anchoring, the RFC 4256 echo bit (plus
  Enter-navigation/autofocus), platform-aware launch-target validation,
  UTC-stamped quarantine names, the mounted-harness test nit.

Candidates left open without an issue: the M5 `sortKey`/`groupBookmarks`
pair (conditional on Séance adopting 02 §5 ordering), the
`local_fs_safety_test` suites (conditional on upstream exposing the
statics — noted in #115), and the narrowed mixed-EOL reconstruction
above. `file_stores`' serialized-flush candidate is closed: the v0.9.1
pin already carries upstream's mutation queue.

## Pin findings

The 2026-09-21 tag re-pin (M8's first slice) moves both live declarations
from rev `2e6d1f138f1704e683870f75e11262bf50e37379` to tag `v0.9.1`
(`035b0d880b47639e390af8cbbd6d316cb5edc86d`), the D2 steady state open
item 2 waited for: the tag contains the rev pin by ancestry and
therefore the PR-S3 merge `2f99f4e` (the M8 gate), PR-S1's `599ff936`,
and #79's probe repair. All four lockfiles resolve to `035b0d8`; the
bench harness's `pinnedSeanceRevision` follows; `dartssh2` stays exactly
3.0.2. Upstream changes in the consumed surface at the tag:
`VaultStore.putSecretBlobs` (batched vault write — port fix recorded in
the `file_stores` entry), the `ServerIcon` enum widening (port fix in
the `server_appearance` entry), plus unconsumed additions (the
`VaultRekeyJournal` interface, the serialized vault mutation queue,
custom server colours/SVG marks, the re-key flow) that stay upstream
like the assistant surfaces before them. `flutter analyze` and the full
app suite verify at the tag; the regenerated audit block below verifies
with `tool/seance_pin_audit`.

The 2026-09-08 pin bump moves both live declarations and all three locks from
upstream `a9add15` to `2e6d1f138f1704e683870f75e11262bf50e37379` (Séance
#81's merge; a commit-rev bridge per D2 — no Séance tag contains #79's
probe repair, checked by ancestry against all eleven published tags). The
pin brings Séance #79's serialized probe sweeps, #80/#81's audit work
(already mirrored in PR #52), SSH trace redaction inside
`SshConnectionLog.add` with the `Iterable<String>` lines view, the
typed `AgentAuthUnsupportedError`, `HostKey.recordId`/`hostKeyLocator`,
`Secret.copyWith`, the additive `assistantSettings` record kind, and new
first-party sources (`test_connection`, `zai_search`, `assistant_settings`)
plus `fake_async` as a seance_core dev dependency. The newly available
assistant/sync surfaces are not consumed (D19 scope; no Poltergeist account).
`dartssh2` stays exactly 3.0.2 (sha-identical in all three locks).

Every PORTS entry was re-diffed at the target against its recorded source
block (2026-09-08): `secure_master_key`, `file_stores`, both dialogs and
their tests, `keystore_resilience`, `atomic_file_test`, and
`identity_file_reader_test` re-diff clean — their source files are unchanged
since the recorded revisions, which predate the pin. The four sources that
moved carry dated dispositions in their entries above (`atomic_file`'s #80
privacy parameter; `app_services`' assistant/sync churn outside the ported
`LockedSecretVault` and identity blocks, plus the inapplicable sandbox-grant
override; `terminal_pane`'s behavior-identical `_ConnectionLogView`
extraction; `identity_audit_log` identical since cb4b010). Attribution
headers in ported files keep their original source revisions — provenance,
not a live-pin claim.

The 2026-09-10 full re-diff sweep (run 3 task 8; per-entry diffs saved
under `tasks/run3-task8-*`, not committed) re-verified every entry above
against the `2e6d1f1` pinned tree. All sixteen file entries re-diff as
recorded: every recorded Séance revision exists with the claimed content
identity, every recorded divergence is still present in the local port,
the four recorded source moves (`atomic_file`, `app_services`,
`terminal_pane`, `identity_audit_log`) verify, and no ported file changed
locally since the 2026-09-08 refresh except through the already-recorded
PR #52 gate mirror. Two stale records are corrected in place above, each
with its citing PR: the probe prerequisite's open-item tail (#62/#67) and
the cleanup dependency's pin reference (#35/#53). The open port-back
candidates were re-verified against the pin and against upstream HEAD
(`b8fc111`, 2026-09-09 — only the #82/#83 dialog changes sit between
them) and stay open: the responder still drops RFC 4256's per-prompt
echo bit, the identity read still catches only `FileSystemException`
with an unbounded audit write, the log view still has no newest-line
anchoring, and the mounted-harness, Enter-navigation, and autofocus-test
candidates remain upstream-absent. Local `file_permissions.dart` and
`uuid.dart` are Poltergeist originals (the helper went upstream in
Séance #80's port-back, not the reverse), so they carry no entries.
Four ported files still lack the 09 §4 attribution header
(`identity_file_reader.dart`, `identity_file_reader_test.dart`, and both
prompt-dialog test files) — recorded as a follow-up, not fixed in this
docs-only sweep. The pin audit block below was
re-verified with `tool/seance_pin_audit` (verify mode matches). This is
close-prep, not the 07 §3.12 milestone-close chore: that sweep runs
after startup wiring lands (task 6's engine bridging merged as PR #66
while this sweep was in review).

The 2026-09-11 addendum (run 3 task 10) re-verifies the entries the sweep
marked task-6/9-adjacent against current main (`43396c5`): PR #66's merge
stat touched only `poltergeist_core` and docs — no ported app source and
no PORTS entry — and PR #69's merge diff over all sixteen ported files is
empty, so no entry drifted from either PR and no pin or lock moved (no
pubspec/lock change in either range; `tool/seance_pin_audit` verify mode
re-run on 2026-09-11 still matches the recorded block). The probe
prerequisite's stale tail
(startup composition open) is corrected above with its citing PR (#69).
The sweep's recorded follow-up is closed: the four ported files it named
(`identity_file_reader.dart`, `identity_file_reader_test.dart`, and both
prompt-dialog test files) now carry the 09 §4 attribution header. The
`TODO(pin)` grep finds no remaining markers in code or docs — only the
plan's and STATUS's own references to the rule — so nothing is obsoleted
at the unchanged `2e6d1f1` pin (no Séance tag contains #79; STATUS item 2
owns the next-tag re-pin). This addendum is close-prep too: the milestone
closes only with the v0.2.0 tag and release rehearsal.

The consumer fix riding the same pin bump: the pool's transcript bridge
forwarded the raw `add()` argument past upstream's new redaction to the live
`connectLog` fan-out. It now forwards the record exactly as upstream stored
it (`lines.last` after `super.add`), so the live stream and the stored
transcript carry identical redacted text. Regressions in
`pool_diagnostics_test.dart` failed at runtime on both the old pin (no
redaction anywhere) and the new pin with the bridge unfixed (storage
redacted, stream raw), and pass after the fix. No redaction logic is copied
or forked; `dartssh2` 3.0.2 stays pinned (upstream's trace audit is
version-bound).

The 2026-09-07 recovery diagnostics change Poltergeist's pool and engine
protocol only. No source copy, pin change, or upstream port is required.

The 2026-09-07 stale-home recovery repair changes Poltergeist's pool only.
No source copy, pin change, or upstream port is required; Séance does not own
this background recovery loop.

The 2026-09-07 prompt-UI and diagnostics slice ports the nine Séance-sourced
files above — five production sources plus four test files — at the existing
`a9add15` pin (no pin change; no Séance tag contains it yet — STATUS item 2
owns the next-tag bump). The engine-side additions (`ServerStatus.detail`,
`ConnectLogLine`, the port coalescer, protocol v4) and the prompt
coordinator, credential dialog, and vault-first resolution are
Poltergeist-only. Current-route dialog guards, malformed audit-line handling,
and owner-only audit storage are port-back candidates recorded above.

The 2026-09-07 engine progress coalescer uses the M0 harness's rate and item
caps, with shared flush windows for the aggregate stream. It adds no Séance
source copy, dependency change, or port-back candidate.

The 2026-09-07 keepalive prerequisite re-pins both declarations to upstream
`a9add15` ([Séance #77](https://github.com/L-K-M/Seance/pull/77)). All ported
sources re-diff unchanged from `2f99f4e`; the `app_services.dart` changes are
outside the ported `LockedSecretVault` class. No port edits, new copies or
new port-back candidates. Existing candidates remain tracked above. No tag
contains the new pin yet; STATUS item 2 owns the next-tag bump. M0's measured
pins and evidence are unchanged.

The 2026-09-07 reconnect slice uses the existing `Prober`/`TcpBannerProber`
and SSH authentication APIs. No Séance source copy, pin change, or port is
required. Its upstream keepalive gap is closed by the prerequisite above;
pool wiring remains STATUS item 3.

The 2026-09-07 vault/store ports copy app-layer sources whose last-touch
revisions all predate the current pin; each re-diffs clean at `2f99f4e`, and
no pin or port-back change is required. The bookmark model is consumed
through the existing `seance_protocol` pin (no copy: PR-S1 is in the pin's
ancestry, retiring 07 §3.3's temporary-copy clause).

The 2026-09-06 dependency-contract tests consume the existing pins through
their APIs. No Séance source or tests were copied; no pin or port-back change
is required. Independent crypto vectors and a signed in-memory SSH peer pin
the assumptions required by 09 §5.

The 2026-09-06 credential repair changes Poltergeist's pool ownership only.
No copied source, pin change, or upstream port is required; the resolver
carries prompt provenance that the pinned SSH opener cannot infer.

The 2026-09-06 dependency-guard repair adds no copied source or pin changes.
Its rules are specific to Poltergeist's package boundaries; no port-back is
required.

The human identity aliases resolve to the repository owner. Other recorded
identities are local automation or bot metadata; no external human
contribution appears in the pin's ancestry. Three stranded assistant
attribution lines in `522c9aaea8a8fcdb81932180aa4bd5e3aa6eaf73`,
`82ba43a64e88f5fb2647b41c82f3f607cedaba58`, and
`c2d60a6f45a4f34828a596a492003822d43ed47c` are automation metadata,
not separate rights holders.

The original PR-S3 vendored-path scan found 80 first-party files under
`packages/` and the
112-file `third_party/xterm` fork. The latter retains upstream xterm.dart
4.0.0's MIT license and patch ledger; it entered at
`82ba43a64e88f5fb2647b41c82f3f607cedaba58` and is app-only, outside the
pinned `seance_core` and `seance_protocol` package trees. No gitlinks exist. The
license scan found only those notices, first-party license/config references,
and Séance's root Unlicense.

## app/poltergeist_app/macos/Runner/PoltergeistFlutterViewController.{h,m}

- Source: app/seance_app/macos/Runner/SeanceFlutterViewController.{h,m}
  (with Runner-Bridging-Header.h and the AppInfo.xcconfig
  `SWIFT_OBJC_BRIDGING_HEADER` setting)
- Séance commit: 15d0fdd (main, 2026-09-24)
- Ported: 2026-09-24 (D32 §11)
- Divergences: class and category names only; the controller is injected
  into `MacOSWindowUtilsViewController(flutterViewController:)` instead of
  becoming the window's content controller directly. Séance's native
  regression script (`scripts/test-macos-accessibility.sh`) is not ported
  yet — its CI gate is the follow-up; until then the workaround is
  verified only by Séance's gate against the same Flutter line.
- Why: Flutter 3.47 destroys `AccessibilityBridge::tree_` before
  detaching native `FlutterTextField`s; with any accessibility client
  active a text-input callback can read the freed tree (Séance's
  docs/macos-accessibility-crash.md). Remove when the engine fixes the
  destruction order.

<!-- SEANCE_PIN_AUDIT_V1:START -->
## Séance pin audit

Full, non-shallow ancestor and tree audit. Raw streams are
content-addressed by SHA-256; line counts aid review. Use
`--print-findings` to reproduce them without adding names to docs.

- Pin: `035b0d880b47639e390af8cbbd6d316cb5edc86d` from `https://github.com/L-K-M/Seance.git`
- Pin: `035b0d880b47639e390af8cbbd6d316cb5edc86d` from `https://github.com/L-K-M/Seance.git` (requested ref: `v0.9.1`)
- Identity: 144 lines; `sha256:9f01616a755c8b7644945cc187439db98324a442932d5bb291bd1d0fa92a6812`
- Companion: 974 lines; `sha256:5fe9e038a53ecbb19f67fa659b787b701a7d5ad181b42f7aaf14001ff8b67c7c`
- Companion orphans: 0 lines; `sha256:d9aed34197440111a0f1a54dd0af36e9e664cc61374ecf38137fad1cf58c6e2b`
- Pinpoints: 1748 lines; `sha256:6fd10bcc6e8380605b74d424850e4661d0a04a41c94bb07c64862e0bf5b2cbe2`
- License scan: 64 lines; `sha256:9fc1950c432536a00f751294a2a795f281c94d6cf67d3eb517328d9bd48c3d56`
- Vendored paths: 440 lines; `sha256:d9d50d9cfb5ba6eaff3ad2b74c5789e06f2fc473606747de232574a699c2fb82`
- Gitlinks: 0 lines; `sha256:d9aed34197440111a0f1a54dd0af36e9e664cc61374ecf38137fad1cf58c6e2b`
- Tree: 1034 lines; `sha256:d95a0743bc331ba9d4f033c47bd6050388b3709834844f7aa772dc7a70f97a2b`
<!-- SEANCE_PIN_AUDIT_V1:END -->

Two `Pin:` lines are correct tool output: the audit emits one line per
distinct locked pin tuple — `seance_core` locked via `ref: v0.9.1`
(rendered with its requested ref) and transitive `seance_protocol`
locked via `ref: <resolved sha>` (requested ref equals the revision, so
no suffix). Under a pure SHA pin both tuples collapse to one line.
