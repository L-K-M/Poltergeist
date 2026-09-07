# Séance ports and pin audits

## M2 real-sshd pool coverage (2026-09-08)

Exercises the existing pinned opener, VFS, and TCP prober through Poltergeist's
pool. No copied sources, pin changes, or upstream port candidates.

## app/poltergeist_app/lib/services/atomic_file.dart

- Source: app/seance_app/lib/services/atomic_file.dart
- Séance commit: e11206a94b5672225432fcd9990750a2ab1002c2 (tag v0.3.0); re-diffed unchanged at a9add158015fc15d805cecd2754ac40bc7860a23 (2026-09-07)
- Ported: 2026-09-02
- Divergences: unique `.poltergeist-<uuid>.tmp` siblings prevent collisions
  and basename overflow; failed writes remove their temporary sibling without
  masking the original failure; optional owner-only writes restrict an empty
  temporary before sensitive content; the source's delete-target Windows
  fallback is omitted per 09 §3.6; corrupt quarantine is store-owned,
  UTC-stamped, and reports move failures.
- Port-back candidates: unique bounded temp names, best-effort cleanup,
  owner-only writes, and timestamped quarantine.

## app/poltergeist_app/test/atomic_file_test.dart

- Source: app/seance_app/test/atomic_file_test.dart
- Séance commit: e11206a94b5672225432fcd9990750a2ab1002c2 (tag v0.3.0); re-diffed unchanged at a9add158015fc15d805cecd2754ac40bc7860a23 (2026-09-07)
- Ported: 2026-09-02
- Divergences: uses the Poltergeist temp-file contract, adds failed-rename
  cleanup, and maps source store round-trip/quarantine cases to
  `settings_store_test.dart`.
- Port-back candidates: none.

## Connection cleanup dependency

- Consumes `packages/seance_core/lib/src/ssh/sequential_cleanup.dart` at the
  existing `2f99f4e` pin; no source copy or pin change (2026-09-05).
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
- Séance commit: 99a35850a59e741b3e542447508dda2ef9424252 (ported class re-diffed unchanged at a9add15, 2026-09-07)
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
- Séance commit: 27552b2 (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: strings localize through ARB (D20); the decision payload is
  the engine protocol's `HostKeyPromptData` (plain data crossing the
  isolate, 03 §5) instead of seance_core's `HostKeyDecision`; a `changed`
  verdict still renders the alarming two-fingerprint review with the
  destructive-styled trust button (D18 hard block, never auto-repin).
  Coordinator-owned route identity and current-route action guards prevent
  a prompt dismissal or repeated activation from popping another route.
- Port-back candidates: current-route action guards.

## app/poltergeist_app/test/ui/prompts/host_key_dialog_test.dart

