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
  `putApiKey`/`getApiKey` dropped — Poltergeist has no provider API keys
  (D19 scope); Séance types imported via the poltergeist_core barrel, never
  seance_core directly. The ported exception messages are frozen port text
  allowlisted in the localization contract; the D20 ARB rule applies where
  the UI renders them (prompt-UI slice).
- Port-back candidates: corrupt-entry misreport — a stored entry that is
  not valid base64 is conflated with keystore unavailability (review round
  1, PR #32); and concurrent probes can race the create-on-first-run
  read-check-write (review round 1). Both are source defects; upstream
  first per 04 §6, not local divergences.

## app/poltergeist_app/lib/services/file_stores.dart

- Source: app/seance_app/lib/services/file_stores.dart
- Séance commit: e11206a94b5672225432fcd9990750a2ab1002c2 (tag v0.3.0; re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
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
- Port-back candidates: the validator and sweep suites, once Séance
  exposes the statics for testing.

## Pin findings

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

<!-- SEANCE_PIN_AUDIT_V1:START -->
## Séance pin audit

Full, non-shallow ancestor and tree audit. Raw streams are
content-addressed by SHA-256; line counts aid review. Use
`--print-findings` to reproduce them without adding names to docs.

- Pin: `2e6d1f138f1704e683870f75e11262bf50e37379` from `https://github.com/L-K-M/Seance.git`
- Identity: 51 lines; `sha256:644500f7f065b2103543d300aee698f0c940547e34b50070f44516cfb2f3033e`
- Companion: 401 lines; `sha256:ec80181de09261fcba405b5d848b976640e06771e8b016681943fae7d2db2047`
- Companion orphans: 3 lines; `sha256:cc2cba9a8662f129c19fdd790a6fd8c242033597118971576b039102bdfd92cc`
- Pinpoints: 717 lines; `sha256:ab8a547be2ef620f895be3ec4cc8f142e72043a80adb99a5db64ace4e4c77115`
- License scan: 31 lines; `sha256:27317917d7065cf9adb99fb4caefe74064f12a1bf362905bc70b9db2ce9591ba`
- Vendored paths: 209 lines; `sha256:621fe5d365980d36c9940de8abba22190a8499d78945f3bc79350b45557f5c4e`
- Gitlinks: 0 lines; `sha256:75fa9b1a198dfbacdcf8f2dfc2ace7d8988f2a7db103e084e8094217f538b6be`
- Tree: 477 lines; `sha256:a9416355d909803fed9a52477d1adb7cdafb459f665da8027f809a33a0430f82`
<!-- SEANCE_PIN_AUDIT_V1:END -->