- Source: app/seance_app/test/host_key_dialog_test.dart
- Séance commit: 27552b2 (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: adapted to the protocol payload; adds ARB-string and
  non-dismissible coverage beyond the source's two cases.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/prompts/keyboard_interactive_dialog.dart

- Source: app/seance_app/lib/ui/keyboard_interactive_dialog.dart
- Séance commit: d1a98f1 (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: strings localize through ARB (D20); the payload is the
  engine protocol's `KeyboardInteractivePromptData` (03 §5); adds per-field
  reveal toggles absent from the source (echo metadata is absent on the
  wire, so reveal is explicit-only), coordinator-owned route identity, and
  current-route action guards. The controller-dispose-in-State lifecycle
  and its IME use-after-dispose lesson are ported verbatim.
- Port-back candidates: current-route action guards; preserve RFC 4256's
  per-prompt echo bit once the upstream responder exposes it.

## app/poltergeist_app/test/ui/prompts/keyboard_interactive_dialog_test.dart

- Source: app/seance_app/test/keyboard_interactive_dialog_test.dart
- Séance commit: fd01515 (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: adapted to the protocol payload; adds reveal-toggle,
  empty-name/instruction fallback, and repeated-submit route-safety coverage.
- Port-back candidates: repeated-submit regression.

## app/poltergeist_app/lib/services/identity_audit_log.dart

- Source: app/seance_app/lib/services/identity_audit_log.dart
- Séance commit: 82507ec (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: `viaBookmark` docs note Poltergeist is unsandboxed at v1
  (D23); wrong-typed optional JSON fields now skip as malformed instead of
  poisoning the full read. Desktop POSIX logs are repaired/created mode 0600,
  including atomic rotation, because they contain private-key paths. These
  local security/reliability repairs close PR #38 findings without waiting
  for upstream (04 §6). The record shape stays frozen identical.
- Port-back candidates: optional-field decode and owner-only audit storage.

## app/poltergeist_app/test/services/identity_audit_log_test.dart

- Source: app/seance_app/test/identity_audit_log_test.dart
- Séance commit: 82507ec (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: adds wrong-typed-field and owner-only-mode regressions for
  the local hardening; record/rotate/serialize behavior remains identical.
- Port-back candidates: port both regressions with their fixes.

## app/poltergeist_app/lib/services/identity_file_reader.dart

- Source: app/seance_app/lib/services/app_services.dart
  (`_readIdentityFile`/`_auditIdentityRead`) plus `IdentityFileException`
- Séance commit: 99a3585 (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: extracted as a standalone service; no security-scoped-bookmark
  grant path (Poltergeist is unsandboxed at v1, D23 — plain expanded reads
  only); `IdentityFileReadException` drops Séance's macOS EPERM sandbox
  hint; non-filesystem read failures are normalized and audited locally so
  arbitrary exception text cannot reach the prompt (D18/D20). `~` expansion
  and best-effort audit remain identical.
- Port-back candidates: audit and normalize non-filesystem read failures;
  the grant path remains Séance-specific.

## app/poltergeist_app/test/services/identity_file_reader_test.dart

- Source: app/seance_app/test/identity_file_exception_test.dart
  (exception cases)
- Séance commit: ffac90f (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: sandbox-hint cases dropped (no hint exists here); adds the
  reader's audit-success/audit-failure/audit-never-blocks coverage.
- Port-back candidates: none.

## app/poltergeist_app/lib/ui/connection_status_panel.dart

- Source: app/seance_app/lib/ui/terminal_pane.dart (the connecting view,
  `_ConnectionError`, and `_ConnectionLogView`)
- Séance commit: d18f1ac (re-diffed unchanged at a9add15, 2026-09-07)
- Ported: 2026-09-07
- Divergences: driven by the engine protocol's streams (03 §5) instead of
  an app-side session object; strings localize through ARB (D20); states
  cover the pool's full lifecycle (reconnecting, blocked) beyond the
  source's terminal states; replacement streams resubscribe and reset stale
  server state/transcript; the transcript starts collapsed exactly as the
  source's does.
- Port-back candidates: none.

## app/poltergeist_app/test/ui/connection_status_panel_test.dart

- Source: none (no Séance test file covers these views directly)
- Séance commit: n/a
- Ported: 2026-09-07 (new coverage for the stream-driven panel)
- Divergences: per-state rendering, live/bounded transcript, copy via a
  mocked clipboard channel, per-server filtering, retry wiring, initial
  pending state, and stream/server replacement lifecycle.
- Port-back candidates: none.

## Pin findings

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

- Pin: `a9add158015fc15d805cecd2754ac40bc7860a23` from `https://github.com/L-K-M/Seance.git`
- Identity: 43 lines; `sha256:629b1110cbc8d49fc3efb4504f5aee9f9152dab7a7b40c15c64c6e91f718de43`
- Companion: 251 lines; `sha256:6e3739b0476eccce880c860f960301f235bf8d3347d76d037681a883edbe9e3b`
- Companion orphans: 3 lines; `sha256:13cbe37c9c90dbf5a1b3ec1541fe8e3a6adfffbce40247e9293a9f849d315bed`
- Pinpoints: 474 lines; `sha256:76e289a88ed507f8e4354ef3c07c7f729df9375c1f2e6575121f7ac2f93c51c7`
- License scan: 30 lines; `sha256:27902a92c40facde6a04fc73fa77eb5512400261849607d1271b0eb0c8427bfc`
- Vendored paths: 201 lines; `sha256:ce44d75b393dbac5d33a2e3a15fc3947cd2557b2e8a6661142c09e9f66336042`
- Gitlinks: 0 lines; `sha256:3b777fa9bc6b4648ef7f07f8e8f1a69d11d66a5bb3ddd737716c64a7a828be9d`
- Tree: 455 lines; `sha256:064c80a6cb4dd8354938cd73f50c603625aeb18616a5c2c5c67bce5ace43428d`
<!-- SEANCE_PIN_AUDIT_V1:END -->
