# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) for build/test commands and
[09-PLAYBOOK.md](plan/09-PLAYBOOK.md) for the PR process.

_Last updated: 2026-09-23. **v1.0.0 IS SHIPPED** — tagged at
d62f95af after the release pipeline's full first exercise
(android `--no-pub` registrant fix #189, bash drift gate #190);
GitHub Actions run 35926951105 green end to end, the GitHub Release publishes
all eight assets (APK, .deb, AppImage, linux tarball, macOS
universal, Windows zip, unsigned IPA, SHA256SUMS), and the
tier-B enforcement armed green before the tag. M0–M10 are all
closed; the fast-follow list (§3.13) is the next-steps queue.
Manual QA on the shipped assets per
[`docs/qa/RELEASE-CHECKLIST.md`](qa/RELEASE-CHECKLIST.md) is
the remaining owner-side item. M9's two polish slices landed (#184 palette/import/a11y/i18n/
chrome, #185 tier-B flip + fast path + update check) and the §3.10
exit-criteria audit closed the milestone per the dated section below
(record: [tasks/m9-closure-record.md](../tasks/m9-closure-record.md)) —
with recorded residuals: the `BENCH_ENFORCE_B` arming tail (open item
31, supervisor-owned), the still-unscheduled D28 chown UI (item 30), and
the human-only QA residual now collected in
[`docs/qa/RELEASE-CHECKLIST.md`](qa/RELEASE-CHECKLIST.md) (item 32).
M8's scanner core
(#174), executor + safety rails (#175),
plan view + savedSync + activity-panel runs (#176), and rsync exporter
(#177) landed, and the §3.9 exit-criteria audit closed the milestone
per the dated section below (record:
[tasks/m8-closure-record.md](../tasks/m8-closure-record.md)) — with
recorded residuals: the purge surface (open item 27), the docroot
warning chip (28), the run-startup temp sweep and rail-8 resume
post-state rule (29), and the D28 chown UI deferral (30).
v0.2.0 remains the latest published pre-release (M3–M8 closed untagged
per their closure records). M0, M1, and M2 stay closed per the Done
table; **open item 4 (the M1/M2 overlap authorization) remains an OPEN
owner decision**; open item 24 carries the AltGr/Ctrl+Alt-letter chord
collision to a spec decision; open item 25's tag re-pin landed with
M8's first slice — the shared-mode "Your Séance servers" surface is
the recorded follow-up; open item 26 carries M7's manual-QA
residual (native macOS Quick Look runtime). Open item 23's remaining
half (remote transfers — and remote *sync endpoints*, which share the
engine-protocol gap — fail honestly until the engine grows
filesystem/transfer verbs) stays open for the engine-host slice.

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Product identity constants plus the connection layer's first slice: the Séance git pin (upstream `v0.9.1` / `035b0d8`), `PoolPolicy` (D9's frozen numbers, test-pinned), the endpoint-keyed `PooledConnectionManager` with the 03 §3.2 growth rules (serialized first connect + single TOFU prompt, interactive-auth single-transport cap, prompting-disabled growth with auth-challenge fallback to sharing, on-demand transports, LRU browse sharing at exhaustion, refcounted shared pools, pane-lifetime teardown), the changed-key hard block with its one prompt-cleared re-pin path, and the `scripts/check-imports.sh` CI guard for the 03 §1 dartssh2 boundary. Connection suites run socket-free per 08 §3.2. This is an initial slice, not M2 completion; audit follow-ups remain in open item 5. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |
| Séance pin | Upstream `L-K-M/Seance@v0.9.1` (`035b0d880b47639e390af8cbbd6d316cb5edc86d`) — the tag re-pin open item 2 waited for: `v0.9.1` contains the previous rev pin `2e6d1f1` (and therefore the PR-S3 merge `2f99f4e`, the PR-S1 merge `599ff936`, and #79's probe repair), so the commit-rev bridge is retired. `poltergeist_core` declares `ref: v0.9.1`; the bench harness's live-revision constant and every lockfile resolve to `035b0d8` (dartssh2 sha-identical at 3.0.2). Pin fallout at the tag was repaired red-first: `FileVaultStore.putSecretBlobs` (upstream's batched vault write) and the widened `ServerIcon` switch. Ported sources re-diffed at the tag with dated dispositions in PORTS.md; the full ancestor/tree/license/identity audit is regenerated and matches. The M0 fork bridge (`BigBoyDevBox/Seance@0a69597`) is retired; committed-bundle validation keeps binding to the pins M0 actually measured, so frozen evidence is unaffected. |
| Séance PR-S0 | LICENSE audit and Unlicense grant merged in [Séance #57](https://github.com/L-K-M/Seance/pull/57), merge `4d8ee1e026ce4e5d939d6390d9fd98a78fabcf6e`. |
| Séance PR-S1 | Record-kind forward compatibility merged in [Séance #58](https://github.com/L-K-M/Seance/pull/58), merge `599ff936b8222e6cd77920495dcdcc4a50643f44`. The release wait ended 2026-09-14 (`v0.9.1` contains the merge; the pin now sits on that tag — M8 dated section). |
| Séance cancellation cleanup | dartssh2 3.0.2 and bounded asynchronous SSH teardown merged in [Séance #59](https://github.com/L-K-M/Seance/pull/59), merge `da9d45492ac7d25cbc4eefb97a6ec29254de219f`. |
| Séance PR-S2 | `openAuthenticatedClient` split merged in [Séance #61](https://github.com/L-K-M/Seance/pull/61), merge `dad6d4f66dbfba6c170b98c204980e5801a890cb`. |
| Séance PR-S3 | `RemoteFileSystem` additions (`setTimes`, `setOwner`, opt-out `computeHash` on transfers) merged in [Séance #62](https://github.com/L-K-M/Seance/pull/62), merge `2f99f4efb25a83340605464635bdf0f3ba95d931`. The upstream-and-pin gate is satisfied by #13 (bench) and #14 (core); remote sync, chown UI, and bulk verification remain future milestone work. |
| M0 — engine fitness | Complete from workflow-dispatch run [`33563514640`](https://github.com/L-K-M/Poltergeist/actions/runs/33563514640), attempt 1, measured commit `6b8873eafdaaa3a4157e265dee838ab3b47219b3`. The 78-row canonical bundle is committed at [`docs/evidence/m0`](evidence/m0); `m0-evidence.json` SHA-256 is `b93660b9f1c06bac206096d25c6fff472bcb31d13589a4d81bd5a3df70fa7fcc`. D7 is final: managed checkouts always hash; bulk transfers and sync hashing are opt-in. D8 passed every isolate gate, so sockets, SFTP, transfers, and hashing stay in the engine isolate. D9 adopts dartssh2 3.0.2 at ladder rung 4: document the roughly 10–11× single-file LAN ceiling versus OpenSSH, compensate with bounded channels/transports, and do not adopt libssh2. `PoolPolicy` is finalized at 2 transports, 4 transfer channels per transport, 8 total channels per transport, 6 global in-flight transfers, and remote readdir depth 8. Keepalive remains 30 seconds, extra idle 60 seconds, reconnect cap 30 seconds, and retry limit 5; these are retained design defaults, not M0-tuned values. Earlier runs `33458209337`, `33481554062`, and `33504660759` were partial; `33534298280` stopped in preflight; `33535334440` diagnosed dartssh2 2.22.0's detached cancellation error. None is admissible evidence. M0 closes untagged. |
| M1 — app scaffold implementation | Implemented in [PR #8](https://github.com/L-K-M/Poltergeist/pull/8) with Flutter 3.47.2, exact dependency pins, generated platform icons from the 1024×1024 master, and the verified platform identity contract. Flutter analysis, 108 tests, and all five client builds pass; see the [PR checks](https://github.com/L-K-M/Poltergeist/pull/8/checks). Closed by the v0.1.0 publish (next row). |
| M1 — closed (v0.1.0) | Published 2026-09-06 as a **pre-release**; not Latest (`/releases/latest` stays 404). One-time manual publish per 00 D23's carve-out for the pre-change draft: the notes' stale `SHA256SUMS.asc` paragraph was dropped (aligned with the direct-publish template) and all seven assets re-verified against `SHA256SUMS` (bijection + strict recompute) immediately before publish; the APK signer-cert check stands from the rehearsal (assets unchanged, sums identical). §3.12 chores: STATUS sweep (this change), PORTS re-diff clean (no upstream drift on ported files, no `TODO(pin)` markers), pin bump impossible (no Séance tag contains `2f99f4e` — open item 2), the tag was already cut, and the M1 mobile invariant was re-verified (`check-imports.sh` + 92 core tests green). The merged direct-publish path's first end-to-end exercise is the v0.2.0 rehearsal. |
| M1 — release versions | Release versions accept canonical `X.Y.Z` only, derive ordered Android codes, keep every versioned pubspec plus the app lock, Apple metadata, and README synchronized, and gate CI and release tags against drift or downgrade. Stable-only is the selected 07 §3.12 rule; suffixed releases are unsupported. The app starts at `0.1.0+10099`; CI verifies that code in the built APK, while Apple and Windows use bounded semantic mappings. |
| M1 — release pipeline (D23) | Releases publish directly from CI (00 D23's 2026-09-03 decision change — Séance's posture; the draft/signature/fingerprint ceremony was removed by owner decision, recorded with rationale in 00). What survives: releases are created once and no later run ever updates them (a release-existence guard refuses any run whose tag already has a release — draft or published; the concurrency group is keyed on the tag so a tag push and a dispatch can never race it), a sums job attaches `SHA256SUMS` and writes the same sums plus the unsupported-platform labels into the notes, enforcing the rehearsal floor (APK + Linux set) before certifying anything. The iOS IPA is zipped out of the `--no-codesign` `.xcarchive` (`flutter build ipa`, ci.yml in lockstep). The Debian copyright file embeds the verbatim Unlicense, and Depends floors map ABI symbol tags to Debian package versions (a raw `GLIBCXX_3.4.30` floor is unsatisfiable under dpkg's ordering — the previous shape would not install). Runbook: [`docs/RELEASE.md`](RELEASE.md). |
| Plan precision patches | Closed the two dated 05 items: §2.1's exporter spec now carries 00 D6's interim ruling — a per-side `connectionShape` flag set on `ResolvedSyncEndpoints` and a prominent `# note:` per flagged gap whenever the pair's connection settings include an identity file or a jump host (golden fixtures pin the identity-file, jump-host, and both-flags variants) — and §8 rail 5 states 00 D15's trash naming (flat `<runId>/<seq>-<basename>` entries, journal-mapped origins) and the copy-then-delete fallback trigger (local pairs fall back only on EXDEV; other local rename failures surface as errors; for a remote pair any rename failure the sequence prefix did not prevent falls back), with rail 9's restore passage aligned. |
| M2 — bookmark model + vault/store plumbing | The pinned `seance_protocol` bookmark model (PR-S1 is in the pin's ancestry, so 07 §3.3's temporary-copy clause never applies) and the vault plumbing surfaces — `SecretVault`, `VaultStore`, `HostKeyStore`, in-memory stores, `VaultCrypto`/`VaultKeys`/`Argon2Params`, `secureRandomBytes`, `Secret`, and the `ServerColor`/`ServerIcon` enums — now flow through the `poltergeist_core` barrel, with a barrel test pinning the 04 §2.1 decode contract (record-id binding, port-range refusal, unknown-kind refusal, verbatim rules retention) at the pin. App layer: ported `MasterKeyManager` (`poltergeist.vault.masterKey.v1`, legacy macOS login keychain), `FileVaultStore`/`FileHostKeyStore` (atomic writes, store-owned UTC-stamped quarantine), and `LockedSecretVault`, each with its PORTS.md entry and ported tests (`keystore_resilience_test`, new `file_stores_test`); `flutter_secure_storage` pinned 10.3.1 — the exact revision Séance's lock resolves, sha-identical. Ported exception messages are frozen port text allowlisted in the localization contract; D20 applies at the UI render site when prompt UI lands. No startup wiring yet — composition joins the engine/prompt slices that consume the vault. |
| M2 — extra-transport idle teardown | Extra transports close after the configured `idleExtraTransportTimeout` (60 s default in `PoolPolicy`) without channels or pending channel opens/closes. Returned transfer channels serve waiters first and, when no waiter takes them, close immediately on an extra transport so caches cannot prevent retirement (03 §3.3); only the first transport caches returned channels. A channel whose close is in flight still occupies the server's MaxSessions budget (`_pendingCloses` is reserved against channel budgets, so no phantom-capacity opens). The first transport keeps its cache, its role is assigned at creation and never reassigned, and follows pane/lease lifetime. Settle-time waiter pumps never await the pump they may be running inside: closes settling within a pump's own call chain trigger a follow-up pass instead, so a failed waiter's cleanup cannot deadlock the pool (regression: pane close and disconnect stranding forever). Idle retirement itself re-drives queued demand — the pump grows a replacement transport (or fails the waiters) instead of leaving a queued lease waiting forever on a pool whose spare capacity just retired (regression: demand queued behind an SFTP-refusing extra). Twenty-seven fake-clock tests cover deadlines, renewed demand, shared bookmarks, queued handoff, delayed cleanup, teardown races, waiting acquisitions, capacity reservation during closes, idle retirement/state/role after primary failure, the pump-reentrancy and retirement-stranding regressions, and growth landing after pool abandonment ([PR #21](https://github.com/L-K-M/Poltergeist/pull/21)). |
| M2 — pool keepalive wiring | One periodic clock per pool pings idle transports every `keepAliveInterval` (30 s) — the single keepalive mechanism: the production opener passes `keepAliveInterval: null`, so the opener's built-in timer never runs (03 §3.3; no second timer, no VFS wrapper, D3). Idle means no in-flight operation: the transport's aggregated concrete-adapter `hasActiveOperations` plus the pool's pending channel opens/closes; held leases and bound browse channels do not count. At most one outstanding ping per transport. A ping unanswered past `SshTransport.pingOperationTimeout` (30 s, matching the VFS adapter's operation timeout) closes its transport so the done-watcher runs the ordinary death path — recovery, pane rebind, and clock re-arm included; non-timeout ping failures leave closure to the done watcher. The clock arms when a transport joins (recovery re-arms after reconnect) and disarms eagerly at teardown, host-key block, last-reference disconnect, and the death of the pool's last live transport, with a tick self-cancel backstop; a nonpositive `keepAliveInterval` is rejected at construction like the backoff cap. Eight socket-free fake-clock tests cover cadence (never immediate), activity and pending-open skips, both-transports ticks, timeout → close → reconnect → rebind, non-timeout error tolerance, teardown cancellation, and the construction guard. Production socket-level behavior (real `client.ping()` round trips) rides the open 08 §5 real-sshd legs. |
| M2 — connection layer (closed 2026-09-11: v0.2.0 pre-release published) | Every 07 §3.3 scope bullet and exit criterion is on main (through #69, merge `43396c5`), each validated in its dated section below: the endpoint-keyed pool with D9's frozen `PoolPolicy` (serialized first connect + single TOFU prompt, interactive-auth cap, LRU browse sharing, refcounted teardown), keepalive, idle teardown, reconnect recovery; the engine isolate, `EngineClient`, and the typed port protocol (bounded progress coalescing, connection/prompt bridging, incident/pin bridging with the pin-coupled seed); the prompt UI (host-key first-use/changed-key, keyboard-interactive, vault-first credential), live transcript, and state-associated failure one-liners; probe wiring end to end (engine control/status, app eligibility, persisted settings + retarget reset, lifecycle forwarding, tri-state dots, coordinator composition); ssh_config import (preview, dedupe, command registration, `FileBookmarkStore`); the debug demo surface; the trust-incident lifecycle (restored-key unblock, persistence, bookmark-removal cascade); live connection-state composition; and the production startup engine-spawn composition (one engine per process, seeded pins + incidents, idempotent mirrors persisting both). Exit criteria ticked: the real-sshd matrix covers key, password, and keyboard-interactive auth, TOFU first-use and changed-key flows, the mid-session sshd kill with backoff reconnect + home re-canonicalization, and the interactive-auth single-transport cap; the import preview shows, dedupes, and imports, and IdentityFile entries resolve through the production prompt path's audited `IdentityFileReader`; `docs/PORTS.md` carries an entry per copied file; the pin bump to `2e6d1f1` is recorded with `dart test packages/poltergeist_core` green; PR-S2 merged upstream (Séance #61), so no branch-rev bridge item applies. 07 §3.12 chores at this sweep (2026-09-11, close-prep PR): STATUS consolidated (header, this row, items 3/4), the PORTS addendum re-verified no drift from #66/#69 and closed the four-file attribution-header follow-up, the `TODO(pin)` grep found no markers, the pin cannot bump (no Séance tag contains #79 — open item 2), and the M1–M2 mobile invariant is re-verified (`poltergeist_core` carries no Flutter import or dependency and the import guard passes; the engine protocol's messages stay plain data, protocol guard green). The v0.2.0 tag was then cut and pushed 2026-09-11 (`5f8ed9a`); the first release run failed at the publish step (a workflow bug — item 8), and the fix (#72) plus the D23 draft-recovery dispatch published the pre-release the same day (dated close section below), closing the milestone. |

## M2 — engine progress coalescing (2026-09-07)

Typed, versioned item progress carries both per-file counters and task rollups.
One engine-wide timer emits immutable batches at ≤ 30/s, retaining at most
64 latest `(taskId, itemId)` updates across all tasks. Refreshes update
eviction recency; overflow drops oldest progress. Task/item discard and shutdown
cancel unused timers and prevent buffered counters following terminal state.
The producer owner must detach callbacks before discarding a finished task.
Terminal events bypass this lossy buffer. No forced final flush.

Validation: 17 tests cover fake-clock floods, rolling-second limits, task/item
identity, recency, lifecycle, immutable snapshots, and real-isolate round trips.
The engine protocol AST guard has 48 fixture tests and runs in CI; callback
fields are allowed only on the engine-internal coalescer. Core analysis and
186 tests pass (one existing fixture skip). A VM-resolution regression observed
31 batches in a rolling second before rounding the interval up to 34 ms.
Review repaired working-directory-dependent CLI tests and added inherited
storage/extension-type checks; nine new guard regressions failed before repair.
Seven more regressions cover erased external extension wrappers, including
generic and nested representations.
This is one M2 protocol component: engine spawn,
`EngineClient`, connection requests/results, prompt cancellation, and production
wiring remain open. No UI change, dependency bump, source port, or milestone close.

## M2 — engine isolate, EngineClient, prompt protocol (2026-09-07)

The connection/prompt half of 03 §5 landed (engine protocol v2): the typed
request set (open/close/list browse channel with per-request `ServerConfig` —
the UI owns bookmarks, the engine holds none; watch/unwatch with
current-state-first forwarding; connected ids; disconnect; prompt reply;
shutdown), typed results with serialized `RemoteFileException`s (kind,
operation, path, message — the unsendable cause stays engine-side), and the
prompt model (`EnginePromptEvent` with kind-specific payloads, one plain-data
reply subtype per kind, `PromptDismissedEvent`, `HostKeyPinnedEvent`).
`EngineClient.spawn(EngineConfig)` boots `engineMain` (boot port handshake,
config first), correlates responses by requestId, exposes broadcast prompt /
dismissal / pin / progress streams and `watchServer` toggling (last listener
unsubscribes), fails every pending call typed on engine death, and shuts down
orderly-then-kill. The engine host owns a `PooledConnectionManager` whose
host-key prompter, keyboard-interactive responder, and credential resolver
are port-bridged: prompts cross as events, replies are validated by promptId,
kind, and reply runtime type, and everything that cannot apply (unknown id,
closed, duplicate, mismatch) is ignored. `CredentialResolutionScope`
dismissal now crosses the isolate boundary — a disconnect withdraws the open
credential prompt and the abandoned open fails disconnected; shutdown
dismisses all open prompts. TOFU pins: `EngineConfig` seeds the engine's
in-memory verifier from the app's store; every pin write surfaces as a
`HostKeyPinnedEvent` for app-side persistence (one TOFU authority, one store
owner — documented in the same-PR 03 §5 precision edit, which also records
that the transfer/queue requests and the `conflict` prompt pair land with
M4's queue, which owns `TransferTaskSpec`).

Validation: every new message type round-trips through a real spawned isolate
pair (08 §3.2); 15 in-process host tests over the socket-free pool fakes cover
the open/credential/host-key flows (first-use decline pins nothing; changed
key review re-pins or hard-blocks with state fan-out), keyboard-interactive
answer round trips, listing success/failure with recovery reporting,
dismissal, cancelled replies, ignored replies, watch semantics, ids, shutdown,
and non-VFS error wrapping; 8 real-isolate client tests cover spawn, watch
re-subscription, a refused-connect failure after a prompt reply, dismissal
across real isolates, shutdown, and fail-fast termination on an invalid
policy. Core 220 tests and app 121 pass; analyze clean; protocol and import
guards pass. No UI change, dependency bump, source port, or milestone close:
production wiring stays gated on open item 6, prompt UI and diagnostics on
the slices below.

## M2 — prompt UI, transcript, diagnostics (2026-09-07)

07 §3.3's prompt-UI bullet and open item 5's recovery-diagnostics follow-up
landed together (engine protocol v4 after reconciliation with #40). Engine
side: `watchServer` now
delivers `ServerStatus` (state + `detail` — the user-facing failure
one-liner; a summarized connect failure, a terminal background-recovery
error delivered through the teardown fan-out when no acquisition awaits the
cycle, or a host-key block reason; cancellation carries none), and every
connect attempt (first connect, growth, recovery) writes its transcript
through a forwarding `SshConnectionLog` that fans each appended line out as
a `ConnectLogLine` to the serverIds referencing the pool at append time;
frozen attempts forward nothing. The `ConnectLogCoalescer` bounds the port:
≤ 30 flushes/s on one shared timer, per-server pending lines capped at the
source log's 400-line bound, drop-oldest, order preserved — and joins the
progress coalescer in the protocol guard's callback-field allowlist.
`ServerStateEvent` carries `detail` across the wire; `ConnectionLogEvent`
is new. #40's `RecoveryFailedEvent` independently carries scoped terminal
failures without a state watch. Same-PR 03 §3.2/§5 edits record both paths.

App side: `PromptBridge` (the engine client's prompt facet) feeds a
`PromptCoordinator` — FIFO, one dialog at a time (02 §10), every post-await
path rechecks `dismissed`/`_disposed` (09 §3.1), and each prompt owns its
route so withdrawal cannot pop another page or strand a pre-frame dialog.
Host-key first-use/changed and keyboard-interactive dialogs are Séance ports;
the changed-key review keeps the alarming two-fingerprint block (D18).
Credential resolution is vault-first: a stored, kind-matching secret answers
without a dialog (stored provenance keeps the pool growable), agent auth
needs no dialog, and key files pass through the audited `IdentityFileReader`.
Audit failures never block connecting; path-bearing audit files use mode 0600
on desktop POSIX and platform storage ACLs elsewhere. Vault-save failures are
localized transient notices (02 §10). The ported `ConnectionStatusPanel`
renders the live transcript during connect/reconnect and keeps it with the
failure/block one-liner; replacement servers reset stale state. No production
composition yet — the wiring slice composes these library surfaces (item 6).

Review regressions cover detail preservation through dead-slot teardown,
queue progress, route ownership and races, async credential reads, empty
vault saves, sibling-batch fan-out, malformed audit lines, owner-only
rotation, and panel lifecycle. Later rounds repaired unobserved fake-clock
diagnostics, malformed-prompt queue stalls, empty stored-secret answers,
stale panel callbacks, uncleared key-path errors, opaque failure leakage,
queued-waiter detail, stalled audit writes, closed prompt bridges,
newest-line anchoring, scroll-safe prompts, and Enter focus/submission. After
reconciliation with PRs #39–#41: core analysis and 257 tests pass (five
integration tests skip without fixture variables); app analysis and 196 tests
pass; protocol guard (49), import guard (92), and pin audit pass. UI surfaces
remain uncomposed, so screenshots ride the wiring slice that first renders
them. `posix` 6.5.2 moved from a transitive to direct app dependency without
changing resolution; no Séance pin change or milestone-close claim.

## M2 — keepalive prerequisite (2026-09-07)

[Séance #77](https://github.com/L-K-M/Seance/pull/77) merged as
`a9add158015fc15d805cecd2754ac40bc7860a23`: nullable SSH keepalive interval
and read-only concrete-adapter activity, without changing the VFS interface
or transfer safety. Its 25 new socket-free tests and all 345 Dart tests pass;
all upstream CI checks pass. Poltergeist pins that merge in both declarations
and all three locks; ported sources re-diff clean, with the pin audit refreshed.

Validation: core 169, harness 79, Flutter 121 tests pass; analysis is clean.
Core and harness each retain one sshd-fixture skip. Two new harness contract
tests failed to compile on the old pin and pass on the new one. The existing
attribution test caught the live harness revision needing the same bump;
frozen M0 evidence and its measured pins remain unchanged. Pool timer wiring
is the next slice, not part of this prerequisite; owner gates remain open.

## M2 — reconnect recovery (2026-09-07)

Transport closure and source-identified VFS disconnect reports start one
cancellable recovery loop per endpoint pool. It probes before authentication,
uses 1/2/4/… s backoff clamped before downward-only jitter, and rebinds existing
pane handles with fresh home canonicalization. New acquisitions fold into the
loop; a healthy sibling can supply recovery without another TCP connect.
Recovery tries cached credentials first; auth challenges re-resolve them.
Interactive provenance still caps growth. Changed keys block without background approval. Closing the last pane
or disconnecting cancels timers/credential resolutions; stale results close
instead of reviving bindings. SSH challenges and answers are bound to their
live authentication attempt. Leases are not rebound or operations replayed.

Validation: 27 socket-free recovery tests; core analysis and 169 tests pass
(one existing fixture skip); Flutter analysis and 121 tests pass. Existing
trust/credential/idle tests now account for automatic recovery instead of
assuming dead bindings remain indefinitely. Two new regressions failed before
repair: channel-open disconnects bypassing recovery backoff, and a pane removed
during home resolution killing its surviving sibling's transport. Three more
failed before adding authentication-attempt guards: late challenges after
cancellation, late answers, and challenges from a failed retry attempt.
Review caught unnecessary credential re-resolution on interactive-capped
pools; two regressions failed before restoring cached-first recovery.
Round 2 isolated permanent home failures to their pane and stopped retries
for resolver/unclassified exceptions. Three regressions failed before repair;
a fourth pins continued retry for transport `SshConnectException`s.

Engine callers must pass the failed operation's VFS identity to `reportFailure`
and refresh current paths after recovery. The protocol/UI half of prompt
dismissal on disconnect landed with the engine-protocol slice
(`PromptDismissedEvent`) and is rendered by the prompt coordinator
(prompt-UI slice, 2026-09-07); pane-level path refresh remains
engine/pane integration work.
M4 owns transfer retry/progress counters. Keepalive, real-sshd recovery,
and the existing owner-decision gates remain open. No milestone-close claim.

## M2 — real-sshd auth-failure summaries (2026-09-08)

Three tagged tests close 08 §5's ungated auth-failure leg against
`sshd-authmatrix` through the production opener (no fakes, no summarizer
fork, no SSH-boundary bypass): a rejected key (publickey accepted, the
offered key itself declined) asserts the summary names the exact key — its
fingerprint cross-checks against the transcript's real "Offering key:"
line — and points at `authorized_keys`; a method-not-accepted user
(`password-only` offered a key) asserts the server-accepts line and the
switch-method guidance; root with its correct password asserts the
`prohibit-password` explanation. Every case also pins the shared
invariants: the one-liner starts with the `Authentication failed for
<user>@<host>:<port>` prefix, never carries raw dartssh2 text (`All
authentication methods failed`, `SSH_Message`), rides exactly one
production open with the pre-seeded pin (no host-key review; the two
public-key flows reach no interactive prompt, while root's PAM round —
auth-pam.c substitutes a faked password for root — is answered and pinned
at one prompt-bearing round), and
fans out as the disconnected `ServerStatus.detail` (03 §3.2). Branch
separation is asserted per case: the other two cause phrases must not
appear.

The suite reuses the committed fixture lifecycle, the existing CI
integration job (its `packages/**/test/**` filter already covers the new
file), and per-suite pin isolation. Docker is unavailable locally; the
three tests skip by name without the fixture variables and pass in CI (run
linked from the PR checks).

Local validation: core analysis clean; 257 core tests pass with fifteen
integration skips (three of them these, twelve from the earlier real-sshd
suites). No production code, wiring,
source port, dependency change, or milestone close.

## M2 — real-sshd interactive auth and TOFU (2026-09-08)

Three tagged tests extend the real-sshd matrix to 07 §3.3's auth/TOFU exit
criteria over the production opener (no fakes): keyboard-interactive auth
against `sshd-authmatrix` (`keyboard-only` user) answers exactly one
challenge via the responder, lands an interactive `AuthKind`, and caps the
pool at one transport under excess demand — the queued fifth lease never
dials again and is served by a released channel; TOFU first use against
`sshd-modern` folds two concurrent panes into one prompt, pins the committed
key, then growth and a fresh-pool reconnect verify silently (one decision,
never a second prompt); the changed-key test swaps `sshd-modern` for
`sshd-keyswap` mid-session — recovery blocks without prompting, every pane
operation and a fresh acquisition fail with the changed-key reason after a
declined review, and the store still holds only the original pin (D18, no
auto-repin). Declining keeps the suite off restored-key-review behavior,
which awaits the owner decision (open item 6). Group teardown runs
`restore-modern`; the suite reuses the committed fixture lifecycle, the
existing CI integration job, and per-suite pin-store isolation (08 §5).

Local validation: core analysis clean; 257 core tests pass (eight
integration skips without fixture variables — three of them these);
fixture-tool, protocol-guard (49), and import-guard (92) tests pass. The
Docker legs run in CI (Docker unavailable locally). The auth-failure
summary leg of 08 §5 (rejected key, method-not-accepted user, root
`prohibit-password`) remains ungated follow-up coverage. No production
code, wiring, source port, dependency change, or milestone close.

## M2 — real-sshd pool integration (2026-09-08)

Four tagged tests exercise the production opener, SFTP adapters, and TCP
prober: stored-key/password pool growth and queued excess demand, completed
keepalive round trips on both transports, and stop/start recovery with
backoff, state transitions, a replacement browse filesystem, and a fresh
canonical home. Old transfer leases remain disconnected. Each test owns
pre-seeded in-memory pins; unexpected trust/auth prompts fail. The existing
service helper owns port-release and SSH-banner readiness; suite teardown
restores sshd even after a failed assertion.

The source-filtered CI integration job now runs the existing fixture lifecycle
on relevant PRs and every main push. Missing fixtures fail closed on
main/dispatch and fixture/workflow edits. Restart coverage exposed the
entrypoint recreating existing users; two regressions failed before the
account helpers became restart-safe.

Local validation: core and Flutter analysis pass, with 238 core, 121 app,
and 50 fixture-tool tests passing; five integration tests skip without the
fixture. All five Docker tests pass in
[CI run 34172611069](https://github.com/L-K-M/Poltergeist/actions/runs/34172611069).
The first run exposed a nullable timeout callback against a non-nullable
future in both growth tests; corrected assertions pass. Review also checks
opener attempts while demand queues, so a pending third handshake cannot
escape the cap assertion. No production wiring, source port,
dependency change, or milestone close. The auth-failure-summary
integration leg and M4's mid-transfer queue recovery remain open exit
criteria.

Review hardened the fixture harness: shell fakes load before extracted code,
GNU timeout kills a stalled helper's process group, teardown audits unexpected
prompts even when SSH catches callback errors, and the CI guard covers a
fixture edit that leaves the file present. Regressions demonstrated a live
helper after the old Dart timeout and late shell-stub installation; both pass
after repair. Timing assertions retain independent 03 §3.3 bounds.

Further review isolated account scripts with a private PATH/cwd and a process
deadline, preserved cleanup after partial PID writes, and added root workspace
manifests to the integration filter (08 §8 clarified). Each regression failed
before repair. The workflow guard tests now match CI's shell flags and control
their environment. Account/process suites declare their GNU-timeout Linux
requirement; broader fixture-tool portability remains open below.

## M2 — TOFU decisions across bookmarks (2026-09-08)

Four Linux integration tests use the production pool/opener and private,
initially empty pin stores. Concurrent bookmarks share one pending first-use
decision; approval pins the committed fixture fingerprint, while rejection
leaves no pin and prompts again on retry. PR #42 owns the growth/reconnect
coverage.
Swapping sshd on the same host:port blocks both
bookmarks, existing pane/lease handles, and new worker acquisitions without
prompting or re-pinning. Explicit changed-key rejection preserves the block;
approval installs the replacement fingerprint and restores SFTP access.

The suite uses the existing bounded swap/restore helper and registers per-test
restoration before mutation, with suite teardown as a fallback. Ordinary tests
skip without both fixture host and modern-port variables; the existing serial
integration CI job runs them.
Local core/Flutter analysis and 257 core plus 196 Flutter tests pass; the
import guard passes. Twelve integration tests skip locally because Docker is
unavailable; all twelve pass after reconciliation with #42 in
[CI run 34195476291](https://github.com/L-K-M/Poltergeist/actions/runs/34195476291).
Review added a next-test pin check that failed in
[run 34194044313](https://github.com/L-K-M/Poltergeist/actions/runs/34194044313)
before per-test restoration and passes after it. The swap test allows four
minutes for its
independently bounded Docker/recovery/review stages. `watchServer` replays
current state, and the process helper inherits its environment. Blocked-handle
assertions throw synchronously in the `fs` getter; the matcher also tracks
future outcomes. These review concerns require no code change.
No production change, source port, pin bump, or milestone close.
Auth-failure summaries and the production-wiring gates remain open.

## M2 — ssh_config import preview/dedupe (2026-09-08)

D22's v1 import slice. `SshConfigImportService` (pure core, injected
`SshConfigFileSource` seam — no IO in core) consumes Séance's
`SshConfigImporter` through the pin (re-exported from the core barrel;
no copy, no second server model): imported rows build `Bookmark`s over
`EmbeddedHostIdentity`. A plain, top-level `Include` resolves read-only
at import time — multiple/quoted tokens, `~`, relative-to-`~/.ssh`,
glob subset `*`/`?`/`[...]` sorted lexically, per-branch cycle detection
(diamonds parse twice, like ssh), and ssh's 16-deep cap recorded as
notes rather than failure. Includes inside host blocks resolve their
hosts after the file's own (cutting there would fragment the enclosing
block across the pin's chunk parsing) while the block keeps its badge;
Match-nested includes stay unresolved. D22 limitation badges: ProxyJump
(own block via the pin's `ImportedHost.proxyJump`, top-level defaults,
wildcard `Host *` blocks), ProxyCommand (own block/top-level/wildcard),
any Match block (every row — criteria evaluation would reimplement ssh
semantics; loud beats silently wrong), host-block includes, and
out-of-range ports (row unimportable; the checkbox is disabled).
Dedupe is by host+port+username against existing bookmarks' embedded
identities — `serverConfigId` refs carry no endpoint in Poltergeist
(04 §2.2) so they are skipped, workspace/sync endpoint identities are
included — and against earlier rows of the same import; duplicates
start skipped but stay user-toggleable. IdentityFile maps to
reference-style `AuthMethod.privateKey` carrying the verbatim path
(`~` preserved, 04 §2.1); the bookmark's `remotePath` starts at `/`
(connect canonicalizes home) and `sortKey` defaults to the row id until
M5's store re-keys. App side: `LocalSshConfigFileSource` (dart:io,
read-only, symlink-following lexical listing) and the ARB-complete
preview dialog — per-row import/skip checkboxes with semantics labels,
endpoint/user/auth columns, duplicate and “won't behave as in ssh”
chips, unresolved-include notes, a count-labeled import action, retry
on an unreadable config, and mounted-guarded async load.

Validation: 24 core import tests (include resolution, globs, cycles,
diamonds, depth, the badge matrix, existing/earlier dedupe,
reference-style mapping, the 04 §2.1 decode round-trip, invalid ports,
the glob subset) and 11 dialog widget tests (defaults, chips, toggling
and count, key mapping, disabled action at zero selection, cancel,
error+retry, empty config, disposal race). Core analysis and 281 tests
pass; app analysis and 206 tests pass; the import guard passes. The
dialog's technical literals (monospace endpoints/identity paths, empty
label fallbacks) join the reviewed per-file exceptions in the
localization contract test.

Review round 1 (applied): the glob matcher now translates bracket
classes per glob(3) — backslash and `^` are literals, `[]`/`[!]` match
nothing, malformed classes fail closed instead of throwing, and a
leading dot never matches unless the pattern names it; host-context
includes no longer promote their block-less proxy directives to
global badges (ssh scopes them to the enclosing host, whose hostInclude
badge already covers the loss); the app file source decodes
leniently (a stray non-UTF-8 byte no longer reads as "unreadable");
the dialog handles unexpected importer exceptions with the retry
surface, filters unimportable rows at the commit path, and asserts
`takeException` in the disposal race; `SshConfigIncludeNotice` renamed
to `SshConfigUnresolvedInclude`; the dedupe key, the glob-fidelity
comment, and the test fake's doc were single-sourced/corrected; a
pre-existing duplicated truncated bullet in open item 3 was removed.
Six regressions (four glob corners, dotfile filtering, deferred
coppering) plus the decode and retry cases failed before their repairs
and pass after. Declined: horizontal-scrolling the preview table for
sub-650-px windows — 02 §1 enforces a 720-px content minimum through
the window lifecycle and the mobile posture (D29) cannot reach this
v1-desktop dialog. Refuted: pattern-alias rows (`Host *`/`!x`/`web*`)
never reach the preview — the pinned importer drops wildcard-only
blocks and keeps only the first concrete pattern (pinned by the `Host
*` tests); the `Key = value` handling matches the pin byte for byte
(both cut at the first separator, so `Host = web` mangles the same way
in both — an upstream port-back candidate for Séance's importer, not
a local divergence). Multi-pattern `Host alpha beta` surfacing one row
is pinned by a new test as the pin's own documented behavior.
Validation after the round: core analysis clean and 30 import tests
pass (full core suite below), app analysis clean and 215 tests pass.

Review round 2 (applied; three regressions failed before repair): a
file included from a wildcard `Host *` block now promotes its
block-less proxy defaults to global limitations — ssh processes
Include in place, so such a file applies to every connection, the
mirror image of the round-1 named-host scoping, which is unchanged;
multi-component include globs (`conf.d/*/*.conf`) surface an
unreadable note instead of silently matching nothing (the
single-listing seam cannot expand across components); an empty home
directory now blocks only `~`-relative and bare-relative include
tokens — absolute paths resolve without one. Hardening in the same
round: row `limitations` lists are unmodifiable, the app file source
catches `FileSystemException` only (programming errors stay loud
instead of reading as an unreadable config), the dialog Match-badge
test pins per-row chips across two rows, the core Match/ProxyJump
tests gain row-count guards against vacuous passes, the diamond test
asserts no notices, the `~otheruser` note kind is pinned, a
leading-dot glob test covers the positive dotfile case, the
depth-chain test documents its length against the 16 cap, and
`_globMatch` documents its single-component invariant. Declined:
the 640-px overflow re-raise (round-1 decline stands — 02 §1's
enforced 720-px content minimum, D29's post-v1 mobile posture), a
Windows symlink-skip for the file-source test (app tests run only on
Ubuntu in CI; open item 1's recorded gate), and the `_keyValueCut`
refactor (parity is pinned by tests; behavior-neutral churn).
Deferred: default-off checkboxes for proxy-limited rows (D22 specifies
the badge; revisited by the wiring slice). Refuted: quoted `#` in
include paths and indented directives (the pin trims and cuts at the
first `#` identically — its own `_stripComment`/`.trim()` — port-back
candidates like the round-1 `Key = value` case), the wildcard-row
outside-diff re-raise (round-1 refutation, pinned by tests), and the
symlink-cycle recursion worry (`_maximumIncludeDepth` bounds every
nesting level regardless of textual path distinctness). Validation:
core analysis clean and 291 tests pass (34 import tests); app
analysis clean and 211 tests pass (the round-1 record's 215 was a
miscount of hidden setUp/tearDown events; the suite's test count is
unchanged this round); the import guard passes.

Review round 3 (applied; every behavior fix's regression failed
before its repair): a new `wildcardDefaults` limitation badges rows
whose `Port`/`User`/`HostName`/`IdentityFile` defaults arrive
before the first block or inside a `Host *` block — ssh applies both
shapes to every connection, while the pinned importer drops each
(top-level directives land in no host block; a wildcard-only block is
deliberately not a host) — so those bookmarks would prompt instead of
inheriting (host-block values stay unbadged: the pin applies them; a
host-deferred include's block-less defaults stay scoped exactly like
its proxy defaults); brace include tokens (ssh globs with GLOB_BRACE)
surface an unreadable note in pattern or directory position instead
of silently matching nothing; a leading `]` in a glob class is a
literal member as in glob(3) (`[]x].conf` matches `x.conf` and
`].conf`); the dedupe key lowercases the host (DNS/ssh resolution is
case-insensitive; usernames stay verbatim); the app file source
refuses non-regular files so an Include pointing at a FIFO or device
cannot hang the preview forever; the dialog's retry is re-entrancy
guarded (a double-tap cannot start concurrent loads). Hardening: the
round-trip test pins `username`/`authMethod`, the Import-button
finder uses `widgetWithText`, and the wildcard-promotion test
documents that its row order stays main-file-first (the chunking
deviation) while "in place" governs directive scope. Declined: the
narrow-viewport overflow re-raise (round-1/2 declines stand), the
Windows symlink-skip re-raise (flutter test runs on ubuntu-latest
only in CI; open item 1 gates Windows test portability), and per-entry
stat tolerance in `listLexical` (no constructible failure — a
mid-listing stat miss reads as notFound and is skipped, not thrown;
ssh's own Include is fatal on unreadable targets, so the tolerance
premise is wrong; untestable without a new seam, and 08 §1 treats
untested rails as absent). Refuted: non-final-component include globs
missing the note (the round-2 `_hasGlobMetacharacter(directory)`
guard covers exactly that case at head, pinned by its regression),
`Key = value` leaving a stray `=` (byte-for-byte parity with the pin's
own `_splitKeyValue`, verified against the pinned source — a local
fix would mis-key hostLimitations against the pin's rows; upstream
port-back candidate, recorded), the round-3 row-order claim
(host-context includes resolve main-file-first by documented design;
option precedence is the pin's parse, not this scan), and the `.`/`..`
glob-entry worry (dart:io's `Directory.list` never yields them and the
app source filters to regular files). Deferred: a multi-pattern-alias
badge (the pin's first-concrete-pattern truncation is documented and
pinned; the badge-surface choice rides the wiring slice with the
deferred default-off question). Verified without change: ARB keys
regenerate identically (the new chip key apart) and every
`_normalizeAbsolutePath` call site anchors relatives first. The
dialog's localization surface grows one key. Validation: core
analysis clean and 299 tests pass (42 import tests); app analysis
clean and 214 tests pass; the import guard passes.

Review round 4 (no code change; steady state declared per the owner's
bar — none of the round's 21 findings is a correctness, security, or
contract item). Refuted: the `mint_id` "compile break" (no such token
exists — all three call sites spell `mintId:`, and CI's flutter job
compiled and ran the suite on this head); the badge-alias drift claim
(scan and lookup share one rule, mirrored byte for byte from the pin:
both strip `"` from the value side, take the first `*`/`?`/`!`-free
token as the alias, and keep its case verbatim — `Host gitlab gh` and
mixed-case lines therefore key identically on both sides); the
wildcard-row re-raise (the pin's `firstWhere(!_isWildcard)` drops
`Host web-*` entirely — pinned by the round-1 `Host *` tests); and the
serverConfigId-dedupe doc suggestion (the limitation text already sits
verbatim at `_existingEndpoints`). Declined: the Windows
symlink/`/dev/null` portability re-raises (rounds 2–3 declines stand;
app tests run on Ubuntu only in CI, open item 1 gates Windows test
portability); the listLexical partial-listing re-raise (round-3
decline stands — no constructible mid-stream failure without a new
seam, and the whole-directory-unreadable outcome matches ssh's fatal
treatment of unreadable Include targets; an untested swallow path
would violate 08 §1); the duplicate-catch-handler merge and the
`_directiveKey`/`_rawDirectiveValue` dedup (behavior-neutral churn —
round 2 declined the identical-parity `_keyValueCut` refactor — and
the deliberate mirroring of the pin's separator logic is the point);
the barrel `show`-list ordering, the widgetWithText finder spread, and
the gate `Completer` type (consistency nits); and the four
test-hardening items (depth-cap `hasLength(1)`, Port-drop and
top-level-drop pins, the vacuous `find.text('web')` line in the
disposal-race test — its real assertion is `takeException`, and the
replacement-tree shape is that test's design). Deferred: an
include-target size cap for `readText` (the pin's whole-string
consumption model on a local-trust surface; a loud OOM is the
inherited failure mode) and the `unreadable`-note granularity
suggestion — both ride the wiring slice's badge/notice-surface pass
with the round-2/3 deferred items. Validation on the merged head
(origin/main #46 merge): the round-3 battery re-verified — core
analysis clean, 299 tests/15 integration skips; app analysis clean,
214 tests; fixture-tool 61; import guard 92 + repo scan; protocol
guard 49; ARB regeneration byte-identical.

Merged as [PR #45](https://github.com/L-K-M/Poltergeist/pull/45)
(merge `e328aaf`) after review round 5 — 20 findings, all
refuted-with-evidence or declined as re-litigated rounds-1–4
items, doc nits, and test hardening (full triage in the PR
description); two consecutive polish-only rounds, so steady state
held and the PR merged without further code change. Local
re-validation on the merge head `302fb14`: core 299/15 skips, app
214, import guard 92 + scan.

**2026-09-08 post-merge correction (follow-up PR):** supervisor
verification produced runtime counterevidence to the rounds-4/5
alias-parity refutation — the local scan tokenized Host patterns on
space/tab only, while the pinned importer splits on every whitespace
run (`RegExp(r'\s+')`), so `Host alpha\rbeta` keyed the per-host
badges under a token the pin never minted and the row silently lost
its ProxyCommand badge (reproducer:
`pr45-alias-parity-proof.dart`, exit 255, two missing badges). The
refutation's "scan and lookup share one rule" claim was true only
within one file, not against the pin. Fix: Host-pattern tokenization
now mirrors the pin's rule exactly (a dedicated
`_tokenizeHostPatterns`); quoted include-path tokenization is
unchanged. Two named regressions (separator parity against the pin
as oracle — space/tab/CR/VT/FF — and the hostInclude badge under a
carriage-return separator) failed before the repair and pass after;
the reproducer exits 0. Review round 1 added two hardening
regressions (quoted-pattern parity; NBSP in the separator map) —
declined the RegExp-hoist churn (round-2 `_keyValueCut` precedent).
Validation: core analysis clean, 302
passes/15 integration skips; app analysis clean, 214 tests; import
guard 92 + repo scan. No pin change, no upstream behavior change
(the pin already tokenizes correctly).

Deliberately unwired (bounded additive slice): no running surface opens
the dialog yet — command registration rides the M3 command registry and
its entry point (sidebar/interim server list) is the production-wiring
slice; imported bookmarks are not persisted (`BookmarkStore` is M5);
IdentityFile entries connecting rides the connect flow gated on open
item 6. Screenshots ride the wiring slice that first renders the dialog
(prompt-UI precedent). No source port (importer consumed via the pin —
PORTS.md unchanged), no pin change, no milestone close.

## M2 — Séance pin 2e6d1f1 + transcript-redaction bridge (2026-09-08)

The pin moves from `a9add15` to `2e6d1f138f1704e683870f75e11262bf50e37379`
(Séance #81's merge) in both declarations (`poltergeist_core`, bench
harness) and all three locks — a commit-rev bridge per D2: no Séance tag
contains #79's probe repair (all eleven tags checked by ancestry). In
the locks, only the Séance `ref`/`resolved-ref` fields changed — four
replacements per lockfile (`seance_core` and `seance_protocol` in each of
the three lockfiles; 12 replacements, 12 added/12 removed lines total) —
with no unrelated dependency drift, and dartssh2 stays exactly 3.0.2
(sha-identical), keeping upstream's version-bound trace audit valid.

The consumer fix in the same change: the new pin redacts credential
records inside `SshConnectionLog.add` (whole `Userauth_InfoResponse`
records; fail-closed on unrecognized named shapes; `lines` becomes an
unmodifiable `Iterable<String>` view), but the pool's forwarding bridge
overrode `add` and fanned its raw argument out to the live `connectLog`
stream — a source-level bypass of upstream's redaction. The bridge now
forwards the record exactly as upstream stored it (`lines.last` after
`super.add`), so storage and live stream carry identical redacted text.
Freeze/late-write behavior, the 400-line bound (forwarding keeps the
newest line when the transcript trims), append-time fan-out ownership,
and coalescing are unchanged and regression-pinned.

(2026-09-08 correction, follow-up PR #54: the evidence figures below
were amended against the saved pre-fix logs — three redaction failures
with the trim test already passing, and the lock delta above restated as
field replacements.)

Regression-first evidence (synthetic fixture secrets only, through the
existing pool/opener seam): three new `pool_diagnostics_test.dart`
redaction tests failed at runtime on the old pin — no redaction anywhere,
raw secrets in the fan-out; both pre-fix runs end at the test runner's
`+10 -3` tally (10 passed, 3 failed) — and failed again, the same three,
on the new pin with the bridge unfixed (a separate scratch proof
recorded upstream storage redacted while the stream still leaked:
`STREAM: ...[raw]` / `STORAGE: ...[redacted]`). The fourth new test,
trim-bound conformance, already passed on both pre-fix pins; the
13-test suite is green after the fix (+13). Canonical, bracket-containing,
and newline-containing whole records plus the fail-closed malformed named
shape are covered; assertions check fixture-secret absence, not equality
between two possibly-raw copies.

Validation: core analysis clean, 306 tests pass (15 integration skips —
Docker unavailable locally, as before); app analysis clean, 220 tests
pass; import guard (92) + repo scan, protocol guard (49) + check, bench
harness (79, includes the live-revision alignment test), pin-audit tests
(9), license/release-version gates, M0 committed-bundle validation, and
the regenerated full pin audit (verify mode) all pass. In the
validation-only Seance tree at `2e6d1f1`: `seance_protocol` +
`seance_core` analyze clean and all 541 tests pass, including the actual
probe-lifecycle, SSH logging/redaction, upload-CAS, and protocol-model
suites (a Séance-side validation of the pinned revision, not a
Poltergeist app/server claim). QA limits: the 15 real-sshd integration
tests and five client builds ride CI (Docker unavailable locally);
newly available assistant/sync surfaces at the pin are deliberately not
consumed (D19 scope; no Poltergeist account). No upstream PR, no
release/tag, no M0 evidence change.

## M2 — engine probe control and status events (2026-09-09)

Protocol v5 adds eligible-target replacement, paused/running control, and
immutable tri-state status snapshots. The engine consumes the pinned
`ProbeService` with 02 §4's 60 s interval, 3 s timeout, jitter, and six-probe
cap. Host:port duplicates share a probe and fan out by bookmark id. Live
pool ids come from a synchronous transport snapshot, avoiding stale state
events and redundant probes. Target changes clear removed/retargeted results;
repeated updates preserve cadence. Pause/shutdown discard stale results and
queued work while already-started probes drain.

The engine starts paused with no targets. The future app consumer must
subscribe before configuring it, supply only seen/permitted targets under
02 §4's settings and sync-provenance rules, and run it only while foregrounded
and enabled. Global opt-out clears targets and pauses activity. No startup
callers or status-dot widgets land here; those remain the next part of item 3.
Item 6 still gates production connection composition. Chapter 03 clarifies
engine ownership under D8 and the synchronous pool snapshot API. PORTS records
pinned consumption; no copied source, dependency bump, release, or milestone close.

Validation: core analysis and 333 tests pass (15 Docker-fixture skips);
Flutter analysis and 220 tests pass; import/protocol scans and all 51
protocol-guard tests pass. Fifteen service tests cover cadence, concurrency,
validation, target identity, and lifecycle; six client tests exercise the
real isolate boundary. Host tests verify live-pool skipping and teardown.
The live-id retarget regression failed before endpoint matching (zero probes
instead of one); the case-alias regression failed before normalization
(two probes instead of one). Both pass after repair. Docker and five-platform
build verification run in CI. No UI change, so screenshots do not apply.

Review round 1 found no important defect. Applied the host shutdown-error
assertion, shared sweep-deadline expressions, and the sequential-query
fixture caveat. Declined unused-metadata refresh and a normalization-helper
extraction: the callback contract reads only id/host/port, while validation
and case-alias tests pin the existing normalization. All five client builds,
SSH integration, and other CI gates passed on the first head. The PR
description records the full triage; review continues on the test-only update.

## M2 — debug-only demo surface: connect → SFTP → listDirectory (2026-09-09)

07 §3.3's demo-surface bullet lands: the existing, tested connection slices
compose into the running app for the first time. A debug-gated entry
(`connect.demoListing`, the toolbar renders it from the registered-command
list — D21; the M2 debug subset of 02 §8.1's command model, replaced with
M3's registry) opens a throwaway listing view: connection facts entered as
host/port/username/auth-method, an ephemeral `Bookmark` built through the
pinned model (04 §2.1 — no second server model, D2/D3), the engine isolate
spawned, `EngineClient` driving the pool's browse channel, `listDirectory`
over the canonicalized home, entries plus the live `SshConnectionLog`
transcript rendered, and failures keeping the transcript and the summarized
one-liner visible. Prompts — host-key first-use trust, changed-key hard
block, keyboard-interactive, credential — round-trip through the existing
`PromptCoordinator` inside a demo-owned nested navigator (02 §10).
`SftpDemoController` is the session's diagnostic owner: it subscribes to
the live streams before connecting and replays to the panel that mounts a
frame later (03 §5's subscribe-before-connecting rule; no engine change).

Debug gating: `PoltergeistApp.debugDemoEnabled` (default `kDebugMode`) is
ANDed with `kDebugMode` at composition, so release builds never render or
register the entry; tests pin flag-off absence and flag-on presence. The
form validates host/username/port at the entry point (1–65535 mirrors the
pinned model's bounds). No pin/lock change, no production composition
(startup wiring, pin persistence, probe dots stay with their owning
slices), no milestone-close claim. All strings ARB-authored (D20); the
localization contract gains the demo files' reviewed technical exceptions.

Validation: 29 new tests — gating/registration, spawn-failure notice,
double-tap session guard, host-key first-use through the real coordinator
with the transcript live during connect, credential collection,
keyboard-interactive round trip, declined changed-key hard block with
persisted transcript + one-liner, failed listing one-liner, disconnect
(widget state and status-replay clearing), entry-point validation,
connect re-entrancy (guard, previous channel/server handoff, and the
disconnect-during-connect late session), connect-failure guard
unwedging, unexpected listing-failure reporting, status-stream fault
reporting, transcript replay-buffer bounds, disconnect-after-dispose
no-op, system-back prompt dismissal, narrow-window toolbar overflow,
broken-transcript-seam unwedging, stale-cleanup dispose race,
stale-cleanup guard window, stale-cleanup resurrect guard, per-session
transcript reset, invalid-facts guard unwedging, stale-session-line
rejection, and a real-isolate
leg — all driving the production
`EngineClient` seam over spawned isolate ports. App analyze clean, 273 app
tests pass; core untouched (analyze clean, 333 tests, 15 fixture skips).
Real-sshd legs were not extended to this surface: no Docker-enabled
Flutter CI job exists (the integration leg runs pure-Dart core tests), and
the engine/pool/opener paths the surface composes already carry real-sshd
coverage; recorded rather than claimed. Screenshots are rootless
widget-render captures (labeled as such), since this container has no
native capture. QA limit: the demo offers password/agent auth; key-file
auth needs the production identity-reader wiring (its own slice).

## M2 — app-side probe eligibility controller (2026-09-09)

`ProbeController` consumes `EngineClient`'s new `ProbeBridge` facet and
publishes immutable probe snapshots independently of root app state.
Only seen, permitted favorites qualify; synced favorites additionally
require a successful connection from this device. Global opt-out clears
targets and results. Only resumed lifecycle state runs probes. Equivalent
endpoint sets preserve cadence; removed/retargeted results clear immediately.
The controller subscribes before sending targets and buffers snapshots that
precede acknowledgements. Restrictions overtake pending acknowledgements;
stale continuations cannot resume probing. Engine loss clears truth to
unknown; request/stream errors use the existing local error sink.

Validation: 24 controller tests cover the eligibility matrix, lifecycle
states, opt-outs, retargeting, delayed/failed acknowledgements, disposal,
engine loss, reentrant listeners, and real-client isolate ordering (including
no-op target updates). The listener-opt-out regression failed before request
identity was established ahead of notification and passes after the repair.
App and core analysis are clean; 244 app and 333 core tests pass (15
Docker-fixture skips). CI validation is recorded in the PR.

Review round 1 found no important defect. Bridge/duplicate-input/lifetime
contracts and first-error reporting are clarified; test failure diagnostics
and the no-op fixture comment are tightened. Paused snapshots deliberately
retain the last known result; opt-out and engine loss clear to unknown.
Automatic duplicate selection and extra public lifecycle state are declined:
the owner supplies unique ids and already owns engine termination. The
host/port probe contract excludes credentials, paths, and TLS settings.
All five client builds and SSH integration passed on the first PR head.

This is an unwired M2 component. The owning store must supply device-local
facts for the current endpoint and reset exposure/history on retargeting.
Persistence, lifecycle forwarding, interim list dots, live connection-state
composition, and startup remain open; item 6 still gates production wiring.
Chapter 03 records the controller contract. No source port, dependency/pin
change, UI change, release, or milestone close.

## M2 — prompt dialog route guards ported back to Séance (2026-09-09)

The current-route action guards in the ported host-key and
keyboard-interactive dialogs are ported back to Séance as
[Séance #82](https://github.com/L-K-M/Seance/pull/82) (head
`5d9da5195a3a9a4d8110d0b2425d55e5cb3fddde`, merge
`5cadb18e823ca1ae089b9fdd940432876e93fd9c`, merged 2026-09-09T01:28:38Z,
"Guard prompt dialogs against stray route pops"). Upstream, every dialog
action now routes through a private `ModalRoute.isCurrent` check (a `close`
closure in the host-key builder, `_close`/`_submit` in the keyboard State),
so a rapid second activation during the exit animation cannot pop the page
below and a callback from an obscured dialog cannot pop or answer a newer
route — the same semantics as the local guards, with result contracts,
barrier behavior, warning/fingerprint/button semantics, answer order,
cancellation, controller-dispose-after-exit-animation, and current
reveal/echo behavior unchanged.

Observed evidence (saved under `tasks/batch2-task9-*.log`): six new upstream
widget regressions — three per dialog, opening the public dialogs above a
pushed page through real Navigator routes and capturing the existing
button `onPressed` seams, with outer-page/result/newer-route/exception
assertions — failed against the unmodified upstream dialogs at `2e6d1f1`
(`flutter test` counter `+7 -6`, six failures: the four double-activation
cases by the page below being popped,
the two obscured-callback cases by the newer route disappearing) and pass
with the guard (`+13`). All 463 upstream Flutter tests and `flutter analyze`
are green; all nine Séance CI checks pass on the merged head's PR run.
Review round 1 found no correctness item (two debug-log hardening minors
and a helper-extraction info declined with reasons recorded in the PR body;
an outside-diff pre-existing `[]`-cancel-sentinel observation deferred to
the upstream SSH-layer contract owner) — steady state per the owner's bar.

Companion ledger corrections in this PR: the four dialog PORTS entries
are re-diffed at `5cadb18` — upstream already carried keyboard scrolling
(`86b1e4d`, 2026-09-04), explicit per-field reveal (`1c2c29b`, 2026-09-04),
empty-name fallback, first-field autofocus, and the controller lifecycle
(`c2d60a6`, 2026-07-09), all inside `a9add15`'s ancestry, so the entries'
"adds reveal toggles" wording is corrected (ported behavior, not local
additions) while the original dated port provenance and the legitimate
ARB/payload/coordinator/dialogKey/Enter-navigation divergences stand. The
route-guard port-back candidates close; Enter navigation, the echo-bit
preservation, the keyboard autofocus-test candidate, and the host-key
scrollable-content/scrollable-assertion/mounted-harness candidates stay
open (owner gates unchanged).

This is app-layer upstream work only: no pin change (the pinned
`seance_core`/`seance_protocol` trees are untouched by #82), no local
production code change, no release, no milestone-close claim.

## M2 — host-key review reachability ported back to Séance (2026-09-09)

The scrollable-content behavior this port has carried since the prompt-UI
slice is ported back to Séance as
[Séance #83](https://github.com/L-K-M/Seance/pull/83) (head
`2f6c49ce6a4af424003261dae3ec116eeb80fa74`, merge
`b8fc1111119cd6c0744b9de9bc35d16c07ae3e9d`, merged 2026-09-09T05:03:47Z,
"Keep host-key review reachable in tight layouts"). Upstream's host-key
`AlertDialog` now sets `scrollable` like its keyboard-interactive sibling,
so the changed-key review (warning + both fingerprints) scrolls inside the
dialog in constrained layouts and Cancel/Trust stay pinned below the scroll
area — matching this port, whose dialog already passed `scrollable: true`
since 2026-09-07.

Observed evidence (saved under `tasks/batch2-task10-*`, the session
task-log store — not committed to the repo): two upstream widget
regressions written against unchanged upstream production at `5cadb18`
failed at runtime with actual rendering overflow — the public dialog through
a real `showDialog` route at 390×644 logical px, text scale 2.0, realistic
43-character fingerprints — `A RenderFlex overflowed by 1616 pixels`
(changed-key) and `280 pixels` (first-use) — the flutter test runner's
per-case tally read `+5 -2` (the suite's five pre-existing cases passed,
the two new regressions failed); both pass with the fix (`+7` — all seven
cases), additionally scrolling the previously trusted fingerprint and the
warning into view and back with the pinned buttons asserted on screen at
the deepest scroll. Review rounds 1–3 each produced applied hardening
(restored indentation, below-the-fold premise assertions, predicate-driven
scroll helper anchored on the dialog's scroll view, deepest-scroll button
assertions); round 2's viewport-clip finding was confirmed real by
measurement (a print at y 616..820 against a viewport of 24..428 counted as
"on screen" under surface bounds) and repaired — visibility is now clipped
to the scroll viewport. All 465 upstream Flutter tests (463 baseline + 2)
and `flutter analyze` are green; all nine Séance CI checks pass on the
merged head's PR run. Rounds 3–4 surfaced only polish-level findings
(round 3's two hardening asserts were applied); steady state per the
owner's bar, all five threads resolved after merge.

Widget-render captures (rootless container — native capture unavailable;
`matchesGoldenFile` harness, 390×644, DPR 1.0, text scale 2.0, identical
data/theme): the BEFORE images paint overflow stripes with content spilling
past the card and clipped at the viewport; the AFTER images show no
stripes, a clean scroll clip, and buttons contained inside the card
(`png/PROVENANCE.md` and `SHA256SUMS.txt`, both relative to
`tasks/batch2-task10-logs`; pairs inspected visually, not
pixel-diffed). Local conformance on the same head: app analysis clean and
the affected dialog suites pass (15 = 5 host + 10 keyboard). No local
production change: the port already carried the behavior, so this PR is
ledger-only — the two host_key_dialog PORTS entries close the
scrollable-content and scrollable-assertion candidates (the mounted-harness
candidate stays open; the keyboard/identity/Enter/echo candidates and
owner gates are unchanged). No pin change (#83 is app-layer only — the
pinned `seance_core`/`seance_protocol` trees are untouched), no release,
no milestone-close claim.

## M2 — probe wiring: persistence, lifecycle, interim dots (2026-09-10)

App-side remainder of item 3's probe bullet (engine control/status #55 and the
eligibility controller #58 already landed).

Persistence (`ProbeSettingsStore` over the existing `SettingsStore`): the
global reachability opt-out (`probe.enabled`, only a persisted `false`
disables — 02 §4's default-on) plus the per-server device-local map inside
settings.json keyed by serverId (03 §6): exposure (`seen`), successful
local connection, and the host/port binding. The host binding ignores case
like probe endpoints; a retargeted bookmark resets exposure and connection
history at the store and the reset is persisted (03 §3.4). Malformed or
hand-edited records read as unseen and are repaired in place. Probe
*results* are never persisted (D19) — the record shape carries eligibility
only, pinned by a test. Per-favorite opt-out lands with M5's bookmark
store: the interim surface's ephemeral bookmark ids cannot carry one.

Lifecycle forwarding (`AppLifecycleForwarder`, a binding-seam
`WidgetsBindingObserver`): attach reports the current state and forwards
changes; detach stops forwarding; the demo route — the only M2 surface
whose session can probe — owns the forwarder, so backgrounding pauses the
engine's probes and returning resumes them (02 §4; only `resumed` runs).

Interim dots (`ProbeStatusDot`, ARB tooltips + semantics): tri-state
unknown/online/offline; online is Material green 800, offline the scheme's
error, unknown the scheme's outline. Contrast is pinned ≥ 3:1 on both
seeded theme surfaces (02 §4's SEA-019 fix) and a render-level test pins
the exact painted pixels per state. The demo page renders the dot beside
the app bar title for the listed server (the sidebar reuses the dot in M5).

Composition (`ProbeCoordinator`): the owning-store role from 03 §3.4 —
constructs the `ProbeController` over the engine's `ProbeBridge`
(subscribing before anything sends, the #55 ordering rule), supplies
store-loaded facts, persists seen/connected, removes the ephemeral
bookmark's record when it leaves the list, and fails closed (no targets,
no activity) when the settings store is unreadable. The demo session is
the first app caller that initiates probes: it constructs the coordinator
with the store-backed settings plumbed from `main.dart` through
`PoltergeistApp`/`WorkspaceShell`, marks the server seen on connect, and
marks the connection fact after a successful listing. Lifecycle,
opt-out, disconnect-clearing, and dispose-before-engine ordering ride the
same path.

Validation: regressions observed failing before implementation where
behavior is new (the four suites reference the not-yet-written services;
subscribe-before-send ordering, pause/resume forwarding, retarget reset,
and file round-trips all pass after). 329 app tests (43 new: store
round-trips/defaults/retarget/malformed-repair/concurrent-writes,
forwarder attach/detach/duplicate-attach, coordinator policy incl.
fail-closed store reads, stale-hide refusal, and replaced-record removal,
dot rendering/contrast/pixel pinning, demo-level
ordering/lifecycle/opt-out/disconnect/persistence) and analyze pass; core
untouched (analyze clean, 333 tests, 15 fixture skips). Review round 1
repaired the retarget-preserving-markSeen bug (a connection fact could
survive an endpoint rebind; regression failed before the fix), serialized
lifecycle forwarding through the coordinator's queue (a hidden change
could re-send a replaced favorite's targets; regression failed before),
skipped store writes for superseded configs (regression failed before),
and hardened the queued-hide path against a disposed controller; the
dot's tooltip excludes semantics so the label announces once; the demo
command gates release-safely on the settings seam. Review round 2
(steady state per the owner's bar — re-raised declines and test
hardening) added replaced-record removal on showServer (the demo's
stale-connect path could orphan an old record; regression failed
before), serialized the store's own read-modify-write operations
(concurrent mutations could clobber; regression failed before),
corrected the green shade name, made the coordinator fake honor endpoint
binding, pinned the exact post-dispose bridge calls and the
pause-before-targets ordering, exercised an unsolicited mid-session
snapshot in the live-status test, and unified the dot harness on the
production theme. Refuted: hideServer
runs in disconnect(), never against a disposed coordinator from
_teardown (the reviewer's attribution was wrong; the same-frame
hide-then-dispose path is the guarded case); the app bar's
background is scheme.surface, not surfaceContainer (pixel-sampled in
the theme builder), so the surface contrast pin is the rendered chrome;
the queued lifecycle update cannot carry a stale favorite (round 1
moved it into the queue after the pending configure; the serialization
regression pins it). Declined: value-equality in _isCurrent — the
identical() recheck is the required post-await idiom (09 §3.1) and the
constructor contract keeps the config instance; refreshPolicy — no
settings-change notification or UI exists in M2, and an API without a
caller is speculative (M5's settings surface wires the update path);
clearServers — a startup sweep of the shared map would be a data-loss
footgun once M5 keys durable bookmark records there, and the residual
risk is one record per crashed debug session on a surface M3 deletes.
Review round 3 (polish-only per the owner's bar) applied: non-Map
malformed records repair in place; the dot's tooltip hit area grows to
24 px; the coordinator fake's host comparison matches the store's
case-insensitive binding; dark-brightness render loops for the dot; an
explicit dispose-idempotency pin; the app-bar background assumption is
pinned at the widget level; the pixel pin documents its deliberate
exactness; STATUS lists the deferred per-favorite opt-out. Refuted:
the third re-raise of the hideServer-in-_teardown misattribution
(hideServer is only called from disconnect(); quoted the methods); the
pumpDemoView engine-close claim (the helper already registers it); the
SettingsStore cross-facade race (setAll mutates the shared in-memory
map inside the store's own serialized write tail). Review round 4
(polish + re-litigations) applied: the fail-closed path narrows to
read failures (an unwritable but readable store keeps probing with the
loaded facts; only unreadable stores disable — matching the documented
intent, with both paths pinned); the subscribe-ordering and hide
assertions pin real commands instead of vacuous passes; the port-retarget
reset persistence and the explicit-opt-in round-trip are pinned; the
demo fake honors endpoint binding; the semantics handle releases on
failure; the scrolled-under surface tint joins the contrast pin; the
null-attach lifecycle contract is pinned; main.dart documents the shared
store's internal write serialization. Refuted with evidence: the
"critical" null-safety compile claim (Dart 3 boolean-variable promotion
makes the code valid — analyze clean and all 329 tests pass on the exact
head the reviewer called broken, and CI's Flutter job is green) and the
fourth re-raise of the hideServer-in-_teardown misattribution
(hideServer is only called from disconnect()). Declined (re-raised a
fourth time, recorded): _isCurrent value-equality. Declined (re-raised):
clearServers/orphan sweep — the round-3 footgun rationale stands.
Rounds 5–6 re-raised the same items again (the hideServer-in-_teardown
misattribution, _isCurrent value-equality, the failed-connect leak, the
stale-favorite window, the compile claim CI already disproved) plus
comment nits; the applied items were the opt-out clear pin, the bounded
gate wait, and two doc/comment corrections. Steady state per the
owner's bar: no correctness, security, or contract finding survived
triage in any of rounds 2–6.
Widget-render
captures before/after the dot in `tasks/probe-wiring-captures` (rootless
container, labeled). No core changes, no pin/dependency change, no source
port, no milestone-close claim: live connection-state composition (the
Connections-section surface) and startup composition remain open (item 6
still gates production wiring).

## Fixture repair — Alpine iproute2 pin (2026-09-10)

Main's post-merge CI leg
([run 34438055897](https://github.com/L-K-M/Poltergeist/actions/runs/34438055897),
head `22eefd1`) failed building the sshd fixture: apk rejected
`iproute2=7.1.0-r0` in `test/integration/sshd-modern/Dockerfile` —
Alpine rotated the package to `7.2.0-r0` and only that version remains
(`iproute2-7.2.0-r0: breaks: world[iproute2=7.1.0-r0]`). The other
three apk pins in the same file (the `10.5_p1-r1` OpenSSH set) still
resolve and are unchanged; the legacy Debian fixture and every other
fixture file pin nothing else on this image. Bumped the pin to
`iproute2=7.2.0-r0`, matching the fixture's established exact-pin
convention (no new pinning scheme), and added the fixture-tool
regression `pins the current modern iproute2 package` beside the
existing OpenSSH pin test — it failed against the old Dockerfile and
passes after the bump. `docs/M0-DARTSSH2-REPORT.md`'s fixture row keeps
`7.1.0-r0`: it records the fixture as measured for M0 evidence, which
does not change retroactively.

Validation: fixture-tool analyze clean, 62 tests pass; core analyze
clean, 333 tests pass (15 Docker-fixture skips — Docker unavailable
locally, as before). The real build + all 15 SSH tests ride the CI
integration leg on the PR head. No PORTS, pin, dependency, or
milestone-close change.

## M2 — trust-incident lifecycle (2026-09-10)

Item 6's owner decision (1a/2a/3a, 2026-09-09T19:52Z) lands in the pool:

- **Restored-key unblock (1a).** A declined changed-key block lifts when a
  connect attempt presents a key the TOFU verifier accepts as `trusted` —
  presented equals pinned, the verifier being the single trust authority.
  The opener never invokes the prompter for a trusted key (the pinned
  Séance verifier returns early), so the first connect observes the
  attempt's verdict through a verifier decorator and clears the incident
  after the transport lands. No new verdict, no prompt, no pin write, no
  state fan-out beyond blocked → connected; a `changed`/`firstUse`
  presentation keeps the existing hard block (D18 unchanged: the block
  ends only via this restored-key match or an explicit approval —
  growth and recovery connects never lift it — and deleted pins still
  cannot enable first-use approval).
- **Persistence (2a).** `IncidentStore` (seam) + `IncidentRecord` (schema:
  `serverId`, `host`, `port`, `username`, `jumpHostId`,
  `presentedFingerprintSha256`, `pinnedFingerprintSha256`; strict
  `fromJson` with port-range refusal, matching 04 §2.1's decode posture).
  Records are keyed by bookmark-derived serverId — the 3a cascade key —
  and re-associate with pools through the normalized endpoint identity
  (`PoolKey`). The manager loads the injected store lazily at the first
  reference resolution and treats an unreadable/absent store as no
  incidents (never a crash, never auto-trust); declines persist
  best-effort (a failed write never affects the live block), approvals,
  restored-key unblocks, and removals delete the records.
  `FileIncidentStore` (core, dart:io — the `LocalFileSystem` precedent)
  follows the app-layer port conventions: JSON, atomic temp+rename writes
  (exclusive create, bounded retry), 0600 owner-only on desktop POSIX
  (chmod failure fails the write), corrupt-file quarantine with a UTC
  stamp, and a serialized write chain so the pool's unawaited writes
  cannot interleave read-modify-write flushes. `InMemoryIncidentStore`
  serves tests and the not-yet-wired engine default.
- **Bookmark-removal cascade (3a).** `ConnectionManager.removeBookmark`
  drops the pool reference (disconnect semantics) and withdraws the
  bookmark's incident stake: its store records are deleted, and the
  endpoint's block clears when the last owning bookmark leaves. Identity
  rule for two bookmarks sharing a server: the block is per-endpoint and
  every bookmark referencing a blocked endpoint carries a record (a join
  persists its own copy), so deleting one bookmark never unblocks its
  sibling — the sibling keeps its review path, and a fresh id at the
  endpoint starts clean with the verifier re-detecting on connect.

Validation: the 1a regressions (`pool_trust_test` repurposes the two
"trusted key reappearing" tests: in-session unblock and unblock after pool
retirement, plus a new changed-key-still-blocks leg) failed at runtime on
the pre-fix code and pass after; the persistence and cascade regressions
(`pool_incident_lifecycle_test` — manager restart round-trips over both
stores, a real on-disk round-trip through `FileIncidentStore`, the shared-
endpoint identity rule, orphan-owner removal) and the store suite
(`incident_store_test` — JSON round-trip, malformed-record refusal,
absent/corrupt-file fail-safe, owner-only mode, serialized writes) failed
to compile before the seam existed and pass after. Core analysis clean;
349 core tests pass (15 Docker-fixture skips); import guard (92 + scan),
protocol guard (51), pin audit (9), fixture tools (61), bench harness
(79), license gate (34), and release-version (155) tests pass.

Remaining wiring (item 3/item 6, deliberately out of this slice): the
engine protocol does not yet seed incidents at spawn or forward incident
changes/removals across the isolate — `EngineConfig`, an
incident-change event, and a `removeBookmark` request land with
production wiring, when the app owns bookmarks (M5) and supplies the
store path. `EngineHost` passes no store yet, so production sessions stay
session-only until then. No production change, source port, pin change,
UI change, release, or milestone-close claim.

(The protocol half landed later the same day — see the engine incident/pin
bridging section below. Sessions stay session-only until the app-side
composition supplies the seeds.)

(The Alpine `iproute2` fixture pin drift that reddened this PR's first
CI run was repaired on main in the separate fixture PR #61 — the
integration leg passed on this PR's head without further fixture
changes.)

Review round 1 (applied; both regressions failed before their repairs):
`removeBookmark` now awaits the lazy incident load — a delete racing an
in-flight load previously let the load re-register the removed bookmark
as an in-memory owner, stranding the block past its last real owner
(regression: gated-load store + removal race); persistence failures now
reach an optional `onIncidentStoreError` observer (mirroring
`onRecoveryFailure`) so a failing store is visible without affecting the
live block (regression: throwing store + observer assertions);
`IncidentRecord.poolKey` and `PoolKey.of` share one `PoolKey.normalize`
factory so record and config keying cannot drift (parity test against an
equivalent config); the record decode rejects whitespace-only hosts;
`_ObservingTofu` delegates `pin` so a wrapped verifier's overrides are
never bypassed; the file store distinguishes an unreadable file (empty
load, file left in place) from a corrupt one (quarantine), documents its
single-instance-per-file contract, and `load` honors the interface's
fail-safe contract on read failures while `put`/`remove` propagate them;
the lifecycle tests disconnect every registered server at teardown and
pin the decline on the blocked failure mode. Refuted with pinned-source
evidence: the presented-host identity premise (the pinned opener passes
`config.host` verbatim to the verifier, so presented == configured host;
the shared normalization makes keying provable regardless) and the
jump-host multi-verdict premise (the pinned opener verifies exactly one
host key per attempt; jump-host chains are D10 work). File locking for
concurrent store instances is deferred to the wiring slice.

Review round 2 (applied; the over-delete regression failed before its
repair): `IncidentStore.remove` is scoped to a record — it deletes only
when the stored record still equals the one being lifted, so a bookmark
re-pointed to a new endpoint cannot lose the new endpoint's block when
an old endpoint's block lifts (regression: newer-record survival
through a 1a lift); `removeAllFor(serverId)` carries the
bookmark-deletion cascade. The store contract now states the mutation
ordering both shipped stores provide (puts/removes apply in issue
order), the chmod failure normalizes to `FileSystemException`, the
owner-map comment reflects its cascade role in session-only mode, the
1a bullet names the exact block-lifting set, and the polling helper
reports the last observed state on timeout. Declined with recorded
reasons: a bookmark-registry reconciliation callback for orphan records
(the engine deliberately holds no bookmark registry — the UI owns
bookmarks and signals removal via `removeBookmark`; an orphan is
self-healing on the endpoint's next review); awaiting join-adoption
writes (would add store I/O latency to reference resolution, and the
ordering contract plus the stores' serialized chains already preserve
put-before-delete); narrowing the barrel's store exports (concrete
in-memory stores already ship in the barrel — Séance's
`InMemoryHostKeyStore` precedent — and the single-instance contract is
documented). Refuted with evidence: the "owners never shrink" premise
(removal and every lift drain the owner set); the "clearing must purge
all owner records" premise (the code already deletes every owner's
record — pinned by the shared-endpoint lift test); the re-raised
presented-host keying premise (round-1 refutation stands — the pinned
opener passes `config.host` verbatim, and `PoolKey.normalize` is shared
by construction); the interface-breakage premise (no other
`ConnectionManager` implementations exist; the suite compiles).
Deferred: a `FileIncidentStore.onLoadError` hook (no consumer exists
until the wiring slice owns store construction).

Review round 3 (applied; the stale-payload regression failed before its
repair): `IncidentStore.removeFor(serverId, endpoint)` replaces the
payload-equality delete — a lift matches the stored record's endpoint
identity, so a stale payload of the same endpoint (a failed re-write) is
still removed while a re-pointed bookmark's newer-endpoint record
survives (both regressions pin the pair); the strict decode rejects
empty fingerprint strings and negative ports; the unreadable-file test
skips when running as root (chmod 000 does not deny root); item 6's
cross-reference now points upward to the dated section. Declined with
recorded reasons: per-serverId write chaining in the manager (re-litigated
round-2 ordering — the store contract documents the issue-order
invariant both shipped stores provide, the reviewer's own alternative);
the bookmark-registry reconciliation re-raise (round-2 decline stands);
the last-write-wins verdict re-raise (the pinned opener verifies exactly
one host key per attempt; jump chains are D10); delegating hypothetical
future `TofuVerifier` members (the production wrapped verifier is the
concrete base class); a crash-orphaned `.tmp` sweep (parity with the
ported atomic-file helper, 0600 temp, no security exposure — a startup
sweep rides the wiring slice); the fixture pin-coupling note (CI on the
head rebuilt the image and ran the 15 real-sshd tests — the pin resolved;
pin rot is the fixture's pre-existing maintenance property). Refuted:
the unhandled-async-error premise (every call site catches —
`catchError` before `unawaited` or an awaited try/catch — no future can
complete unhandled) and, for the teardown-misses-s3 premise, round 4
showed the snapshot fix had landed only in the gated-store test —
`_harness`'s teardown now snapshots `harness.servers.keys` too (see the
round-4 record).

Review round 4 (applied; first polish-only round — both majors are
re-litigations): `_harness`'s teardown snapshots `harness.servers.keys`
(the round-3 refutation had overstated the earlier fix's reach); the
re-pointed test's poll check guards `.single` with a length check; the
M2 heading gained its missing blank line; a file-store test covers
`removeFor`'s endpoint guard and its early-return-before-flush.
Declined with recorded reasons: the fire-and-forget ordering re-raise
(third packaging — the store contract documents the issue-order
invariant both shipped stores provide, the reviewer's own alternative);
the `chmod` PATH re-raise (03 §2.2 prescribes PATH-based `Process.run`
chmod for core; a same-user PATH influence yields at worst
process-default modes — content authority stays in-process); the
first-record-wins payload divergence (payloads affect only the block
detail; the schema carries no ordering data by design); the
last-verdict re-raise (one verification per attempt at this pin); the
quarantine-stamp overwrite (microsecond-precision stamp, best-effort
evidence preservation — parity with the ported helper).

Review round 5 (applied; the invalid-UTF-8 regression failed before its
repair): a torn write's invalid UTF-8 is treated as corruption
(quarantine + recovered writes) instead of wedging every later write;
`_forgetIncident` dropped its vestigial null-incident guard (the delete
is endpoint-scoped, not payload-dependent); the strict decode rejects
blank usernames. Declined with recorded reasons: the store-delete-first
ordering for `removeBookmark` (fourth packaging of the orphan-record
family — the claimed permanent block is self-healing through the
endpoint's next review; either crash window leaves only a stale block,
never a trust grant); the cached-failed-load retry (matches the
fail-safe contract and the ported store convention; re-detection covers
it); one-bad-record skip (whole-file quarantine is the ported
convention, and atomic writes make partial corruption the rare case);
the stack-trace observer shape (parity with `onRecoveryFailure`); the
chmod re-raise (round-4 decline stands); the pin-observation and
verifier-delegation re-raises; the fsync-durability and
blank-username-block re-raises (best-effort persistence; username
blankness is now rejected anyway). Refuted: the epoch-guard premise
(no concurrent block source exists while a serialized first connect
holds the attempt), the late-load resurrection premise (reference
resolution awaits the load; no pool exists before it), the
observation-never-cleared premise (a fresh per-attempt instance), and
the teardown re-raise (round 4 fixed it).

Review round 6 (applied; docs-only): the round-5 record edit had
overwritten the round-4 record, so the round-4 record is restored in
full and item 6 keeps its original escalation description alongside the
owner decision. The round also suggested broadening `load()`'s
fail-safe catch and asserting the test-setup `chmod` succeeded; the
response commit (f0efd1b) applies only the doc restoration, and PR #60
records no disposition for either suggestion. The scorecard records no
correctness, security, or contract finding in rounds 4-6 and declares
steady state.

## M2 — ssh_config import composition (2026-09-10)

D22's import flow is wired end to end in the app shell (#45 landed the
preview/dedupe component; this slice supplies composition, persistence,
and command registration).

`FileBookmarkStore` (`poltergeist_app`) persists the pinned `Bookmark`
model (D2/D3 — no second server model) to `<app-support>/bookmarks.json`
through the repo's atomic-write plumbing: a `version`/`bookmarks` JSON
root, a serialized write tail, swap-after-write so a failed write leaves
memory intact, quarantine of a corrupt file with a UTC stamp (a quarantine
that cannot move the file fails the load rather than starting empty over
bytes it could not read), read failures propagating to the caller (never
silently overwritten), a newer on-disk `version` failing in place (no
quarantine, no overwrite), and per-record skip-and-preserve so a record
from a newer Poltergeist survives a local re-save (04 §2.1). Only
04 §2.1's synced fields are written — 04 §2.3's device-local data never
enters the file. `BookmarkRepository` is the seam the UI depends on, so
widgets never touch `dart:io`; M5's app-wide `BookmarkStore` (grouping,
reordering, the sync-coordinator seam, the sidebar) builds on this file.

The registered `favorite.importSshConfig` command (`RegisteredCommand`
grows an optional icon; the toolbar renders it, D21) loads the persisted
bookmarks for dedupe, opens the existing ARB-complete preview, and
`upsertAll`s the rows the user kept, with a transient ARB-authored
confirmation. Dedupe runs against the store, so persisted rows are flagged
and start skipped (D22's recorded semantics); an explicit re-selection
still imports as a second bookmark. `main.dart` builds the setup over
`~/.ssh/config` through the testable `buildSshConfigImportSetup` factory
(the ported `expandHomePath`, macOS-sandbox home recovery included),
registering the command only when a home directory resolves and never on
Windows — the core import service normalizes POSIX paths, so a
drive-letter config cannot be read there and the command stays
unregistered instead of always failing. The shell adds no bookmark UI (M5).
Four new ARB strings carry the command label, the confirmation, and the two
store-failure notices.

Validation: regressions observed failing first (both suites did not
compile before the seams existed). New tests: twelve `bookmark_store_test`
cases (disk round-trip, id update, corrupt quarantine with byte
preservation, failed-quarantine fail-closed, skip-and-preserve for an
unknown kind and for a wrong-typed field, newer- and unrecognized-version
fail-in-place, read-failure propagation, a load waiting for a queued
write, concurrent-write serialization, and the service-built import
persisted to disk); seven `ssh_config_import_command_test` cases (wiring
gate, preview→persist with reference-style IdentityFile, existing endpoint
flagged+skipped, no-match store, a missing config's retry surface, and the
load- and save-failure notices); and four `ssh_config_import_setup_test`
cases (POSIX wiring, no home, Windows gate, macOS sandbox home). The
shared `FakeSshConfigSource` lives in `test/support/`. 352 app tests pass
(329 + 23); app analysis clean; import guard, protocol guard, and the
repository scan pass. Core untouched (356 tests, 15 fixture skips).
Rootless widget captures (before / after / dialog, labeled as such) under
`tasks/m2-ssh-import-captures`, since the shell's toolbar layout changes.

Review round 1 (applied; the parked-write regression the reviewer described
was real — deleting the serialized tail makes the new test fail with a lost
bookmark, verified): the concurrent-write test now parks the first write
before enqueuing the second; a wrong-typed record joins the
skip-and-preserve cases; an unreadable-but-present file's rethrow and a
newer store version's fail-in-place are pinned, with `_load` resetting its
state per attempt. Refuted with the pinned model source: `Bookmark.fromJson`
wraps every non-`FormatException` failure (`_guardFormat`), so `_decode`'s
`FormatException` catch is complete — widening to `on Object` would only
swallow model bugs. The hardcoded `/` in the config path stands: the core
import service normalizes on `/` (its include base is `.ssh/`), so
`Platform.pathSeparator` would not make Windows work; the Windows import
gate now lives in `buildSshConfigImportSetup`.

Review round 2 (applied; one re-raise): a quarantine that cannot move the
file aside now fails the load instead of starting empty (a later save
could overwrite unreadable bytes — regression with the quarantine path
blocked by a directory); the two rethrowing `_load` paths no longer
`_report` (the calling service reports once), while quarantine-return paths
keep reporting; the quarantine test pins the corrupt bytes verbatim; the
read-denial setup asserts `chmod` succeeded; the load- and save-failure
notices have widget coverage; `main.dart`'s wiring moved to the testable
`buildSshConfigImportSetup` factory (with the Windows gate); and the test
fake source is shared. Refuted (re-raise, no new evidence): widening
`_decode`'s catch — round 1's pinned-source proof stands and the
wrong-typed-field case already passes through skip-and-preserve. 349 app
tests, analyze, and the guards pass on the reviewed head.

Review round 3 (applied; polish only, one re-raise): the version guard now
fails closed on any unrecognized encoding (a non-int version included);
`load()` awaits the write tail so a read racing a queued write cannot
return pre-write state (regression: gated writer, verified to fail without
the await); the quarantine name is a shared `bookmarkQuarantinePath`
helper rather than duplicated in the test; a missing `~/.ssh/config` is
pinned to the dialog's retry surface; the toolbar icon wraps; the fake
source's doc says listings are absent, not empty. Refuted again (third
raise, no new evidence): widening `_decode`'s catch to `on Object` —
`_guardFormat` in the pinned model normalizes every failure to
`FormatException`, and the wrong-typed-field regression passes through
skip-and-preserve.

Review round 4 (applied; polish, one re-raise): the version gate now
rejects any non-null value other than this store's integer (an older or
non-integer encoding included — a v0 test joins the v2 case), the two
skip-and-preserve tests assert deep record equality instead of spot
fields (verified: the store preserves the whole nested record, wrong-typed
field included), and the widget suite's `setup()` helper takes a store
override, collapsing three hand-rolled wirings. Refuted with evidence: a
composition-level re-selection test — the #45 dialog suite already pins
re-selection (`toggling rows updates the count and the imported set`
selects the flagged row and imports it), and this suite pins that the
returned rows persist, so the union covers the claim. Declined (fourth
raise, no new evidence): widening `_decode`'s catch. No correctness,
security, or contract finding survives triage; the only repeat is a
re-litigated decline. Steady state per the owner's bar.

Deliberately out of scope: M5's `BookmarkStore` UI (grouping, reorder,
sidebar), the connect flow that consumes an imported IdentityFile (still
gated on open item 6), and any core/pin change. The import writes exactly
the 04 §2.1 model through the pinned importer; key material is never read
(D18). No source port, dependency change, release, or milestone close.

## M2 — live connection-state composition (2026-09-10)

Item 3's remaining app-side slice and the audit finding 4-note's recorded
open work: the Connections surface and 03 §6's app-wide `ConnectionStatus`
notifier, consuming the engine's existing state lanes.

- `ConnectionStatusController` (the app-wide notifier): the bookmark store
  supplies the rows — endpoint-bearing bookmarks, whose id is the pool's
  serverId (03 §3.5); `serverConfigId` references and workspace/saved-sync
  endpoint identities carry no serverId of their own and stay with M5's
  sidebar — and `ConnectionStateBridge`, a two-lane seam over `EngineClient`
  (`watchServer` plus `recoveryFailures`), supplies live truth. Engine loss
  clears truth and keeps the rows; a refused watch or a faulting lane is
  reported, never rendered as a guessed state. A reload carries live
  truth forward by serverId (the recovery lane is replay-free, so fresh
  rows would erase an unresolved pane failure), a removed bookmark keeps
  nothing, and a byte-identical replay does not re-notify. Probe truth is
  deliberately absent here: 02 §4 gives the Connections section pool
  state, and 03 §3.4 keeps the probe controller from overriding live
  connection state.
- `serverIndicatorOf` composes the one indicator per server (SEA-021).
  Connection truth that contradicts a probe result outranks it: a block,
  a failure the state explains, or — the review rounds' addition — an
  authenticated transport over any non-online result (offline or
  unknown; live truth outranks probes, 02 §4, in both directions). That
  is the audit note's fix, a green "reachable" dot no longer rendered
  beside a blocked panel (the demo's interim-list dot now composes
  through it; the regression failed on the pre-fix head). Where the
  truths do not contradict, 02 §4's tri-state probe dot stays the
  favorite row's indicator, which is what 07 §3.3 requires the interim
  list to render.
- `ConnectionsView` and the `view.connections` registered command (D21),
  in the production shell and not debug-gated: rows carry the endpoint,
  the state label, the state-associated detail one-liner, per-pane
  attribution from the recovery lane (a pool-level terminal failure rides
  the status detail with the same summary, so the lane adds attribution
  only), and for a blocked row the warning copy plus a review affordance
  wired to a seam that leads into the existing changed-key prompt path —
  absent while no composition can start a connect, the same posture as
  the panel's optional retry. A pane's terminal-failure attribution stays
  until the rows reload; clearing it on a successful pane reopen lands
  with M3's reopen flow (the only caller that can know one happened).
- Composition: `main.dart` now owns the one `FileBookmarkStore` instance,
  shared by the import command and this surface (two instances over one
  file would race their write tails), so `buildSshConfigImportSetup` takes
  the store instead of building one. The shell rebuilds its controller
  when either seam is replaced (the review round's guard: the
  startup-wiring flow can supply an engine after mounting with the same
  store). The engine seam is null in
  production: the startup-wiring slice owns the spawn, which must seed
  host-key pins and trust incidents together (item 6, audit finding A);
  until then every row reads "not connected" — the app holds no transport
  — rather than guessing at a failure.

Validation: regressions observed failing first — the blocked-outranks
regression failed on the pre-fix head, and each rail (state mapping,
outranking, detail one-liner, command registration, empty/offline list
states) re-failed under an isolated mutation of its own code; the
review rounds' connected-over-offline/unknown, engine-swap,
reload-preserves-truth, and re-notify regressions likewise failed on
the pre-fix heads. 49 new
tests: 19 controller (including a leg over a real spawned `EngineClient`,
proving the adapter consumes the real lanes, with the shutdown lane-close
asserted), 15 indicator (including the
≥ 3:1 contrast pin for every color it paints), 14 surface, 1 demo
regression. App analysis clean and 401 tests pass; core untouched
(analyze clean, import guard passes). Rootless widget captures
before/after in `tasks/m2-connection-state` (PROVENANCE.md and
SHA256SUMS.txt; tofu text — the container ships no fonts). No core
change, no pin/dependency change, no source port, no milestone close.

Declined in review: a try/catch around the `recoveryFailures` listen
(refuted in three rounds — the getter is a plain broadcast stream in
the production client and the fake; it cannot throw, broadcast streams
accept re-listeners, and a listen on the closed stream delivers
`onDone` to the graceful engine-stopped path); keying the demo's
status read by a selected server id (the demo is single-session:
status is minted and cleared with its serverId, and no cross-server
selection exists). Deferred: an open Connections pane
following a swapped engine seam — no production path swaps the seam
yet, and the lookup/provider composition belongs to the startup-wiring
slice (item 6) that will actually spawn lazily. Round 3's remaining
applies were hardening only (shared contrast math asserting opacity,
the indicator pin gaining the scrolled-under background the probe dot
already pins, a debug assert that the glyph paints no probe truth, and
test-support consistency); no behavior changed.

## M2 — engine incident/pin bridging + store hardening (2026-09-10)

Item 6's engine-protocol half lands, closing audit finding A and the three
#60 store deferrals (`tasks/run3-audit-m2-report.md`). Core only: no app
caller exists yet, so production engines still spawn an empty config.

- **Seeding is coupled (audit A).** `EngineConfig.incidents` joins
  `hostKeyPins`, and `EngineHost` seeds both from that one config: an
  in-memory incident store behind a forwarding bridge, and the verifier's
  pins. A seeded record is restored only while its
  `pinnedFingerprintSha256` names the pin at its *own* endpoint — the
  verifier's `(host, port)` lookup, never the same fingerprint pinned
  somewhere else (03 §3.2 rule 1 and §5, amended in this PR). Otherwise the
  block would outlive both of D18's escapes and leave `removeBookmark` the
  only way out: with no pin every connect verifies `firstUse`, which a
  blocked pool refuses to prompt for, and 1a's restored-key match has
  nothing to match; with a different pin the block's detail would name a
  fingerprint the store no longer holds and 1a would lift it on a key the
  record never named. Skipping costs no protection — the next connect
  re-detects against the pin store, which is the trust authority. The stale
  record is deleted only when the endpoint definitively holds a different
  pin; with no pin at all the app keeps it, because an empty pin seed is
  indistinguishable from a pin store that failed to load and erasing a
  persisted decline cannot be undone. No verdict, prompt, or crypto
  semantics changed (D18).
- **The incident bridge (03 §5, protocol v6).** Every engine-side mutation
  crosses as a typed `IncidentStoreEvent`: `IncidentRecordStoredEvent` (a
  declined changed-key block installed or re-written) and
  `IncidentRecordRemovedEvent` (endpoint-scoped for a lift or an approval,
  so a re-pointed bookmark keeps its newer record; endpoint-null for the 3a
  cascade). `EngineClient.incidentChanges` broadcasts them live and closes
  on engine death. This is the incident half of the `hostKeyPins` bridge
  with the same split — the engine decides, the app stores — and carries
  only the existing plain-data types (`IncidentRecord`, `PoolKey`).
- **`removeBookmark` crosses the port.** `RemoveBookmarkRequest` →
  `EngineClient.removeBookmark` → `EngineHost` → the manager's 3a cascade.
  The host forgets the id's config and watch in a `finally`, and the client
  closes the id's state stream: a removed bookmark can never emit again.
  Manager-side, `watchServer` now completes when its controller closes, and
  the removal drops the id's `_events`/`_lastStatuses` entries.
- **Cascade exception safety (audit F).** `removeBookmark` runs the owner
  withdrawal and the record delete in a `finally` — the app has already
  deleted the bookmark, so a thrown teardown must not strand records or
  owner stakes for an id that can never be retried.
- **1a lift's epoch guard.** The restored-key lift checks
  `_isCurrentTrustEpoch`, not only `_isCurrentPool`, so a lift clears just
  the block that existed when the attempt started — symmetric with the
  prompter's and growth's staleness checks. No production interleaving
  reaches it (first connects are serialized per pool; growth and recovery
  refuse a blocked pool), so its regression stages the invariant directly:
  one attempt that declines a changed key and then observes the pinned key.
- **#60's deferred store hardening.** `FileIncidentStore.onLoadError`
  observes load failures (an unreadable file, a quarantined corrupt one)
  without changing the fail-safe result — local diagnostics, never telemetry
  (D19) — and an observer that throws cannot break the load; write failures
  still propagate and are not load errors. The startup sweep deletes this
  file's orphaned `.tmp-*` litter, but only past a one-hour abandonment
  bound: an ungated sweep deletes a concurrent writer's temp and fails its
  write (observed — a second instance loading while the first persisted lost
  every record of that round-trip).

File locking for concurrent store instances stays deferred, now on measured
grounds rather than assumption. `dart:io`'s `RandomAccessFile.lock` needs no
new dependency, but on POSIX it is per-process: a second descriptor in the
same process locks a file the first already holds exclusively (verified),
while a child process fails with EWOULDBLOCK. It therefore cannot address
the only race the store's contract names — two *instances in one process*
over one file — which the documented single-instance contract and that
instance's serialized chain already govern. Cross-process locking would need
a separate lock file (a rename replaces the locked inode, so locking the
target cannot span a write), adding a second persisted artifact for a writer
v1 does not have: one app process (D13), one store instance built at
startup. The ported app-layer file stores lock nothing either, so locking
here would diverge from the port convention (09 §4).

Validation: twenty-four new core tests, each observed failing before its fix
(or, for the protocol seams, failing to compile before the types existed).
The audit's scratch scenario is now a regression: a restored record with no
pin comes up blocked with no prompt and no escape, and after the fix it is
dropped, deleted, and reaches the first-use review; the pin-moved-on and
no-pinned-half records re-detect through a changed-key review; a drop whose
delete fails still loads unblocked and reports to the observer; the cascade
now empties the store after a thrown teardown; a removed bookmark's watch
now completes; a mid-attempt block is no longer lifted by that attempt's
later trusted observation. Store side: the ungated sweep deleted a live temp
where the gated one spares it and still clears the abandoned litter, and the
absent sweep left the litter; the load-error observer reports corruption,
invalid UTF-8, and unreadable files. Engine side: seeded pins plus incidents
restore a block the pinned key lifts with no prompt, the decline, approval,
and cascade mirror their events, and the client's `incidentChanges`
broadcast, removal-closed watch, and shutdown closure round-trip through
spawned isolates; protocol v6 round-trips the new request, both events, and
`EngineConfig.incidents`.

Core analysis clean; 380 core tests pass (15 Docker-fixture skips — Docker
unavailable locally, so the real-sshd leg rides CI on the PR head). Import
guard (92 + scan), protocol guard (51 + scan), pin audit (9), fixture tools
(62), bench harness (79), license gate (34), and release-version (155 +
check) tests pass. App analysis clean and 352 app tests pass, unchanged: no
app file is touched (lane B owns the app-side connection-state composition).

Deliberately out of scope: the app-side composition — supplying both seeds
from the app's pin and incident stores, persisting the mirror events, and
calling `removeBookmark` from bookmark deletion — which rides production
wiring (item 3) and M5's bookmark store, since no app-side bookmark
deletion exists before it. No source port, pin, dependency, UI, release, or
milestone-close change.

Review round 1 (three applied, one applied in corrected form, two refuted
with evidence, one already satisfied): the temp sweep resolves its target
before building the prefix — a bare relative filename's parent is `.`, whose
listing yields `./name.tmp-…`, so the unresolved prefix matched nothing and
the sweep was dead code in that wiring (regression: a chdir'd basename store
sweeps an aged temp and spares a live one; observed failing without the
resolution). The protocol round-trip now carries a second incident record at
a different endpoint, so a dropped or misaligned entry fails. The removal
test asserts both mirror events, the unknown id's included. The major
finding — a throwing `_deleteStoredBookmark` skipping the fan-out teardown —
rests on a path that does not exist: `_deleteStoredBookmark` catches every
error and reports it through the guarded observer, so it cannot throw (the
STATUS line the finding cites describes `FileIncidentStore`'s own API, whose
write failures propagate to *its* callers; every manager call site catches).
The fan-out teardown moved before the awaited delete regardless — the
finding's own alternative — which drops the sequential dependency without a
nested `finally`; a new test pins that a store whose deletes throw neither
fails the removal nor strands the watch (it passes before and after the
reorder, so it is a pin, not a regression). Refuted: the "weak or hardcoded
password" at `engine_host_test.dart:72` is a socket-free fixture reply
(`'pw'`) that predates this PR and appears in some ten existing tests in the
same file — no credential, no connection, and CI's Gitleaks and
fixture-key-scope leg passes on this head. Already satisfied: the load-time
skip deletes through `store.removeFor` when the endpoint holds a different
pin (round 4 narrowed it to that case), so the app mirror converges — pinned
by "a seeded incident without its pin is skipped, not deleted".

Review round 2 (two applied, one applied as a pin, five refuted or declined
with evidence): incident seeding is now structural —
`InMemoryIncidentStore.seeded` fills the map in its constructor, so the
manager's lazy, pin-filtered load cannot read a half-seeded store even if
`put` later grows an `await`; the invariant had lived in a comment. The pin
seed keeps the unawaited-put convention because `InMemoryHostKeyStore` is
Séance's pinned class, and a missing pin fails closed (a first-use
re-prompt) where a missing record would not. The observer test asserts the
quarantine length before `.single`. A new test pins that a removal during a
parked first connect leaves nothing behind — no dial, no state, no record —
which is the evidence for the refuted race finding: `disconnectServer` drops
the pending identity synchronously, `_resolveReference` re-checks it after
its await, `_firstConnect` re-checks the epoch and its references before and
after the transport lands, `_emit` guards a closed controller, and the engine
forgets the id's config so a later connect cannot resolve one.
Refuted with evidence: `File.absolute` not stripping `..` does not defeat the
sweep — `Directory.list()` joins the unnormalized parent path it was given
(verified: `/cwd/data/../incidents.json.tmp-old` matches the prefix built
from `/cwd/data/../incidents.json`), so the suggested URI normalization would
create the mismatch it claims to fix; the observer assertions cannot race —
`_dropStaleRecord` is awaited inside `_loadIncidents`, which
`_resolveReference` awaits, and `_deleteStoredBookmark` is awaited inside
`removeBookmark`, so both report before the call returns, and `_eventually`
there would weaken a guarantee that holds; the epoch guard cannot strand an
approved-key unblock — `_blockPool` is the only site that advances the epoch,
and the approval path adopts the new epoch before awaiting the prompt, then
guards on incident identity; `IncidentRecord` and `PoolKey` are already
barrel exports, which the protocol test proves by naming both through the
barrel alone.
Declined (second raise, no new evidence): the "weak or hardcoded password" at
`engine_host_test.dart:72` — a socket-free fixture reply (`'pw'`) predating
this PR, used by some ten existing tests in the same file; CI's Gitleaks and
fixture-key-scope leg passes on this head. Declined: `pumpEventQueue` drains
in the client test — the assertions follow the file's existing convention
(the recovery-failure test asserts the same way and has been stable since
#55), and the ordering is guaranteed by port FIFO plus microtask scheduling;
pumping in one of the two would leave the file inconsistent.
Recorded for the app-side composition: the mirror must apply removals
idempotently — including for a record it just seeded, which the engine drops
when its pin is gone — and must never re-seed the engine in response.

Review round 3 (five applied, four declined or refuted with evidence):
`EngineConfig.incidents` now states that the drop rule matches the pin at the
record's *own* endpoint (the verifier's `(host, port)` lookup), never a
fingerprint found anywhere in the pin list, and a test pins it — a record
whose fingerprint is pinned only at another endpoint (a cloned machine, a
shared jump host) still drops; observed failing against a fingerprint-only
check. 03 §5 names `endpoint` instead of an ambiguous pronoun in the removal
event's cascade clause, `RemoveBookmarkRequest`'s doc states the removal is
final even when the teardown throws, the torn-write leg asserts its own
quarantine, and two subsumed round-trip assertions are gone.
Declined with recorded reasons: swallowing `disconnectServer`'s error inside
the cascade (raised as major). The finding's "an id the engine never
connected" case does not throw — `disconnectServer` returns early, pinned by
the host test's unknown-id ack — and no throw path exists on that route today
(audit F's own verification: every cleanup await there runs
`CleanupFailureMode.ignore`). The suggested `_reportIncidentStoreError`
channel is documented for *store* failures, a new removal-failure observer is
a public seam this slice's boundary excludes, and silently absorbing an
unexpected internal failure contradicts the repo's explicit-errors rule. The
`finally` already delivers audit F's guarantee, which is the part the owner
decision requires.
Refuted (second raise): the in-flight-connect race — round 2's evidence
stands and is now pinned by a test. A late host-key answer is rejected by the
prompter's own epoch and incident rechecks (the pool left `_pools`, so it is
no longer current), and the engine forgets the id's config, so a later
connect cannot resolve one. `_forgetServer`'s remaining per-id state
(`_channels`, probe targets) is audit finding C's tracked M3 scope in item 3:
probe targets are app-driven and refreshed on every bookmark-list change, and
no request maps a channelId back to a serverId.
Declined (third raise, no new evidence): the "weak or hardcoded password"
fixture literal.
No correctness, security, or contract finding is open after round 3: the two
majors are a hypothetical whose premise the code contradicts and a doc
precision fix (applied), and the rest is polish or re-litigation. Steady
state per the owner's bar.

Review round 4 (one substantive finding applied; two majors refuted; the rest
declined as polish or re-litigation): a skipped record is now deleted only
when its endpoint definitively holds a *different* pin. "No pin at all" is
indistinguishable from a pin store that failed to load — both ported file
stores read an unreadable file as empty — and the previous rule deleted the
app's persisted declines in that case: irreversible, and exactly the state
the app-side composition reaches if its pin load fails while its incident
load succeeds. The record is now skipped in memory (the endpoint stays
unblocked and reviewable, so audit finding A's fix is intact) and kept on
disk, so the block returns if the pin does. Three tests pin the split,
observed failing against the delete-on-absent rule. 03 §3.2, 03 §5, and
`EngineConfig.incidents` state the endpoint-scoped match and the two-case
delete rule.
Refuted with evidence: both "resurrection" majors. The engine's
`_servers[serverId] = request.config` runs synchronously at the top of the
open handler, before its first await, so a removal starting later removes it
and the open's continuation registers only a channelId; `_watch` is reachable
only from `WatchServerRequest`, so an open cannot re-arm a watch. In the
manager, `disconnectServer` drops the pending identity synchronously and
`_resolveReference` re-checks it after its await, so a resolve in flight is
rejected. The residual window — a *new* open arriving between
`disconnectServer` and the fan-out drop — needs the app to open a bookmark it
is concurrently deleting, ends in a bounded pool that no later open can join
(the engine forgets the config) and that its pane's close tears down, and
changes no trust state. A tombstone or per-id generation would add
never-shrinking per-id state, the growth audit finding C targets, so that
shape belongs to M3's Quick Connect design (item 3).
Declined with recorded reasons: absorbing `disconnectServer`'s error (round
3's decline stands); the re-raised `finally`-body throw
(`_withdrawIncidentStakes` and `_forgetStateFanOut` are synchronous map
operations and a closed-guarded controller add, with no throw path); the
quarantine-report reorder (`_quarantineCorruptFile` catches internally, so it
cannot mask the reported cause); the event-shape split for bulk versus scoped
removals (the
nullable endpoint mirrors `IncidentStore.removeFor`/`removeAllFor` and is the
documented protocol shape; two event types would be a new seam for no
behavioral gain); the `chmod` exit-code assertions (both tests fail loudly
without the mode change — the observer and `throwsA` assertions cannot pass
if `chmod` no-ops); the `dart format` nit (the repository is not
format-clean: 21 pre-existing core files deviate and CI has no format gate);
the two assertion-precision nits on tests whose failure modes are already
loud; and the fourth raise of the fixture-password "critical".
Steady state stands: round 4's one substantive finding is applied and no
correctness, security, or contract finding remains open.
Also applied from round 4 (doc precision, no behavior change): 03 §5's
`RemoveBookmarkRequest` copy now carries the finality-on-throw guarantee the
source doc states; `_forgetServer`'s doc says it runs from the cascade's
`finally` rather than asserting the manager finished; the bridge's bulk erase
states that a null endpoint means "every record for this serverId", never an
unmatched lookup; `IncidentStoreEvent` records that `IncidentRecord` and
`PoolKey` must stay deeply sendable and are received as snapshots;
`removeBookmark`'s interface doc says the manager keeps no tombstone, so
watching a removed id afterwards behaves like watching an id it never saw.
That last point is recorded in item 3 as audit finding C's residual: a
re-watch of a deleted id allocates a controller nothing will close, and a
tombstone is the same never-shrinking per-id state M3's lifecycle design
owns.

Review round 5 (steady state; three small applications, the rest refuted or
declined): the file store absolutizes its path at construction, so a relative
store cannot read, write, and sweep three different files if
`Directory.current` moves; a contradictory test comment is corrected (a
worker lease does prompt for a fresh changed key — what it never does is
review an inherited block); and two engine assertions are added (a trusted
connect emits no re-pin, and the accepted-change flow mirrors exactly one
re-write before the approval's delete).
Refuted with evidence: the "stale-record deletion may bypass the mirror"
major — the wired store *is* the emitting decorator (`_IncidentBridge`, in
this diff), so `_deleteStaleRecord`'s `removeFor` is what emits, pinned by "a
contradicted seeded incident is deleted and mirrored"; the suggested
`isEmpty` assertion on the accepted-change flow is wrong for the same reason
(the review attempt re-detects and re-writes before the approval deletes, now
pinned at exactly one stored event); a repeated removal, or one for an id the
engine never saw, already acks, so no retry wrapper can draw a spurious
failure; `SendPort.send` returns false rather than throwing for a dead port,
so the bridge cannot desynchronize its local state from its report; and the
second record in the pin-moved-on test is dropped for its own null pinned
half against a pin that exists, not for sharing the first record's endpoint.
Declined with recorded reasons: the third raise of the removal/open
interleaving (rounds 2-4 stand, and the fix needs never-shrinking per-id
state); an `isBulkErase` getter on the removal event (a new public member on
a protocol type against a hypothetical mirror bug, with the semantics already
stated in the event class, at the producer, and in 03 §5 — and no mirror
exists yet); the `Directory.current` test-hygiene note (saved and restored in
`addTearDown`, `dart test` runs each file in its own isolate, and the file's
other tests use absolute temp paths); spawning the real engine in the
stream-closure test (it matches its sibling and exercises the production
spawn path); the fixture error message (matches the sibling fixture's
convention); and the fifth raise of the fixture-password "critical".
After five rounds no correctness, security, or contract finding is open, and
the last two rounds produced only polish and re-litigation: steady state per
the owner's bar.

## M2 — PORTS full re-diff sweep (2026-09-10)

Close-prep evidence work for 07 §3.12's PORTS chore — **not a
milestone-close claim**: startup wiring is still pending and the chore
runs again at M2 close. Task 6's incident/pin engine bridging
([PR #66](https://github.com/L-K-M/Poltergeist/pull/66)) merged while
this sweep was in review (merge `d853aa8`); it changed no ported source
or PORTS entry — the #66 citations in PORTS were added by this sweep as
context, not by #66 — so no entry needed a task-6 re-diff marker.

Method: every PORTS entry re-diffed against the pinned Séance tree
(`2e6d1f1`, full non-shallow worktree — recorded-revision → pin source
drift plus local-port ↔ pin diffs; evidence saved under
`tasks/run3-task8-*`, not committed), and `tool/seance_pin_audit` re-run
in verify mode (matches the recorded block). No pin or lock change.

Outcomes: 20 entries swept, 18 re-diff clean, 2 stale records corrected
in PORTS with the PR that changed each cited. Clean: all sixteen file
entries (every recorded Séance revision verified against its claimed
content, every recorded divergence still present in the local port, the
four recorded source moves verified; no ported file changed locally
since #52's already-recorded gate mirror), the real-sshd consumption
note, and the pin findings. Corrected: the probe prerequisite's open
tail — interim dots, persistence, lifecycle forwarding, and composition
landed in #62, connection-state composition in #67 — and the cleanup
dependency's `2f99f4e` pin reference (the consumed file is unchanged
through the #35/#53 bumps to `2e6d1f1`). Open candidates re-verified
open against the pin and upstream HEAD (`b8fc111`, 2026-09-09): the
RFC 4256 echo bit is still dropped in the responder, the identity read
still catches only `FileSystemException` with an unbounded audit write,
the log view still has no newest-line anchoring, and the
mounted-harness, Enter-navigation, and autofocus-test candidates remain
upstream-absent. Owner-gated candidates unchanged.

Recorded follow-up (not fixed in this docs-only sweep): four ported
files lack the 09 §4 attribution header — `identity_file_reader.dart`,
both prompt-dialog test files, and `identity_file_reader_test.dart`.
No milestone-close claim, no production change, no pin/lock change.

## M2 — startup engine-spawn composition (2026-09-10)

Item 3's final production-wiring slice and item 6's app-side half: the
engine spawns once at app startup — not debug-gated — with the app-owned
persistence seeded, and every composed surface consumes that one engine.

- **`EngineSession` (app/services/engine_session.dart)** owns the
  long-lived engine: `startEngineSession` reads the app-owned pin store
  (`<support>/host_keys.json`) and incident store
  (`<support>/incidents.json`) and spawns through `EngineConfig` with
  both seeds in one message (audit finding A's coupling — an incident
  never crosses without the pin list it names; each store read is
  fail-safe by its own contract, so unreadable storage seeds empty and
  never blocks boot). Spawn failure reports and returns null: the app
  still runs with every surface reading "no engine" rather than failing
  to boot. The `AppEngine` facet keeps production code off the concrete
  client; the mirrors subscribe at construction (subscribe-before-send,
  03 §5): every `HostKeyPinnedEvent` persists to the pin store (writes
  serialized through one tail — the ported file store does not
  serialize internally) and every `IncidentStoreEvent` persists through
  the incident store's own chain — stored records upsert, scoped
  removals apply `removeFor`, bulk removals `removeAllFor`, all
  idempotent, and no mirror ever sends back to the engine (the engine
  decides, the app stores — a mirrored event can never re-seed).
- **Prompts and the review affordance.** The session starts the one
  `PromptCoordinator` for the engine (a second subscriber would render
  every prompt twice) on the app's root navigator — `main.dart` shares
  one `GlobalKey` between `MaterialApp` and the coordinator — with the
  audited `IdentityFileReader` wired so an imported IdentityFile
  bookmark's credential prompt can read its key (the vault/master-key
  flow stays unwired and open, below). The Connections surface's
  blocked-review affordance is now live: `reviewBlockedHostKey` resolves
  the bookmark through the store, opens a review connect under the
  `review` pane-tab id, and lets the pool raise the changed-key prompt
  (prompting enabled, D18); approval persists through the mirrors,
  decline stays visible on the row's state lane (not reported as a
  fault), and the reference is always dropped — a review is not a
  session.
- **Lifecycle.** `PoltergeistApp` (now stateful) attaches an
  `AppLifecycleListener` forwarding to the session; `detached` — the
  final lifecycle event on desktop, delivered best-effort at exit —
  triggers the idempotent orderly shutdown (coordinator disposed,
  mirrors cancelled fire-and-forget, engine stopped), and
  `onExitRequested` is wired for the window-close path — where platform
  delivery of `detached` is not guaranteed — flushing the pending
  mirror writes best-effort first: a failed flush is reported and never
  blocks the exit. A missed event is safe (the process dies with its
  sockets) and a repeated one is a no-op. The session forwards nothing else: it owns no probe activity
  (the demo session remains the only probe initiator, 03 §3.4;
  durable-favorite targets await M3/M5's connect flow).
- **Demo reuse (one engine per process).** The debug demo reuses the
  production engine: `SftpDemoController` gains an explicit
  `SftpDemoEngineOwnership` mode — `sessionOwned` (the old posture:
  teardown shuts the engine down; tests and a spawn-failed boot keep it)
  or `shared` (teardown closes only the session's own channel and server
  reference; the shared adapter's `shutdown` throws `UnsupportedError`
  as an unreachable-by-contract guard). The demo also consumes the
  session's coordinator instead of constructing its own (one coordinator
  per engine), so its prompts render on the root navigator above the
  demo route; the shell prefers `session.demoEngineFactory` over any
  injected factory while a session lives. The alternative — a separate
  demo engine — was rejected because the production spawn is
  unconditional, so it would double engines per process.
- No new per-server maps anywhere (audit finding C): the session holds
  streams and single-slot state only.

Validation: both new suites were observed failing to compile before the
seams existed
(`tasks/run3-task9-logs/regressions-fail-first.txt`);
13 `engine_session_test` cases (seeding together, spawn-fail null,
subscribe-before-return, pin/incident persistence and idempotent
removals over real files, detach shutdown and idempotency, review
open/close/disconnect/decline/unknown-id/coordinator routing, and
demo-facet routing to the same engine) and 5
`production_engine_wiring_test` cases (Connections live against the
production engine with the demo disabled, the review dialog rendering
from the production surface, the demo reusing the session engine with a
sentinel factory never called and no shutdown on close, demo prompts
rendering through the shared coordinator, and app-detach shutdown).
Fake-async quirks were test-side, not production: real-IO store
construction inside `testWidgets` hangs (widget tests inject the
in-memory stores), and a store instance caches its first load, so
persistence assertions poll the file before reading it back. A
review-suggested awaited tail-flush inside `EngineSession.shutdown`
was declined on reproduced evidence: an awaited instance-field
future as the closure's first suspension deadlocks flutter_test's
teardown zone (the identical test passes without the await and hangs
with it), and no production exit path awaits that future anyway. App
analysis clean, 419 tests pass (18 new); core untouched (analyze clean,
380 tests, 15 Docker-fixture skips — the real-sshd legs ride CI on the
PR head); the import guard passes. No layout change (the review button
already shipped inside the Connections surface), so no captures.

Deliberately out of scope: the vault/master-key startup flow (the
coordinator runs vault-less; credential prompts always render the
dialog), production probe targets (no favorite-connect flow exists to
mark bookmarks seen; M3/M5 own it), `removeBookmark` from bookmark
deletion (no deletion UI before M5), M5's sidebar, M4's transfers, and
any milestone-close claim. Two review-declined seams are recorded for
their future owners: the demo session's probe teardown leaves the
shared engine's probe activity paused with no targets (inert today —
nothing else drives probes; the production probe owner must own the
activity state when it lands), and the review's teardown drops the
bookmark id's engine reference via `disconnectServer` (correct today —
the review is the only reference holder; M3's pane references share
the serverId and must own that decision). No core change, no
pin/dependency change, no source port, no release.

## M2 — v0.2.0 release rehearsal (2026-09-11)

The 07 §3.12 tag chore ran `scripts/release.sh 0.2.0` (lkm-release 1.0.0;
prerequisites verified: clean main at `7151cdd` with CI green — run
34559623524). The version commit `5f8ed9a` bumped the three versioned
pubspecs, the app lock, Apple metadata, and the README line in lockstep
with no unrelated changes; the Séance pin stayed `2e6d1f1`. Tag `v0.2.0`
created annotated, no signer (D23); branch + tag pushed.

The tag triggered [release run 34560964912](https://github.com/L-K-M/Poltergeist/actions/runs/34560964912).
Per-leg outcomes:

- Test (release gate): success (04:06:50 → 04:08:21Z).
- Client legs, all five success: linux (→ 04:10:43Z), macos (→
  04:11:49Z), windows (→ 04:12:52Z), ios (→ 04:12:56Z), android (→
  04:13:41Z).
- Leg-race watch (open item 4's watch clause): the linux leg created release 386780359
  at 04:10:37Z; macos, ios, windows, and android each briefly created a
  duplicate draft, which action-gh-release v2 detected and removed
  ("Using release 386780359 … instead of duplicate draft …", "Removing
  duplicate draft release …"). Exactly one release object survived
  (`gh release list` shows no duplicate). Single ownership held
  end-state, but the created-once guarantee inside one run rests on the
  action's own duplicate-draft cleanup — the tag-keyed concurrency group
  serializes runs, never legs within a run.
- Checksums: the rehearsal-floor check passed (APK + .deb + AppImage +
  bundle), SHA256SUMS was computed over the seven assets and uploaded,
  and the notes (D23 labels + sums) attached — then the publish step
  **failed**: `gh release ready` is not a gh subcommand ("unknown
  command \"ready\" for \"gh release\""; the real command is
  `gh release edit "$RELEASE_TAG" --draft=false`). The fail-loud probe behaved as
  designed: the run went red instead of silently leaving an unpublished
  draft.

Where it stopped: the release is a **hidden draft** ([v0.2.0](https://github.com/L-K-M/Poltergeist/releases/tag/v0.2.0))
with all eight assets and the correct notes attached — not published
(public asset URLs 404). Authenticated spot-check:
`poltergeist-linux-x64.tar.gz` (10,595,049 bytes) recomputes OK against
the attached SHA256SUMS. No retry was attempted: the failure is a
workflow bug, not transient. Recovery per D23 ("a failed run leaves
only an invisible draft: delete it, re-run"): fix the publish step
(open item 8), delete the hidden draft, re-run via `workflow_dispatch`
with tag `v0.2.0` dispatched from a ref that carries the fix — the tag
itself still holds the buggy workflow file, so dispatching the tag ref
would reproduce the failure, and the draft must be deleted first — the
created-once guard refuses while a draft for the tag exists.
M2 closed
with the publish (dated close section below); install-tested-asset QA
(07 §3.13 / v1.0 bar) and the 07 §4 APK in-place-upgrade rehearsal
remain open regardless.

## M2 — closed: v0.2.0 published (2026-09-11)

The rehearsal's publish-step bug (item 8, now closed) was fixed in
[PR #72](https://github.com/L-K-M/Poltergeist/pull/72) (merge
`c96681d`): the publish step now calls
`gh release edit "$RELEASE_TAG" --draft=false` — the gh manual's
documented publish-a-draft mechanism — with a post-publish `isDraft`
re-probe that fails loud on a silent no-op, and both `actions/checkout`
steps pin the resolved ref (an existing tag checks out itself; a
dispatch-created tag falls back to the dispatched commit), so a
dispatch from the fixed ref builds the tag's own commit. The guard
suite in `tool/release_version/test/release_workflow_test.dart` was
updated regression-first: three tests went red against the unfixed
workflow — including a dry-run reproduction of the rehearsal's
`unknown command "ready"` failure — and pass after the fix. Two
review rounds applied seven test/hardening items and declined or refuted
the rest (triage in the PR description); a third round found nothing
(steady state).

Recovery per D23: the hidden draft was deleted (release object only —
tag v0.2.0 untouched at `5f8ed9a`, no `--cleanup-tag`), then
release.yml was dispatched from `main` at the fix merge with tag input
v0.2.0: run
[34572521676](https://github.com/L-K-M/Poltergeist/actions/runs/34572521676)
— the test gate (checkout-ref resolution found the existing tag, so
the built commit equals the tag commit and the version gate passed on
the exact tag tree), all five client legs, and the checksums job
including the fixed publish step all green. Leg-race watch (open item
4's clause): the same shape as the rehearsal — four transient duplicate
drafts auto-removed by action-gh-release, one surviving release
(386841889); no new anomaly.

Publish verification: the release is public as a pre-release
(unauthenticated release page returns 200, `isDraft` false,
`isPrerelease` true), the asset set is complete (8 assets: APK, .deb,
AppImage, Linux tarball, macOS zip, Windows zip, unsigned IPA,
SHA256SUMS), and the spot-check recomputes —
`poltergeist-linux-x64.tar.gz` (10,594,801 bytes), downloaded
unauthenticated, hashes to
`0403867aabc479ab9b0fedc2a4ad47df2cc71ca7ed84d1fc02e03a9b7e0c3771`,
matching SHA256SUMS.

## M3 — LocalFileSystem, the one VFS's local half (2026-09-11)

M3's first slice (07 §3.4 scope bullet 1): `LocalFileSystem implements
RemoteFileSystem` in `poltergeist_core/lib/src/fs/local_file_system.dart`
— a second implementation of the pinned interface (D3; never a wrapper,
never a second abstraction). The pin (`2e6d1f1`) already contains
PR-S3, so `setTimes`, `setOwner`, and `computeHash` are plain interface
overrides from day one — no `// TODO(pin)` markers, no concrete-method
bridge. The full contract: `canonicalize` (`resolveSymbolicLinks`,
falling back to the normalized absolute path for missing paths — never
an error; `~` expands through the pinned `expandHomePath` with a
constructor-injected environment), `listDirectory`
(`followLinks: false`, links reported as links with null metadata,
never statted), `stat` (both link modes), `setMode`/`setOwner`
(`Process.run` chmod/chown with `--`, `LC_ALL=C` over the injected
environment, trailing-stderr-segment exit mapping — `Operation not
permitted`/`Permission denied` → permissionDenied, `No such file or
directory` → notFound — never a substring match), `setTimes`
(`setLastModified`/`setLastAccessed`), `readSymbolicLink`,
`createSymbolicLink`, `createDirectory`, `rename` (destination-lstat
preflight, D26 case-only two-step via a unique sibling,
type-dispatched renames — dart:io's File/Directory/Link renames refuse
the wrong type), `delete` (one entry, no recursion, Séance's non-empty
directory wording), and the `download`/`upload` integrity protocols
mirroring the pinned adapter (double-stat snapshots ⇒ conflict, short
reads ⇒ conflict, exclusive `.poltergeist-<8 hex>.tmp` sibling with
regenerate-on-collision, sticky cancellation raced against every
pull, declared-length verification, `expectedTarget` CAS including the
digest re-read, commit via the backup-rename dance — never
delete-then-rename — and temp cleanup on every failure path). One
funnel maps every dart:io failure to the pinned typed taxonomy
(ENOENT/EEXIST/EACCES/EPERM and the Win32 code set incl.
ERROR_SHARING_VIOLATION → "file is in use by another process"), with
the adapter's `Could not <op> "<path>": <detail>` message shape and
precondition failures (RangeError/ArgumentError/FormatException)
throwing raw, like the adapter's own early checks.

Safety rails beyond the table rows, all test-pinned: attribute writes
refuse symlinks first (lstat-style) and re-stat after the write — a
path swapped to a symlink mid-write fails as
`LocalPathTypeChangedException` carrying the dereferenced landing
path, never `conflict` (the pinned enum has no `pathTypeChanged`
member; the subclass carries the distinctness — recorded in a same-PR
03 §2.2 precision edit); upload validates the destination leaf name
(empty/`.`/`..`/`/`/`\`/NUL plus the Windows hazards: reserved device
names by base segment incl. CONIN$/CONOUT$, forbidden characters,
trailing dot/space) before touching the disk; the commit dance refuses
to replace links/non-regular targets and fails when the backup name
would exceed NAME_MAX. Two same-PR 03 §2.2 precision edits record
verified code reality: dart:io cannot set a directory's timestamps on
any platform (EISDIR on POSIX, not utimensat — Dart 3.13), so
`setTimes` throws the typed `unsupported` for every non-regular
target (directories, FIFOs, sockets, device nodes — dart:io's
open-for-writing would block forever on a FIFO); and the
`pathTypeChanged` representation above.

The §2.3 public helpers (`replaceLocalFile`, `ensureSafeLocalDirectory`,
`validateLocalName`, `validatePathComponent` in `local_fs_safety.dart`,
with Séance's tests and PORTS entries) are **not** in this slice — this
PR is original code only, so PORTS.md is unchanged. Upload's commit
dance and leaf-name validation are private in-class implementations
following §2.3's spec; the port replaces them (open item 9).

Validation: 88 dedicated tests over a temp-dir fixture — every method,
the error taxonomy (kind + message shape per operation), symlink
cases (list/stat/report/refuse/no-follow-down/download/link-rename),
path-traversal rejection at the upload boundary, chmod/chown exit
mapping through PATH-injected fake binaries (including the
trailing-segment rule pinned against a file legally named `Operation
not permitted`), the mid-write swap → `LocalPathTypeChangedException`,
mid-download/mid-upload conflict and CAS cases via deterministic
mutation seams, cancellation before/mid-stream with temp cleanup,
case-only rename vs. same-lowercase distinct entries, and the
NAME_MAX backup guard. Regression-first: the download-missing taxonomy
bug (a missing path read `unsupported` before `notFound`) was observed
failing as `unsupported` in the suite and fixed to `notFound` — pinned
adapter parity. Full core suite 468 green (+15 Docker-fixture skips,
Docker unavailable locally); core analyze clean; import guard (92 +
repo scan) and protocol guard (51) green; app untouched but re-verified
(analyze clean, 422 tests) since the barrel and core deps changed —
`crypto` and `path` are new direct core dependencies (03 §1's
sanctioned set; both already resolved at identical shas in every lock,
no resolution drift). CI green on the PR head. No UI (screenshots ride
the slice that first renders panes), no engine wiring (the seam to
mount a local pane rides the PaneController slice), no bookmarks, no
milestone-close claim.

## M3 — local-safety helpers ported public (2026-09-11)

STATUS item 9 closed: 03 §2.3's port landed. The four statics left
Séance's `RemoteFilesController` at the pin (`2e6d1f1`) and became
public top-level functions in
`poltergeist_core/lib/src/fs/local_fs_safety.dart`, exported from the
barrel — `validatePathComponent`, `validateLocalName`,
`ensureSafeLocalDirectory`, `replaceLocalFile` — plus the
plan-mandated crash-recovery sweep `restoreOrphanedLocalBackups`
(restores an orphaned `<name>.poltergeist-<8 hex>.backup` whose target
is absent; run by `replaceLocalFile` before its dance and callable as
a startup sweep; several orphans for one absent target resolve
newest-mtime-first, losers stay parked, never deleted).
`LocalFileSystem`'s commit/validation paths now call the public port
and the private in-class originals are deleted (one implementation,
four eventual call sites — the transfer queue's download executor, the
checkout store, and the sync executor still own theirs as they land,
M4/M7/M8). The helpers stay below the VFS taxonomy by design: raw
`FormatException` preconditions and `FileSystemException` refusals,
funneled by each caller — `upload`/`rename` failures now arrive as the
standard `Could not <op> "<path>"` shape instead of the private
copies' bespoke `Could not replace` messages (kind `other` unchanged,
pinned by the existing suite).

Regression-first finds: the pre-port original's Windows reserved-name
regex carried dead branches — `\$` in the non-raw pattern string
decodes to a bare `$`, an anchor inside the alternation, so `CLOCK$`,
`CONIN$`, and `CONOUT$` were never rejected although 03 §2.3 and
09 §3.5 name them. Three new tests failed before the raw-string
repair and pass after. The port also replaces the original's raw
control bytes (a literal NUL/0x1F/0x7F inside the forbidden-char
regex — the bytes that made grep read the file as binary) with proper
escapes.

Séance-test parity per 08 §2: the only upstream coverage of the
statics is the download half of `remote_files_controller_test.dart`'s
'recursively uploads and downloads directories with aggregate
transfer' — ported re-homed to the public helpers (the controller-level
bookkeeping rides M4's queue), with the upstream source cited in the
test. Séance has no dedicated statics suites; the remaining coverage
(validators, containment walk, dance refusals/restore, NAME_MAX,
sweep) is new and local. PORTS.md carries an entry per ported file
including the full divergence list (public split, one-path
`ensureSafeLocalDirectory` signature, `.poltergeist-<8 hex>` backup
shape, NAME_MAX guard, backslash rejection, the extended reserved
list, the sweep) and the port-back candidates.

Validation (current through review round 10; round 10 changed no
counts): 63 dedicated tests;
full core suite 536 green (+15
Docker-fixture skips, Docker unavailable locally); core analyze clean;
import guard (92 + repo scan), protocol guard (51), license gate (34),
release-version guard (156), and the Séance pin audit (9) green. No
app change, no engine protocol change, no pin change, no new
dependency, no milestone-close claim.

Review round 1 (all applied or refuted with evidence): applied the
sweep's per-orphan resilience — one locked/permission-denied/vanished
orphan stays parked for the next pass instead of aborting the
remaining restores (regression: a read-only directory makes every
rename fail EACCES after the listing; observed failing with the
abort, passing after; the reviewer's suggested ENAMETOOLONG fixture
is unconstructible on a NAME_MAX-255 volume — the orphan's own name
embeds the target's, so it cannot exist long enough to fail its
rename) — plus the sweep's stat moved off the synchronous static
(round 2 finished this: `await entity.stat()`, the async instance
future — round 1 had merely put an await in front of the sync
`FileStat.stat`), `on Object` narrowed to
`on FileSystemException` at the three best-effort guards (programming
errors surface again), the two validator regexes hoisted to top-level
finals, the reserved-shape convention documented on the sweep, and
the lone-surrogate encoding comments corrected in both files (Dart's
encoder substitutes U+FFFD — `ef bf bd`, verified by run — not
WTF-8; three bytes either way, so the guard's arithmetic stands).
Test hardening applied: the symlink-traversal fixture now targets a
directory (a file target cannot distinguish the no-follow check from
the non-directory refusal), the newest-wins fixture opposes hex order
to mtime so name-based selection fails, and the surrogate overflow
test pins the guard's message. Refuted: the "second finally cleans
`partial`" claim — the committed head already reads `again` at that
line (the suggestion anchored on the first branch's line-390 text).

Review round 2 (both majors applied — genuine correctness findings):
`replaceLocalFile` now validates the target's basename like every
locally materialized name (09 §3.5; the commit point is the
leaf-level twin of the walk's per-component check — regression:
'aux'/'NUL.txt'/'x.txt ' targets reject before any IO, observed
failing first), and the pre-dance repair is scoped to the replace's
own target — a directory-wide repair inside a replace could consume a
concurrent dance's live backup (its target is absent precisely between
the two renames) and, on Windows, fail that transfer under M4's
parallel queue (regression: another target's parked backup survives a
replace untouched, observed failing first; same-target repair and the
unfiltered startup sweep unchanged). A same-PR 03 §2.3 precision edit
records both rules. Also applied: `await entity.stat()` (the round-1
fix had left the *synchronous* `FileStat.stat` behind an await —
round 1's STATUS note overstated it), the backup pattern derived from
the constants that build backup names, the read-only-dir test's
root bail moved before the chmod as a `markTestSkipped`, the
NAME_MAX=255 premise documented on both overflow tests, `id`-less
hosts read as non-root, and the symlinked-ancestor refusal (macOS
`/tmp`) documented on the walk. Declined: the subdirectory
continuation fixture — the sweep is non-recursive, so it cannot
observe iteration-past-failure in a writable directory (any name
creatable as an orphan is creatable as its target); the no-throw
contract is pinned and the limitation documented in the test.

Review round 3 (all applied — the round's one major was a genuine
coverage gap): the rollback fixture now stages its part inside a
read-only sibling directory so the commit rename fails with EACCES
deterministically *after* the backup exists — the merely-missing-part
fixture could be satisfied by a future part pre-flight without ever
reaching the rollback branch (verified: the test fails with the
rollback disabled and passes restored; root hosts skip — mode bits
cannot deny there). The validators now reject components over NAME_MAX
bytes (255 UTF-8 bytes, observed failing first — ASCII and two-byte
boundaries both pinned; 03 §2.3's validator bullet records the rule)
so an over-long server-reported name fails at the boundary instead of
mid-transfer as an opaque ENAMETOOLONG. The sweep keeps a failed
target's older orphans parked too — restoring an older generation
after the newest failed to rename would strand the newest data
forever (the target would then exist, so no later sweep repairs it);
the failure-path fixture is unconstructible on POSIX (same class as
round 2's declined item) and the invariant is documented. The lexical
`.`/`..`/separator rejection in the walk now reports 'Refusing to
traverse an unsafe path component' — a static shape rejection, not a
symlink observation. The stale lead sentence in 03 §2.3 ("the next
touch of that directory") now reads "the next replace of that same
file", matching the scoped repair the round-2 precision note records.
Test hygiene: both fixture chmods check their exit code. PORTS.md's
backup-shape divergence line now spells the `.backup` suffix on both
sides.

Review round 4 (steady state — no confirmed correctness, security, or
contract finding; one worthwhile hardening applied): the dance now
refuses a non-regular *part* symmetrically with its target refusal —
rename moves a swapped-in symlink without following it, so the dance
would have installed the link as the user's file (regression verified
red with the check disabled, green restored; no current call site can
stage a non-regular part — upload's exclusive create — so this is
prophylactic at a public boundary). The sweep doc records its
check-then-rename advisory posture (dart:io has no no-clobber
rename), and 03 §2.3's sentence ends "before that replace's dance
begins" — removing the circular "any new replace" reading. Refuted:
the NAME_MAX-overhead claim (the 228–255-byte range is exactly what
the backup-name guard exists for — it fails the replace before any
rename, pinned by the overflow and surrogate tests; rejecting those
names in `validateLocalName` would break the plan's own documented
behavior) and the "predictable PRNG" claim (`Random.secure()` is
right there). Declined: no-clobber rename (no dart:io primitive; the
same accepted race as 03 §2.2's rename preflight, now documented on
the sweep), running the validator groups on Windows (the suite-wide
skip matches the sibling LocalFileSystem suite and CI's Ubuntu-only
core job — open item 1 owns the OS matrix), dropping the walk's
backslash shape check (09 §3.5 rejects `\` for every destination by
rule; the split-dead Windows half is harmless), chmod-absent-host
probes (the suite's POSIX-toolchain premise is the sibling
convention), and the legitimately-shaped-filename collision (the
reserved-shape convention from round 2 records the residual).

Review round 5 (three majors applied — including a macOS defect the
round-3 info suggestion had introduced): the walk's root guidance
now tells callers to resolve the existing portion first
(`resolveSymbolicLinksSync`) — `Directory.systemTemp` itself starts
at a symlinked component on macOS (`/tmp` or `/var/folders/...`) and
the strict walk rejects it unresolved; the round-3 wording had
recommended exactly what the walk refuses (the test fixtures now
resolve their temp root, so the suite runs on macOS too). The sweep's
listing and stat are guarded like its renames — a missing/unreadable/
mid-sweep-deleted directory repairs what was collected and never
throws the startup pass (regression: sweeping a never-created
directory is a quiet no-op), and a vanished entry's notFound stat
(with its epoch mtime) is skipped instead of polluting the ordering.
The surrogate overflow fixture is sized to discriminate: 226 code
units (254 with the 28-byte suffix — passes a wrong code-unit guard)
but 228 UTF-8 bytes (256 — trips the byte guard); verified red
against a code-unit-counting implementation and green against the
real one. The sweep's equal-mtime tie behavior (arbitrary under
non-stable sort; no portable rename-recency signal) is documented.
Declined: having the sweep delete backups whose target exists (the
reclaim suggestion escalates the recorded false-positive collision
from relocation to data loss, and the sweep never deletes by design
— D15's posture; accumulation is one invisible leftover per crash
under the `*.poltergeist-*` ignore rules) and the friendlier
create-once refusal message for 228–255-byte names (the refusal is
03 §2.3's documented behavior and the message already names the
limit).

Review round 6 (minor/info only — no correctness, security, or
contract finding): the dance now redraws a colliding backup name
instead of letting rename(2) clobber a parked backup (~2⁻³² per
operation, but permanent loss of a crash-recovery copy; the redraw
has no deterministic fixture — the generator is `Random.secure()`
behind no seam — and is verified by inspection plus the unchanged
suite). The no-concurrent-dance precondition is now stated as a
contract on every caller of the exported sweep (03 §2.3 and the
function doc), same-target concurrency is documented as the
caller's to serialize, and durability is scoped to process crashes
(power-loss ordering rides the filesystem's rename journaling).
Test tidy: the chmod restriction fixture is deduplicated into
`restrictModeBitsForTest`, and the newest-wins test asserts the
winning orphan was consumed. Declined: the auto-resolving
`resolvedRoot` helper — resolving the longest existing ancestor
resolves exactly the component a planted symlink occupies, silently
defeating the containment walk; the trust decision stays with the
caller (doc guidance from round 5).

Review round 7 (the major closes the reserved-namespace residual at
its root): `validateLocalName` now refuses names matching the dance's
reserved `<name>.poltergeist-<8 hex>.backup` shape — rounds 4–5 had
left the collision "reserved by convention" only, so a
server-reported name of exactly that shape could land on disk and be
hijacked (target absent) or stranded (target present) by a
directory-wide sweep; the rejection is enforced where untrusted names
enter, and the commit point inherits it (`replaceLocalFile` refuses
such targets; regressions observed failing first, benign look-alikes
— plain `.backup` names, non-hex suffixes, the empty-prefix form —
pinned as passing). The NAME_MAX cap moved to `validatePathComponent`
so both validators genuinely enforce it (03 §2.3 and PORTS wording
now match the code), the backup-collision redraw probe uses the
no-follow `FileSystemEntity.type` (consistent with every other probe;
no deterministic fixture — same generator-seam limitation as round
6), and `_uidIsRoot` checks `id`'s exit code. Declined: the
parked-backup litter assertion (the test's direct survival check is
strictly stronger — the parked backup is legitimate litter by the
helper's definition) and the NAME_MAX ≥ 250 host-probe re-raise
(round 4 recorded the documented premise; CI and dev hosts are
ext4/APFS/tmpfs).

Review round 8 (refuted major; polish and consistency applied): the
claimed root/Windows failure of the EACCES tests is already guarded
— `restrictModeBitsForTest` calls `markTestSkipped` before its chmod
when running as root, and the whole library skips Windows via
`@OnPlatform`. Applied: the backup NAME_MAX check is hoisted to fail
fast before any repair/probe I/O (the fixed-width ASCII suffix makes
it draw-independent; same message, outcomes unchanged), the backup
path is derived via basename/dirname instead of raw concatenation (a
trailing-separator target can never park the backup inside the
directory the sweep scans), equal-mtime orphans break ties
deterministically by name (recency stays unknowable; the choice no
longer varies run-to-run under unstable `List.sort`), the fast-path
rename's external-creator window is documented as 03 §2.2's accepted
rename race, the primary replace test asserts the part was consumed
(a copy-based regression would now fail), and one test title no
longer claims an ordering it does not verify. Declined: the sweep
returning a repair count — no caller exists yet, and the M4
startup-sweep integration owns the reporting shape it needs then
(additive if wanted).

Review round 9 (steady state declared — no correctness, security, or
contract finding; two consecutive such rounds): three re-raises of
round-8 refutations (root/Windows behavior of the EACCES and
symlink fixtures — `markTestSkipped` reports the skip; the library
skips Windows wholesale) and six polish items declined with reasons
in the PR description (part-vanished message wording, draw-site
dedup, two hardening-only asserts, the counts-placement reading —
clarified — and subdirectory-nested orphan coverage, re-anchored to
round 2's non-recursive-by-design record). No code change.

Review round 10 (one confirmed major — streak reset): the pre-dance
repair now runs only when the target is absent. With the target
present, the scoped sweep is provably a functional no-op (its
restore loop skips existing targets) whose only effect was an
O(entries) directory listing per replace — O(n²) across an n-file
sync commit on the shared M4/M7/M8 path; after a successful repair
the type is re-probed so a restored orphan flows into the normal
dance instead of the plain-rename branch. The full suite passes
unchanged (no test depended on a sweep under an existing target);
the residual per-replace listing for bulk first-time creates is
recorded as an M8 measurement note. 03 §2.3's
`ensureSafeLocalDirectory` bullet now carries the caller-side
resolve-first obligation (the round-5/6 trust decision, in the
canonical text). Declined: the recursive-sweep test re-raise
(non-recursive by design, rounds 2/5/9; the startup sweep's
traversal shape is M4's), the validator/sweep hex-parity pins (both
sides consult the same `_backupNamePattern` object — parity is by
construction, not coincidence), and the `id`-less-root re-raise
(rounds 4/7 records; the suite's POSIX-toolchain premise). 

Review round 11 (steady state per 09 §7(b) — re-raises without new
evidence, plus ledger nits): the major re-raises enforcing the
sweep's documented no-dance precondition at runtime (round 4
declined the no-clobber primitive — dart:io has none — and round 6
recorded the precondition on every caller and in 03 §2.3); the
minors re-raise the Windows library skip (rounds 4/8/9), the root
assumptions (rounds 8/9/10), the stale-backup reclaim (round 5),
and the empty-prefix parity (round 10's same-RegExp construction).
New-but-declined: rolling back a partially created tree on a
mid-walk validation failure (Séance parity — the port source leaves
created prefixes; callers own cleanup), control-character escaping
in messages, and a Windows MAX_PATH cap (no v1 surface). Applied:
the PORTS divergence heading now names the rounds it spans and the
STATUS validation parenthetical tracks round 10.

## M3 — engine-side local browse seam (2026-09-11)

STATUS item 11 closed: the engine protocol (v7) gained
`OpenLocalBrowseChannelRequest` — a local variant of the browse-channel
open carrying only the root path (no `ServerConfig`, no pool,
no server-state surface; the engine canonicalizes the root with 03
§2.2's realpath semantics, `~` expanding through its environment) and
answering the existing `BrowseChannelOpened`/`CloseBrowseChannelRequest`/
`ListDirectoryRequest` shapes on the same channel-id space, so listing,
closing, and the closed-channel error taxonomy are additive and unchanged.
Recorded contract (review round 1, made explicit in the request's doc):
the root is the channel's initial home, not a sandbox — like pool
channels, listings may navigate to any absolute path, the user's OS
permissions bound the reach, and confinement belongs to 03 §7.2's
app-side `ScopedPathAccess` seam (v1 desktop grants pass-through),
never to this request. Round 3 added the open-failure contract: only a
missing root is guaranteed to open (`notFound` at first listing); a
root under an unreadable ancestor fails the open itself, typed
`permissionDenied` operation `resolve` through the local funnel.
`EngineHost` mounts a `_LocalPaneChannel implements PaneChannel` backed by
a `LocalFileSystem` instance the engine owns (03 §5's ownership table;
D8 — no app-side dart:io, no second engine): the pool's existing
`_listDirectory` plumbing serves it, `reportFailure` is a no-op (local
failures are terminal facts — the funnel never produces the
`disconnected` kind recovery keys on), close is idempotent and retires
the engine's reference, and shutdown closes local channels directly
(the seam 03 §7.5's directory watchers clean up through when they land).
`EngineClient.openLocalChannel` returns the same `EngineBrowseChannel`
facade as `openBrowseChannel`, so panes list and close identically;
no watch surface exists to subscribe to, consistent with a local pane
not being a connection. Directory watching, per-location view prefs,
and the rest of 07 §3.4 stay with their own slices; the pane slice
resumes against this facade.

Validation (failing-first: the new-surface tests failed to compile
before the implementation landed): protocol round-trips through a
spawned isolate for the new request plus the v7 bump; nine host tests
over temp-dir fixtures (canonicalized home + listing with files,
sizes, and directories; links reported as links with null metadata;
missing root opens and its first listing answers the pinned `notFound`
taxonomy with operation `list`; a root under an unreadable ancestor
fails the open typed `permissionDenied`/`resolve`; chmod-000
directory answers `permissionDenied`; `~` expansion through the
engine environment; idempotent close with the disconnected
closed-channel error; local and pool channels sharing one id space
without interference; shutdown retiring local channels); three
real-isolate client tests (browse + subdirectory navigation across a
spawned engine, the typed taxonomy crossing as `RemoteFileException`,
idempotent close retiring the channel). Full core suite 546 green
(+15 Docker-fixture skips, Docker unavailable locally); core analyze
clean; import guard (92 + repo scan) and protocol guard (51) green.
No app change, no pin/lock change, no transfer/queue protocol work
(M4), no port (original code — PORTS.md unchanged), no
milestone-close claim.

## M3 — panes v1 foundation (2026-09-12)

07 §3.4's first pane slice, lane A: the production two-pane shell browses
local and remote through the one VFS. `WorkspaceController` (03 §6,
foundation form: pane pair + active pane) drives two `PaneController`s,
one per pane, each implementing 02 §2.8's normative listing machine —
optimistic location at issue, monotonic generations with stale answers
dropped (errors included), verbs disabled over cached post-error entries,
Esc-cancel restoring the last quiescent snapshot (error included),
generation never moving backward — with 09 §3's idioms (dispose guards,
bind-attempt counters, channel `identical()` rechecks after every await).
Local panes bind through `EngineClient.openLocalChannel` (the #77 seam,
D8: no dart:io anywhere in the pane stack; the engine owns the
`LocalFileSystem`); remote panes subscribe to `watchServer` BEFORE the
channel open (live streams keep no replay) and open the pool channel at
the bookmark's `remotePath` ('/' = canonical home), reusing the session's
one engine. The sealed `PaneLocation` (Local/Remote, value equality,
02 §2) is app-side this slice — core is closed to it — recorded as open
item 20 with the NFC/case-fold keying rule.

The `PaneView` renders the foundation surface: clickable ancestor path
segments (focused pane accent per 02 §2.1, location glyph), fixed-extent
rows (28 px comfortable × text scale) with kind glyph, size (decimal
macOS/Linux, binary Windows), and mtime (today/yesterday relative,
absolute otherwise) with name–size–date semantics labels (D20, all new
copy in ARB); the 150 ms anti-flash grace governs the dim, the 2 px
progress line, the footer's loading line swap, and the ✕ cancel;
errors render inline (ARB taxonomy sentence + the engine's diagnostic +
Retry) over the cached listing; the 02 §2.7 connection-lost banner owns
the dim layer while the transport reconnects, with a Cancel that drops
the server reference. Keyboard-first: arrows/Home/End move the cursor,
Enter opens directories on Windows/Linux (macOS Enter stays the rename
key — rename is a later slice), Backspace goes up, Tab swaps panes from
inside a listing (§8.2 scoping), Esc cancels navigation — all on the
pane's focus node, never global. Commands (D21): `go.open`,
`go.enclosing`, `view.refresh`, `pane.focusLeft`, `pane.focusRight`,
`pane.swapFocus`, dispatched by `CommandChordScope` (dual macOS/Ctrl
chords; unmodified single keys deliberately excluded so the layer can
never fire Enter/Tab globally).

The M2 debug demo surface is retired per plan ("M3 replaces it"): the
controller, view, command, ARB copy, tests, and the app/main wiring are
deleted; the panes supersede its exact flow in production. The interim
Connections surface stays (M5 owns removal) and gains each row's
"Open in Pane" action — the M3–M4 window's remote entry point, binding
the ACTIVE pane to the row's bookmark. Probe wiring survives as services
but loses its only driver (the demo session): probes do not run again
until the launcher/empty-states slice supplies the interim-list owner —
a deliberate, temporary deviation from 07 §3.4's bullet ("its probe
dots stay live for the M3–M4 window"): release builds never had a
driver, so shipped behavior is unchanged, but debug builds lose the
live dots until the launcher slice lands; recorded below with the
slice's follow-ups.

Follow-ups this slice deliberately leaves to their owning M3+ slices
(each per 07 §3.4's own bullets): launcher/empty states incl. Quick
Connect (02 §2.7) with the interim-list probe dots and a durable-id
probe owner; tabs per pane and the pane toggle (02 §3); path editing
`go.editPath`/`go.toFolder` and navigation history back/forward (02
§2.1); view modes + the §2.3 natural comparator in core + per-location
view prefs with the §2.4 precedence chain (the hidden-files default
filters dotfiles with no toggle yet; sorting is the placeholder
directories-first/name comparator, app-side); the §2.5 selection
model, type-ahead, Quick Select, filter; row interactions incl. rename
(Enter on macOS), file open actions, Get Info; single-key-scoped
Enter-on-link classification (02 §2.3's metadata rule); §7.5 directory
watching; §7.2 ScopedPathAccess; menus + the keyboard-completeness
invariant test (08) and the quick-open palette (M9); footer
user@host/free-space; the empty-rootPath fail-fast guard on the local
open facade (#77's deferred hardening — the pane surfaces the typed
open failure, the guard itself is core-side); the teardown-order swap
(03 §7.5's watcher slice). The demo's scrollable-prompt regression
coverage was removed with its surface; the coordinator suites and the
blocked-review production test carry the coordinator behavior.

Validation (regressions observed failing first — see
tasks/run3-task15-logs/regressions-failing-first.log): 15 controller
tests (the ListingState machine transition-by-transition: issue/accept/
stale/error/Esc-snapshot-with-error, bind ordering subscribe-before-
open, rebind channel close, taxonomy kinds, banner state, cursor
semantics, dotfile filtering, parent-at-root no-op), 15 pane-view widget
tests (rendering local and remote listings through the seams, empty
state, taxonomy surface with Retry re-issue, anti-flash timing, Esc
cancel with no stale repaint, platform-conditional Enter/Backspace,
Tab focus swap, connecting state, banner, path-bar segment navigation,
focused-pane accent, row semantics, no-engine state), 7 shell tests
(panes browse through one engine seam, placeholders and demo command
gone, Ctrl+R/Meta+R chord targets the focused pane, focus commands,
open-in-pane end to end), 2 Connections row tests, plus the updated
shell/wiring/localization-contract suites. Full app suite 422 green,
analyze clean; core re-verified untouched (analyze clean, 548 tests,
+15 Docker-fixture skips); ARB regenerated. Rootless widget captures
(5 labeled states, not native QA) under tasks/run3-task15-captures.
No core change, no pin/lock change, no port (PORTS.md unchanged), no
milestone-close claim.

Demo-suite coverage mapping (round-14/15 review requirement — the
deleted sftp_demo_view_test's behaviors by successor):
- prompt flows (host-key first-use/changed, credential,
  keyboard-interactive): the owning suites remain — prompt_coordinator
  (24 tests), engine_session, and the production wiring test's
  review-affordance flow; the deleted cases exercised the same
  production paths through the demo route only.
- teardown ordering (engine shutdown once, channel close once):
  engine_session_test (shutdown) and pane_controller_test (dispose
  closes the channel; rebind closes the previous; detach releases) —
  plus the new round-15 regressions.
- probe #55 subscribe-before-send: probe_coordinator_test (21 tests,
  the owning suite) remains; the demo was one consumer.
- double-tap spawn guard: the shell's one-command-session guard is the
  production successor and now has its own double-tap regression
  (connections suite).
- SftpDemoController-specific races (stale-cleanup awaits, `_connecting`
  guard unwedging, zombie-connect): obsolete with the controller; their
  PaneController equivalents are the bind-attempt invalidation, the
  cancel-during-connect invalidation, and the failed-bind watch drop —
  each pinned in pane_controller_test/pane_cancel_regressions.

### Foundation recovery verification (2026-09-13, PR #84)

The preceding validation counts are historical, not final-head proof.
Recovery retains main #93's watch contracts and stable open-item IDs;
#78 and #83 are closed, unmerged predecessors of this one task.
Their two 90-minute review cancellations and truncated GitHub summaries
remain evidence gaps, not approval. The PR preserves earlier dispositions;
later runtime evidence supersedes incorrect declines explicitly.

Fresh red-first tests reproduce a failed bookmark's landing path leaking
into another bookmark, cancellation disconnecting a replacement bind, and
open-in-pane callbacks opening after a pop veto or popping a covering route.
The fixes stay in the owning controller/row. `maybePop`'s boolean is never
used as proof of a pop. The alleged post-await landing-path race does not
reproduce: HEAD issues navigation synchronously. A parked old listing,
newer failed bind, old completion, and retry still land on the newer path;
successful retries clear the error.

`pane_session_lifetime_test` exercises two pending pane opens through one
production session/coordinator, FIFO trust prompts, separate channel
releases, sibling refresh after detach, and exactly-once engine shutdown.
It also replaces a session with a listing outstanding and proves the old
answer cannot repaint either replacement pane. Its first harness runs
stalled by awaiting a fake-zone shutdown future in real teardown; the
corrected harness awaits and asserts shutdown within each widget test.

Local recovery checks: app analyze and 548 tests pass; core analyze and
749 tests pass with 16 platform/fixture skips; import scan, protocol scan,
and 51 protocol-guard tests pass. All exit 0. Full bounded logs and explicit
exits live in `tasks/run3-task15-logs/recovery3/`. Final-head CI/review are
recorded on PR #84, not inferred from earlier green runs.
The mixed-owner r17 run is excluded.
The five inherited `tasks/run3-task15-captures/` images were inspected:
Ahem glyphs and transparent backgrounds limit them to widget geometry;
they do not establish text legibility, native rendering, or install QA.
Native desktop/install QA remains unverified. Recovery4 adds readable-font
widget captures of the production shell through fake engine lanes, not native
QA. The isolated harness loads installed Roboto/MaterialIcons and substitutes
Roboto Mono for the requested monospace family; product fonts are unchanged.

Those captures exposed stale toolbar enablement after binding, selection,
and focus changes. Three runtime regressions failed before a toolbar-only
listener repair and pass afterward. Pending-listing transitions also update
the controls without rebuilding pane listings. Full app analyze and 551 tests
pass; bounded logs/exits and before/after captures are retained under
`tasks/run3-task15-logs/recovery4/`. The initial capture harness compile error
and premature tap assertion are harness failures, not product red evidence.

The latest route review premise was refuted against pinned Flutter 3.47.2:
`isActive` reads entry presence, not navigator attachment. Isolated runtime
checks prove opening during animated pop before disposal, veto/local-history
refusal, and covering-route safety across the await. A correctly sequenced
fake also proves the superseded channel closes once without closing its
replacement. These checks add no product changes; the existing route guard
stays. Fresh exact-head CI/review after the toolbar repair remain PR gates.
No full-M3, watch-wiring, probe-driver restoration, or release claim.

### Post-merge reconnect truth repair (2026-09-13, #84 follow-up)

Independent runtime verification found two gaps after #84: a status-only
transport loss left cached verbs enabled, and `connected` dismissed the
banner before a healed listing. The preceding green suites did not cover
these cases. The unchanged supervisor tests fail on the merged foundation;
this companion repair does not close M3 or count as another foundation slice.

The production engine rebinds healthy pane channels before emitting connected;
a failed pane binding can still retain a permanent recovery error. The pane
now latches loss, invalidates old listings, and re-lists its existing channel
on connected. Only the accepted healed listing restores verbs and removes
the banner. Failed healing keeps cached rows and offers localized Retry;
Retry awaits old-channel release before reopening this pane, retaining the
cache meanwhile. Cancel/detach invalidate pending healing and respect newer
same-id binds and healthy siblings. Recovery after a cancelled first listing
uses the bound channel's home when no location remains. A failed/ended status
watch clears its stale status but retains retryable loss, not false healing.

The loss banner owns one dim layer, never a stacked loading/error overlay.
It reserves space above cached rows rather than covering the first rows.
Refresh and cached-entry actions stay disabled until listing proof arrives.
The public `canRetryRecovery` getter supplies only the existing Retry action's
availability; binding/recovery modes and engine mechanics remain private.

Validation: the two supervisor failures, stacked error overlay, and covered
first-row layout were observed red before repair. Fourteen controller cases
cover status-only recovery, delayed/failed healing, stale results, explicit
retry, release waits, cancellation, same-id replacement, siblings, and the
cancelled-first-listing boundary. Pane/session widget coverage verifies toolbar
state and single-overlay rendering. Three status-watch runtime reds corrected
the old assumption that EOF/error could dismiss unhealed loss. Full app 566
tests and analysis pass.
Bounded logs/exits and seven inspected readable widget captures live under
`tasks/run3-task15-logs/reconnect/`; fonts remain harness-only substitutes,
not native/install QA. No core/backend/protocol, pin, port, or stable open-item
ID change. #84's route refutation, toolbar fix, and historical review gaps
remain valid. Exact companion-head CI/review are recorded in its PR.

## M3 — pane listing-state transitions (2026-09-12)

`ListingState<Location>` implements 02 §2.8's pure transitions in the app
service layer: optimistic navigation, immutable sorted row snapshots,
current-generation success/error acceptance, stale-answer rejection, and
Esc restoring the last quiescent location, rows, and error. Stacked requests
retain one snapshot; cancelling advances both counters. A cancelled Retry
restores its error and keeps stale-row actions disabled. Duplicate terminal
answers and unsolicited future generations are ignored. The ready factory
requires an accepted listing (or empty launcher); unlisted directories enter
through navigation. No filesystem operation runs or is cancelled by this
model.

02 §2.8 clarifies that location is a type parameter; the future
PaneController specializes it with `PaneLocation`. Canonicalization remains
at the location-construction boundary. 03 §5 records the verified upstream
listing-cancellation prerequisite (item 12), rather than treating an
abandoned future as cancelled I/O.

Validation: 11 transition tests pass after first failing to compile against
the absent model. They cover defensive copies, lazy stale-payload rejection,
monotonic generations, stacked cancellation, retry-error restoration, and
terminal answer rejection. All 433 Flutter tests pass; Flutter analysis and
the dependency guard are clean.
[CI](https://github.com/L-K-M/Poltergeist/actions/runs/34692910410) also passes
core checks and all five client builds. Review's constructor and validation
claims were refuted: [Dart 3.12 supports private named initializing formals](https://dart.dev/language/constructors#private-named-parameters),
and CI confirms 433 passing app tests on the reviewed revision.
Round 2 clarified chain-scoped generations, immutable location values, and
identity equality. The loading formula remains exactly 02 §2.8's contract.
No widgets, D12 rendering surface, dependency/pin change, or source
port; PORTS.md is unchanged. PaneController's D2 port, scoped local access,
location construction, browsing widgets, and the rest of M3 remain open.

## M3: deterministic listing sort (2026-09-12)

`sortFileEntries` supplies 02 §2.3's pure core sorting: natural names,
seven column keys with their initial directions, optional directory grouping,
ascending secondary names, and immutable output retaining entry identity.
It folds names once per row with pinned Unicode 17.0.0 simple mappings;
numeric runs compare without integer conversion. Directory inode sizes never
substitute for calculated totals. The function performs no I/O.

02 §2.3 now specifies ASCII digit runs, leading-zero ties, missing metadata,
Kind ordering, POSIX permission masking, numeric ownership, and supplied
directory totals. Unicode data, source hash, offline generator, exhaustive
mapping test, and license are committed; the package LICENSE includes the
Unicode notice for Flutter's license collector. No dependency or Séance pin
changed; original code, no D2 port, PORTS.md unchanged.

Validation: 17 sorting tests and seven Unicode tests pass after the new
surface tests first failed to compile. They cover all columns/directions,
grouping, nulls, long numeric runs, Unicode, shuffled-order determinism,
input preservation, and every Unicode scalar against the pinned source.
Core analysis and 572 tests pass (15 existing SSH-fixture skips); Flutter
analysis and 433 tests pass. The dependency guard passes. A local 100k-row
model-sort smoke test measured a 272 ms median over five warm runs; this is
not a D12 paint benchmark. The Linux Flutter asset bundle builds and its
`NOTICES.Z` contains the Unicode notice. [PR #80's first CI run](
https://github.com/L-K-M/Poltergeist/actions/runs/34710378767) passes all five
client builds, core/app checks, and real-sshd integration.

Review round 1 added a descending-name assertion, verified by removing
direction handling and observing failure, plus license formatting and small
contract/test clarifications. Missing-mapping, provenance, and license-year
claims were refuted against the full source and fresh upstream downloads;
the PR description records each disposition. No production defect found.

This is an ungated M3 model slice. PaneController, widgets, and D12 rendering
benchmarks remain with their slices. Listing cancellation remains item 12;
the raw-name prerequisite discovered here is item 13. No milestone close.

## M3 — engine-owned local directory watch seam (2026-09-13)

03 §7.5's engine prerequisite (the task-18 seam): the engine protocol
(v8) gains `WatchLocalDirectoryRequest` / `UnwatchLocalDirectoryRequest`
and the typed `DirectoryWatchEvent` (`DirectoryWatchSignal.changed` /
`.lost`). `EngineBrowseChannel` (both open paths return it) exposes
`directoryChanges` (broadcast, per channel, closes on channel close and
engine death), `watchDirectory(path)` (retargets; the engine canonicalizes
the target through the channel's `LocalFileSystem`), and
`unwatchDirectory()`. The engine owns the resources (D8): a private
`LocalDirectoryWatcher` adapter (`lib/src/engine/local_directory_watcher.dart`,
not barrel-exported; tests import it by path) drives one non-recursive
watch per local channel behind an injectable `LocalWatchBackend` seam
(production: dart:io `Directory.watch`). Contract: no implicit watch on
channel open/list alone; ordinary changes coalesce into `changed` 300 ms
after the last event (burst = one refresh; a sustained stream defers the
refresh until quiet by design); root removal/rename, backend error, and
backend close emit `lost` immediately and release the watch — never a
silent stop; retarget replaces atomically (release-then-subscribe with no
await between, plus an epoch guard) so stale callbacks from a replaced
watch cannot invalidate the new binding; events carry the canonical
watched path so a consumer can drop signals for a directory it no longer
shows. Pool channels answer an explicit typed `unsupported` refusal for
both watch and unwatch — watching a remote directory would be a polling
feature the engine deliberately lacks. Typed request failures: empty
path (`other`), missing root (the local funnel's `notFound`, operation
`inspect` — the open seam's `resolve` precedent), non-directory target
(`other`). Release paths: unwatch, channel close, and host shutdown all
cancel the backend subscription and the pending debounce timer.

Backend guarantees were verified against the Dart SDK sources before
implementation (3.13.3, `runtime/bin/file_system_watcher_{linux,macos,win}.cc`
plus the Dart-side `_WatchedPath` patch): Linux and macOS report a
removed/renamed watched directory as a delete event naming the watched
path itself and then close the stream (the adapter emits one `lost`, the
epoch guard swallowing the duplicate); Windows surfaces
`ReadDirectoryChangesW` buffer overflow and unexpected closure as stream
errors; macOS FSEvents already depth-filters non-recursive watches to
direct children in the C++ layer (events whose relative path contains a
separator are dropped), so the adapter's own child filter is defense in
depth — it also covers a future subtree-reporting backend and makes the
macOS constraint testable everywhere. Move events qualify on source or
destination. Two implementation findings worth recording: dart:io
emits no event a Dart consumer can see for Linux inotify queue overflow
(see open item 14), and a broadcast subscription's `cancel()` future
completes on the event loop — under `fake_async` it never completes — so
the adapter's release is fully synchronous (epoch bump, timer cancel,
cancel issued unawaited); correctness rests on the epoch, never on the
cancel's completion.

Validation (failing-first: all four suites failed to load before the
implementation landed — `tasks/task18-logs/failing-first.txt`, not
committed): 20 fake-clock adapter tests over an injected backend (debounce
edge, burst collapse, grandchild/sibling filtering both separators aside,
move-destination qualification, root-self modify, immediate lost for
root delete/rename/backend error/backend close/throwing backend, the
Linux delete-then-close shape collapsing to one lost, lost cancelling a
pending debounce, stop/after-stop, retarget release + stale-event races,
dispose, re-watch after loss); 11 host tests over the in-process harness
with the backend injected (canonicalization + forwarding, immediate root
loss, retarget replacement with stale events never crossing, the pool
refusal, missing-root/file/empty-path/unknown-channel typed failures,
idempotent unwatch with release observed, close and shutdown release);
7 real-isolate client tests over real temp directories and the real
dart:io backend (a real change crossing the boundary debounced, no
grandchild/sibling noise, safe retarget, real root deletion → lost,
unwatch and channel-close release with no late events and the mirrored
stream closing, engine death closing the stream); protocol v8
round-trips through a spawned isolate for both requests and the event's
both signals. Full core suite 587 pass (+16 Docker-fixture skips — the
#81 Ubuntu baseline of 549 + 38 new); core analyze clean; protocol
guard (51) and import guard (92 + repo scan) green. The engine barrel's
existing protocol `show` list gained the four new public names (the
app must be able to name the event type through the barrel; no new
export lines). No app/UI change — pane refresh is NOT wired: the pane
slice that consumes this seam (activation-driven watch/unwatch,
navigation retarget, launcher/remote drop — 03 §7.5's pane policy)
remains open and now depends on this seam. No source port (original
code — PORTS.md unchanged), no pin/lock change, no milestone-close
claim.

The first native CI round (run 34719413261) produced three platform
findings, all repaired on the PR head: the protocol-boundary repo
scan (not just its test suite — the CLI check is part of validation)
rejects function-typed fields in engine sources, so the backend seam
became an interface class (`DartIoWatchBackend` default; test fakes
implement it) and the local channel exposes a `signals` getter
instead of a callback field — no guard allowlist widening; macOS
FSEvents delivered changes made shortly before the watch started
(dart:io's documented limitation), so the real-backend tests drain
that fixture-setup backlog past the debounce before staging the
events they assert on; and Windows produces no root-deletion loss
signal at all — the OS defers removing a directory an open handle
watches (delete-pending), so the children-removal `changed` and its
rescan are the observable path there for a NON-EMPTY directory (the
root-loss logic itself is covered cross-platform by the injected-backend
adapter suite, and the real-OS vanish test skips Windows with that
reason — a focused, documented skip, not a global one). Production
semantics unchanged; the adapter's doc records the per-backend loss
shapes. (The 2026-09-13 post-merge repair below sharpened this: an
empty watched directory yields nothing observable on Windows — open
item 16.) App re-verified on the rebased tree (barrel changed):
analyze clean, 433 tests pass. On the final tree the full core suite
is 611 pass +16 skips.

## M3: Quick Select matching and selection model (2026-09-13)

`QuickSelectQuery` matches decoded basenames using the pinned Unicode simple
fold: literal fragments, or whole-name globs with `*` as the only wildcard.
It reserves anchored ends and searches interior segments in order, without
regex backtracking. `QuickSelectState<Key>` captures immutable row-name and
selection snapshots, recomputes Add/Remove previews from the opening
selection, confirms the current preview, and restores the baseline on cancel.
Terminal states ignore late callbacks. Row keys are independent of names;
manually selected rows excluded from name matching remain selected.

02 §2.5 specifies wildcard grammar, case handling, empty queries, baseline
recomputation, and session invalidation. The pane must cancel before replacing
the listing or visibility policy, then prune the restored selection. Item 13
still gates production exclusion of flagged names; a valid literal U+FFFD is
never treated as evidence of invalid encoding.

Validation: 71 matcher cases and 13 selection tests, with initial missing-API
failures observed. Independent review caught the initial rejection of manually
selected flagged rows; its regression failed before the repair. An independent
temporary dynamic-programming oracle agreed on 278,715 short pattern/name
pairs. Core analysis and 685 tests pass (16 existing fixture/platform skips);
Flutter analysis and 446 tests pass; the dependency guard passes.
PR #85's first CI run passes all three core hosts, app tests, SSH integration,
and all five client builds. Automated review found no correctness issue;
its empty-query documentation suggestion was applied, and repeated name
folding is deferred to pane-wiring measurement (item 15).

One ungated M3 model slice. The field, command, keyboard integration, selection
pruning on actual pane changes, and widget tests remain with pane wiring.
No widget or D12 rendering surface, persistence, dependency/pin change, or
source port; PORTS.md is unchanged. M3 remains open.

## M3 — watch-seam lifetime repair (2026-09-13, post-merge on #82)

Supervisor verification of merged #82 reproduced a confirmed lifecycle
race the review rounds missed: `WatchLocalDirectoryRequest` then
`UnwatchLocalDirectoryRequest` issued back-to-back before the watch's
canonicalize/stat awaits resume — the unwatch acked, then the older
validation resumed and installed the watch anyway (the fake backend
kept a live listener). Root cause: the channel checked only `_closed`
after its awaits; nothing invalidated an in-flight validation against
later watch-control requests, and the watcher's epoch starts too late
(only at retarget) to protect the validation window.

Fix, at the channel request lifetime boundary:
- `_LocalPaneChannel` gains a watch generation. Every watch-control
  request (watch, unwatch, close) bumps it; a watch captures it at entry
  and rechecks after its awaits — superseded validations answer the
  typed `cancelled` refusal ("superseded by a later watch or unwatch")
  and install nothing, so last request wins regardless of which I/O
  resumes first, and an acknowledged unwatch can never be undone by an
  older, slower watch. A close still wins with the typed `disconnected`
  refusal (checked before and after the awaits). Invalid-target
  validations still leave an installed watch untouched, deliberately.
- The adapter's release is now a completion-tracked tail: every backend
  cancellation issued is chained in order, `stop()`/`dispose()` complete
  only when the whole tail has, and errors are contained per link. An
  acknowledged unwatch/close/shutdown therefore means the backend
  subscription really is gone, not merely scheduled to go — epoch
  suppression is signal routing, not resource release. `retarget`'s ack
  still means establishment (the replaced watch's teardown rides the
  tail; its callbacks are dead synchronously).

Also opened honestly (not silently deferred): Windows root-removal is
unobservable through dart:io including the empty-directory case where
even the children-removal `changed` never fires — open item 16, with a
compatible parent-watch adapter proposal; item 14's overstated "every
other failure mode is surfaced" sentence corrected; the protocol,
adapter, and chapter docs now carry the empty-directory nuance.

Validation (regression-first, delayed completion — no timing guesses):
the supervisor's repro (kept verbatim in
`test/engine/watch_supersession_test.dart`) observed red on merged
e009b1f (`tasks/task18-logs/postmerge-race-before.log`, exit 1 — a
live listener after the acknowledged unwatch) and passes after; new
regressions cover the typed `cancelled` refusal with no backend touch,
reordered watch/watch (only the newer installs, whichever I/O resumes
first), shutdown superseding a validating watch (`disconnected`), and
release completion gated on explicit completer-held backend cancels —
including the finding that a broadcast controller's `cancel()` does NOT
gate on `onCancel`'s future while `Stream.multi` (dart:io's watch-stream
shape) does, which is why the gated fakes use `Stream.multi` and why
the production guarantee is real. Full core suite, protocol repo scan,
and guards green; native CI on the repair PR.

## M3 — close-boundary and review-resolution repair (2026-09-13, post-merge on #86)

Supervisor verification of merged #86 (original race verified fixed)
confirmed a second lifetime defect at the host close-request boundary:
`CloseBrowseChannelRequest` removed the channel from the routing map
before awaiting its close, so a concurrent duplicate close saw no
channel and acked immediately — while the first was still parked on the
backend cancellation. The channel-level memoized close never saw the
second request. Fix at the host request boundary: retirements in flight
are tracked per channel id (`_pendingCloses`, bounded — entries
self-remove on settlement, ids never reused, duplicates await rather
than create), duplicate closes share the pending completion, shutdown
drains the map without clearing it, so shutdown cannot ack over a
still-closing channel that settles (corrected 2026-09-13 by the
shutdown-drain repair below — #87 as merged cleared the map
pre-drain and could ack early on a drain-window duplicate); a
never-settling retirement is abandoned at the drain's bound and
its release dies with the isolate,
and routing still retires synchronously so no stale
events or requests leak; closing a fully retired channel stays
idempotent. The Windows root-removal gap's STATUS entry was also
renumbered 15 → 16 (it collided with #85's Quick Select item 15) with
all seven textual references updated.

The supervisor's full-pagination audit also found both merged PRs' 44
inline review threads still flagged unresolved despite recorded body
dispositions, and the latest edited review summaries carrying findings
beyond the inline sets. All threads were resolved after per-thread
verification, and the newly-triaged findings received dispositions
(appended to the PR bodies, not reconstructed): declined — late-
subscriber replay cache for early `lost` signals (subscribe-before-watch
is the documented client contract; the pane wiring must subscribe before
setup/retarget — recorded as a pane-wiring requirement, not a cache
redesign) and the close-error mirror (premise false: the host removes
routing first, so no post-failure path exists for a "live routable
channel"); deferred — a capped debounce (trailing-only starvation is
documented behavior; a max-wait cap is a behavior decision for the pane
owner, not a repair invention); corrected rationale — the isDirectory
fixture parameterization decline (the adapter never inspects the bit —
the earlier delete-self SDK evidence was about delete events and did
not address modify shapes; parameterization stays optional); applied —
doc accuracy (the pool-channel refusal on `watchDirectory`/
`unwatchDirectory`, the Windows rescan-failure-is-implicit-loss hint on
`changed`, the failing-request-supersedes contract sentence, and the
backend cancel-completion obligation: a cancel must settle and settle
only after teardown, while error containment is bookkeeping, not proof
of OS release), plus test hardening (real-backend debounce coalescing,
pre-close and pre-death positive controls, `pumpEventQueue` over
wall-clock sleeps, dispose-while-parked on the retarget test, and
both-futures consumption in the close-race test).

Validation (regression-first): the supervisor's concurrent-close repro
(verbatim in `test/engine/concurrent_channel_close_test.dart`) observed
red on merged `8b4f493` (`tasks/task18-logs/close-boundary-before.log`,
exit 1 — second close acked before backend release) and passes; new
deterministic regressions cover shutdown interleaving with a pending
close (shutdown ack gated on the backend release) and post-retirement
idempotency. Core suite 697 pass (+16 fixture skips), analyze clean,
protocol repo scan clean; native CI and app checks on the repair PR.

## M3: per-location view preferences (2026-09-13)

Immutable view preferences cover List/Details, density, directory grouping,
hidden visibility, relative dates, sorting, column visibility/order, and widths.
`ViewPreferencesStore` persists complete folder snapshots above global defaults
through the existing atomic `SettingsStore`. Reset removes a snapshot; changing
defaults leaves explicit folder choices intact. One device-local 500-entry LRU
spans local volumes and remote server ids; reads of saved locations and writes
refresh durable recency. Unsaved locations consume no entries. Server removal
clears only that server's entries. Serialized operations preserve concurrent
pane edits; malformed schemas and write failures propagate without replacing
stored preferences, and later operations can retry.

Location keys carry kind, volume/server identity, and an already-canonical path
as separate fields. Canonicalization remains the location owner's contract
(02 §2); this service cannot infer remote or volume case sensitivity. Transient
tab hidden overrides have no persistence field. The view-options controls,
command registration, active-pane binding, and transient hidden toggle remain
with the pane slices; this adds no widget or timing surface. Chapters 02/03
clarify defaults, complete snapshots, and the shared LRU representation.

Validation: 50 focused model/store tests and all 496 app tests pass; app and
core analysis, dependency boundaries, and the engine protocol guard are clean.
The tests cover immutable snapshots, schema validation, identity isolation,
restart persistence, LRU eviction, concurrent edits, and failed-write rollback.
No dependency or source-port change; PORTS.md was checked and has no affected
entry. [CI 34742129311](https://github.com/L-K-M/Poltergeist/actions/runs/34742129311)
at `57faa73` passed the app checks, all five client builds, three native Dart
suites, and tooling checks. SSH fixtures were skipped by scope detection;
M0 measurements remain dispatch-only. M3 remains open.

## M3 — shutdown-drain repair (2026-09-13, post-merge on #87; PR #88)

Engine and test changes: this PR (#88) carries them — the red
baseline is anchored at `0289922`
(`tasks/task18-logs/shutdown-drain-before.log`, exit 1).
Supervisor verification of merged #87 found the next lifetime window:
`_shutdown` snapshotted `_pendingCloses` and then CLEARED the map before
awaiting the drain — so a duplicate `CloseBrowseChannelRequest`
processed while shutdown was parked on a gated retirement found no
pending entry and acked early, exactly the early-ack shape #87 exists
to close. Fix: the clear is gone and the drain loops until the map
empties — entries already self-remove on settlement, so a drain-window
duplicate still finds and awaits its retirement, and a retirement
created during the drain (a channel opened in the window before the
shutting-down gate starts rejecting opens, then closed by
its own request — the one-shot snapshot's blind spot, found by #88's
review) is awaited too before shutdown acks — arrivals after the
drain's final emptiness check cannot interleave the check-to-ack
microtask boundary (no await between them; request handlers run on
event-loop turns), so the window is structurally closed and
documented at the drain. The supervisor's repro
(verbatim
in `test/engine/supervisor_shutdown_close_test.dart`) was red on merged
`0289922` (`tasks/task18-logs/shutdown-drain-before.log`, exit 1) and
passes; the during-drain-creation regression was observed red on the
repair's first head `e6fa3c3` (batched-drain commit `9e3b2f3`'s parent;
mutation-verified: `Expected false, Actual true` against the one-shot
drain) and passes with the loop drain. The suite now pins
the interleavings: pre-shutdown duplicate closes (both-acks-gated),
drain-window duplicates (this repro), the retire-loop race (a close
racing the loop shares the tracked retirement), open rejection once
shutting down, and the never-settling retirement bound (an injectable
drain timeout keeps the ack bounded; gating opens once shutting
down closes off both the fixed point's leak and the starvation
premise). The mid-loop
mutation is
now deterministic (a pump between issuing the racing close and
releasing the gates guarantees the map mutation lands inside the loop's
iteration; without it the microtask-resumed loop could finish first and
the regression pass vacuously). Review-surfaced hardening in the same
PR: the debounce-coalescing test awaits its first emission via the
proven timeout before the quiet window (loaded runners can no longer
flake `hasLength(1)`), the close-race test asserts the watch contract
before consuming the close future (a throwing close can no longer mask
the assertions), the pumped negative assertions document why
`pumpEventQueue` suffices (the watcher's only nonzero timer — the
debounce — is cancelled synchronously on release), and `_closeChannel`'s
doc states the failure-sharing asymmetry (a failed retirement surfaces
its error to every sharing close; only post-settlement closes ack
idempotently). PR #87's final review round was initially misreported
as "no findings": its edited summary actually carried this exact major
finding plus four minors and one info finding (zero inline/actionable
count). Those summary findings are fully dispositioned in that PR's
corrected body, and this repair applies all of them.

## M3 — close-timeout truthfulness repair (2026-09-13, post-merge on #88)

Supervisor verification of merged #88 reproduced the final defect in
the close-lifetime chain: a non-shutdown close whose bound elapsed
returned `EngineAck` — false success over a backend release known not
to have settled, while the engine remained live and serving. The
documentary "ack means release completed or the bound elapsed"
framing was itself the error: a deadline is a failure to confirm
release, not a completed release, and the repository's explicit-error
rule applies through the existing taxonomy (`_guard` already
serializes any throw as `EngineError`; `operation: 'close'` names the
request) — no new protocol variant was ever needed, and the earlier
"background release genuinely completes later" claim was unfounded
(the backend can stay wedged forever). Fix: starter and duplicate
closes await the tracked retirement under the shared bound and, on a
timeout, answer a typed `RemoteFileException` (kind `other`, operation
`close`) — while the retirement STAYS tracked, so closes racing a
still-pending release keep reporting the same truthful failure, and
the eventual settlement (whenever it comes) drops the entry through
the existing self-removal listener, restoring the idempotent-ack
path. Only the shutdown drain keeps bounded abandonment semantics:
its ack precedes the isolate's death, a different operation. Closes
racing shutdown report the timeout failure too while the retirement
stays tracked — the engine is still serving until the shutdown ack (a
close arriving after the drain itself abandons the entry acks with
the drain, as before). Regression-first: the supervisor's
repro (`supervisor_close_timeout_test.dart`, gated backend, 200 ms
bound, engine proven live by a concurrent open) was red on merged
`0ced8ef` (`tasks/task18-logs/close-timeout-before.log`, exit 1 —
`[EngineAck, EngineAck]`) and passes; the prior round's two
bounded-close tests were rewritten to the truthful contract with new
coverage for a close while still pending (typed failure), eventual
release (idempotent ack after settlement — failure did not prevent
cleanup), and closes racing shutdown (typed failure for the closes,
EngineAck only for the shutdown's own drain). All earlier race
regressions (duplicate sharing, drain-window duplicates, retire-loop
race, open gating, never-settling drain bound) pass unchanged.

## M3: Windows watched-directory loss (2026-09-13)

The Windows backend combines non-recursive root and parent subscriptions.
Parent rename/removal loses the binding even if another directory already
occupies the old path. An asynchronous root-type check after setup and child
events detects delete-pending roots when Dart drops a synchronous native
read failure. Checks coalesce with a trailing check for intervening events;
cancellation retires both subscriptions and waits for outstanding metadata.
Sibling events are ignored. No timer, recursive scan, new VFS, or protocol
change. Chapter 03 §7.5 records the backend contract and corrects its earlier
blanket claim that Windows empty-root deletion cannot signal.

Regression baseline: Windows [job 103720537033](
https://github.com/L-K-M/Poltergeist/actions/runs/34756069942/job/103720537033)
at `58bd488` timed out waiting for populated-root loss; empty-root deletion
passed. Linux and macOS passed both. This supports the SDK's distinction
between [silent synchronous read failures](
https://github.com/dart-lang/sdk/blob/3.13.3/runtime/bin/eventhandler_win.cc)
and [reported asynchronous deletion errors](
https://github.com/dart-lang/sdk/issues/62193). Parent watching alone is
insufficient because [Windows retains delete-pending entries](
https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-removedirectoryw).
Local validation: core and app analysis, the import/protocol guards, 21
deterministic backend tests, the core suite (730 passed, 16 fixture skips),
and all 496 app tests passed. [CI 34756562117](
https://github.com/L-K-M/Poltergeist/actions/runs/34756562117), attempt 2 at
`4ef9a03`, passed: all five client builds, real SSH fixtures, tooling, and
native packages (Linux 730/16 skipped; macOS 729/13; Windows 705/37).
All four deletion/rename cases ran on every desktop. Attempt 1 passed the
watch cases but failed the unchanged Windows incident-store test; its job
passed on retry (item 19). Ancestor invalidation remains item 18; Linux
overflow is closed by the inotify backend (item 14). M3 stays open.

Review round 1 found no confirmed important defect. Two minor suggestions
were applied: an internal absolute-path assertion (test failed before it)
and positive event-fidelity coverage. Symlink-root failure was refuted:
the engine resolves links before subscribing; an added native link-path
test pins that boundary. Transient retry was declined under 03 §7.5:
Dart type lookup collapses lookup errors to `notFound`, so the proposed
exception-code retry cannot classify them. The proposed deletion flag
assertion was refuted against Dart's API: `isDirectory` is always false
for `FileSystemDeleteEvent`. PR #92 records each disposition with evidence.

Original engine code; PORTS.md checked, no affected port or upstream change.
The Séance pin and dependencies are unchanged. The subscription tools are
unavailable; PR #92 uses GitHub polling and an hourly Paseo heartbeat, deleted
on completion.

## M3: ancestor-watch evidence correction (2026-09-13)

PR #93 is redirected to contracts/tests, not a Windows loss fix. Production
behavior remains #92's root+parent Windows watches and leaf-only Linux/macOS
watches. Host close deadlines, shared release futures, immediate loss, and
probe/cancellation ownership are unchanged. M3 and item 18 remain open.

The test-only baseline `7afbefc`, [CI 34762015179](
https://github.com/L-K-M/Poltergeist/actions/runs/34762015179), did NOT
reproduce Windows missing loss: all three native ancestor cases failed at
`Directory.rename` with access denied (errno 5), before awaiting loss.
Five fake failures were separate evidence, not a native reproduction.
Linux/macOS did reproduce missing ancestor signals; their tests and raw logs
remain in the archived candidate and external `tasks/task20-logs/`.

Native operation probes at `cb059e7`, [CI 34763389767](
https://github.com/L-K-M/Poltergeist/actions/runs/34763389767), Windows job
`103740002147`, and candidate `6366437`, [CI 34763626749](
https://github.com/L-K-M/Poltergeist/actions/runs/34763626749), job
`103740628858`, isolate a live-handle restriction on the tested runner/SDK.
With no watches, all five moves succeed. With live root-only, root+parent,
or full-chain handles, root rename succeeds but the tested ancestor moves
are refused; every refusal succeeds after cancellation on the same fixture.
Both runs retain the three rename-denied failures. This is not evidence
that all Windows filesystems or move mechanisms prevent ancestor moves.

The unsupported loss assertions and their chain-only fake tests are removed,
not skipped. Fifteen native operation probes retain the unwatched and existing
production handle layouts, with parent-first Windows installation and explicit
post-cancel success. They record native outcomes, not a repaired loss signal.
A Linux regression test requires real leaf events beneath an owned traverse-only
ancestor (mode 0111). It fails with candidate EACCES and passes with #92 behavior.
No global permissions, fallback policy, registry, FFI, or polling changes.

Candidate `6366437cf715a0b51995b9ddd5f2f089a020bc59` is preserved as
`archive/task20-ancestor-candidate-6366437` and an external Git bundle.
Raw baseline/candidate/native logs, permission red/green logs, sources,
review summaries and dispositions are retained in `tasks/task20-recovery/`.
The chain's ancestor-permission regression rules out retaining it as-is;
Linux/macOS ancestor detection needs a separate justified task (item 18).
Protocol/03 comments also remove the stale Windows empty-root-loss claim:
#92 already closed item 16. No source port or dependency change.

Redirect validation on Linux: 15 native operation probes plus the permission
regression, 23 unchanged Windows-backend fake tests, 207 engine tests, and
749 core tests pass (16 fixture skips); core analysis and the protocol scan
pass. Final-head native CI and review are recorded on PR #93.

## M3 — Linux inotify overflow backend (2026-09-13)

STATUS item 14 closed: a real Linux kernel queue overflow now surfaces as
an immediate `lost` through the production-selected backend. The new
`LinuxInotifyWatchBackend` (`lib/src/engine/linux_inotify_watch_backend.dart`)
sits behind the unchanged `LocalWatchBackend` seam; `platform()` selects it
on Linux only (Android keeps dart:io — `Platform.isLinux` is false there;
macOS keeps dart:io; Windows keeps #92's backend). No VFS, protocol,
ancestor-watch, or permission change; the watch stays leaf-only, so the
#93 traverse-only-ancestor regression passes untouched.

Design: one non-recursive `inotify_add_watch` per shown directory; a
helper isolate blocks in a timeout-less `poll` on {inotify fd,
stop pipe} — the engine isolate never blocks, and there is no timer,
spin, or filesystem polling (dart:ffi descriptors cannot join the Dart
event loop). The helper decodes raw `struct inotify_event` batches
(host-endian header, NUL-padded names decoded with malformed-UTF-8
replacement, matching the plan's listing stance) and forwards records;
the owning isolate maps them to the dart:io event shapes the adapter
already consumes — move halves pair by cookie into one merged
FileSystemMoveEvent, unpaired halves flush as create/delete, exactly as
dart:io's Linux watcher does. `IN_Q_OVERFLOW` (descriptor −1) becomes a backend
error — the adapter's immediate `lost`; `IN_DELETE_SELF`/`IN_MOVE_SELF`/
`IN_UNMOUNT` produce dart:io's Linux root-loss shape (one delete naming
the watched path, then stream close, collapsed to one lost by the
adapter's epoch); `IN_IGNORED` is dropped. Cancellation writes one
stop-pipe byte and closes the write end, so `poll` wakes immediately and
teardown never waits on filesystem activity; the cancel future completes
only after the helper acknowledged its loop exit and the owning isolate
closed the inotify descriptor, both pipe descriptors, freed the read
buffer, and closed the ports. Setup failures release stepwise (init →
watch → pipe → buffer → spawn), overflow and read errors deliver the
loss before teardown, repeated cancels share one memoized release, and
host shutdown rides the existing channel-close tail. Honest limit: an
unsupervised engine-isolate kill bypasses all Dart cleanup and leaks the
descriptor set plus a parked helper until process exit — documented in
the backend and 03 §7.5, never claimed as released.

Native failing-first proof (real kernel overflow, not synthetic): the
owned child fixture runs the production `LocalDirectoryWatcher`, proves
installation with a real marker event, is SIGSTOPped (all threads, so
nothing drains the queue), receives `max_queued_events + 4096` distinct
create/delete events from the supervisor, is SIGCONTed, and must report
a lost whose detail names the overflow. At base `36211a27` (production
still dart:io) the child printed `TIMEOUT` and exited 3 — no signal, the
exact silent-drop defect (`tasks/task21-logs/native-overflow-baseline.log`,
harness exit 1); with the backend selected the same harness passes in
~4 s (`native-overflow-after.log`, harness exit 0). The sysctl is only
ever read; the child is always resumed, killed, and reaped in `finally`;
only the owned child is ever signalled.

Validation: 13 pure decoder/mapper tests (packed batches, unnamed and
overflow-shaped events, malformed-UTF-8 names, truncated header/name
deterministic errors, every mapping branch including ignore/overflow
asymmetry) run on all platforms; 7 native Linux backend tests (real
event fidelity, delete/rename root loss with stream close, 25-cycle
cancellation with descriptor accounting, post-cancel silence, sibling
loss isolation, 20-cycle adapter retarget/stop release); the overflow
harness runs unskipped on Linux CI (`@TestOn('linux')` elsewhere, the
same focused-skip pattern as #81/#93). Full core suite 770 pass + 16
fixture skips; app analyze + 496 tests pass; core analyze clean;
protocol scan and import guard clean. New direct dependency: `ffi ^2.2.0`
(dart:ffi has no allocator; version matches the existing lock entry —
the workspace lock itself is unchanged). PORTS.md unchanged (original
code, no port). M3 stays open; item 18 (ancestor invalidation,
Linux/macOS) remains the open watch follow-up.

*Cancellation fairness repair (2026-09-13, companion PR):* supervisor
verification of merged `48d7c5c` reproduced a confirmed cancellation
defect: the helper's drain ran until EAGAIN, so four owned rename
producers keeping the kernel queue non-empty prevented the stop pipe
from ever being revisited — cancellation stayed pending for as long as
producers ran and only finished after they stopped (probe: pending at
5002 ms, done by 5067 ms; committed regression
`cancellation completes while the kernel queue stays busy` red on the
merged content). The drain is now bounded to
`maxReadBatchesPerPoll` read batches before `poll` is re-armed, and
`poll` checks the stop pipe first, so stop latency is capped at one
drain's decode/send work — cancellation is bounded by the helper's own
cycle, never by filesystem quiescence. After the repair the unchanged
5 s probe releases at `elapsedMs=0` with all four producers alive, and
the committed regression is green. Overflow, move pairing, root loss,
repeated cancel, partial setup, and sibling semantics unchanged; the
cancellation doc records the precise control flow (engine suite 235,
external lifetime proofs 18, overflow harness, full core 777 + 16
skips, analyze/protocol/import guards green;
`tasks/task21-logs/*cancel-fix*`). *Fixture portability repair (same
day, companion):* `markTestSkipped` does not throw (test_api 0.7.13
requires an explicit return), so on hosts without python3 the busy-cancel
fixture fell through to `Process.start` and failed with
`ProcessException` after printing its skip message (supervisor runtime
log, exit 1). Both unavailable-probe paths now return before any
resource exists; the producer spawn loop moved inside the try/finally so
partial startup reaps what it spawned; and the finally always awaits
the real cancellation future (the body's or its own), not a
placeholder. Verified: absent python3 and a nonzero `python3
--version` shim both skip with exit 0; the normal pressure test, the
unchanged supervisor probe (released at `elapsedMs=0`), engine suite,
core suite, and guards stay green (`tasks/task21-logs/*fixture-fix*`,
`no-python-repro-after.log`, `nonzero-python-repro-after.log`).

Review follow-up: cancellation timeouts and errors now emit distinct
failure-only diagnostics with stacks, and a synchronous `cancel()` throw
stays inside the producer-reap guard. The focused backend suite (8), engine
suite (235), and core analysis pass on the follow-up head.

## M3 — pane listing uses the core natural sorter (2026-09-13)

PaneController's placeholder comparator (lowercase lexical) is replaced by
the pinned `sortFileEntries` defaults at the presentation boundary: name
key ascending, directories first, natural digit runs, Unicode simple fold,
unmodifiable copy. Dotfile filtering, accepted-listing snapshots, and
cancellation/generation behavior are unchanged; the VFS-returned list is
never reordered in place and entry identity is retained. Listings now show
file1, file2, file10 instead of file1, file10, file2. No sort controls,
per-location prefs, hidden toggle, ARB keys, or registered commands; those
ride their own slices. Item 13 stays open: the helper orders decoded names
only, so this wiring closes no raw-byte collision ordering and makes no
byte-preserving claim. No core, pin, or port change.

Validation: three controller regressions (numeric order plus VFS-list
immutability, simple-fold names where toLowerCase differs, directories
first with dotfiles hidden) and one widget test reading the painted row
order back from the laid-out rows each failed against the placeholder,
then passed with the wiring. App analysis clean, 570 tests pass; core
re-verified untouched (analyze clean, 749 tests, 16 fixture skips); import
and protocol guards pass. Bounded logs and exits:
tasks/task22-logs/ (red-phase, green-phase, suites, guards). No widget
captures: layout is unchanged and order is proven programmatically.

## M3 — bench harness relocated to packages/poltergeist_bench (2026-09-14)

The 07 §3.4 relocation: the M0 SSH fitness harness moved wholesale from
`tool/bench/` to `packages/poltergeist_bench/` (git mv; package name
`poltergeist_m0_bench` and every import unchanged; the frozen standalone
resolution — dartssh2 3.0.2, Séance `2e6d1f1` — stays outside the workspace
lock, byte-identical lockfile). Entrypoints now live under its `benchmark/`
directory per 08 §6 (`bench`, `aggregate`, `package_source`,
`validate_bundle`); the CLI body is exposed as `benchMain` in
`lib/bench_cli.dart` so both locations run identical code. `tool/bench/` is
reduced to a thin compatibility entrypoint (a `run.sh` exec forwarder, a
`bin/bench.dart` forwarder, and a `poltergeist_m0_bench_compat` pubspec that
path-depends on the package), so the legacy documented invocations still
work and results land beside the harness. Default CLI output moved from
`tool/bench/bench-results.json` to `packages/poltergeist_bench/` (run.sh
always passed `--output` explicitly, so CI/local results move with it;
fixture roots and path discovery are unchanged). New repo-root
`test/benchmarks/` contract tests prove the legacy entrypoints forward with
identical help/error output, exit codes, and exact run.sh shard routing via
the existing fake-driver hooks. ci.yml/release.yml point at the new
location (working directories, benchmark/ entrypoint names, artifact
paths); the `m0_bench` dispatch legs keep their shard topology and
envelopes. The import guard now verifies the harness through its own
package config and scopes the sanctioned dartssh2 carve-out to it; the
bundle validator's measurement-affecting path list still binds the frozen
M0 evidence to the tree that was measured, so committed evidence and the
v0.2.0 tag are untouched.

Validation: bench package analyze clean, 79 tests + 1 fixture skip from the
new location (identical to the pre-move baseline); check_config contract
suite 64/64 against the new paths; new forwarding contracts green; live
import guard, protocol guard, release-version lockstep (now 4 pubspecs
including the moved one), and `benchmark/validate_bundle.dart` on the
committed M0 bundle all pass. Docker/SSH-backed runs were not exercised
locally (no Docker on this host). Exact-head CI did cover the SSH
integration suite and the lifecycle-backed run.sh paths; the
**dispatch-only `m0_bench` measurements did not run there** (dispatch
jobs are skipped on PR/push CI), so those measurements stayed
unexercised between the relocation and the next dispatch. The restored
legacy aggregate forwarder (#101) is covered by the forwarding contract
tests instead. CI
trigger surface shifts slightly: `packages/**` path filters now match the
harness, so bench changes trigger the integration and pin-audit jobs.
That slice gave the M3 D12 benchmarks their planned home; it added no
benchmark, budget, checker, or enforcement — the tier-A entrypoints
remained open M3 work (open item 21) until the checker PR below landed
`test/benchmarks/check.dart` + `budgets.json`; the scenario collectors,
bench CI job, and `BENCH_ENFORCE_A` remain open.

## M3 — D12 offline benchmark checker (2026-09-14)

08 §6's checker only, in `test/benchmarks/`: `check.dart` (CLI, manual
argument parsing like the other root tools — no new dependency),
`check_core.dart` (pure evaluation: parsing/validation, aggregation,
comparisons, drift-state transitions), `budgets.json` (the P1–P7 catalog
mirroring 02 §12: exact operators, units, tiers per 08 §6, P3's
median-of-≥5 warm runs per 07 §3.4, everything else ≥3 in-job
repetitions), and a README documenting the formats and the future bench
job's artifact handoff. All scenarios stay unlanded and the tier-A
calibratedFingerprint stays null — no fabricated fingerprints, baselines,
or measurements; the tier-B baseline file is deliberately absent (the
M3 spike window notice path). Semantics implemented per 08 §6: `--tiers`
scoping of expected (landed) scenarios with missing/errored scenarios
failing in every mode; per-tier BENCH_ENFORCE_A/B env flags (unexpected
values are usage errors, never silently unenforced); medians of
in-job repetitions with per-scenario floors; exact boundary operators;
tier-B >25 % median regression against the committed baseline (strict);
tier-A controlled-axis drift skipping budget comparison with a loud
recalibrate notice and exit zero in every mode; tier-B controlled-axis
mismatch hard-failing once enforced but loud-zero while soft; the
uncontrolled CPU axis skipping with a notice, never auto-reddening;
drift-state time-boxing with main-run-only updates (PR runs never write,
a tier-B-blind run with --update-drift-state is refused), ≥7-run stale
escalation red once BENCH_ENFORCE_B, clean-main reset, and
missing/unreadable state counting conservatively at the threshold
(08 §6's "never a reset" — the recorded interpretation: unknown history
is treated as already at the escalation threshold under enforcement,
which can redden the first enforced run after state loss; recorded here
and in the README rather than weakened silently). Debug/JIT rows are
ineligible per tier and never satisfy a repetition floor. One design
point the plan implies but does not spell out: `mode` cannot be a
cross-row fingerprint axis (one `--tiers ab` job writes tier-A AOT rows
and tier-B profile rows into one file), so mode is validated per store
(row eligibility, calibration/baseline mode checks) instead — pinned by
tests. Drift-state writes are atomic temp+rename and touch nothing else.

Review round 1 (all findings triaged in the PR description; every
behavioral fix's regression failed before its repair): invalid UTF-8 in
an input document now exits 65 instead of surfacing as an IO error
(bytes are read raw, then decoded inside the malformed-input guard); an
existing-but-unreadable drift-state file counts as unknown history
instead of aborting with 74; negative baseline medians keep the
regression sign (magnitude division); a hand-built ResultsFile with an
uncatalogued scenario is rejected explicitly instead of hitting a
null-check; tier-B fingerprint drift is evaluated once per run, so
enforced controlled-axis failures and notices appear once per
mismatching axis, not once per landed scenario; the unknown-history
notice prints whenever the state was unreadable, not only when drift
fired. Minor hardening applied alongside: single-run timestamp shared
by evaluation and the state write, IO errors name the offending path,
fromJson always returns a validated catalog, eligible-mode literals
single-sourced, ambient BENCH_ENFORCE_* scrubbed from soft-mode tests,
pass-row assertions anchored on the table row, and the drift fixture
deduplicated. Declined: renaming calibratedFingerprint (documented,
versioned schema — churn), and skipping the state write on an
unknown-history clean run (the plan's clean-run reset is run-scoped;
skipping would leave enforcement hair-triggered after state loss).

Review round 2 (minor-only, all four applied): the locked-state test
skips on Windows (Process.run throws on a missing executable) and, per
round 3's follow-up, records a real skip via markTestSkipped when the
reader is privileged (root bypasses mode bits, so the EACCES path is
untestable there — a silent pass would hide the untested path); runChecker asserts the memory sinks never routed
output through addError (closing the vacuous-pass gap the round-1
recording introduced); the negative-baseline regression test covers the
higher-is-better branch too. Round 3 was a single minor finding; with
two consecutive minor-only rounds, steady state held and optional
review work ended there.

Validation: `dart analyze test/benchmarks` clean; `dart test
test/benchmarks` 81/81 (78 new: pure arithmetic/validation incl. the
committed-catalog mirror of 02 §12, CLI-level fixtures in temp dirs
covering scoped expectations, repetition floors, soft/enforced
combinations, both drift axes, drift progression/reset/PR-read-only,
conservative unknown history, dedup, and three real-subprocess runs
pinning process exits; plus the 3 pre-existing relocation contracts).
Logs: tasks/run3-task25/. No CI wiring needed: the dart_tools job
already analyzes/tests `test/benchmarks`. Scope is the checker only —
no collectors, scenarios, bench CI job, calibration, or enforcement
activation; item 21 stays open for those.

## M3 — pane rows announce entry kind (2026-09-14)

`_PaneRow`'s semantics label gains the entry kind: `paneRowSemantics` is now
`{name}, {kind}, {size}, {modified}` with four localized kind words
(file / folder / symbolic link / item) mapped exhaustively from the pinned
`RemoteFileType`; `other` announces "item", never "file". This restores the
Name-Kind-Size-Date contract of 02 §13 / 08 §7 — the missing-row-type
finding recorded in #94's inherited-UI review summary and confirmed on
current main; lane B's #94 disposition carried no UI edits, so the fix
lands here. Visual layout, icons, natural sorting, keyboard behavior,
selected state, activation, and the exclusion of stale/inert rows under
loss/loading/error are unchanged. Richer kind descriptions (MIME/extension
text like 02 §13's "PDF document" example) remain explicit future scope;
this slice ships only the existing `RemoteFileType` metadata.

Validation: a new widget test asserting the anchored per-field order on
each row's own semantics node — directory, file, symbolic link, and
`other`, including that `other` is never announced as a regular file —
failed before the change and passes after; the existing name–size–date
announcement test and the inert-rows-under-overlay regression are
preserved. App analyze clean, 571 tests; core untouched (analyze clean,
777 tests, 16 fixture skips); import, protocol, license-gate,
release-version, and pin-audit guards green. Bounded logs and exits:
`tasks/task23-logs/` in the worker's evidence area. Semantics assertions
prove the contract; no native screen-reader QA is claimed.

## M3 — pending remote-connect cancellation (2026-09-14)

A pending remote bind (`PanePhase.connectingRemote`, `loading` still
false) is now cancellable from the pane: plain Esc on the focused pane
abandons the in-flight connect at any point — including inside the
150 ms anti-flash grace — and past the grace the connecting body shows
a `Cancel` action (`pane.connect.cancel`, new `paneConnectCancel` ARB
string). Both reach the shell's existing sibling-aware
`_cancelPaneRecovery`: `detachRemote` when a sibling still browses the
server, `cancelRecovery` (which drops the server reference) when this
pane is alone. Cancellation invalidates the bind attempt, so a late
channel completion closes instead of binding or repainting. Esc
repeats are consumed without cancelling a replacement binding;
modified chords, unfocused panes, the loading/error Esc branches, and
`openingLocal` are unchanged. UI cancellation stays a presentation
abandon — no new engine API, no immediate physical-IO retirement
(open item 12's uncancellable VFS listing IO is unaffected).

Validation: six new widget tests failed before the change — four in
`pane_view_test.dart` (Esc before and after the grace, the post-grace
Cancel action, an Esc repeat over a replacement bind) and two in
`workspace_panes_test.dart` driving the production shell callback
(same-server sibling stays live with zero `disconnectServer` calls;
alone, only the pane's own reference is dropped) — all pass after.
App analyze clean; controller, cancel-regression, reconnect,
session-lifetime, localization-contract, and shell suites green.
Widget-render captures (labeled as such; rootless container, no
native capture): `tasks/run3-task26/connecting-{pre,post}-grace.png`
in the worker's evidence area.

## M3 — pane row-selection model (2026-09-14)

`SelectionState<Key>` is the pure, immutable selection service for pane
wiring (02 §2.5): single selection, toggle, anchored contiguous ranges over
caller-supplied ordered visible row keys, select all, and invert. Row keys
are opaque identities, never decoded names or indices. Cursor and anchor are
tracked as identities: `withRows` (navigation, sort, filter, or hidden-policy
replacement) prunes missing selected keys and drops a pruned cursor or anchor
to null rather than re-targeting a moved index — reordering keeps surviving
identities exactly. Duplicate row identities and unknown targets are
rejected explicitly; every transition copies its inputs and exposes only
unmodifiable snapshots. Standard file-manager anchor semantics, pinned by
tests: the anchor is the last non-range activation and survives range
extension/shrink (which recompute the selection as the anchor..target span,
replacing discontiguous leftovers); a range with no anchor spans from the
cursor (the fallback stays implicit — the recorded anchor stays null); with
neither, it degrades to a single selection of the target. Quick Select hands
its confirmed or restored `selectedKeys` over via `withSelectedKeys` on the
same listing, reusing the existing session's output; `withRows` then prunes.
No query/glob or session semantics reimplemented. PaneController still owns
its index cursor; nothing is wired yet.

Validation: 16 model tests written first (the missing-API compile failure is
the new-feature red). The first run then exposed one real gap before the
repair — `SelectionState.begin` did not reject duplicate rows or unknown
selected keys — plus two test expectations that contradicted the pinned
anchor semantics and were corrected against the documented rule. Full app
suite 593 green; analyzer clean; the localization contract allowlists the
model's validation diagnostics (programmer errors, never rendered).

Review round 1 (applied): both bulk validation paths (`begin`,
`withSelectedKeys`) test membership against a row set instead of O(n·m)
scans; `rows`/`selectedKeys` memoize one unmodifiable snapshot per state —
the reviewer's `late final` form is incompatible with a const constructor
(analyzer `late_final_field_with_const_constructor`), so the private
constructor drops its never-used `const` instead; `invert`'s no-op guard now
states the only satisfiable case (empty rows) rather than a disjointness
equality.

**Post-merge anchor-stability repair (2026-09-14, companion PR).**
Supervisor verification caught a runtime regression the review rounds and
my own tests missed: after row replacement pruned the explicit anchor, a
sequence of range activations re-derived its fallback endpoint from the
(moving) cursor each time, so select 2 → range 5 → prune 2 → range 3 →
range 4 selected {3,4} instead of {4,5} — violating this slice's own
stable extension/shrink invariant (probe: `pr106-anchor-probe.dart`, exit
255). The implicit-fallback documentation in the merged revision did not
preserve that behavior. A range with no anchor now adopts the cursor as
the recorded anchor, so the whole range sequence keeps one stable
endpoint; an adopted anchor is pruned by later row replacement exactly
like an explicit one. The regression (repeated forward/backward extension
and shrink around an adopted anchor, second pruning, degenerate
no-cursor case) failed before the one-line fix and passes after.

One ungated M3 model slice. Selection UI, keyboard/field wiring, controller
adoption, and pruning on actual pane changes remain with pane wiring; item
13 still gates raw-name metadata. No widget, D12 surface, persistence,
dependency/pin change, or source port; PORTS.md unchanged. M3 remains open.

## M3 — pane row selection wiring (2026-09-14)

The pane-row-selection slice: `PaneController` now owns the selection
through the 02 §2.5 model (`SelectionState` over stable row
identities) and the pane view and command registry drive it. Row
identity is explicit per listing — the entry's full path plus an
occurrence ordinal disambiguating decoded-name collisions (two raw
byte names decoding to the same string share a path string; the
ordinal keeps every row distinct without inventing a name heuristic,
and two colliding rows may swap ordinals across a reorder — item 13's
gap stays open, unsolved here). Pointer gestures follow the platform:
plain click singles, ⌘-click toggles on macOS / Ctrl-click elsewhere,
shift-click extends or shrinks the anchored range (shift wins the
modifier race on every platform). Arrows single-select on plain moves
and extend under shift; Home/End keep their plain behavior and extend
under shift; PageUp/PageDown are untouched (still unbound in this
surface). `edit.selectAll` (⌘A/Ctrl+A) and `edit.invertSelection`
(⇧⌘I/Ctrl+Shift+I) are registered commands with dual macOS/Ctrl
chords, ARB labels, `verbsEnabled` gating, and active-pane resolution
at invocation; the chord layer never fires while a covering route's
text field holds focus (asserted against a real TextField's own
Ctrl+A). Cursor compatibility is preserved: `cursorIndex`,
`setCursorIndex`, and `moveCursorBy` keep their contracts, with the
cursor now derived from the selection state's identity (an optional
`update` parameter carries the gesture). Reset happens on actual
location change and binding replacement/detach; a same-location
refresh (or a recovery re-list) keeps surviving identities and prunes
on acceptance, and a healed recovery listing prunes without reviving
stale-generation results. Esc-cancel restores the snapshot's selection
with its entries. Selected rows render a quieter container tint; the
cursor row additionally carries a leading 3 px bar — the bar is the
cursor's shape cue (M3's `primaryContainer`/`secondaryContainer` are
visually too close to carry it alone, confirmed by capture review);
the unfocused pane drops both to neutral tones (02 §2.1). Row semantics
announce selected state (02 §13). The stale rows under an inline error
are now pointer-inert too (an `IgnorePointer` scoped to the listing
subtree behind the error card, matching the key and semantics gates). Esc's deselect tier, the
context-menu select-on-right-click, Quick Select hand-off wiring, and
type-ahead remain with their owning slices; no Quick Select/filter/
type-ahead surface or file operation was added.

Validation: regression-first — the new controller and widget tests
failed to compile against the pre-slice API (missing methods/params,
the new-feature red; logs under `tasks/run3-task29/`), one real
regression was caught by the existing suite during development (Esc
restore briefly dropped the snapshot error; repaired before commit),
and review round 1's confirmed modifier race was reproduced red first
(Shift released inside the double-tap window collapsed a range click
to a single; modifiers are now captured at pointer-down, in the row,
before the delayed tap commits) before its repair.
New coverage: controller-level gesture semantics (single/toggle/range
grow+shrink both directions, adopted-anchor stability across pruning,
select-all/invert incl. empty listings), same-location refresh
prune/reorder with identity survival, new-location reset, cancel/restore
with selection, stale delayed listings, remote detach and recovery
pruning; widget-level wiring (plain/meta/control/shift clicks per
platform with the negative macOS-Ctrl case, plain/shift arrows,
Home/End with shift, keyboard repeats, distinct cursor/selected/plain
surfaces plus the cursor-bar shape assertion, selected semantics
flags, inert keys/taps under error and connection-loss, chords on both
platforms, active-pane-only scope incl. toolbar focus, covering
TextField/route suppression). App analyze clean, 627 tests pass;
core re-verified untouched (analyze clean, 777 tests, 16 fixture
skips); localization contract updated with the new command ids.
Readable opaque widget captures with real fonts (inspected, not just
generated): `tasks/run3-task29/selection-{active,inactive}-readable.png`.
Native screen-reader QA remains distinct and unclaimed. No core,
pin, benchmark, dependency, or PORTS change; M3 remains open.

## M3 — D12 checker policy repairs (2026-09-14)

Supervisor verification blocked task25 after #102 merged: six independent
contract/data-loss defects plus the privileged-reader skip fall-through
survived 81 green tests, exact-head CI, and four review rounds; the PR's
"14 resolved" thread claim was also false (replies, not closure). This
companion PR repairs them on a branch from main; the review history of
the four completed rounds carries over (confirmed important findings
reset the minor-only streak).

Repairs, each with a failing regression observed first (red/green logs
and the independent probe's before/after under tasks/run3-task25-repair/):
an errored repetition of an expected scenario now fails the run in every
mode with the repetition and message attributed — successful siblings
cannot hide it, and no budget/trend comparison runs for the incomplete
measurement; a read-only (PR) call no longer grades a hypothetical next
main count — evaluation now takes an explicit DriftRunKind (mainRun
advances and escalates on what it advances to; readOnly grades the
persisted streaks as-is, so six actual main runs stay six); drift-state
publication acquires an owned uniquely named temporary on the target
filesystem (`.checker-<pid>-<seq>.tmp`) — a pre-existing `<state>.tmp`
file or symlink is never overwritten or followed (that was concrete data
loss), and a failed publish cleans only the temp this run created; a
failed or unobserved main run no longer clears prior drift history —
reset requires a genuinely clean, observed tier-B comparison, a
no-news run leaves the store byte-identical, and genuinely fired drift
still counts when other gates fail; a valid empty results file is no
longer rejected — with no landed scenarios it prints the honest
no-budgets-evaluated outcome in soft mode (no fabricated fingerprint),
and with landed expectations it still fails explicitly; and the
privileged-reader guard in the unreadable-state test now returns after
marking the skip (markTestSkipped neither throws nor returns — #102
round 3 had accepted reviewer guidance to the contrary without
exercising the branch; the chmod-unavailable guard got the same fix).

Companion review round 1 (the confirmed major found a real hole in the
reset gate, fixed with a failing regression first): a partially
populated tier-B baseline (one expected scenario comparable, another
skipped for a missing entry) cleared prior drift streaks — the
OR-accumulated observation flag contradicted the run's own
"skipped comparisons preserve" invariant; reset now requires every
expected tier-B scenario that reached comparison to have actually
compared. Also applied: best-effort temp cleanup that cannot mask the
original IO error, a seeded prior streak in the clean-clears test (it
was empty-in/empty-out), host-neutral basename extraction, an explicit
fingerprint promotion instead of `!`, a loud notice when the results
file carries no rows at all, and a guarded no-news write that also
skips rewriting a known-empty store on clean runs (byte-identical).
Declined with mapping: duplicating the CLI battery as core-level
evaluate() tests — each suggested case already exists through the real
entrypoint (errored-soft, empty-rows-expected, readOnly grading,
reset preservation); one genuinely missing edge (a persisted
threshold streak reddening a read-only call) was added.

Validation: analyzer clean; `dart test test/benchmarks` 93/93 (11 new
regressions plus the split drift-preservation cases); the supervisor's
independent policy probe passes 7/7 (before: 6 failures) and the scoped
chmod-shim run reports a real skip (before: fall-through failure).
Thread debt also repaired on #102: all 18 review threads individually
re-verified and resolved via GraphQL, two misattached replies corrected,
and the four final suggestions dispositioned; the PR body's false
resolution/count claims were corrected in place.

## M3 — D12 P3 listing-overhead collector (2026-09-14)

The first tier-A scenario collector (07 §3.4 / 08 §6): 
`packages/poltergeist_core/benchmark/p3_listing_overhead.dart`, a pure-Dart
CLI over the production pool — a `PooledConnectionManager` browse channel,
private-key credentials from `POLTERGEIST_SSHD_KEY`, and the 08 §5
pre-seeded committed fixture pin (a healthy fixture never prompts; an
unexpected host-key review aborts instead of benchmarking an unverified
server). The protocol is fixed in code and tests: one retained channel
serves every pair; each pair times a minimal control listing and then the
target listing; stated warmup pairs are discarded before ≥ 5 measured
pairs; every row carries the raw pair timings, the unclipped
target-minus-control difference (negatives preserved), and a
detected-mode fingerprint — `dart compile exe` output reports aot,
source/kernel runs report jit, so a JIT process can never label itself
AOT. Rows match `poltergeist-d12-results-1`; the per-row scenarioConfig
axis records canonical paths, observed entry counts, warmups, and
repetitions; a tree that changes size mid-run fails the run at the
changing pair (error row, nonzero exit) instead of smearing one count
across the rows. Honest failure paths: a failed listing or
deadline writes the completed rows plus one error row and exits 1;
missing flags/env or aliasing paths exit 2 with actionable messages and
write nothing; channel close and server release are bounded and run on
every exit path. The collector issues only `listDirectory` and
`canonicalize` against caller-supplied existing distinct directories
(canonical aliasing rejected) — no writes to the fixture trees, no
retries. `dart run` lifecycle ownership stays with
`test/integration/run.sh --lifecycle-only` (documented real-fixture
command in benchmark/README).

Validation: tests written first (the missing-API compile failure is the
feature red); one real defect surfaced red before its fix — the result
captured `released` before the finally-bound cleanup ran, so every
failure path reported no release; the restructure made cleanup precede
the result and the regression went green. Twenty deterministic tests
(`test/benchmark/p3_listing_overhead_test.dart`): sampler
pairing/ordering, warmup discard, negative differences, repetition
identities, timeout/deadline/warmup failures, one-channel + cleanup
contracts over a fake `PaneChannel` (the production interface, no
sockets), usage validation, CLI subprocess contracts (help, missing
--output, missing env naming each variable, raw-identity pre-connect
rejection, sub-floor repetitions), the mode-detection rule table, and
the real `test/benchmarks/check.dart` CLI evaluating collector output
against a test-owned catalog whose calibration is derived from the
emitted fingerprint (pass exits 0; an enforced 120 ms overrun exits 1).
Core analyze clean; 797 core tests pass (16 fixture skips unchanged);
`test/benchmarks` 93/93; import and protocol guards green; `dart compile
exe` of the exact final source verified, with the binary's help/usage
contracts exercised. Docker is absent on this host: the fixture-backed
measurement did not run, and no number is claimed — the documented
real-fixture command awaits the CI bench job. Scope held: P3 stays
unlanded in budgets.json, calibratedFingerprint stays null, no CI
workflow, no enforcement activation — item 21 remains open for the
bench job, calibration, and the landed flip; P3's functional
cancellation gate (open item 12) is untouched.

**Companion repair (2026-09-14, same day).** Independent verification
blocked the merge's acceptance with a runtime-red probe: the whole-run
deadline was only checked between pairs, so a listing already in flight
was waited out — a 50 ms budget with a 5 s per-listing timeout returned
after 2018 ms and only then reported the deadline (probe
`pr108-deadline-probe.dart`, exit 255). A source audit found the same
ownership hole class #105 repaired for the checker: the results temp
name was written without an exclusive claim, so a preexisting file or
symlink at the predictable name would be truncated or followed. Both
are repaired with regressions observed red first: every control/target
await is capped at the lesser of the per-listing timeout and the
positive remaining budget, the between-legs guard never starts a target
after the control consumed the budget, and whole-run expiry attributes
distinctly from a per-listing timeout (the probe now returns in ~66 ms,
exit 0); the temp name is claimed with an exclusive create, only
recognized platform name-exists codes (POSIX 17, Windows 80/183) retry
with the next candidate, foreign resources are never written, followed,
or deleted, and only an owned temp is cleaned. The deadline stops the
wait, never the underlying VFS IO (no cancellation exists in the pinned
interface — open item 12); the docs state this and the bounded cleanup
retires the channel. No retry was added and no ownership pattern was
shared with the checker (mirrored, not refactored).

## M3 — sibling cancel-race repair (2026-09-14)

The fusion review's source-only finding, reproduced: the banner cancel
decided sibling sharing synchronously, but `cancelRecovery`'s detached
reference drop ran after the pane's awaited channel close — a sibling
binding the same server during that await re-registered the serverId's
pool reference, and the late `disconnectServer` removed whatever
reference was current (the engine keys by serverId), severing the
sibling's fresh binding. `PaneController.cancelRecovery` now takes a
`serverStillUnshared` predicate evaluated after the detach's awaited
release and the bind-attempt recheck; the shell — the sibling-knowledge
owner — passes it from `_cancelPaneRecovery`, so the controller learns
no sibling state and no engine layer grows UI knowledge. The predicate
and the engine send are atomic in the app isolate and same-port sends
are FIFO, so a sibling binding after the check reconnects on a fresh
reference instead of being severed — that ordering holds while bind
and disconnect messages share one engine port, a required invariant
of this fix. A sibling whose bind merely STARTED is also covered:
connectRemote publishes the pending binding synchronously before its
first await, so the predicate sees even an unsettled sibling connect
(pinned by the mid-flight regression). Alone-pane cancellation (the
reference still drops), the shared-server detach-only path, Esc and the
post-grace Cancel affordance, late-channel retirement, and replacement
binds during the await are unchanged.

Validation: red-first — a new `workspace_panes_test` regression parks
pane A's channel close on a held completer, binds pane B to the same
bookmark inside the window, then releases A; on the pre-fix code the
late `disconnectServer` fired (log `tasks/run3-task29/sibling-race-red.log`,
exit 1) and after the repair the shared reference stays, B remains
bound and listable, and the alone-pane drop test still passes
(`sibling-race-green.log`, exit 0). Review round 1's claimed mid-flight
hole was refuted with the sibling's open parked at the engine boundary:
the late check sees the pending bind and the parked open completes
undisturbed (`pr111-midflight-refutation2.log`, exit 0; its teeth were proven by
mutating the late check back to the unconditional drop and observing
the test fail — `pr111-midflight-teeth.log`, exit 1). Focused pane
suites — panes, cancel-regressions, reconnect, selection (state and
controller), and workspace shell — 161 green
(`sibling-race-focused-final.log`);
app analyze clean; full app suite 631 green
(`sibling-race-full-app-final.log`). Core, benchmark, pins, and
dependencies untouched.

## M3 — D12 per-scenario config axis (2026-09-14)

Fusion review of the #108/#110 merge found an independently reproduced
D12 blocker the original task28 rounds missed: the checker treated
`scenarioConfig` as one job-wide fingerprint axis while P3 emits a
scenario-specific value, so a planned single P3+P7 results file exited
65 and the singular tier-A calibration could match at most one
scenario. Reproduced with a real CLI fixture before editing (combined
P3+P7 file, exit 65; the same fixture exits 0 with both rows reported
after the repair). The axis split is now explicit: job-wide controlled
axes (runner image, arch, Dart/Flutter version; mode validated per
store; CPU row-equality) versus per-scenario config — one config within
a scenario's repetitions (conflicting configs are a malformed
measurement set, exit 65), distinct configs permitted across scenarios
in the one results file 08 §6 prescribes. Each landed tier-A scenario
compares against its own calibrated config while common-axis drift
handling is unchanged (tier-A skips never redden; tier-B controlled
mismatch still fails once enforced). Migration is compatibility-safe:
budgets schema `-2` is canonical (per-scenario `calibratedScenarioConfig`,
required when a tier-A scenario lands; the singular calibration records
common axes only), the legacy `-1` stays readable — its singular config,
when present, calibrates every tier-A scenario, with a loud deprecation
notice — and mixed forms are rejected explicitly (`-1` carrying the
per-scenario field; `-2` calibration claiming a job-wide config;
landed tier-A without its config; a tier-B baseline claiming a job-wide
config). Rollback is equally explicit: on revert, `-2` catalogs and
multi-config results files fail schema/row validation with these
messages rather than being silently misread. No tier-B scenario carries
a config yet; per-scenario tier-B baseline configs arrive with the first
config-carrying tier-B collector (baseline schema unchanged until then).

Same PR repairs P3's partial-evidence attribution (fusion item 2,
regression red first): the sampler mutated the observed entry counts
before its mid-run identity guard, so rows completed at the frozen size
were stamped with the later changed count. The failure outcome now
carries the frozen identity — every row, ok and error, keeps
target-entries=10000 — and the changed observation appears only in the
error text (10000->9999). #110's exclusive-temp and deadline semantics
are untouched. Also added an AGENTS build note after reproducing it from
a fresh checkout: the root benchmark tests need standalone `dart pub
get` in `packages/poltergeist_bench` and `tool/bench` before `dart test
test/benchmarks` (exact paths in AGENTS.md; before/after logs under
tasks/run3-task28-scenario-config/).

Scope held: no app files, no engine production behavior, no CI bench
job, no real measurements or calibration values, P1–P7 all unlanded,
calibratedFingerprint still null — open items 12 (cancellation gate), 21
(bench job/calibration/landed flip), and M3 closure remain open.
Validation: `dart test test/benchmarks` 110/110 (17 new regressions
across schema forms, per-scenario axis, drift policy, and legacy
compatibility), core benchmark tests 34/34 (two delayed-change
regressions added red first, the two existing identity-guard tests
strengthened to pin frozen counts), full core suite and analyzers green,
import and
protocol guards green, `dart compile exe` of the exact final P3 source
verified.

## M3 — Quick Select field: UI, command, controller wiring (2026-09-14)

`selection.quickSelect` (⌘E/Ctrl+E, 02 §2.5) is live: the command is
registered pane-scoped and resolves the active pane at invocation, and
`PaneController` owns the field's visibility — `openQuickSelect`
captures the visible listing's name map plus the current selection as
the session baseline, the strip below the path bar carries a text field
with an Add/Remove segmented toggle, every query or mode edit recomputes
the preview from that baseline through `QuickSelectState`, Enter keeps
the preview, and Esc restores the opening selection (both return focus
to the listing). Callers keep §2.5's ordering: hidden policy is applied
before matching because the matcher only ever sees the accepted listing,
and names containing U+FFFD are excluded from the match map while a
manually selected flagged row survives in the baseline under both modes
(real flag metadata is open item 13's; the decoded-name signal is the
documented stand-in). Sessions end before every listing or policy
replacement — `_issueNavigation` and `_applyEntries` restore the
baseline against the old row identities before `withRows` prunes — so a
stale session can never restore into a new listing, and a controller-
side session end returns stranded primary focus to the listing. The
command layer now guards all chords field-first (02 §8.2): while any
`EditableText` holds primary focus no registered chord fires, so the
field's own editing shortcuts (⌘A/⌘C/⌘V/⌘X/⌘Z and the Ctrl equivalents)
reach it, and the pane's single keys stay inert under the field.

Validation: controller session tests cover open/close, baseline
recomputation, Remove mode, flagged exclusion with preselected survival,
hidden-before-match, empty-query no-op, Enter/Esc, late-edit ignore,
navigation/refresh invalidation with prune ordering, stale-answer
safety, and no re-baseline on a second open; widget tests pin the
field-below-path-bar placement, the toggle, live preview, key
suppression, and focus return; the command test covers registration,
scope, per-platform activators, active-pane resolution, and the
field-first chord guard. Real-font captures (DejaVu + MaterialIcons)
of the closed strip, Add mode, and Remove mode are under
`tasks/run3-task30/`. Full app suite and analyze green.

## M3 — D12 P7 scan-rate collector (2026-09-14)

Second tier-A collector in
`packages/poltergeist_core/benchmark/p7_scan_rate.dart`, a pure-Dart
entrypoint following the accepted P3 pattern (#108/#110/#112): it
measures 02 §12's P7 scan rate ("sync scan rate, LAN", `atLeast 1000`
entries/s) as **sustained bulk listing throughput of a fixture tree over
one retained browse channel** — the measurement substrate of 05 §3's
`TreeScanner` (the engine itself lands later; the scenario gates at M8).
Each measured repetition recursively scans the canonicalized target tree
with at most 8 outstanding `listDirectory` calls — 05 §3's pipelined
readdir at D9's frozen `readdirDepth` — counting every entry (symlinks
counted, never descended) and dividing by unclipped elapsed seconds.
Warmups (≥1, default 2) are discarded; ≥5 measured scans are enforced by
the collector — stricter than budgets.json's spec-mirrored P7 floor of 3
(08 §6's generic floor; M8 names none, while P3's 5 comes from 07 §3.4's
explicit median criterion). Rows emit `scenario: 'P7'`, `unit: 'entries/s'` in
the shared `poltergeist-d12-results-1` document with a P7-specific
`scenarioConfig` (canonical root, entry count, readdir depth, warmups,
repetitions) on the per-scenario axis #112 established, so one results
file carries P3 and P7 rows side by side.

P3's seams are reused, not copied: `detectRunMode`, `medianOf`,
`P3FingerprintFields`, and `p3ResultsSchemaId` are imported from the P3
source; the owned exclusive-temp publication is a faithful mirror of the
`p3TempNameAttempts` pattern (the same ownership class the checker's
drift state carries) — no P3 file churn. The honest-failure contract is
identical: usage errors exit 2 with no results file; measurement
failures exit 1 with partial rows plus an error row carrying frozen
entry counts; publication I/O exits 74. The whole-run deadline bounds
both call issuance and the pipeline drain, so an in-flight listing is
never waited out past the budget; the run deadline and per-listing
timeout are attributed honestly (`run deadline` vs `listing timeout` in
the error text). A mid-scan entry-count change fails the run; completed
rows and the error row keep the frozen identity.

Scope held: no app files, no engine/lib production changes, no fixture
changes, no CI job or `BENCH_*` enforcement, no calibration values — P7
stays `landed: false` and P1–P7 all unlanded; open item 21 still owns
the bench job, calibration, and the landed flip. Validation:
`packages/poltergeist_core/test/benchmark/p7_scan_rate_test.dart` adds
39 tests (pipelined-walk ordering and depth bound, warmup discard,
symlink non-descent, mid-run count-change guard incl. frozen partial-row
configs, deadline/timeout attribution, owned-temp collision and symlink
safety, channel cleanup on every path, CLI subprocess contracts, and the
real `check.dart` CLI evaluating collector output — including a one-file
P3+P7 mixed-config run under `--tiers a` with both scenarios unlanded,
exit 0, both reported). `dart analyze packages/poltergeist_core` clean;
`dart test packages/poltergeist_core` 844 green; `dart test
test/benchmarks` 110/110 after standalone pub gets; `dart compile exe`
of the exact source verified plus `--help` smoke of the binary (logs and
exits under `tasks/run3-task31/`). Docker is unavailable on this host,
so the real-fixture measurement command is documented in
benchmark/README, not locally claimed — the CI bench job owns the first
real run.

## M3 — D12 P5 drop→start collector (2026-09-14)

Third tier-A collector in
`packages/poltergeist_core/benchmark/p5_drop_to_start.dart`, a pure-Dart
entrypoint following the accepted P3 (#112) and P7 (#115) patterns: it
measures 02 §12's P5 "drop → transfer starts (no upfront tree stat)",
`lessThan 500` ms, as **the time from a drop event until the first
payload byte of the first transfer item arrives** — the measurement
surface for the M4 transfer queue's drop→start leg. The queue itself is
M4 work and deliberately not implemented here; the collector models the
leg over the existing seams: the retained browse channel classifies the
drop (one stat) and descends to the first regular file by listings only
(symlinks never followed), then each leg leases a transfer channel via
the production `leaseTransferChannel` and times the download to the
first byte through a counting `StreamSink` that cancels on arrival — the
lease acquire/release pair is inside the measured window because
queue-less drop→start includes it.

The structural half of the budget is a falsifiable contract, not prose:
the drop→start path issues exactly one stat plus listing-only descent,
and the deterministic test counts stat calls through a fake filesystem
at 1k and 50k entries and requires identical counts ("O(first file), not
O(tree)" — a path that stated the tree upfront would grow with it).
Every row carries `statCalls`/`listingCalls`/`firstFile`/
`firstChunkBytes`/`legSettledMs` provenance, and a per-leg change in
either count fails the run as an identity change alongside the frozen
kind/root-listing/first-file axes. Warmups (≥1) are discarded; ≥5
measured drops are enforced (stricter than budgets.json's generic
P5 floor of 3). Rows emit `scenario: 'P5'`, `unit: 'ms'` in the shared
`poltergeist-d12-results-1` document with a P5-specific
`scenarioConfig`, so one results file carries P3, P5, and P7 rows.
First-byte semantics are honest in both directions: the collector's own
post-byte cancellation settles the leg cleanly, a cancellation or
failure before any byte is a leg failure, and an empty first file fails
("unobservable") rather than reporting full-download time as "start".

Scope held: no app files, no production transfer-queue or engine
changes (the lease/sink seams already existed), no fixture changes, no
CI job or `BENCH_*` enforcement, no calibration values — P5 stays
`landed: false` and P1–P7 all unlanded; open item 21 still owns the
bench job, calibration, and the landed flip. Validation:
`packages/poltergeist_core/test/benchmark/p5_drop_to_start_test.dart`
adds 45 tests (the 1k-vs-50k flat-stat structural assertion,
listing-only descent, file/symlink/empty-tree drop shapes, warmup
discard, deadline/timeout attribution incl. the in-flight-await probe,
mid-run identity changes with frozen partial-row configs, owned-temp
collision and symlink safety, per-leg lease and channel cleanup, CLI
subprocess contracts, and the real `check.dart` CLI evaluating
collector output — including a one-file P3+P5+P7 run under `--tiers a`
with all scenarios unlanded, exit 0, all reported). `dart analyze
packages/poltergeist_core` clean; `dart compile exe` of the exact
source verified (logs and exits under `tasks/run3-task33/`). Docker is
unavailable on this host, so the real-fixture measurement command is
documented in benchmark/README, not locally claimed — the CI bench job
owns the first real run.

## M3 — pane type-ahead buffer (2026-09-14)

02 §2.5's type-ahead is live on the pane focus node: printable keys
accumulate into a per-pane buffer, 1 s of inactivity resets it (every
keystroke re-arms), and the first row whose decoded basename matches
the buffer as a prefix becomes the cursor and scrolls visible — no
match is a no-op. Space never accumulates (reserved for §2.6's
file.preview), so space-bearing names match by their non-space prefix;
control characters and modified chords never reach the buffer. The
matcher is deliberately NOT Quick Select's: Quick Select keeps §2.3's
simple case fold with substring/glob shapes, while type-ahead folds
through canonical decomposition + mark removal + case folding —
two specified semantics, two matchers. The fold ships as a generated
Unicode 17.0.0 table
(`lib/services/unicode_diacritic_fold_data.dart`, built by
`tool/unicode/generate.dart` from hash-pinned `UnicodeData` and
`CaseFolding` fixtures), covering recursive decompositions and the
Hangul jamo formula. §8.2 ordering is preserved: type-ahead is inert
while any text field holds primary focus (the Quick Select field, an
outside field — the `hasPrimaryFocus` gate covers all descendants and
non-descendants alike), while a stale listing is dimmed, or under the
connection-lost scrim; Esc clears a pending buffer below
navigation-cancel and above deselect; a listing replacement drops the
buffer with the rows it matched. The buffer renders as a transient
bottom-center badge that unmounts on reset and announces through its
own live-region semantics node (`paneTypeAheadBadge`, ARB-authored).
Hidden policy runs before matching because the matcher only ever sees
the accepted listing; flagged (U+FFFD) names stay excluded from
by-name matching — the same caller-side stand-in as Quick Select until
item 13 lands real flag metadata — while remaining selectable by
cursor and click.

Validation: fold unit tests cover ASCII, composed/decomposed
diacritics, recursive decompositions, simple-fold-only letters, Hangul
jamo equivalence, spacing-mark survival, and table-wide idempotence;
controller tests under a fake clock pin accumulation, the exact 1 s
reset with per-keystroke re-arm, case/diacritic prefix matching,
first-match and no-match no-op, flagged exclusion with continued
selectability, hidden-before-match, basename-only matching, buffer
drop on listing replacement, and the Esc-tier clear; widget tests pin
key dispatch, badge visibility + live-region semantics + the exact
announcement, space exclusion, scroll-reveal on jump, field and
outside-field suppression, Esc ordering, flagged-row tap
selectability, dot-key behavior, and modified-chord exclusion.
Real-font captures (DejaVu + MaterialIcons) of the idle pane, the
pending badge, and the post-reset state are under
`tasks/run3-task32/`. Full app suite and analyze green.

## M3 — D12 tier-A bench job (2026-09-14)

The `bench` job in `ci.yml` runs the three tier-A collectors per 08
§5/§6/§8: a `detect_bench` paths-filter gate (PRs touching
`packages/**/lib|test|benchmark/**`, `packages/**/pubspec.yaml`, root
pubspec/lock, `test/benchmarks/**`, `test/integration/**`, the two
scripts, or `ci.yml`; always on `main`/dispatch) feeds a single
`ubuntu-latest` job that enters `run.sh --lifecycle-only` — the shared
§5 lifecycle, not a forked copy — and hands off to
`scripts/bench-tier-a.sh`, which compiles each collector AOT
(`dart compile exe`), runs P3/P5/P7 against `sshd-modern` on loopback
with the README-documented targets, and merges the per-scenario
documents into one `bench-results.json` via
`scripts/merge_bench_results.dart`. The collector failures run to
completion so partial rows and error rows still publish, and the script
exits non-zero on any collector failure — a silently skipped benchmark
is how budgets die. `check.dart --tiers a` grades the merged file under
`if: always()`; `bench-results.json` plus the per-scenario documents
upload as the always-present `bench-results` artifact (the future
drift-state fetch's store). Every scenario stays `landed: false`, no
`BENCH_ENFORCE_*` flag is set, no calibration values are fabricated —
the job's first runs are reports, and the landed flip plus calibration
are the dedicated baseline-refresh procedure (08 §6). Drift state is
never written here: `--update-drift-state` requires `--tiers` including
`b`, and PR runs are read-only by contract. A missing Docker daemon or
fixture fails the job loudly; there is no `continue-on-error` anywhere
in the path.

Validation: `scripts/merge_bench_results.dart` analyzes clean and was
dry-run locally against three synthetic per-scenario documents (15
rows, distinct `scenarioConfig`s) — merge exit 0, `check.dart --tiers a`
exit 0, all three reported unlanded (log under `tasks/run3-task34/`).
`dart test test/benchmarks` (110) and `dart test test/integration` (64)
pass; the workflow YAML parses and the new jobs are structurally present.
The fixture-backed run itself is unverifiable on this host (no Docker);
CI owns the first real run. Item 21 narrows accordingly.

## M3 — P3 collector CLI parser repair (2026-09-14)

The P3 collector's `flagValue` carried the flag-duplication and
flag-as-value flaw the P7 review repair fixed in #115 (its deferred
follow-up, recorded in commit `12999d1`): a repeated flag silently took
the first value — `--repetitions 5 --repetitions 20` under-collected
rows while still passing the checker floor — and a flag token in a
value position was bound literally (`--target --control /b` parsed
`--control` as the target path). The repair applies the P7/P5 shape
verbatim at the parser layer: a repeated flag throws a usage error
naming the flag, and a value starting with `-` throws "looks like an
option". No collection-semantics, schema, deadline, or temp-ownership
change; P5/P7 parsers untouched (P5's later positional/non-empty
hardening stays its own slice — P7, the reference repair, carries
neither).

Validation: four regressions failed red before the fix — unit-level
repeated-flag and flag-as-value rejections (message names the flag)
plus subprocess contracts asserting exit 2 and the distinctive error
text — then went green alongside a still-parses test. `dart analyze
packages/poltergeist_core` clean; the P3 file runs 39 tests green;
`dart test packages/poltergeist_core` 905 pass (16 fixture skips
unchanged); `dart test test/benchmarks` 110/110 after the standalone
pub gets (logs and exits under `tasks/run3-task36/`).

## M3 — Filter field: view.filter (2026-09-14)

`view.filter` (⌘F/Ctrl+F, 02 §2.5) is live: the command is registered
pane-scoped and resolves the active pane at invocation, and
`PaneController` owns the strip's open state plus a transient query
that lenses the accepted listing in place — the pre-filter listing is
retained (`_listing`) so clearing or widening re-shows rows without a
re-list, and the query survives navigation and refresh within the
binding (§8.2's Esc order requires it to outlive an in-flight load)
while a replaced binding or a detach drops it with the rows it hid.
Matching is a third, separate matcher — `ListingFilter`, a plain
case-insensitive substring — deliberately NOT type-ahead's diacritic
fold (§2.5 never extends folding to Filter: `e` does not match
`Étude`) and NOT Quick Select's glob query (`*` is an ordinary
character). The strip drops in below the path bar with a live
`visible of total` helper and a Clear affordance, stays mounted while
a query is active after the field yields focus (the helper is the only
visible proof the lens is on), and a re-invocation re-focuses the
mounted field through a focus-generation counter. Esc follows §8.2's
tiers: the field's own Focus clears at the field tier while focused;
once unfocused, the pane's Esc chain clears the filter below
navigation-cancel and above the type-ahead buffer. Filtering to zero
renders §2.7's dedicated `No items match "q"` state with a Clear
button — never a blank pane. Every `changeFilterQuery` replacement
ends an open Quick Select session BEFORE the restored baseline prunes
against the filtered rows (the #114 invalidation seam), drops any
pending type-ahead buffer, and re-folds the visible names so
type-ahead matches the filtered listing; pane keys and type-ahead stay
inert while the field holds focus, and registered chords keep the
command layer's field-first guard. Filter state is per-tab and
transient by construction — it never reaches ViewPreferences, §3
workspace snapshots, or session restore (a forgotten filter reads as
data loss); the decision is stated where persistence lives in
`view_preferences.dart` and pinned by a toJson key-set test.

Validation: matcher unit tests cover case-insensitive substring both
directions, the no-fold contract against `Étude`, literal `*`,
basename-only matching, and the empty-query pass-through; controller
tests cover apply/clear, visible-of-total counts, verbs gating and the
closed-field edit guard, Quick Select end-before-prune ordering,
type-ahead over filtered rows, buffer drop on edit, survival across
navigation/refresh, Esc-cancel snapshot restore re-applying the query,
rebind and remote-detach drops, and the no-persistence pin; widget
tests cover strip placement and focus, live filtering with the count
helper, Enter-keeps/Esc-clears at both tiers, navigation-cancel
outranking the filter tier, the filtered-empty state and its Clear,
key and type-ahead suppression under field focus, and re-invocation
refocus; the command test covers registration, scope, per-platform
activators, and active-pane re-resolution. Real-font captures (DejaVu
+ MaterialIcons) of the closed strip, the active filter with helper,
the filtered-empty state, and the post-Esc clear are under
`tasks/run3-task35/`. Full app suite and analyze green.

## M3 — Tab strip + tab lifecycle within a pane (2026-09-15)

Each pane is now a `PaneTabsController` — the strip's ordered tab set,
active tab, and ghost ring — over per-tab `PaneController`s, with the
workspace owning exactly the two strips (03 §6). Tab ids are
predictable (`pane.left.tab1`, …) and double as the engine channel's
`paneTabId`. `tab.new` (⌘T) honors the persisted "New tabs open"
preference (`NewTabTarget.duplicate` default / `home` / `launcher`,
read at open time; the shell's initial tab is explicitly `home` since
startup has no duplicate source, and a `duplicate` ⌘T on an empty
strip — the post-last-close launcher — likewise has no source and
opens an unbound launcher tab); `tab.close` (⌘W), `tab.reopenClosed`
(⇧⌘T), `tab.next`/`tab.previous` (⌃⇥/⌃⇧⇥ plus ⇧⌘]/⇧⌘[) are registered
app-scoped commands resolving the active pane's strip at invocation —
cycling never crosses panes. The close guard lives INSIDE
`requestCloseTab` (the SEA-009 lesson): chord, chip ✕, and
middle-click all funnel through the one operation, whose trigger
registry (navigation via `loading`, inline rename via
`inlineRenameActive`, plus declared-for-later folderSize /
applyToEnclosed / syncAnchor) consults the presenter only when a probe
fires — a trigger with no presenter fails closed, and a re-entrant ⌘W
rides the in-flight confirmation rather than stacking dialogs.
Closing the last tab leaves the pane on the launcher (02 §2.7) —
never blank, never auto-opened. ⇧⌘T pops a LIFO ring of ten ghosts —
the most recently closed tab reopens first, and the oldest ghost is
evicted at the cap.
Binding + location re-open and the transient lenses (filter query and
field state, hidden-file override, view mode) restore through
`restoreTransientState`; selection and in-flight state are not
restorable (selection keys name dead listing identities) — the ghost
doc says so. Remote closes reuse the banner-cancel's sibling rule:
the pooled reference drops only when the closed tab was the server's
last binding, re-checked after the awaited channel release. Chip
titles are the folder name; remote chips carry the `ServerBadge`
accent + `ServerStateGlyph` dot (Séance `server_appearance.dart`
ported for the badge/accent/icon half — PORTS.md entry added) and the
tooltip shows full path + server. Per-tab state (location, listing,
selection, cursor, filter, hidden override, view mode, Quick Select
session) lives on each tab's controller, so switching is an atomic
pointer change with no cross-tab leak. The listing pipeline gained a
pre-filter stage (`_sortedListing` → hidden policy → `_listing` → §2.5
filter → `entries`) so `showHidden` re-derives without a re-list, and
the accepted listing keeps its `List.unmodifiable` contract.
`AppPreferences` persists `tabs.newTabTarget` (unknown values fall
back to `duplicate`); `main.dart` loads it before constructing the
app. `tab.select1`–`9` stays unregistered this slice (menu path waits
for the menu task). The §8.3 table's `tab.reopen` is renamed to
`tab.reopenClosed` to match the brief.

Validation: 28 `PaneTabsController` unit tests cover targets,
cycling/wrapping and pane scoping, guard fire/decline/stale outcomes,
no-presenter fail-closed, re-entrancy, ghost ring cap and restore,
sibling-aware remote close, and dispose; widget tests cover the strip
chrome (badges, dots, tooltips, middle-click routing), the launcher,
command registration/bindings/enablement, and active-pane resolution;
the existing pane/workspace suites were re-homed onto strips
(`test/support/test_panes.dart`). Real-font captures of the multi-tab
strip, the guarded-close dialog, and the post-last-close launcher are
under `tasks/run3-task38/`. Full app suite (753 tests) and analyze
green; core and benchmark suites unchanged and green.

## M3 — P3/P5 bench medians explained (2026-09-14)

Investigation of the first fixture-backed tier-A results: explain why
P7 passes while P3/P5 miss 02 §12's budgets by ~90×/~10× before any
`landed` flip. Evidence: the merged and per-scenario `bench-results`
artifacts of main runs 34895640926 (`44cf810`) and 34900409596
(`7086503`) plus PR runs 34894693487 and 34893060698 — all
`ubuntu-latest@20260907.300.1`, AOT, AMD EPYC 7763.

Medians across the four runs: P3 4 340–4 554 ms (control ~140–147 ms,
target ~4 482–4 719 ms per leg), P5 4 676–4 884 ms (1 stat + 1 listing
call per drop), P7 2 228–2 331 entries/s (10 813 entries / 10
directories). Within-run spread < 2 %: stable, not noisy.

Decomposition — every scenario lands on the same floor:

- OpenSSH sftp-server caps one `READDIR` reply at 100 entries
  (`sftp-server.c`: "send up to 100 entries in one message"), each entry
  `lstat`'d server-side; dartssh2 3.0.2's `listdir` awaits each batch
  before requesting the next (no pipelining), and the pinned
  `RemoteFileSystem.listDirectory` is an all-or-nothing Future over it.
  A 10 000-entry listing is therefore ~104 strictly sequential
  request/response pairs (OPENDIR + ~101 batches + EOF + CLOSE).
- The control leg (4 round trips, ~140–147 ms) prices one sequential
  pair at ~35 ms; the target legs price it at ~44–46 ms — consistent
  once each big reply's ~100 server-side lstats and ~15 KB payload are
  accounted for. M0's own evidence independently corroborates the
  floor: `pipeline-readdir-1-lan` listed the eight 100-entry sibling
  directories serially in 1 659 ms on the same runner+fixture stack
  (run 33563514640) — ~32–40 sequential request/response pairs (~4–5
  per directory: OPENDIR, the 100-entry-capped READDIR replies, EOF,
  CLOSE), i.e. ~41–52 ms per pair — versus 220 ms at depth 8.
- P5's measured window is confirmed correct: the leg's stat, scan
  listing, transfer-channel lease, and first-byte read are all inside
  the drop→first-byte interval, and the VFS listing is all-or-nothing —
  the "lazy scan to the first file" still pays the full ~104-round-trip
  root listing. `legSettledMs` ≈ value + ~0.2 ms cancel unwind.
- P7's critical path is the same serialized 10 000-entry stream; the
  nine remaining directory listings pipeline under it at depth 8, so a
  scan ends at ~4.6–4.8 s ≈ 10 813 entries / ~2 300 entries·s⁻¹ — the
  identical bottleneck's ceiling (≈44 ms per 100-entry batch).
- No netem shaping is involved: `run.sh` never invokes
  `netem-profile` and the fixture entrypoint installs but does not
  apply it. The ~35–52 ms per-request cost is the environment itself —
  loopback to a Docker-published port (userspace forwarding) on a
  shared-runner vCPU plus sshd per-request work — not a true sub-ms
  loopback.

Defect audit: no population/setup leak (channel open, canonicalization,
and both warmups precede the measured legs), no cold-channel first
repetition (repetition 0 is not elevated), minimal control (2 entries),
correct interval boundaries, unclipped honest values, stable tree
identity enforced per run. The measurement plumbing is correct; the
numbers are runner/fixture reality — no code change was made.

Consequence for landing: P3's < 50 ms is unreachable by construction on
this environment (~104 sequential pairs would need < 0.5 ms each; even
a true ~1 ms LAN yields ~100+ ms). Open item 22 records the owner
decision this needs before any `landed` flip; see also the
"First fixture-backed observations" note in `test/benchmarks/README.md`.
No `landed` flips, `budgets.json`, or workflow changes here.

## M3 — D12 tier-B UI benchmark harness (2026-09-15)

The P1/P2/P6 profile-mode suites land under
`app/poltergeist_app/integration_test/perf/` with
`scripts/bench-tier-b.sh` driving them via `flutter drive --profile -d
linux` under Xvfb; P4 waited on lane A's tab UI and lands in the next
section. Each suite boots the
production app over a real engine session on a per-run temp support
directory, drives the left pane's production `PaneController`, and
captures real raster timing through
`SchedulerBinding.addTimingsCallback` — no `traceAction` summaries, no
synthetic timing. P1/P2 anchor first paint at the navigate()-issue
timestamp through the first frame whose build began after the listing
landed; P6 runs a scripted 30 s linear scroll of the 100 000-entry
fixture, derives the refresh rate from the smallest positive vsync
interval — dropped frames only lengthen intervals, so the minimum is
the display period a median would mask — (recorded in
`scenarioConfig`), and reports late-frame percent against
the measured deadline — a capture under `floor(30 s × measured Hz)`
publishes an error row with the count, never a ratio over a too-small
sample.

Timing reduction is pure Dart in `app/poltergeist_app/lib/bench/`
(`frame_stats.dart`, `bench_results.dart`) with deterministic unit
coverage in `test/bench/` (9 frame-stats + writer/schema cases). The
one non-obvious mechanism: the suites set
`LiveTestWidgetsFlutterBindingFramePolicy.fullyLive`, because the
default `fadePointers` policy silently skips platform BeginFrames that
nothing pumped — under Xvfb (no Present extension, no free-running
vsync) a ticker-driven scroll starves without ever timing out.
llvmpipe's observed rate is ~11 fps; the measured-Hz floor and
deadline scale to the platform's real rate.

CI: the `bench` job installs the GTK/Xvfb/Mesa toolchain and runs the
tier-B leg on main pushes and manual dispatch only — never on PRs,
since PR invocations must not mutate drift state — grading
`--tiers ab`/`--tiers a` accordingly, with `if: always()` evaluation
and upload so partial results still grade and publish. No
`BENCH_ENFORCE_B`, no `landed` flips, no committed baseline: tier B is
trend-only until M9 per 08 §8.

Local validation on llvmpipe+Xvfb (evidence, not budgets): P1 ≈
1.0–1.5 s, P2 ≈ 10.7–14.8 s first paint (engine scan dominates; both
scenarios remain unlanded), P6 309–315 frames/rep at a measured
10.00 Hz with 100 % of frames past the 100 ms software-stack deadline
— real numbers from a software rasterizer, which is exactly what
trend-only collection exists to expose.

## M3 — app menus render from the command registry (2026-09-15)

Menus are now a rendering of the registry (07 §3.4, D21), never a
parallel list: `RegisteredCommand` gained `menuPlacement` —
`(menu, order, group, submenu)` declared at each registration site —
and `buildAppMenus` derives the menu model from whatever is actually
registered, so unplaced commands are omitted outright (no disabled
placeholders for future commands) while the gapped order slots keep
placement stable for them (02 §9's table). On macOS the model is
pushed to the native bar through `PlatformMenuBar` — the application
menu is standard chrome only (About/Services/Hide/Quit, no
Poltergeist commands) and the Window menu leads with the native
Minimize/Zoom group; on Windows and Linux the same model renders as
a Flutter `MenuBar` strip above the toolbar. Placement today: File
gets the tab block (New/Reopen Closed/Close), Open, and the
ssh-config import; Edit gets Select All/Invert/Quick Select/Filter;
View gets Refresh and the interim Connections entry; Go gets
Enclosing Folder; Window gets Next/Previous Tab. Empty menus —
Commands, Help — do not render. Enablement is `command.enabled()`
verbatim (the same predicate the chord layer and toolbar consult,
rebuilt off the shell's shared workspace listenable), and menu hints
display the command's registered activator rather than a duplicated
chord spelling.

The M3 menu spike's outcome is recorded as a D11 amendment in
00-OVERVIEW: `PlatformMenuBar` alone expresses 02 §9's Edit-menu
retargeting — only modified chords bind as native key equivalents
(an unmodified equivalent would steal typing), and a field-owned
chord's menu activation re-dispatches the matching text intent to the
focused `EditableText`, so the Swift `poltergeist/menu` focus-flag
channel is unnecessary (SEA-008 is moot by construction).
`NSWindow.allowsAutomaticWindowTabbing = false` is set in
`MainFlutterWindow`. §8.1's keyboard-completeness invariant is a
test that walks the shell's live registry per platform — every
command must have a chord, a menu path, or an entry in
`kMenuReachabilityExceptions` (empty today).

Validation: `flutter analyze` clean; menu tests cover derivation
(placement/order/groups), unplaced omission, submenu nesting, macOS
chrome (app menu + window provided items), enablement and
shortcut-hint parity, the retarget path (⌘A selects field text under
focus, runs the command otherwise), and the registry invariant;
real-font captures of the bar and open File/Edit/View menus are
under `tasks/run3-task40/`. The palette stays M9.

## M3 — D12 tier-B P4 tab-switch suite (2026-09-15)

The P4 scenario joins the tier-B leg now that pane tabs are on main
(#123). `p4_tab_switch_test.dart` seeds a five-tab strip on the left
pane — a five-location working set per 02 §3, the heavy end of an
everyday strip — with every tab bound to the 10 000-entry fixture,
then times each scripted `PaneTabsController.activateTab` (the one
call chip taps and ⌃⇥ cycling share) from issue to the raster
completion of the first frame whose build began after it. The anchor
reuses `firstPaintedFrame` semantics: activation is a synchronous
active-pointer change (02 §3), so the first post-issue build is the
first frame that can carry the target tab's already-loaded listing;
the measurement asserts the mounted PaneView serves the target tab's
controller before reporting. Five measured repetitions cover each tab
as a switch target once (median lands via the checker; budget
`minimumRepetitions` 3). `bench-tier-b.sh` gains the `p4` leg — one
`run_scenario` line plus the cleanup/merge-required lists; the bench
job's tier-B step needs no restructuring, and P4 stays unlanded —
reported trend-only like the rest of tier B. Local llvmpipe+Xvfb
evidence is in `tasks/run3-task41/`: five `ok` rows at 168–264 ms per
switch — environment-scale numbers, not budget reads.
## M3 — path bar editing + navigation history (2026-09-15)

`go.editPath` (⌘L / Ctrl+L) swaps the segment bar for an in-bar text
field seeded with the current path, selected whole; Enter submits and
Esc closes the field first, leaving the §8.2 navigation-cancel tier
for a second press. `go.toFolder` (⇧⌘G / Ctrl+Shift+G — the §8.3
table wins over the task brief's Ctrl+Alt+G) opens the same editor
seeded empty. Submission resolves through `resolvePanePathInput`, a
pure shape check ahead of any engine call: absolute POSIX paths pass
through, `~`/`~/…` expand against the channel's `homePath`, relative
names join the committed location, and a Windows local pane applies
drive/UNC rules — `~name`, drive-relative `C:name`, root-relative
`\name`, and control characters are rejected shape, not engine
failures. Unresolvable input closes the field and raises the pane's
typed `PaneFault.invalidPath` on the existing inline error surface —
no dialog. A valid target navigates through the ordinary
`PaneController.navigate` seam, so generation counters and
stale-listing rejection apply unchanged. While the field owns focus
the existing text-field suppression keeps pane single keys and
type-ahead out (02 §8.2's field-first tier); a pointer down outside
the strip rescues focus to the listing.

Per-tab back/forward history lives on each tab's `PaneController`:
a user navigation truncates the forward branch and appends the
target, refresh/same-location issues no entry, and `go.back`/
`go.forward` (⌘[/⌘] on macOS, Alt+Left/Right elsewhere) walk the
trail without recording. Esc-cancelled navigation reconciles the
trail the way a browser's stop-then-forward does. Rebinding or
detaching a tab clears its trail; nothing persists. The commands
carry `AppMenuId.go` placement (Back 10, Forward 20, Go to Folder 50,
Edit Path 60) so the reachability invariant holds, and Back/Forward
disable at the trail ends. 02 §2.1 is precision-edited: `go.toFolder`
is the in-bar editor seeded empty, not a dialog.

Validation: `flutter analyze` clean; app suite 821 tests green
(`pane_path_input_test` covers the shape grammar including the
POSIX-legal drive-looking names; `pane_history_test` covers
push/back/forward/up, branch truncation, per-tab isolation, cancel
reconciliation, and rebind reset; `path_field_test` covers
seed/select, Enter through the seam, the two-tier Esc, field-first
chord suppression, and reseed-while-open; `pane_commands_test`
covers ids, per-platform activators, Go-menu order, and
disabled-at-ends). Real-font captures of the closed bar, the editing
state, the inline invalid-path error, and the empty `go.toFolder`
field are under `tasks/run3-task42/captures/`. The command strip's
button label now collapses under squeeze so the four new Go commands
cannot overflow narrow shells.

## M3 — D12 tier-B baseline committed (2026-09-15)

`test/benchmarks/tier-b-baseline.json` now carries the first real
tier-B baseline, measured from the `bench-results` artifacts of
main-branch CI runs 34920829912, 34925105848, 34925201167, and
34937535607 (run 34934485531 excluded — `AMD EPYC 9V74`, a different
uncontrolled-axis environment): P1 1061.087 ms (n=12), P2 10781.459 ms
(n=12), P4 35.398 ms (n=5 — the P4 suite has produced main-branch rows
only once so far, with the dispatch run 34935534520 corroborating at a
36.8 ms median). The fingerprint records the tier-B runtime axes (the
per-tier axis from #125): `ubuntu-latest@20260907.300.1`, Flutter
3.47.2's bundled Dart 3.13.2, `profile`, `AMD EPYC 7763`. **P6 has no
entry** — every tier-B leg has returned only error rows for it
(insufficient frame capture: ~750–800 frames against the >= 1800-frame
floor the ~60 Hz measured vsync cadence implies under llvmpipe), so no
honest median exists; the P6 harness question belongs to its owner.

With the baseline committed, a declared tier-B scope runs the per-run
fingerprint-drift evaluation instead of the absent-baseline notice —
soft-mode `hardware drift` notices (controlled axes) or
refresh-the-baseline notices (the uncontrolled CPU axis) now print on
real runs, never failing while `BENCH_ENFORCE_B` stays unset.
Per-scenario trend lines still wait on the `landed` flips (kept out of
this change per the task boundary; the committed-catalog test pins
every scenario unlanded). Verified end to end against the real
artifacts: as-committed run exits 0 with no absent-baseline notice; a
simulated-landing budgets variant prints trend pass lines and fails on
P6's errored rows (exit 1 — the missing/errored rule); a simulated
+40 % P1 run prints the regression notice and exits 0; the real
9V74-CPU artifact prints the uncontrolled-axis drift notice and exits
0. Logs under `tasks/run3-task43/`. New coverage: the committed
baseline's own contract (parses, tier-B runtime axes, tier-B-only
finite-median entries) plus the baseline-present soft semantics —
unlanded scenarios never become expected, and drift is evaluated per
run even with nothing landed. `dart test test/benchmarks` 118/118;
`dart analyze test/benchmarks` clean. The README gained the dedicated
baseline-refresh procedure (the path a future runner rotation uses)
and the baseline's provenance.

## M3 — Sync Browsing (2026-09-15)

`view.toggleSyncBrowsing` (⌥⌘B on macOS, Ctrl+Alt+B elsewhere — the
§8.3 table) links the two panes per 02 §7: enabling records both
visible tabs' committed directories as the fixed anchor pair, and a
committed relative navigation on either side replays at the same
relative path below the other pane's anchor through the ordinary
navigation machinery. Every transition keys on
`PaneController.committedLocation` — a directory the channel verifiably
listed — never the optimistic `location`, so a failed or Esc-cancelled
move can neither replay nor suspend, and a tab's server change drops
the link only when its landing listing commits. Relative moves replay
after a `directoryExists` probe: a missing mirror suspends without
moving the other pane ('"foo" missing on right'), and a commit outside
the anchored subtree suspends outright ('outside the anchor subtree') —
no `..` replay chains, no snap-into-place, no directory creation. The
amber link-broken chip with the named cause renders on both anchored
path bars and the status bar; resume fires under the single predicate
of §7 (both anchored panes committed at the same valid relative path),
with `diverged` and the re-visibility cause (tab switch or hidden
second pane) carrying the plain suspended line.

Closing an anchored tab routes through the existing ⌘W guard via the
new `TabCloseTrigger.syncAnchor` registry entry — no call-site special
case — and a confirmed close drops the link with the tab.
`view.toggleSecondPane` (⇧⌘D / Ctrl+Shift+D, View menu) hides pane B
whole — strip and tabs survive — and the same suspension/resume rules
cover both the user toggle and the shell's responsive auto-hide, which
now reports its effective second-pane visibility into the workspace.
The Sync Browsing command is app-scoped, enabled while linked or
linkable (both panes committed), and carries `AppMenuId.go` placement
at order 80 per §9's Go-menu row.

Validation: `flutter analyze` clean; app suite 850 tests green.
Focused suites cover anchor
recording, child/up/path-jump replay, both suspension causes with
distinct chip copy, the auto-resume predicate and its rejections,
commit-gated server-change drop (Esc-cancel keeps the link), guard
routing on anchored close, tab-switch re-visibility, hidden-pane
suspend/resume, command registration/chords/menu slots, and the
shell-level status chip (`sync_browsing_controller_test`,
`sync_browse_ui_test`). Real-font captures of the linked, replayed,
and both amber suspended states are under
`tasks/run3-task44/captures/`.

## M3 — inline rename (2026-09-15)

`file.rename` (02 §2.6) lands the inline-rename slice: Return on macOS
and F2 elsewhere — both plain keys dispatched by the pane's focus node
per §8.2, declared on the command for menu reachability only — opens a
text field floated over the cursor row's name cell, seeded with the
row's name and its stem selected. Enter validates the basename
client-side (blank, `/`, and the NTFS-reserved set on a local Windows
pane; remote panes stay POSIX-permissive), closes the field, renames
through the browse channel's new `rename` verb, refreshes the listing,
and re-anchors the cursor on the renamed row; the unchanged name is a
silent no-op. A refused commit re-opens the field carrying the typed
error and the refused draft; Esc and click-outside cancel at the field
tier of §8.2's order without a request. The engine protocol moves to
v9 for `RenameEntryRequest`, which routes through the same channel-id
fan-in as `ListDirectoryRequest` into `RemoteFileSystem.rename` —
never an overwrite, so a destination conflict answers typed without
touching recovery.

The tab-close guard's existing `TabCloseTrigger.inlineRename` entry
now reads a derived state — open session OR in-flight commit — so a
submitted rename still holds the guard after its field closes. A
location change ends the session at navigation-issue time; a
same-location listing replacement ends it silently when the edited row
survives and re-attaches it with the `renameTargetGone` fault when the
row vanished. Validation faults stay client-side; untyped failures
report through `onError` like every other non-VFS pane failure.

Validation: focused controller, validator, widget, command-registry,
and engine host/client suites plus real-font captures of the open,
mid-edit, and error states under `tasks/run3-task45/`.

## M3 — file open: gestures, action preference, notices (2026-09-15)

`go.open` and the row's double-tap land 02 §2.6's file half: folder rows
navigate under every preference value, and file rows follow the new
persisted `Double-click action` (`open`/`edit`/`transfer`/`nothing`,
default `open`, unknown stored values fall back to `open`). The strip
controller owns the live value and stamps it on every existing and
future tab. macOS keeps Return for rename — the bare-Enter leg of
`go.open` is dispatched by the pane's focus node per §8.2, which is
where the platform split lives (⌘↓/⌘O on macOS, Enter elsewhere); F2
rename elsewhere is untouched.

Local Open rides a new engine seam — protocol v10's
`OpenLocalFileRequest` routes through the channel-id fan-in to an
injectable `LocalFileOpener`, so the pane never launches a process
itself. Launcher failures surface in the pane's inline error overlay
(typed `RemoteFileException` verbatim, untyped mapped to the new
`PaneFault.openFile` one-liner); Retry re-opens the same entry rather
than relisting, and a successful retry clears the stale fault. Remote
Open is honest about the gap: an informational strip posts the
localized not-yet-available notice and nothing launches — managed
checkout stays with milestone 06. Edit and Transfer post their own
localized later-milestone notices (06 and the transfer milestone
respectively); Do Nothing is inert. Notices dismiss manually,
auto-dismiss after a short lifetime, and clear on a fresh activation or
binding teardown — never the error overlay, never a modal.

Validation: focused controller, tabs, preferences, widget, command,
localization-contract, and engine host/client/protocol suites under
`tasks/run3-task46/`.

## M3 — D12 tier-B baseline per-scenario config binding (2026-09-15)

Fusion review round 2's finding F9 (reproduced red-first): a landed
tier-B scenario whose fixture config changed uniformly across
repetitions still numerically compared against the old baseline — the
baseline stored only median/unit/repetitions and required the job-wide
config to be null, so a different workload scored as the same. The
baseline contract is now versioned: schema
`poltergeist-d12-baseline-2` records each entry's own `scenarioConfig`
(key required, `null` a legitimate record for a config-free collector),
and `_evaluateTierB` receives the run's per-scenario config and
enforces the match — a recorded-but-different config is a loud
non-comparison skip (`skipped: config mismatch`, never cross-compared),
soft-mode notice / hard fail once `BENCH_ENFORCE_B` is set. The legacy
`-1` file stays readable with a loud deprecation notice, but its
entries record no config, so every one reports
`baseline-config-missing` and skips rather than inventing one; both
non-comparison outcomes veto the drift-state reset like any unexecuted
comparison. The committed baseline moved to `-2` with the REAL configs
extracted from the same cited artifacts (P1
`local-entries-10000-first-paint`, P2
`local-entries-100000-first-paint`, P4
`local-tabs-5-entries-10000-tab-switch`; medians, counts, and
fingerprint unchanged, re-verified). Within-run config agreement and
the job-wide-null rejection are unchanged; no tier-A, workflow, or
`landed` changes.

Red evidence (pre-fix numeric `pass` under a changed config) and the
post-fix logs live under `tasks/run3-task47/`. New coverage: schema
forms (-2 required key, -1 mixed-form rejection, recorded-null),
changed/unchanged config comparison outcomes, legacy migration outcome
in both modes, and the config-skip reset veto. `dart test
test/benchmarks` 130/130; `dart analyze test/benchmarks` clean.

## M3 — rename ownership repairs, fusion review round 2 (2026-09-15)

Three confirmed findings from the second source-level review of the
rename path (#131/#132) are repaired, each red-first:

- **Rename completion owned whichever binding the tab now held.** A
  commit settling after a rebind refreshed and reselected the NEW
  binding (a same-path rebind could even select an unrelated row at the
  old destination's spelling), and a typed refusal resurrected the
  stale editor after a same-path rebind or an away-and-back navigation
  while a different-location failure dropped silently. `submitRename`
  now captures an ownership token (channel identity, bind attempt, and
  a new `_locationRevision` bumped on every location-changing
  navigation issue): the in-flight guard always settles, but
  refresh/reselect/reopen only run while the token still owns the
  presentation, and a retired operation's refusal reports through the
  pane's `onError` sink instead of attaching to the new binding or
  vanishing.
- **An invalidated rename session stayed a live mutation capability.**
  After the `renameTargetGone` re-attach, submitting still sent
  `channel.rename` for the old path — renaming a merely-hidden file or
  a replacement that took the path since. Submission now re-checks row
  membership: a session whose row key is absent is diagnostic-only —
  Enter dismisses it, a new edit needs a fresh row session — and the
  detached editor now floats over the empty-listing state too, so the
  fault and its dismissal stay reachable when the last row vanishes.
- **Trailing POSIX backslashes corrupted the destination.** A basename
  ending in `\` (a legal POSIX filename byte) was trimmed as if it were
  a separator, and the fallback split then landed on a backslash inside
  the name (`/parent/weird\name\` → `/parent/weird\plain.txt`). The
  parent derivation now uses the entry path's own separator grammar,
  removes the exact basename before any separator trimming, and joins
  the location with ITS separator as the last resort.

Validation: seven new controller regressions (rebind success/refusal,
away-and-back refusal, invalidated and same-path-replacement submits,
internal+terminal backslash names on local POSIX and remote panes) and
one widget regression (gone-row fault on an emptied listing) failed
before the fix and pass after; `flutter analyze` clean; full app suite
green (912 tests). Logs under `tasks/run3-task48/`.

The exact-head GLM review (#134, round 1 at `9f38ed8`) returned two
minor findings, both confirmed and repaired red-first:

- The last-resort location join unconditionally appended the base's
  separator, doubling it on root locations (`/` → `//name`). The join
  now respects a base that already ends with its separator.
- `_renameInFlight` was pane-global: a stalled commit on a retired
  binding kept `startRename` closed on the live one until the request
  settled. The guard now releases where the operation's ownership token
  retires (bind, detach, location-changing navigation), and each
  settle frame clears the flag only while the operation still owns it,
  so a late settle cannot release a newer commit's guard.

Validation: four new controller regressions (local and remote root
joins, rebind and navigation guard release including a stale settle
racing a newer commit) failed before the fix and pass after;
`flutter analyze` clean; full app suite green (916 tests). Log:
`tasks/run3-task48/flutter-test-reviewfix.log`.

Round 2 flagged a stray word in this entry (fixed). Round 3 (`365c388`)
confirmed one further hole: a retired commit settling while the pane
still browsed the renamed directory on the same channel — the
away-and-back or same-spelling-rebind case — never re-listed, so the
accepted listing could show the old name indefinitely. The stale-success
branch now re-fetches when `identical(channel, _channel) &&
location == _location` still holds, keeping the retired session's
editor and reselect off. A new controller regression (back-nav listing
predating a held commit) failed before and passes after; full app suite
green (917 tests). Log: `tasks/run3-task48/flutter-test-reviewfix2.log`.

Round 4 (`ca042a0`) flagged that the stale-success branch dropped the
settle notification when the pane browsed elsewhere — the guard itself
already releases at token retirement (round 2), but the settle signal
is restored so observers always learn the commit finished, and the
still-browsed-directory refresh stays gated on identical channel plus
matching location. The new test asserts listener notification across
the stale settle and the round-3 test now asserts list-call growth
rather than a matching tail call. Full app suite green (918 tests).
Log: `tasks/run3-task48/flutter-test-reviewfix3.log`.

## M3 — transactional replacement binding, fusion review round 2 (2026-09-15)

Finding F5 of the second fusion review is repaired red-first: replacing
a pane binding destroyed the prior state before the candidate committed,
so Esc during the replacement's connect or first listing lost the old
location/listing and could detach the pane to the launcher — and the
§7 sync link dropped without the manual `openLocalAt` reconstruction the
old test used to mask it.

Replacement binding is now transactional. `_beginBinding(replace)` moves
the live channel and the full browsing state (location, committed
marker, sorted listing, error, selection, history, filter/hidden/view
lenses, connection status, recovery phase) into a `_BindingRollback`
record — the channel stays open — instead of discarding them. The
record survives until the candidate's first listing answers (commit or
error retires it and the pane stays on the candidate), a bind failure,
a restore, or dispose. `cancelNavigation` during the landing listing
and `detachRemote`/`cancelRecovery` during the pending open both route
to `_rollbackCandidateBind`, which bumps the bind attempt (a late
candidate open now hits the stale-attempt close instead of being
adopted, and `cancelRecovery`'s one-bump bookkeeping still decides the
candidate server's disconnect), retires only the candidate channel and
watch, restores the prior state, and re-subscribes the prior server's
status lane under the current attempt. The candidate's issue skips the
quiescent-snapshot capture while a rollback is pending — the record is
the only honest restore target. A genuinely-fresh pane (no prior
binding to restore) keeps the detach-to-launcher semantics, and a
stacked rebind keeps the last DISPLAYED binding as the restore target
rather than superseding it with the intermediate candidate.

Validation: three new regressions failed before the fix and pass after
— remote→local rollback (`pane_controller_test`), and in
`sync_browsing_controller_test` an Esc-cancelled server change during
the first listing plus a pre-open `cancelRecovery`, each asserting the
restored location/committed marker/rows/selection, live old-channel
navigation, late-candidate-answer immunity, and the link kept without
manual reconstruction. Three existing tests that encoded the
destructive semantics were updated to the contract: the reconnect
suite's cancelled-first-listing heal now runs on a fresh pane, and the
two workspace cancel tests assert the restored local binding while the
candidate's server-reference bookkeeping is unchanged (sibling keeps
the reference, alone drops it). `flutter analyze` clean; focused pane
suites green (183 tests); full app suite green (920 tests). Logs under
`tasks/run3-task49/`.

The exact-head GLM review (#135, round 1 at `df96e07`) surfaced two
confirmed findings, both repaired:

- `cancelNavigation`'s rollback branch sat behind the
  `connectionLost`/`_loadingActive` guards, so a candidate server
  flapping to `reconnecting` mid-window (which sets `_recovery` and
  `_error` through the candidate's own status lane) dead-ended Esc on
  the failing candidate. The rollback check now runs before both
  guards.
- `_bind`'s catch blocks retired the parked rollback on ANY bind
  failure, including a `retainCache` recovery retry of the candidate —
  a transient reconnect failure would have destroyed the escape hatch
  before the replacement ever committed. The retire is now gated on
  `replace`.

Minor rounds applied: the sync tests now park the cursor on a
non-default index so the restored selection is observable, assert the
old channel's survival and restored rows after late candidate answers,
and document the double-settle replay convention; `detachRemote`'s
Esc-only reachability and the stale `connectionStatus`/`recovery`
capture semantics are commented; three new controller regressions cover
dispose mid-rebind (both channels close), a stacked rebind (the oldest
record stays the restore target; the superseded candidate retires), and
remote→remote rollback. Declined with evidence: carrying a
`_QuiescentSnapshot` in the record — the restored state IS the
baseline and `_issueNavigation` recaptures before any listing flies —
and defensive copies of `sortedListing`/`selection`, both
reassign-only/immutable (the invariant is now documented on the
record). The two outside-diff-range majors (dispose leaking the parked
channel, a re-entrant rebind corrupting it) were already handled by the
`_retireRollback` dispose call and the no-supersede guard; the new
regressions pin both. Full app suite green (923 tests). Log:
`tasks/run3-task49/flutter-test-reviewfix.log`.

Round 2 (`4e88d93`) was minor-only with zero actionable findings: the
one comment noted the two round-1 repairs lacked regressions, so two
more now pin them — Esc during the candidate's mid-window
`reconnecting` flap (also asserting the restored baseline drops the
candidate's stale error/loss state), and the failed `retainCache` retry
keeping the rollback parked. Full app suite green (925 tests). Log:
`tasks/run3-task49/flutter-test-reviewfix2.log`.

Round 3 (`8d07793`) again carried zero actionable findings; its three
minor comments are applied: a post-Esc `candidate.closeCalls` assert in
the failed-retry test, a mid-window `controller.error` assert in the
flap test, and the rollback branch moved out of public `detachRemote`
into a dedicated `cancelPendingBind` entry point so detach keeps a
single meaning — `cancelRecovery` and the shell's sibling-bound cancel
route now funnel through it, and any future explicit disconnect
affordance gets a literal detach. Both info comments are
verified-or-declined: the four rollback-retirement points all hold
(first answer retires via `_load`, a stacked replace keeps the oldest
record, `_retireRollback` releases the parked channel for `dispose`),
while the suggested `presentation != replace` retire guard is declined
— a `retainCache` bind continues the same replacement transaction, so
retiring there would re-break the retry path the round-1 fix
preserved; the fresh-pane coverage question is already answered by the
new pane-controller regressions plus the deliberately-fresh reconnect
test. Full app suite green (925 tests). Log:
`tasks/run3-task49/flutter-test-reviewfix3.log`.

## M3 — stale-selection eligibility, fusion review round 2 (2026-09-15)

Finding F1 of the second fusion review is repaired red-first: a
location-changing navigation resets `_selection` to empty rows at issue
while `_entries`/`_rowKeys` keep the old listing rendered for 02 §2.8's
150 ms anti-flash grace — but interaction eligibility followed the dim,
not the disowning. Inside the window, keyboard selection, type-ahead,
pointer activation, and semantics activation could reach the cached
rows: `setCursorIndex` threw `ArgumentError('not a visible row')` out of
`SelectionState.activate`, and a stale `openEntry` issued a listing
request for the OLD directory that superseded the pending navigation.

Presentation grace and interaction eligibility are now separate states.
`PaneController._staleRows` is set the moment a location-changing
navigation disowns its rows and cleared only when a listing is accepted
or a quiescent snapshot, rollback, or binding reset restores an owner —
never by a mid-flight lens edit, which re-derives rows from the same
disowned listing. Every controller row-interaction entry point guards on
it (`setCursorIndex`/`moveCursorBy`, `selectAll`, `invertSelection`,
`typeAhead`, `openEntry`), so a caller bypassing the widget can neither
throw nor mutate stale selection; a stale activation can no longer
supersede the pending navigation. The view reads `controller.staleRows`
to gate its own dispatch: owned listing keys and type-ahead characters
swallow from issue (Esc and Tab stay live), `IgnorePointer` drops stale
row gestures, and `ExcludeSemantics` removes the cached rows from the
live semantics tree at issue — a reachable-but-inert row would read as
broken to AT activation, which bypasses hit testing. The grace itself is
untouched: no early spinner, dim, or footer change, and permitted
navigation chrome stays live.

Validation: three controller regressions and one widget regression
failed before the fix and pass after — the throw, the stale-activation
supersede, and stale rows lingering in the semantics tree are all
reproduced red-first. The widget test drives t=0 and t≈100 ms Down/
Home/Up/Enter, a matching type-ahead prefix, and single/double taps on
cached rows: no throw, no selection, no extra listing request, the
pending destination is unchanged, no early spinner/dim appears, and Esc
restores the prior listing with selection live again. `flutter analyze`
clean; focused pane suites green (197 tests); full app suite green (929
tests). Evidence and logs under `tasks/run3-task50/`.

AT note: rows leave the semantics tree at navigation *issue*, so screen
readers see the listing vanish even during sub-150 ms loads. The removal
is deliberate — a reachable-but-inert row reads as broken, and AT
activation bypasses hit testing — and it is not silent: while the rows
are disowned, a polite live region announces the transition with the
same `paneLoadingFolder` string the footer shows once the grace dim
lands (WCAG 4.1.3 — review round 2's major). A device pass
(VoiceOver/TalkBack) remains a follow-up to confirm the announcement
lands on real AT, including fast local listings that can resolve within
the frame they were issued — a live region that mounts and unmounts
inside a single semantics frame produces no announcement, which is
acceptable there because no intermediate inert state ever reached AT.

## M3 — mirror-probe binding identity, fusion review round 2 (2026-09-15)

Finding F2 of the second fusion review is repaired red-first: a held
mirror probe could navigate a REPLACED binding using the old endpoint's
answer. With a linked pair, committing a child navigation on one pane
starts an existence probe on the other; rebinding that pane while the
probe pends, letting the new channel open with its landing listing held,
and then releasing the old probe issued `other.navigate(mirrorPath)`
onto the NEW channel — superseding the user's landing navigation with a
path/existence answer from the old server. A stale 'missing' answer
published a false `mirrorMissing` suspension on the new binding the same
way, and a target-side navigation issued while the probe pends was
superseded by the replay's navigate.

The probe is now bound to the pane's operation identity, not just its
channel. `PaneController.probeMirrorDirectory` returns a
`PaneMirrorProbe` carrying the existence verdict plus the operation
identity it was taken under — `_operationIdentity`, a token rotated on
every binding transition (`_beginBinding`, `detachRemote`,
`_rollbackCandidateBind` — the rollback restore returns the SAME channel
object, which channel identity alone cannot distinguish) and on every
navigation issue, plus the probed channel itself. The replay rechecks
`mirrorProbeCurrent` immediately before issuing the mirror navigation:
a stale probe abandons the replay outright — neither 'exists' nor
'missing' — so it can never suspend on a stale notFound or move a newer
binding with an old endpoint's answer. §7's semantics on stable bindings
are unchanged: replay, the two-cause suspension taxonomy, and the single
resume predicate all ride the same paths as before.

Validation: three regressions failed before the fix and pass after —
held probe + rebind + held landing (the new channel receives only its
intended landing request, its generation is not superseded, the link
stays armed until the landing commit drops it), stale probe resolving
missing (no false `mirrorMissing` on the new binding), and a target-side
navigation issued mid-probe (the replay abandons; the user's commit
re-evaluates on its own and suspends `mirrorMissing` honestly).
`flutter analyze` clean; focused suites green (sync_browsing_controller,
pane_controller, workspace_panes, pane_tabs_controller — 162 tests);
full app suite green (934 tests). Evidence and logs under
`tasks/run3-task51/`.

## M3 — review round 2 minors, fusion review round 2 (2026-09-15)

Findings F7 and F8 of the second fusion review are repaired red-first,
one PR, app-only (no engine-host change — the seam did not require it).

F7: returning to a tab showed a blank Quick Select query while its old
preview stayed active. The active-only keyed `PaneView` disposes the
field on a tab switch, and `_QuickSelectFieldState` always created an
empty text controller, never seeding it from the retained session —
Enter then confirmed an invisible query's preview. The fix exposes the
active query read-only from `PaneController.quickSelectQuery` and seeds
the remounted field from it; the session's baseline and preview are
untouched, and per-tab state semantics are unchanged (the segmented
mode already read live from the controller).

F8: tilde resolved to a duplicated tab's initial directory, not the
local user's home. Duplication (and the ghost reopen) called
`openLocalAt(currentPath)`, and the engine reports the canonicalized
opening root as `homePath`, which path input treats as the user home.
The fix binds every local channel at the user's home (`open '~'`) and
browses the requested root on that binding in a single listing — the
channel's `homePath` is always the real user home, so `~` and
`~/child` resolve identically from original, duplicated, and reopened
tabs. No environment/filesystem lookup in widgets or controllers (D8
holds: `~` still expands inside the engine). The browsed path keeps its
requested spelling like every navigation target; retry still returns to
the targeted directory. Two existing call-shape assertions now expect
`openLocal:~` (duplicate, ghost reopen).

Validation: both regressions failed before the fix and pass after —
the widget test types a query in tab A, visits B, returns to A, and
asserts the displayed text plus the selected rows, then changes
Add/Remove and confirms (`pane_tabs_view_test.dart`); the duplication
test spans tab duplication plus path submission and verifies `~` and
`~/child` from original, duplicated, and reopened tabs against an
engine-faithful fake whose `homePath` is the opening root
(`pane_tabs_controller_test.dart`). `flutter analyze` clean; focused
suites green (pane_tabs_view, pane_tabs_controller, quick_select,
pane_view, pane_path_input/pane_controller — 200 tests); full app
suite green (936 tests). Evidence and logs under `tasks/run3-task52/`.

## M3 — second-pane toggle (2026-09-15)

`view.toggleSecondPane` (⇧⌘D / Ctrl+Shift+D, View menu order 70 per
02 §8.3/§9) was already registered by the Sync Browsing slice, and
hiding pane B already ran through one mechanism — the workspace's
`secondPaneHidden` intent and the AdaptiveShell's stage-2 auto-hide
converge on `secondPaneShown`. What was missing was the §3 rule that
a hidden pane's tabs take no keyboard focus or commands: a hide while
pane B was active left `activePane` — and every pane-scoped command
resolving it — aimed at an unmounted strip, and keyboard focus dropped
to nowhere until the next click.

The workspace now parks the active pane on the survivor the moment
pane B leaves the screen, whichever flag hid it; `setActivePane`
refuses the hidden pane outright (a focus event racing the unmount
cannot park commands on it), and `swapFocus`/the focus commands
resolve to the shown pane. The shell moves keyboard focus to the
surviving pane's listing node on the shown→hidden transition — before
the unmount on the user toggle, after the layout's post-frame report
on the auto-hide. Re-showing restores pane B exactly — the strip and
every tab object are the same instances, so location, listing,
selection/cursor, the transient filter, the hidden override, view
mode, history, Quick Select, and an open rename session all survive
untouched — and never re-grabs the active pane (the remembered pane
is state, not focus). No window-title or checked-menu surface exists
to reflect one-pane mode, so none changes.

Tests pin the contract at every seam: the workspace retarget/refusal/
swap rules plus the transient-vs-latched intent split
(`workspace_controller_test.dart`, new); the production shell — chord
hide, focus handoff, `pane.focusRight`/Tab folding to the survivor,
and a deep per-tab state assert across hide/show including a two-tab
strip and a Back that still lands on the pre-hide parent
(`workspace_panes_test.dart`); the layout's visibility report carrying
stage hide, regrow, and intent hide on one channel
(`adaptive_shell_test.dart`); the existing §7 hidden-pane suspend/
resume test now also proves the refresh chord never reaches pane B's
channel while hidden (`sync_browse_ui_test.dart`). Real-font captures
of the two-pane, one-pane, and restored layouts are under
`tasks/run3-task53/captures/` (`pane_toggle_capture_test.dart`).

Validation: `flutter analyze` clean; full app suite green (948 tests);
logs under `tasks/run3-task53/logs/`.

## M3 — inter-pane tab drag (2026-09-16)

02 §3's "drag tabs between panes" is implemented as a genuine MOVE at
the workspace seam: `WorkspaceController.moveTabToPane` detaches the
`PaneTab` from the sibling strip and inserts the same object into the
destination — nothing is copied, closed, or reopened. Because the tab's
`PaneController` crosses intact, every per-tab state rides with it:
committed location and listing, selection/cursor, the transient filter
and filter-field, the hidden-file override, view mode, Quick Select,
history, and an open rename session. The engine's browse channel
identity is the tab's minted paneTabId (`pane.left.tab3`), which the
move leaves unchanged, so the channel is never torn down or rebound —
the `pane.left`/`pane.right` id prefix names where the tab was CREATED,
not which strip owns it (PaneTab.id documents this).

Detaching is deliberately NOT routed through `requestCloseTab`: a move
is not a close, so the close guard never runs, no ghost is pushed (⇧⌘T
cannot resurrect a tab that still lives), and in-flight work — a held
navigation or a held rename commit — keeps running and settles on the
destination pane. The strip→controller listener detaches at the source
and attaches at the destination, so late controller notifies land on
the owning strip; the destination strip's live settings (double-click
action) stamp on arrival like any other tab. A pane that loses its
last tab lands on the launcher, the same state a guarded last close
leaves (02 §2.7/§3); the dropped tab activates and its pane becomes
the active one.

Sync Browsing takes the 02 §7 rule through the strips' notifies alone:
the sync controller's residency check drops the link silently the
moment both anchors would share one strip — no move-specific code path.
A non-anchored tab crossing panes suspends the link `pairNotVisible`,
the same mechanism as a tab switch, and the anchor flags stay armed.

At the widget layer each chip is a `Draggable` carrying the `PaneTab`
itself (pointer-anchored avatar: `DragTargetDetails.offset` is the
avatar's top-left, so pointer anchoring keeps the reported offset equal
to the pointer for the insertion math). The strip is the `DragTarget`:
it refuses its own residents — a drop back on the source strip is the
cancelled case, since within-strip reorder is not this slice — and a
release anywhere outside a foreign strip cancels with no state
disturbance. Hovering resolves the insertion index against each chip's
midpoint clipped to the scroll viewport (a half-scrolled chip's
offscreen half cannot swallow the strip's trailing drop zone, so
appending stays reachable) and paints a 2px accent indicator at the
insertion point, cleared on leave or accept. A hidden pane B's strip is
unmounted, so it can neither accept drops nor start drags; the service
seam refuses it too.

Tests pin the contract at both seams (`pane_tab_move_test.dart`,
`tab_drag_test.dart`): object-and-channel identity with a fake engine
proving no close and no reopen; location, selection, cursor, filter,
hidden override, view mode, and history all surviving; the destination
strip owning listener forwarding and live settings; drop indexes at
start/middle/end plus the clipped-last-chip append; launcher fallback
with no ghost; the close guard never consulted; in-flight navigation
and rename commits settling on the destination; same-strip, foreign,
and hidden-pane no-ops; and both §7 link outcomes. Real-font captures
under `tasks/run3-task54/captures/` show the hover indicator plus drag
avatar and the post-drop state.

Validation: `flutter analyze` clean; full app suite green (971 tests);
logs under `tasks/run3-task54/`.

## M3 — Quick Connect launcher slice (2026-09-16)

02 §2.7's first parsing slice: the launcher renders Quick Connect as its
initial content — no Servers/Recent tab scaffolding, which depends on
M5's sidebar/favorites work. The address grammar lives in
`quick_connect_address.dart` (pure Dart, no Flutter, no I/O):
`user@host:port` bare form with scp disambiguation (a purely numeric
token in 1–65535 is a port with the visible `2222 → port;
use sftp://host/2222 for a folder named 2222` hint; anything else,
including `/srv/www`, `22-backup`, and out-of-range numerics, is a
verbatim scp-style start path on port 22 with a parse hint),
positional `sftp://` URLs (the unambiguous escape hatch — numeric path
segments never read as ports; an out-of-range URL port rejects),
unbracketed multi-colon hosts rejected with the `wrap the IPv6 address
in [ ]` hint, bracketed IPv6 parsing the port after `]` (the plain
heuristic never splits the address), and WHATWG-style userinfo (last
`@`, password after the first `:`) extracted before the colon
heuristics — the password is stripped with an inline notice and a
sanitized echo form, never connected with, echoed, or persisted.

Connect mints an ephemeral `adhoc:<uuid>` bookmark (03 §3.5) and binds
a fresh tab through the existing `connectRemote` seam, so prompts,
errors, and banner behavior stay owned by the connect flow. After a
successful connect the "Save as favorite…" bar renders prefilled from
the live session (endpoint label, captured context path). The save
writes through the M2 interim `BookmarkRepository` — verified a real
store (`FileBookmarkStore`, the one production instance main.dart
shares with import and Connections; in-memory in tests) — persisting a
promoted favorite under a fresh id while the live adhoc session keeps
its own; 03 §3.5's serverId-migration promotion rides M5. With no store
wired the save posts the honest `saveFavoriteLater` notice (the #132
pattern: typed notice in the controller, ARB copy in the view), and a
throwing store keeps the bar mounted with an inline retryable error.
All user copy is ARB (D20, 17 keys); the field is a real TextField so
02 §8.2's suppression seams apply untouched, the launcher aims mount
focus at the field (never from an inactive pane), and Enter submits
while plain Tab still swaps panes. `connect.quickConnect` (⌘K) command
registration rides the M5 command/menu slice with the tab scaffolding.

Tests pin the contract red-first (`quick_connect_address_test.dart`,
23 cases; `quick_connect_test.dart`, 14 widget tests: hint rendering,
seam connect with adhoc identity, Enter submit, focus/suppression,
address-field keyboard posture, save-through-store with no secret in
the record, no-store notice, failure retry, narrow-pane reflow). Real-font captures under `tasks/run3-task55/captures/`
show the port hint, the IPv6 hint, and the save bar (inspected).
Follow-ups: `connect.quickConnect` registration + ⌘K/File-menu entry;
serverId-migration promotion (03 §3.5) with M5.

Review round 1 (applied; the narrow-pane regression failed pre-fix
with a 48px RenderFlex overflow and passes after): the save bar lays
out as wrapping runs so a narrow pane reflows instead of overflowing,
and the address field takes no autocorrect/suggestions with a URL
keyboard.

Review round 3 (applied): an empty bracketed token (`[host]:`)
returned `''` where the bare form lands home — normalized, with a
regression that failed pre-fix and passes after.

Review round 4 (applied): round 3 over-corrected `[host]:/path`
(dropped a real path) — an empty head now keeps the slash tail, so
only a truly empty token lands home; the suggested path regression
failed pre-fix and passes after.

Validation: `flutter analyze` clean; focused suites green (parser 23,
widget 14, captures 2, localization contract 10); full app suite green
(1010 tests, plus core 918); logs under `tasks/run3-task55/`.

## M3 — Get Info inspector (2026-09-16)

02 §2.6's inspector slice: a non-modal info rail slides over the
focused pane's right edge on `file.getInfo` (⌘I on macOS, Alt+Enter
elsewhere — File menu, order 65 group 1, `CommandScope.selection`,
enabled with an inspectable target or an already-open panel). The
280px rail is a `Stack` sibling owned by `PaneTabsController`, not a
route or dialog: rows beneath stay interactive and the panel retargets
as the cursor/selection moves (cursor row wins; otherwise the first
selected row in listing order — identity-based, never captured
indices). It renders the entry's name, kind, size, modified/accessed
dates (no created date exists in the VFS model — rendered honestly
where present), permissions in `rwx` + octal, read-only owner/group
numerics, and the full path with a copy affordance that reuses the
transient-notice seam. Esc closes it at its 02 §8.2 slot — after
rename and pending remote-recovery cancellation, before
filter/type-ahead clearing — and closing returns focus to the listing
unless another target claimed it. Folder size is calculated on demand
over the existing `AppBrowseChannel.listDirectory` seam (no new
engine protocol): an explicit-stack walk with cooperative
`RemoteTransferCancellation`, progress snapshots, cycle/dot-segment
protection, no symlink traversal, and partial accounting that counts
unreadable/sizeless entries instead of presenting an exact total —
root listing refusals fail, nested typed refusals are counted, and
untyped channel faults propagate. Sessions are token-identity-gated
so superseded or cancelled runs cannot overwrite current state, and
are invalidated on navigation issue, binding reset, remote detach,
dispose, and session replacement; an in-flight measure participates
in the tab-close guard.

Validation: `flutter analyze` clean; focused suites green
(folder-size unit 8, controller session 11, 12 widget, command,
format, localization contract); full app suite green (1046 tests,
plus core 918). Inspected real-font captures under `tasks/run3-task56/`:
inspector over a local file, a local folder's settled size, a remote
file (uid/gid), and a remote folder's Calculate affordance.

## M3 — session state restoration on launch (2026-09-16)

02 §3's launch restoration: one versioned `session.state` document inside
`settings.json`, behind the prefs layer (`SessionStateStore` over the
generic `SettingsStore` — strict decode, schema version 1, read-before-
write so a document this build cannot decode is never silently
overwritten; a malformed or newer-schema load reports and boots the
default session). `SessionPersistence` captures both strips (ordered
tabs, active index, per-tab location, id counter), the active pane, and
the pane toggle's user intent at every safe point — tab open/close/
switch, navigation commit, pane toggle — debounced and deduplicated by
encoded content, with `flush()` awaited inside `onExitRequested` and the
window-close interception (the app-quit safe point). Window geometry
keeps riding the existing `DesktopWindowLifecycle` path.

A `PanePhase.restored` tab adopts its persisted location, remote
identity, and cached listing snapshot WITHOUT a channel: remote rows
render stale and inert under a localized Reconnect bar (the §2.8 banner
contract minus Cancel — nothing was opened to cancel), and the tab holds
no pool reference so sibling last-binding accounting and close-time
disconnects ignore it (`hasLiveRemoteBinding`). `resumeRestored` drives
the ordinary connect/local-open flow on the restored path. The new
"Reconnect restored tabs automatically" setting defaults ON: activation
of a restored remote tab reconnects; OFF, activation alone never
reconnects — the bar waits for the explicit click, which always works.
Restored local tabs rebind live on activation regardless. Launcher
semantics hold: a pane persisted with zero tabs restores to its
launcher — restoration never auto-opens a tab — and an unbound persisted
tab restores unbound.

Validation: `flutter analyze` clean; focused suites green (doc codec +
store fail-closed 12, controller/strip restore 14, safe-point commit
coverage 9, prefs round-trip, 5 shell-level widget tests covering the
two-pane multi-tab round trip with a hidden pane, ON/OFF reconnect
semantics, live local rebind, and the empty session); localization
contract green; full app suite green (1094 tests). Inspected real-font
capture `tasks/run3-task57/captures/session-restore-reconnect-bar.png`:
restored remote tab under the Reconnect bar with cached rows.

## M3 — Workspaces: save/open/undo (2026-09-16)

02 §3's final bullet: named workspaces persist a snapshot of both
panes' tab sets, each pane's active tab, and per-tab view state —
local path or remote identity + remote path, listing snapshot, filter
query/field state, hidden-file visibility, view mode. Selection,
history, and in-flight operations are deliberately not captured.

Persistence boundary: per the §4 schema a workspace is a favorite
KIND, but the favorites store is M5 — this slice persists the named
list through the versioned session-store layer instead
(`WorkspaceListStore` over `SettingsStore`, key `workspaces.saved`,
strict decode, read-before-write, serialized writes — the same
fail-closed contract as `session.state`). M5 migrates the document
into the favorites store. `WorkspaceLibrary` keeps records
newest-first, saves over an existing label case-insensitively while
preserving its id, and stamps `lastOpenedAt` on open.

Open is transactional per the §3 close-guard contract:
`WorkspaceController.requestApplyWorkspace` asks each strip to run
the SAME tab-scoped close triggers ⌘W uses (#123: in-flight
navigation, folder-size, inline rename, sync anchor) across both
panes BEFORE replacing anything, captures the displaced snapshot,
then routes replacement through `PaneTabsController.replaceTabs`.
Any declined or un-presentable confirmation leaves the entire
workspace untouched. The toast `Workspace "X" opened` (ported
`top_toast.dart`, 12 s) carries an Undo action that re-applies the
displaced snapshot through the same guarded path — undo cannot
restore in-flight state, hence guard-first (documented in code).
Restored tabs land in `PanePhase.restored` and keep their saved
lenses through the deferred rebind (`_beginBinding` skips the lens
reset only when resuming a restored tab); local tabs rebind live,
remote tabs honor the existing reconnect preference.

UI: `workspace.save` ("Save Workspace…", Commands menu order 50)
opens a localized name dialog; `workspace.open.<id>` entries fill a
Workspaces submenu (order 55+, newest-first, disabled "No saved
workspaces" row when empty) keyed on persisted ids, never labels.
The shell re-derives the submenu when the library notifies. All
strings ARB'd; schema keys and diagnostics registered in the
localization contract.

Validation: `flutter analyze` clean; focused suites green (state
codec, list-store fail-closed, library ordering/disposal, 12
guarded-apply cases incl. per-trigger decline and undo reconfirm,
command/menu widget tests); localization contract green; menu-bar
capture regression green. Real-font captures inspected:
`tasks/run3-task58/workspaces-submenu.png` (submenu, newest-first)
and `workspace-toast.png` (toast with Undo over the applied
workspace).

## M3 — permissions editor (2026-09-16)

02 §2.6's D28 slice completes the Get Info inspector: the permissions
row is now an editor — a four-digit octal field (leading
setuid/setgid/sticky digit preserved through the 12-bit domain) in
lockstep with an owner/group/others × r/w/x checkbox grid. The draft
is a target-keyed `PermissionsEditSession`: verbatim octal text, the
parsed mode the grid binds, an inline invalid flag, and a revision
counter so a programmatic re-seed never lands mid-keystroke. Invalid
octal stays for correction and blocks Apply; a valid keystroke moves
the mode and the grid, a checkbox moves the mode and re-seeds the
field. Esc at the field tier reverts the draft; a clean field's Esc
falls through to the panel's close slot. Read-only surfaces render
the symbolic + octal display with a reason note (flagged name,
symlink, Windows local) — owner/group stay display-only (the D3
setOwner seam is an upstream dependency, unchanged).

The engine chmod seam did not exist end-to-end: the pinned Séance
`RemoteFileSystem.setMode` was already there, so the narrowest seam
was added — `SetPermissionsRequest` (protocol v11) through the engine
host's dispatch and the client channel, surfaced to the app as
`AppBrowseChannel.setPermissions`. Apply writes the draft's exact
masked mode through it — local and remote over the one VFS — with
typed refusals landing inline under the editor, never modal.

"Apply to enclosed items…" (folders only) runs a read-only count
pass, then a destructive-class confirmation naming the mode, the
folder, and the quantified item count (flagged names and links
disclosed, hedged when the count is incomplete); the confirmed walk
chmods files during discovery and directories post-order with the
root last — a mode that strips owner-execute cannot strand its own
subtree. Flagged names (02 §13) and symlinks are skipped without a
wire call, path dedupe defeats cycles, nested listing/chmod refusals
are tallied and the walk continues, while a root listing or root
chmod refusal fails the run typed. Cancellation is cooperative with
separate tokens for the count and apply passes; a cancelled run that
already changed items keeps a terminal cancelled snapshot. The
in-flight operation joins the tab-close guard's quantified triggers,
the confirmation resolves false when the operation is invalidated,
and every invalidation funnel (navigation, rebind, detach, panel
close, dispose) retires the draft and the run. A completed apply
refreshes the listing.

Validation: `flutter analyze` clean; `dart analyze` clean; full app
suite green (1180 tests), core suite green (924). New coverage:
octal/checkbox sync both directions, invalid rejection, exact-mode
apply through the fake channel, typed-refusal inline rendering,
read-only surfaces, count/confirm/cancel/ordering/failure walkers,
guard triggers, panel-close and rebind invalidation, the
localization contract, and core protocol/host/client seam tests.
Real-font captures inspected under `tasks/run3-task59/`: local file
editor, mid-draft sync, the counted confirmation dialog, the
settled tally, and remote file/folder inspectors.

## M3 — D12 tier-A recalibration, landed flip, enforcement (2026-09-17)

Owner ruling on open item 22 (Option 1, recommendation accepted): the
P3/P5 tier-A budgets are recalibrated to CI-fingerprint reference
values, all three tier-A scenarios flip `landed`, and `BENCH_ENFORCE_A`
is enabled. P7 keeps its plan budget (≥ 1 000 entries/s — it passes at
~2 280/s). An upstream pipelined READDIR stays explicitly non-blocking.

The recorded calibration is the fingerprint the current bench job
actually emits: `ubuntu-latest@20260907.300.1`, `linux_x64`, Dart
3.13.4 (the job SDK's stable, AOT collectors), `aot` mode, `AMD EPYC
7763 64-Core Processor`, with each scenario's
`calibratedScenarioConfig` carrying the exact config string its
collector emitted. The pool is the five main-branch runs matching that
fingerprint in full — 35005140193, 35028604913, 35033568776,
35086417157, 35125183171; 25 `ok` repetitions per scenario, within-pool
spread < 0.4 %. The earlier same-image runs on Dart 3.13.3
(34920829912, 34925105848, 34925201167, 34937535607 — the set #122
analyzed) corroborate within ~1.5 % but sit across the controlled
`dartVersion` axis, and the mixed-fleet CPU runs (9V74, 9V45, Xeon
6973P-C/8573C) are different environments — neither is pooled.

Policy: observed pooled median × 1.2 headroom, rounded up to the next
500 ms — P3 < 5 500 ms (median 4 451.6), P5 < 6 000 ms (median
4 775.8); 02 §12's P3/P5 rows carry the new values with the provenance
note, and the README gained the full calibration record. The 02 §12 P7
row, every tier-B row, and the tier-B baseline are untouched.

`ci.yml`'s bench job now forwards `vars.BENCH_ENFORCE_A` into the
checker's environment — the wiring #119 did not need while every
scenario was unlanded — and the repo variable `BENCH_ENFORCE_A=true`
is set via the Actions variables API. Landed tier-A overruns on the
calibrated fingerprint now gate; drift skips stay exit-zero in every
mode per 08 §6. `BENCH_ENFORCE_B` is not forwarded or set — tier B
remains trend-only until M9.

Checker coverage (existing suites extended, no new schemas):
`check_cli_test.dart` drives the committed catalog end to end —
in-budget medians pass enforced, an over-budget landed median fails
enforced and notices soft, a missing/errored landed scenario fails in
both modes, a per-scenario config mismatch drift-skips only that
scenario, and a controlled-axis mismatch drift-skips tier A even
enforced. `check_test.dart` re-pins the catalog: landed flags, the
recorded fingerprint, the per-scenario config strings, and the new
P3/P5 values.

Post-merge verification: the first main-branch `bench` run after this
lands must show the three tier-A rows evaluated as enforced
comparisons at the recalibrated budgets with exit 0 (or a documented
fingerprint drift-skip if the runner image rotated). Run id and output
are recorded with this PR's report.

## M4 — transfer queue core: task model, scan-then-execute, channel leases (2026-09-17)

M4 opens engine-side with the `TransferQueue` in
`poltergeist_core`'s new `src/transfer/` library (03 §4, 07 §3.5's
first scope bullet). One `enqueue` is one `TransferTask` over a
`TransferTaskSpec` (source/destination as the sealed `FsLocation`
pair, roots, destination directory, resolved conflict policy,
copy/move verb); the model carries `TransferPlan`/`PlannedFile`/
`PlannedDirectory`/`DestinationStat`, per-item `TransferItem` rows,
and enum-only state (`TransferTaskState`, `TransferItemState` — no
ambiguous booleans, no `cancelling` state since the sticky task token
trips instantly). Enqueue dedupes and drops nested roots with
source-aware separator handling (a remote name may contain a
backslash; `C:\` is never stripped to `C:`).

The scan walks the source under a lease pair held for its duration,
re-leasing through the pool on `disconnected` inside
`PoolPolicy.taskRetryLimit` — while the executor already dispatches
earlier entries, so the first byte flows before `scanComplete` and
`totalBytes` is a growing floor until then (03 §4.2, 02 §5.3).
Directories materialize parents-first through a serialized chain and
only after their listing closed; file children wait on the container
key so a keep-both-renamed ancestor rebases the subtree. Commits are
serialized per (endpoint, case-folded path) through a shared registry
— waiters hold no dispatch slot or lease and re-stat reality on
release — with Unicode simple fold when the destination reports
case-insensitive. Every file hop pipes `download` into `upload`
through `BoundedTransferSink` (03 §4.5's small buffer), and an upload
that dies early aborts the source read instead of buffering the whole
file or wedging.

Concurrency rides `leaseTransferChannel` — endpoints leased in sorted
server-id order, bounded per server by the pool and process-wide by
`maxGlobalInFlightTransfers = 6` (03 §4.3); leases release exactly
once on completion, failure, cancel, and dispose, and a lease call
that blocks past cancellation still releases when it lands. Pause is
split per the pinned semantics: queue pause stops admission while
in-flight work completes; task pause cancels each attempt token so
items return to `pending` and restart from byte zero on resume; task
cancel trips the sticky token, flips pending items to `cancelled`
immediately, and drains in-flight work — nothing wedges, including a
cancel that lands while a lease call or a scan listing is blocked.
Conflict policy resolves per item at commit time: `skip`/`replace`/
`replaceIfNewer` (±2 s window) are live, `keepBoth` lands
`name (n).ext` numbering with the registry consulted per candidate,
and `ask` plus file-replaces-directory fail honestly as per-item
conflicts until the prompt machinery lands. `move` deletes each source
file only after commit and removes source directories deepest-first
only when their whole subtree completed.

Deferred to later M4 slices, per the task's non-goals: journal/
persistence/history (03 §4.6 — landed, next section), the D14
produce-on-demand hook, the conflict prompt, and all UI. The
token-bucket throttle and remote→remote pipe transport landed in the
third M4 slice below.

Validation: 43 deterministic tests in `test/transfer/` over an
in-memory `FakeTreeFileSystem` + lease-bounded fake connection manager
(temp-dir `LocalFileSystem` for local endpoints) — scan-executes-
before-scan-completes, growing totals, strict queue order, the global
cap, per-server lease bounding, lease release on every exit, queue and
task pause/resume, cancel during lease wait/transfer/scan, conflict
policies, case-folded duplicate serialization, move semantics, retry
budgeting, early-upload-death abort, and dispose drain. Full core
suite 958 green (16 fixture skips), analyze clean. No app, protocol,
pin, or lock change.

## M4 — transfer persistence: journal + history store (D16) (2026-09-17)

D16 lands on the queue core: `FileTransferPersistence` in
`src/transfer/` keeps two append-only JSONL files under a
caller-provided directory — `transfer_queue.jsonl` (the live queue's
write-ahead journal) and `transfer_history.jsonl` (finished-task
records for the activity panel's History tab). The queue takes the
store as an optional seam: `persistence == null` runs the #147
in-memory behavior unchanged.

The journal vocabulary is the §4.6 set — `taskEnqueued` (full spec),
`planEntry` (per scanned item, with the itemId minted at scan time so
replay upserts on (taskId, itemId) and a re-scan reuses journaled ids
via destination-path merge), `scanComplete`, `taskState`,
`fileCompleted`, `fileFailed` (with error text + failure kind),
`itemRemoved`, `taskRemoved`. Every transition is journaled before the
in-memory effect it describes (a fault-injection test records the
journal tail at append time and asserts the state is not yet visible).
Appends funnel through one serialized writer chain shared with the
compaction rewrites, so no record can land on a pre-rename inode;
fsync runs on the §4.6 boundary (every ~64 records or ~250 ms, always
before a task's history append).

Recovery replays the journal at open: a torn non-newline tail is
truncated with its dropped bytes counted; a complete-but-unparseable
line or an unknown record type/schema version quarantines the file
(timestamped copy), replays the intact prefix, and atomically rewrites
the journal to that prefix so no quarantine loop. `TransferTask` now
carries a constructor-taken stable `id`/`enqueuedAt` plus
`startedAt`/`finishedAt` so restored tasks keep their identity and
history durations span the pre-crash work. Restored tasks map
journaled state per §4.6 — `paused` survives, `running`/`scanning`
become `queued` — while `restore()` sets the runtime-only queue-level
pause flag (only when the replay is non-empty) so nothing dispatches
before Resume; a journaled-paused task additionally waits for its own
`resumeTask`. A task that crashed mid-scan re-scans on resume and
merges journaled items by destination path — a file the user watched
fail or removed never silently resurrects — while a fully-scanned task
rebuilds its plan from journaled records with no re-scan. Restore also
sweeps `.poltergeist-*.tmp`/`.seance-upload-*.tmp` debris in
directories the journal names, scoped by the journaled paths only.

Compaction runs at startup after replay, at clean `shutdown` (which
suppresses I/O failures — `flush` stays the error-propagating
durability boundary), and whenever finished-task count or journal
bytes cross a threshold: finished tasks append to history first
(idempotent by task id), then the journal atomically rewrites to the
pending tasks' full record sets, preserving unknown additive fields
verbatim via raw-line passthrough. Rewrite temps are exclusive-owned,
fsynced before rename with a directory fsync after; crash debris older
than an hour is swept at open. History appends one record per terminal
task at completion (mid-session live) and trims to the 10 000-record
cap only once the 10 % slack is crossed, keeping the newest.

Validation: 25 new tests in `test/transfer/transfer_persistence_test.dart`
— recovery/torn-tail/quarantine/schema-version, single-writer ordering
across a gated rewrite, compaction and history-cap retention,
write-before-effect ordering, full journal lifecycle, restore mapping
(paused survival, mid-scan re-scan merge, completed-item suppression),
`removeTask`, journaled-path temp sweep, and the persistence-disabled
no-op. Full core suite 993 green (16 fixture skips), analyze clean.

## M4 — token-bucket throttle + remote→remote piping (2026-09-17)

The queue's remaining engine-side concurrency features land per 03 §4.3
and §4.5. `BandwidthLimiter` (`src/transfer/bandwidth_limiter.dart`) is
the §4.3 token bucket: capacity `max(rate, maxChunkBytes)` with
`maxChunkBytes` injected (default `maxTransferChunkBytes` = 64 KiB, the
largest chunk a VFS stream read hands the pipe), a full initial bucket
for the bounded start burst, capacity-sized grants for oversized
acquires, FIFO waiter release, and a `bytesPerSecond` setter that is the
dynamic rate-change API — a decrease clamps the banked tokens (never a
fresh burst), an increase is observed by parked acquires, and `<= 0`
normalizes to unlimited so a hand-edited zero can never build a stuck
bucket. Waits ride zone `Timer`s on `clock.now()`, so `fake_async`
drives the whole contract and no acquire ever blocks the event loop; a
parked acquire takes an optional cancellation token and fails with a
typed `cancelled` error. The queue owns one bucket per direction,
engine-global exactly as §4.3 specifies — every remote-bound file hop
acquires per chunk, and a local leg rides a shared always-unlimited
instance so the pipe path stays literal.

The pipe itself is the existing `download` → `BoundedTransferSink` →
`upload` hop, now exercised for remote→remote: `BoundedTransferSink`
gains optional read/write chunk gates that park each chunk on the bucket
grant (the read gate also on free buffer space, so the high-water bound
holds under throttle) and unwind on abort or attempt cancel through a
sink-owned gate token. Both endpoint leases come from the sorted
server-id acquisition order already in `_leaseEndpoints` — a cross-server
pipe holds one channel per connection and releases both on success,
failure, cancel, and pause. Progress is counted once: both VFS calls
report cumulative bytes into a max-of-sides combiner, so a silent source
still progresses through upload reports and a reporting pair never
double-charges. Either side's failure cancels the other — an early
upload death aborts the read, a source failure poisons the consumer
stream — and the thrown error names the failing side (`transfer source:
…` / `transfer destination: …`) while preserving the typed
`RemoteFileErrorKind` for conflict-retry and cancelled-requeue
classification. One latent defect the new coverage exposed and fixed: a
source error relayed through the sink into the upload stream was
previously indistinguishable from an upload failure, which cancelled the
attempt token and laundered the failure into a silent requeue; the sink
now records `sourceError` and the upload watcher skips relayed errors.

No journal schema change: pause/cancel/complete milestones ride the
existing `taskState`/`fileCompleted`/`fileFailed` records (a piped task
journals enqueued → planEntry → scanComplete → fileCompleted →
taskState, asserted in order), and throttle rate changes are engine
configuration, not queue state — the settings layer persists them, the
journal never replays them. Same-server rename stays a separate
server-side operation per §4.5's carve-out; this slice pipes
byte-for-byte for every remote→remote combination.

Validation: 13 `fake_async` limiter tests in
`test/transfer/bandwidth_limiter_test.dart` (burst-then-sustain pacing,
window bound, capacity-sized grants, waiter FIFO, unlimited release,
cancel eviction, clamp-on-decrease, observe-on-increase, no banked burst
on enable, zero/negative normalization) plus 15 queue-level tests in
`test/transfer/transfer_throttle_test.dart` (per-direction bucket
charging across all four location pairs, parked-acquire stall/resume,
pause eviction and lease release, bounded in-flight bytes via a
production/consumption probe, counted-once progress, silent-source
progress, side-named failures, both-lease release, sorted acquisition,
journal order). Full core suite 1029 green (16 fixture skips), analyze
clean.

## M4 — conflict model: the §5.2 five-verb decision layer + ask-park seam (2026-09-17)

02 §5.2's conflict model lands in two layers. `conflict_policy.dart` is
the pure half: `ConflictPolicy` carries the per-direction/per-kind
settings matrix verbatim (upload/download/local/remote-to-remote ×
files/folders, all defaulting to `ask`, `merge` normalized out of file
fields at construction and on decode, enum names persisted — never
booleans) with `policyFor` resolving a source/destination pair into the
per-task `ResolvedConflictPolicy`; `resolveTransferConflict` is the
metadata-only decision function — source/destination kind plus fresh
destination stat plus source mtime in, one typed disposition out
(proceed / replace-with-`expectedTarget` / skip / keep-both / merge /
ask). The ±2 s mtime window governs `replaceIfNewer`; missing or
in-tolerance mtimes are never newer — files skip, a directory falls
back to `merge` when the occupant is a directory (recursion is
possible) and to `ask` when it is not. `numberedConflictName` owns the
`name (n).ext` scheme (last-dot extension, leading-dot names
extensionless, existing ` (n)` stripped so retries never stack), and
`taskScopePolicy` is the apply-to-all mapping — `merge` keeps folders
merging while its file analog is `replace`.

The queue half turns `ask` from the honest placeholder failure into the
real §4.1 park: a colliding file or directory lands in the new
non-terminal `TransferItemState.conflictPending` — no dispatch slot, no
lease, no registry claim, nothing journaled — and surfaces a
`PendingConflict` (both sides' name/size/mtime, plus the legal verbs,
`merge` offered for folders only) through `queue.pendingConflicts` and
the new `TransferQueueConflictEvent` (`pending: true`/`false` births and
dismissals). `resolveConflict(taskId, itemId, verb, scope:)` is the
answer seam the future dialog drives: it rejects `ask` outright and
`merge` on a file item, returns `false` for stale/cleared/unknown ids,
records the answer session-scoped, then requeues the item so the
decision re-runs against a fresh destination stat — a vanished occupant
proceeds, a freshened one re-decides honestly. `scope: task` is the
"apply to all remaining" checkbox, installed through `taskScopePolicy`;
an earlier per-item answer still outranks a later scope. The surfaced
set is queue-wide bounded (`maxSurfacedPendingConflicts`, default 256):
collisions past the cap wait unsurfaced — still holding nothing — and
promote in queue order as answers free slots, re-statting fresh rather
than reusing a stale entry. A §3.3 reconnect (task → `queued`)
invalidates the surface — parked items re-dispatch, re-stat, and
re-park fresh — and cancel/fail sweeps dismiss it; recorded answers
survive invalidation since they are decisions, not prompts.

Persistence needs no new record types, per §4.6's session-scoped prompt
rule: a parked item journals nothing, so a crash mid-prompt replays the
still-pending plan entry, which re-dispatches, re-stats, and re-surfaces
the conflict on resume (proven by the new restore test). Resolved items
journal their outcome at the existing `fileCompleted`/`fileFailed`
safe points. Deferred unchanged: `replace` that must remove an occupant
(dir→dir wholesale, either direction onto a kind-mismatched occupant)
fails honestly — the delete belongs to the D15 trash story — and no
dialog/panel UI exists; `TransferQueueConflictEvent` is the seam it
will bind.

Validation: 26 contract tests in `conflict_policy_test.dart` pin the
decision table (every verb × every source/occupant shape, tolerance and
missing-mtime fallbacks, numbering scheme, direction matrix, JSON
round-trip with hostile values); 14 queue tests in the new
`transfer_conflict_test.dart` cover park posture (slot-free/lease-free,
sibling items unaffected), every answer verb, fresh-state re-decision,
validation errors, apply-to-all per kind, surface bounding and
promotion, cancel dismissal with late-answer rejection, and reconnect
invalidation with re-prompt; `transfer_persistence_test.dart` gains the
restart re-prompt. Full core suite 1071 green (16 fixture skips),
analyze clean. No journal schema, protocol, app, pin, or lock change.

## M4 — recursive walker: streaming enumeration for upload/download/delete (2026-09-17)

07 §3.5's recursive-operations bullet lands as the app-level
`RecursiveWalker` (`src/transfer/recursive_walker.dart`), and the
queue's scan now consumes it instead of owning the inline walk. The
walker enumerates the source tree over the one VFS (D3 — local and
remote endpoints alike) as a pull-driven `Stream<WalkEvent>`: the
generator suspends at every yielded event, so pending discovery stays
bounded at the in-flight listing plus the not-yet-listed directory
backlog — a stopped consumer stops all further listing work, and a huge
tree never materializes. Two purposes share the machinery:
`WalkPurpose.transfer` keeps the queue's parents-first breadth order
with a `WalkListingClosedEvent` marking each directory's planned
children final (03 §4.2's closed-listing rule), and
`WalkPurpose.delete` enumerates post-order (children before their
container, symlinks as leaf targets — never followed) for the D15 trash
follow-up; the walker itself never deletes — enumeration and reporting
only.

Safety is the walker's, ported from Séance's RemoteFilesController
boundary rules: destination leaf names validate per the destination
endpoint (`validateLocalName` for local — the full Windows reserved
table, forbidden characters, trailing dot/space — `validatePathComponent`
for remote), traversal containment requires every listed child to be a
bare name joined under its container (`..`, separator-carrying, and
path-mismatched entries fail the walk loudly instead of escaping the
root — symlink loops cannot form since links are never followed), and
§13 flagged names report as `WalkItemKind.flagged` rows — never
silently dropped; a flagged directory is never listed because its lossy
name cannot round-trip to the wire. Flag detection rides the injected
`isFlaggedEntry` seam until the pinned `RemoteFileEntry` exposes
raw-name metadata (open item 13); nothing is flagged by default, and a
literal U+FFFD is never treated as flag evidence.

The queue's `_walkRoots` consumes the stream with the pause/cancel gate
ahead of every pull (a paused task runs zero listings; cancel unwinds
at the next check point — an in-flight listing may still drain
engine-side since the VFS has no cancellable listing, open item 12).
Report kinds land as terminal rows (symlink skips, flagged skips,
rejected-name and unsupported-type failures), files/dirs plan, journal,
and arm exactly as before, and the per-item conflict check still runs
at dispatch on fresh destination stats. `TransferTask` gains growing
`totalFiles`/`totalDirectories`/`completedDirectories` counters and
`TransferQueueProgressEvent` surfaces them alongside the existing byte
totals and `scanComplete` marker (02 §5.3's `N+` floor).

Validation: 22 walker tests in `recursive_walker_test.dart` (order and
container linkage, pull-bound enumeration, growing totals, root/listing
failures, the exact reserved-name table for both destination kinds,
traversal escapes, flagged reporting including flagged-directory
terminality in both walk modes, both cancel shapes, delete
post-order and enumerate-only boundary) plus 9 queue-integration tests
in `transfer_walker_test.dart` (upload and download direction, conflict
handoff through `ask`, per-item rejections with siblings transferring,
escape loud-failure, flagged row, transient and persistent mid-scan
disconnects riding the re-lease seam, mid-walk cancel admitting no new
listings or items). Full core suite 1102 green (16 fixture skips),
analyze clean. No journal schema, protocol, app, pin, or lock change.
Recursive delete *execution* remains the D15 follow-up's — the walker
only enumerates and reports delete candidates.

## M4 — local↔local first-class ops (D26) (2026-09-17)

07 §3.5's D26 bullet lands on the #147–#151 engine with no second code
path: a local→local copy already rides the one task pipeline — scan,
conflict decide, the bounded `BoundedTransferSink` pipe, per-item
progress, and the same sticky/per-attempt cancellation as the remote
directions, with both legs charging `_localLimiter` so neither network
bucket pays. What this slice adds is the move semantics.

A same-device local move now commits as rename(2) through the VFS seam
(`RemoteFileSystem.rename` on the injected local fs) — one atomic
directory-entry swap per file carrying mtime and mode (directory trees
are still materialized at the destination and removed entry by entry,
never renamed whole), with the same expected-target re-verification the
piped upload performs, and full-size progress on completion for parity
with the piped path. A rename that
reports EXDEV — surfaced as the new typed
`LocalCrossDeviceRenameException` out of `LocalFileSystem` so the
generic guard cannot flatten it — degrades to the piped copy+delete
inside the same task: the copy is byte-verified by the pipe, then the
new `flushLocalDestination` seam fsyncs the landed file's data and its
containing directory (reusing the journal's `TransferJournalIo`
primitives, 03 §4.6's durability rule) before the source unlinks. A
partial or cancelled copy therefore leaves the source fully intact and
nothing committed at the destination — either the original or a durable
copy, never neither (00 D26). The barrier also covers remote→local
moves; a same-device rename needs none (the atomic swap is itself the
either/or).

Case rules: a move whose resolved destination IS the source — the same
path, or a spelling that canonicalizes to it on a case-insensitive
volume — completes in place instead of piping onto itself and unlinking
the only copy (the pre-change code destroyed the file under `replace`).
The check lives at file level in `_decideFile` and at directory level in
`_materializeDirectory` (`_DirState.selfTarget` exempts the tree from
`_removeMovedDirectories`), ahead of the conflict verbs, so an
in-place move reports completed rather than colliding with itself.
Case-only renames still ride `LocalFileSystem`'s two-step sibling path
(unchanged); on a case-sensitive volume a case-only target is simply a
new name — the folded-destination registry and the #150 conflict model
decide collisions as before, and both behaviors are pinned by tests
driving a case-folding `FakeTreeFileSystem` as the local side.

Preserved vs dropped metadata (D26 v1, unchanged from the pipe's
existing contract): mtime via `setTimes` post-commit and the POSIX mode
bits via `preserveMode` on upload; rename carries both natively.
xattrs, ACLs, ownership, and birth time are dropped — explicitly out of
v1 scope per the decision; the native fast-path spike (APFS clonefile,
Linux FICLONE, Windows CopyFileEx) remains scheduled in 07.

Validation: 19 new tests in `local_ops_test.dart` — bounded streamed
copy with a byte probe, progress events, mid-copy cancel with no orphan
temps, mtime+mode preservation, throttle-bucket isolation, journal
milestones; rename-path move (no bytes piped); EXDEV move ordering
(flush before unlink), mid-copy failure and cancel both preserving the
source, flush-failure pinned to the durability barrier with the source
intact; file and directory self-moves; keepBoth self-copy; a same-device
directory move asserting rename(2) stays file-only;
case-insensitive self/occupant folding and case-sensitive distinct-name
behavior on the fake plus an adaptive real-fs probe — plus one
`isCrossDeviceRenameError` predicate test covering POSIX EXDEV and
Win32 ERROR_NOT_SAME_DEVICE (17, platform-gated so POSIX EEXIST never
misfires). Full core suite 1122 green (16 fixture skips),
analyze clean. No UI, no trash/D15, no DnD, no pin or lock change.

## M4 — trash service + delete tasks (D15) (2026-09-18)

07 §3.5's D15 bullet lands the delete half of the VFS: every user-facing
destructive action now routes through one trash service above the raw
`RemoteFileSystem.delete` primitive, which stays one-entry,
nonrecursive, and unreachable from the UI layer (03 §7.1/§7.3).

`trash_service.dart` carries the boundary. Local deletes dispatch by
platform: macOS and Windows ride the new `poltergeist/trash` channel
(`ChannelTrashBackend` over an injected `TrashChannelInvoker` — the app
binds `FileManager.trashItem` and `IFileOperation` +
`FOF_ALLOWUNDO|FOFX_ADDUNDORECORD` in the apartment-threaded COM
initialisation; with no invoker wired the backend reports unavailable).
Linux spawns `gio trash` through an injectable `ProcessRunner` — arg
list, never a shell — with the `gio --version` capability probe run
once and cached. `LocalTrashService.withBackend` is the test seam.
Unsupported platforms and absent backends throw typed `TrashException`s
(`unavailable`, `unsupportedPlatform`, `failed`) — never a silent
fallback unlink.

Remote trash is opt-in per server (`remoteTrashEnabled`): a confirmed
trash request moves entries into `<common parent>/.poltergeist-trash/
<runId>/` under flat sequence-prefixed names (`000001-basename`), so
same-basename roots cannot collide and a collision in the shared folder
just bumps the sequence. Both directory levels are created (or
repaired) to `0700`; a server that cannot `setMode` or where a file
squats on the trash name refuses rather than degrading. Moves are VFS
`rename`s — a rename failure fails the item, never falls through to
permanent delete.

The queue gains `TransferOperation.delete`: `prepareDelete` walks the
roots for the confirmation sheet (names, item/byte totals, flagged-descendant
count, the effective disposition after opt-in and availability checks)
and `enqueueDelete` builds a journaled task. Roots are normalised,
deduped, nested roots dropped, and filesystem roots refused. The scan
runs `WalkPurpose.delete` — post-order, symlinks as leaves, listing
failures preserved — and execution is a single serial chain so children
always precede their container. Permanent delete additionally requires
`DeleteConfirmation.confirmed`; anything else throws before touching
the VFS. Journal `FileCompletedRecord`s now carry the per-item
`ItemDisposition` (`osTrash`/`remoteTrash`/`permanent`) and history
rows the task-level `DeleteDisposition`, so a restored task replays
terminal delete rows without re-trashing them and a delete spec missing
its disposition fails strict decode rather than defaulting. Flagged
descendants (safety filter) surface as skipped rows and are never
unlinked — a partially-flagged directory then fails its permanent
delete honestly instead of emptying around the flag. Occupant
replacement inside the normal copy/move conflict verbs is still the
declared later slice: `replace` on an existing directory occupant
continues to fail with the explicit later-slice message.

Validation: 24 new tests in `trash_delete_test.dart` — channel dispatch
and argv shape for all three platforms, unavailable/unsupported typing,
the cached gio probe, 0700 creation and repair, seq naming, collision
bump without clobbering trash, post-order unlink ordering, opt-in
refusal, confirmation gating, backend delivery vs raw unlink, flagged
disclosure, prepareDelete quantified/unquantified, and a journaled
delete task replaying terminal items without re-dispatching.
`FakeTreeFileSystem` grew `setMode` and directory rename with subtree
rebase to support it. Full core suite 1146 green (16 fixture skips),
analyze clean. No UI wiring, no engine protocol surface yet — the pane
delete gesture and the app-side channel binding land with their own
slices.

## M4 — native trash bindings wired (D15) (2026-09-19)

The `poltergeist/trash` channel now exists end to end. The platform
`MethodChannel` answers only on the UI isolate, so the engine reaches it
through an explicit relay (03 §7.1): `EngineConfig.trashRequests` (protocol
v12) carries a SendPort across the spawn, `trashChannelInvokerFor` turns it
back into a `TrashChannelInvoker` (`TrashInvokeRequest` out, per-request
reply port, `TrashInvokeReply` back, 5-minute bound so a wedged server
fails the item rather than hanging the task), and `EngineHost.localTrash`
builds the dispatching `LocalTrashService` from it — the seam the
engine-side transfer queue takes when it lands. App side,
`TrashChannelServer` binds on macOS/Windows only and is closed on session
shutdown and every spawn-failure path.

macOS Runner serves `trash` through `FileManager.trashItem` off the
platform thread and returns the `trashedPath` (the Put Back anchor; Put
Back itself stays Finder's). Windows Runner adds `TrashOperations`, a
dedicated STA worker (`CoInitializeEx(COINIT_APARTMENTTHREADED)`) that runs
`IFileOperation.DeleteItem` with `FOF_ALLOWUNDO | FOFX_ADDUNDORECORD` —
Recycle Bin delivery plus Explorer's undo record — with results delivered
off the worker and teardown ordered channel → worker → controller. Bad
arguments answer `TRASH_BAD_ARGS`; operation failures `TRASH_FAILED`.

Linux packaging: `gio` is a spawned binary, invisible to the ELF-derived
Depends scan, so `package-linux.sh` now adds `libglib2.0-bin` explicitly —
verified: `--print-deps` emits it on the real bundle. The AppImage ships no
system tools, so on a gio-less host the cached probe reports unavailable
and the confirm-then-permanent fallback applies — honest, never a silent
unlink.

Validation: 11 new core tests (`trash_channel_relay_test.dart` —
feature-detection, reply/failure/malformed/timeout relay semantics, a real
`SendPort` crossing a spawned isolate; `trash_roundtrip_linux_test.dart` —
a live `gio trash` + `.trashinfo` restore round-trip, honestly skipped
where gio is absent) and 5 new app tests (`trash_channel_test.dart` —
bind/no-bind per platform, mocked-channel round-trip, PlatformException
propagation, malformed-message reporting; `engine_session_test.dart` — the
port lands in `EngineConfig`, a failed spawn leaves a closed port).
`flutter analyze` clean, core suite green, `flutter build linux --debug`
builds, `package-linux.sh --print-deps` shows `libglib2.0-bin`. macOS/Windows
native compilation is CI-leg verified; no local runners exist, so the OS
round-trips are covered by the channel-contract tests instead.

Manual QA note (07 §3.5's exit criterion — the legs CI cannot prove):
on macOS, trash a file from a local pane and confirm it lands in Finder's
Trash with Put Back enabled (best-effort OS behavior, per 07 §3.5 — the
app returns the `trashedPath` anchor but does not guarantee Finder keeps
the origin metadata); on Windows, trash a file and confirm it appears in
the Recycle Bin and restores via Explorer's Ctrl+Z (the
`FOFX_ADDUNDORECORD` record); on a packaged `.deb` install on a
desktop-lite distro, confirm `gio trash` works because `libglib2.0-bin`
is now a hard dependency, and on the AppImage on a host without `gio`,
confirm the delete dialog offers only the confirm-then-permanent path —
never a silent unlink.

## Review-workflow stall hardening (2026-09-18)

The GLM review workflow's Z.ai step hung silently three times in ~12
hours (run 35138309899 on #145; run 35309295043 twice on #154 — each
frozen ~60 min with no status update, manual cancel required),
blocking the merge gate of green PRs each time (task68 review gap).
The per-attempt 170 min step timeout and unfinished-review report
already on the workflow convert a hang to a loud failure; this slice
adds the one automatic retry (two attempts max, per the
reviewer-integration stopping rule) and makes the final failure
explicit: first attempt runs with `continue-on-error` so a failure or
timeout reaches the retry, a retry success posts findings and leaves
the job green, and only a retry failure or skip reaches the reporting
step, which posts the "review did not complete" comment naming both
attempts and exits non-zero. The 170 min per-attempt value is kept
with its Seance PR #89 data (healthy revisions took 76 and 105 min;
170 covers ~27 chunks at that mean) — sizing to Poltergeist's ~50-65
min healthy range would falsely fail large-diff reviews. Job backstop
rises 180 to 350 min (2 x 170 plus reporting; under the 360 min
GitHub-hosted ceiling). No prompt, model, trigger, or semantics
change. Validation is config review (actionlint clean) plus
simulated path reasoning in the PR body; a real hang cannot be forced
on demand, so the next genuine stall converting to an actionable
failure is the proof. After merge the review is re-requested on #154
without merging it, for supervisor verification.

## M4 — activity panel: the queue's window (D16) (2026-09-18)

02 §6's transfer surface lands over the #147–#153 engine as optional
bottom-panel chrome — hideable by intent, never by omission: rows are
the queue's only representation while tasks exist (the status bar's
transfer chip is a summary, not a substitute), and the empty→live edge
re-opens a hidden panel for new work.

The app-facing seam is `AppTransferQueue` (`services/app_transfer_queue.dart`)
— the queue's snapshot/query surface plus its verbs, with a
`TransferQueueAdapter` for in-process fakes. `EngineClient` still
exposes no transfer verbs (protocol v11's placeholder seams), so the
shell takes a nullable queue and mounts the panel empty rather than
fabricating activity; the engine-host transfer slice owns the
production wiring when it lands. `ActivityPanelController`
(`services/activity_panel_controller.dart`) mirrors the queue into a
`ChangeNotifier`, owns presentation state only — tab, linger timers,
the §5.3 smoothed rates (`TransferRateTracker`: 5 s window, ETA gated
on 3 s of data and refreshing at most 1 Hz, non-monotonic byte counts
reset the window) — and delegates every mutation to the seam.

The panel itself (`ui/activity/`): Activity/History tabs, queue
pause/resume, a bandwidth popover (Off/256 KB/s/1 MB/s/5 MB/s/custom
with `parseTransferRate` validation — bad input is an inline error,
never a clamp), the restored-queue banner (Resume/Discard over
`TransferTask.wasRestored`), the pending-conflict strip fed by the
queue's `pendingConflicts` query, and the §5.2 chooser dialog with
apply-to-all scope. Task rows band live/pending/terminal — only the
pending band drags (`ReorderableListView.onReorderItem` mapped onto
`beforeTaskId`) — and carry per-state verbs: cancel on live, retry +
remove + copy-error on terminal, reveal-in-pane. Item sub-rows offer
Skip/Cancel/Retry/Resolve by state. Completed rows linger 10 s before
auto-removal (the persisted auto-clear preference, default on); failed
and cancelled rows wait for explicit removal. The growing-totals
footer shows `N of M+` while any scan is still discovering work.

Persistence: `activityPanelHidden` joins `SessionState` (optional,
decode-safe on old documents), and `AppPreferences` gains panel height
(default 200, floor 120), per-direction throttle limits (non-positive
decodes unlimited), and the auto-clear flag — keys
`layout.activityPanelHeight`, `transfer.{download,upload}LimitBytesPerSecond`,
`transfer.autoClearCompleted`.

D21: `queue.togglePause` (Commands menu, order 70) and
`view.toggleActivityPanel` (View menu, order 80 — the §8.1 reserved
slot, ⌥⌘A / Ctrl+Alt+A) are registered commands, not palette-only.

The narrow core seam the panel needed: `TransferQueue` grew
`moveTask` (queued/scanning only), `cancelItem`, `retryItem`/`retryTask`
(re-enqueue from journaled records — a missing record refuses rather
than resurrecting), `history`/`clearHistory` on `TransferPersistence`,
the `TransferQueueOrderEvent`, and `TransferTask.wasRestored` (03 §4.6's
journaled provenance marker the banner keys on).

Validation: 20 new core tests (`transfer_queue_panel_ops_test.dart`),
30 app tests across `activity_panel_controller_test.dart`,
`activity_panel_test.dart`, `activity_shell_test.dart` (D21 menu
reachability, auto-show, splitter persistence), and
`activity_panel_capture_test.dart` (three real-font PNGs under
`tasks/run3-task68/captures/`). Review round 1 dispositions landed in
the same PR: `parseTransferRate` rejects an infinity product before
rounding, `TransferRateTracker.bytesPerSecond` expires the window
read-side once the newest sample ages out, the fake queue's
`cancelItem`/`cancelTask` drop parked conflicts with dismissals (the
real queue's exact semantics), the panel-resize clamp guards a
sub-240px window, `commonParentPath` seeds at the first path, the
bandwidth popover seeds its Custom prefill in `didChangeDependencies`,
`conflictApplyToAll` pluralizes, and `addTask(id:)` without
`wasRestored` throws rather than silently dropping the key. Round 2
added the `_loadLimit` non-finite guard (a corrupt settings file's
`1e999` decoded to Infinity and `toInt()` threw outside the try) and
widened the parser guard to `!isFinite`; the `clearCompleted`
iterate-while-removing suggestion was declined with evidence
(`List.unmodifiable` already snapshots on both seam implementations —
the `tasks` doc now says so). Round 3 fixed the retry-debit check to
compare against the previous sample rather than the window's oldest —
a partial debit above the floor had evaded the reset and misreported
a stale rate. Round 4: `commonParentPath` treats `/` as an ancestor of
every absolute path (reproduced red-first — `['/a', '/b']` returned
`''` since `'/a/'.startsWith('//')` is never true), the popover barrier
is `HitTestBehavior.opaque` (translucent leaked tap-down/ripple and
hover to the panel behind; the tap arena had already protected
`onTap`), and the tabs carry `Semantics(selected:)`. Full suites: app
1242 green, core 1170 green (16 fixture skips), both analyzers clean,
localization contract green.

## M4 — drag & drop: in-app pane↔pane + OS drop-in (D14) (2026-09-18)

07 §3.5's DnD slice lands per 02 §5 and D14. In-app pane↔pane drags use
`Draggable`/`DragTarget`; OS drop-in uses `desktop_drop` with Séance's
gating pattern — desktop platform, `TickerMode.enabled`, and route-current
checks, so hidden or covered panes never accept. No drag-out to the OS
(D14's explicit exclusion), no trash UI, no sync-engine change.

The enqueue seam is `AppTransferQueue.enqueue(TransferTaskSpec)` — drops
build specs and hand them to the queue; nothing executes inline and the
existing conflict/paused/throttle flow owns collisions unchanged. The verb
matrix is 02 §5's: same filesystem/server defaults to move, across
filesystems or servers defaults to copy, Option/Ctrl forces copy,
Command/Shift forces move, and OS drop-in always copies; remote→remote
across servers is a copy through the local machine, and same-server remote
moves ride server-side rename when the engine path lands.

`PaneDropArea` (`ui/panes/pane_drop_area.dart`) wraps each pane's listing:
it owns the in-app `DragTarget<PaneEntryDrag>`, the OS `DropTarget`,
folder-row vs current-directory resolution, the target border and action
pill ("Move to …" / "Copy to …"), and the spring-load dwell — a folder row
held 1 s opens in place, a tab chip held 700 ms activates. Drop position
decides the
destination — a rendered folder row means that folder, background means
the pane's current directory — and hit testing works on rendered row
rects inside the virtualized list rather than model indices, so a
scrolled-out folder cannot shadow the row actually under the pointer.
Rows drag only on desktop platforms (mobile keeps touch scrolling), only
while a drop delegate is wired, and only while the pane's verbs are
enabled (stale/disowned panes refuse). A `HardwareKeyboard` handler
re-resolves the hover on modifier events, so copy/move labels and the
avatar's `+` badge track live modifiers without pointer movement. Tab
chips are drop targets with the same spring-load. The drag avatar is a
stacked-icon chip with a count badge for multi-selection and `+` for
copy; the source row shows the pending ghost (`childWhenDragging`) and
the target row/zone highlights per §5's pending/completed row states.

`services/pane_drop.dart` carries the pure rules — `PaneEntryDrag`,
`PaneDropVerb`, destination/verb resolution, and the queue-wired
`PaneDropDelegate` — so the widget layer stays thin.

Validation: 20 service tests (`pane_drop_test.dart`) pin the verb matrix,
containment (no drop onto self/descendant), the §5.2 direction bucket at
enqueue time, and the absent-settings ask defaults; 25 widget tests
(`pane_drop_test.dart`) cover enqueue correctness, copy/move modifiers,
folder vs background targeting, scrolled-list hit honesty, hidden-pane
rejection (the hidden second pane is unmounted by the shell), TickerMode
and route-current gating, `desktop_drop` channel fakes, tab-chip drop +
spring-load activation, and multi-selection badges. The capture suite
(`pane_drop_capture_test.dart`) writes five real-font PNGs under
`tasks/run3-task70/captures/` under `POLTERGEIST_CAPTURE=1`. The
localization contract gains per-file technical-literal exclusions for the
path mechanics in `pane_drop.dart` and the count/`+` badge glyphs in
`pane_drop_area.dart`. `desktop_drop` self-applies the Kotlin plugin in
its own Gradle file — no file_picker-class AGP9 exposure (verified in the
plugin's build script). `flutter analyze` clean; full app suite 1287
green. Logs under `tasks/run3-task70/`.

## M4 — quit guard: prevent-close wired to the transfer queue (2026-09-19)

07 §3.5's last scope bullet: the M2 `window_manager` close interception
now consults the transfer queue. `DesktopWindowLifecycle` gains a
`confirmClose` seam that runs before anything else on the close path —
a false veto unwinds `_closing`/`_closeFuture` so the window is fully
live again and the next close re-runs the whole path — and `main.dart`
hands it `QuitGuard.confirmClose`. The same guard also gates
`AppLifecycleListener.onExitRequested` in `app.dart`, so Cmd+Q / OS quit
gets the identical warn/flush semantics as the window chrome's close
button.

`QuitGuard` (`services/quit_guard.dart`) owns the flow behind the app
services layer: `WorkspaceShell` binds a live `AppTransferQueue?`
lookup (rebound on widget replacement, unbound on dispose) so the guard
never keys on a stale queue. With no queue, or only terminal tasks, it
flushes the journal and lets the close through silently. With
active/paused tasks it raises 02 §10's quit dialog over the app
navigator — "N transfers are running (X remaining so far)", the
restart-from-the-beginning honesty note, and the three verbs: `Pause
and Quit` (default, pauses non-terminal live tasks), `Cancel Transfers
and Quit` (cancels them), `Keep Transferring` (veto; barrier dismissal
vetoes too). Both quit verbs then await
`AppTransferQueue.flushJournal()` — a new app-seam method delegating to
`TransferPersistence.flush`/`shutdown` — inside a bounded timeout
before `destroy`, per D16. A flush timeout or failure surfaces the
§10-style warning dialog (`quitFlush.*`), reports through `onError`,
and vetoes the close: the window never destroys with a silently
unflushed journal, and a retry closes once the journal recovers.

All copy lives in `app_en.arb` (`quitConfirm*`, `quit*`,
`quitFlushFailed*` keys); the dialog's widget keys (`quit.dialog`,
`quit.pauseAndQuit`, `quit.cancelTransfers`, `quit.keepTransferring`,
`quitFlush.dialog`, `quitFlush.dismiss`) are registered in the
localization contract's allowlist.

Validation: `desktop_window_lifecycle_test.dart` gains the guard
veto/retry and guard-error cases (fakes extracted to
`test/support/fake_window_adapters.dart` for reuse);
`test/ui/quit_guard_test.dart` drives the real lifecycle → guard →
dialog chain end to end — active/paused warn with no destroy, each verb
(pause/cancel semantics, journal-flush-before-destroy ordering proven
by a parked flush), barrier-dismiss veto, silent close with no active
tasks or no queue, paused-only warning, and flush timeout/failure
warning that keeps the window up while a retry succeeds.
`quit_dialog_capture_test.dart` writes
`tasks/run3-task72/captures/quit-confirm-dialog.png` under
`POLTERGEIST_CAPTURE=1` (hollow-box fallback fonts on this host — the
dialog frame, copy lines, and the three-verb row are verified). The
capture's real-IO close path runs inside `tester.runAsync` with
condition-driven waits — fixed fake-zone delays flaked under suite
load. `flutter analyze` clean; full app suite 1315 green.

Known seam: `main.dart` still boots with no `transferQueue` (queue
composition is a later M4 slice), so the guard is inert in production
until that lands — the no-queue path is the covered silent close.

## M4 — exit-criteria audit and close (2026-09-19)

All six 07 §3.5 exit criteria audited against main head `b58af0d`;
the per-criterion evidence record lives in
[tasks/m4-closure-record.md](../tasks/m4-closure-record.md). Verdicts:

1. **P5 drop→start enforced — MET.** Post-#158 main run
   [35420036073](https://github.com/L-K-M/Poltergeist/actions/runs/35420036073),
   D12 job `105835867500` ran with `BENCH_ENFORCE_A: true` forwarded to
   the checker: **P5 4 774.887 ms median of 5 < 6 000 ms — pass**
   (~20 % margin); P3 4 448.165 ms < 5 500 ms and P7 2 280.086
   entries/s ≥ 1 000 also pass. The prior main run (35414902815, job
   105821522661) showed the same enforced green at 4 646.887 ms.
2. **Kill mid-queue → restore — MET**, now proven at the app seam: the
   new `test/services/transfer_relaunch_test.dart` drives a real
   `TransferQueue` + `FileTransferPersistence` through a simulated
   kill/relaunch — journaled-queued and journaled-paused tasks restore
   (`wasRestored`, forced queue pause), the completed task sits in
   `history`, and the panel's Resume finishes the surviving work.
   Engine-side replay is covered by `transfer_persistence_test.dart`'s
   queue-integration group (crashed running → queued, paused survives,
   mid-scan re-scan merge, completed items never resurrect). **Named
   gap, not a criterion failure:** open item 23 — the queue is not yet
   composed into `main.dart` (no engine protocol transfer verbs yet),
   so a production boot has no live queue to restore until the
   engine-host composition slice lands. *(Closed app-side 2026-09-19 —
   the M5-bridge section below composes the real queue into
   `main.dart`; remote transfers still fail honestly pending engine
   verbs, which stays on item 23.)*
3. **Conflict dialog, five verbs, per-direction defaults, merge
   recursion — MET.** The §5.2 chooser renders `PendingConflict`'s
   `availableVerbs` — four file verbs (merge excluded) and all five on
   folders; the widget tests now assert every verb key plus submit,
   apply-to-all scope, and Stop. Per-direction defaults ride
   `ConflictPolicy.policyFor`'s direction matrix
   (`conflict_policy_test.dart`: "every direction maps to exactly one
   bucket pair", all-ask defaults, merge-in-file-field normalization).
   Folder merge recursion is proven at the decision layer ("merge
   recurses (stat-else-mkdir, per-file policy inside)") and end to end
   at the queue (`transfer_conflict_test.dart`: "a folder ask parks the
   directory and holds its children; a merge answer recurses into the
   occupant" — new.txt lands, kept.txt survives).
4. **10k-entry recursive delete progress + cancel, local + remote —
   MET**, covered by the new `a 10k-entry delete tree` group in
   `trash_delete_test.dart`: a 10 101-item tree (100 dirs × 100 files +
   root) held mid-walk by a listing gate shows growing totals and
   progress events with `scanComplete == false`, completes post-order
   (root unlinks last), and cancels cleanly mid-walk leaving the queue
   healthy — run for both the `srv1` remote endpoint and the local
   endpoint through the injected `localFileSystem` seam. The local
   variants skip on Windows (`FakeTreeFileSystem` models posix
   separators only — the same convention as `local_ops_test`); Linux
   and macOS CI carry them.
5. **Trash round-trip per platform — MET.** The live `gio trash` +
   `.trashinfo` restore round-trip
   (`trash_roundtrip_linux_test.dart`) runs and passes in CI on
   ubuntu-latest (job `105821502762`). macOS and Windows have no
   CI-exercisable round-trip (the channel needs a native host binding);
   the manual QA note covering Finder Put Back, Explorer Ctrl+Z /
   Recycle Bin, the `.deb` `libglib2.0-bin` dependency, and the
   AppImage confirm-then-permanent fallback is recorded in the
   native-trash dated section (2026-09-19). Channel-contract tests run
   in the app suite; native compilation of both bindings is verified by
   the macOS/Windows client-build legs.
6. **Remote→remote pipe between two Docker sshds — MET**, covered by
   the new `test/integration/transfer_sshd_test.dart`: one
   `PooledConnectionManager` over `sshd-modern` (:2201) and
   `sshd-legacy` (:2202) — two TOFU pins, two pools — drives a
   101-item directory copy remote→remote through the client pipe and
   verifies the landing by listing and byte-reading through the
   *destination's* own SFTP channel. The test is `@Tags(['integration'])`
   and runs in the CI SSH-integration job (`run.sh` already exports
   `POLTERGEIST_SSHD_LEGACY`); Docker is unavailable on this host, so
   local verification is the clean skip + analyzer — CI execution is
   the proof.

§3.12 chores at this close: STATUS swept (header + this section), no
`TODO(pin)` markers exist, the pin still cannot bump (no Séance tag
contains `2e6d1f1` — open item 2), and PORTS.md carries no M4 additions
(the walker's boundary rules were reimplemented per plan — the §3.5
walker dated section records the Séance comparison; no verbatim copy).
The M4 mobile-invariant row (07 §5) **re-verifies clean**: pause-all +
journal restart is a working suspend primitive (criteria 2 + 4 — queue
pause stops admission, the journal rebuilds restored tasks, and
per-attempt channel leases mean no task assumes a long-lived socket;
the remote→remote pipe re-leases a pooled channel per attempt). The
`v0.4.0` tag chore is **not run here**: M3's precedent closed untagged
and a tag push publishes release assets — left to the supervisor/owner
with `lkm-release` available at `~/.local/bin`.

## M5 bridge — production transfer-queue composition (2026-09-19)

Closes open item 23's app half: `main.dart` now boots the real queue.
`services/transfer_queue_session.dart` opens `FileTransferPersistence`
in the app-support directory, builds a `TransferQueue` over it, runs
03 §4.6's `restore()` (journaled-paused stays paused, every other
non-terminal survivor replays queued behind the forced queue pause),
and hands one `AppTransferQueue` seam to `PoltergeistApp` — the
workspace shell's pane-drop delegate, the activity panel, and the quit
guard's close-time flush all share the instance. A startup failure
reports through `ApplicationErrorReporter` and boots queue-less,
matching the engine session's posture; production never disposes the
queue — the quit guard's non-closing `flushJournal()` remains the exit
durability point, and a vetoed quit leaves the queue writable.

Two consequence fixes ride the same slice:

- **Boot-held live tasks un-hide the panel.** The activity
  controller's auto-show is an empty→live edge; a restored queue
  already holds live tasks when the mirror binds, so no arrival ever
  fires for them and a session saved with the panel hidden would bury
  un-acknowledged work. `WorkspaceShell` seeds visibility from the
  queue snapshot at mount — live restored tasks win over the
  persisted hidden flag.
- **Remote endpoints fail honestly.** The engine isolate owns every
  socket (D8) and the §5 protocol carries no transfer verbs yet, so
  the composed queue's `ConnectionManager` is honest absence: lease
  attempts answer `unsupported` and remote tasks land as visible
  failed rows rather than stalling. Local↔local work runs for real —
  it never touches the pool. Item 23 stays open for the engine-host
  transfer-queue slice that replaces this seam.

Coverage: `test/ui/transfer_queue_composition_test.dart` boots three
sessions over one journal — a "crashed" session seeds
done/paused/queued rows, the composed session proves the restore
semantics, the mounted shell's restored banner, the pane-drop
delegate's identical queue seam (the item-23 boot-path assertion that
the production wiring hands a live queue, not none), the quit guard's
pause-and-flush, and a third boot's durability replay; a separate
test pins the remote-failure honesty. `POLTERGEIST_CAPTURE=1` writes
the restored panel to `tasks/run3-task74/captures/boot-restored-queue.png`.

## M5 — bookmark store: the 04 §2 persistence foundation (2026-09-19)

03 §6's `BookmarkStore` row lands as core code: `FileBookmarkStore`
moves from `app/services/` into `poltergeist_core` over the pinned
`Bookmark` model (D2 — one schema, never a second; PR-S1 is in the
pin's ancestry, so §2.1's temporary-copy clause does not apply), and
the app keeps only the bootstrap: `main.dart` builds one store on
`<app-support>/bookmarks.json`, every consumer still depends on the
`BookmarkRepository` seam, now exported from the barrel next to the
full `BookmarkStore` surface.

The on-disk payload is the model's `toJson()` verbatim — the exact
shape M6 seals into `bookmark:` records — so the serialization
boundary this slice owns is the sync contract, not a file format.
The 04 §2.3 split is enforced by construction and pinned by the
payload-purity suite: persisted records carry only synced keys, no
scoped-access blobs or per-device view state can appear, and the
64 KiB save-time hard cap (`BookmarkTooLargeException`) keeps
local-only never-synced state impossible per §2.5.

Grouping and ordering follow §2.1/§2.5: `sortKeyBetween` mints
fractional `a`–`z` keys (midpoint of the neighbors, `m` when none
exists, the all-`a` floor reserved and never minted — the worked
`b` → `am` → `ag` descent is unit-pinned) with the record-id
tiebreak in `compareBookmarkSortKeys`; `groupBookmarks` sections
the list the Séance way (case-insensitive group keys, name-sorted,
ungrouped last, one anonymous section when flat). `moveToGroup`/
`reorder` re-mint only the moved record's key — LWW-friendly by
construction — and a single named neighbor bounds the other side by
the adjacent member. Interim `sortKey: <uuid>` mints and other
non-`a`–`z` keys are repaired deterministically at load and on every
write, so `save_favorite_bar`'s interim mint keeps working while the
store converges the file onto minted keys.

Local CRUD stamps `updatedAt` (LWW's comparator half) and emits
synchronous `BookmarkSavedChange`/`BookmarkRemovedChange` events on
`changes` — the store-behind-callback seam the M6 coordinator marks
dirty on; `applySynced`/`removeSynced` are the verbatim, quiet
apply path so a pulled record can never re-mark itself dirty.
Failure posture is unchanged from the app store: atomic temp+rename
writes through `TransferJournalIo`, serialized write tail,
corrupt-file quarantine that fails closed, newer-`version` refusal,
and verbatim preservation of undecodable records (§2.1's
skip-and-preserve).

Coverage: 52 tests in `test/bookmarks/` — the ported app-store
persistence/atomicity matrix plus sortKey sequences (200 repeated
head and tail insertions), strict-decode preservation, restart
persistence, the M6 payload-purity and sealed-envelope contract,
group/reorder invariants, the size cap, and the change-event split.
Sidebar UI, the editor, and sync are deliberately not in this slice.

## M5 — sidebar UI over the core BookmarkStore (2026-09-19)

02 §4's global sidebar replaces the M2 interim server list, which is
deleted outright — the sidebar and the empty-state launcher are now
the only entry points (07 §3.6). `WorkspaceShell` mounts it inline at
the desktop stage and as the overlay drawer below
`desktopStageBoundary` (exposed from `pane_allocation.dart`);
`view.toggleSidebar` flips `WorkspaceController.sidebarHidden` — a
persisted user intent the stage-1 auto-collapse never latches —
and opens the drawer at the narrow stage instead.

The widget tree (`ui/sidebar/sidebar_view.dart`) renders named
collapsible groups plus the ungrouped "Favorites" section over
`SidebarController`, which drives every mutation through the core
`BookmarkStore` seam — `save`, `remove`, `moveToGroup`, `reorder` —
and reloads sections off `store.changes` with a generation guard so
stale loads cannot overwrite newer state. All four bookmark kinds
render (localFolder, remotePath, workspace, savedSync); workspace
and savedSync opens post the honest not-yet notice per D20 rather
than a dead button, since restore is the next slice. Open actions
are plain, new tab, and opposite pane — via context menu or
Ctrl/Meta/Alt modifiers — and `Bookmark.preferredPane` wins over the
active pane for remote/local opens. Keyboard operation covers arrow
traversal, Enter/Space activate, and Shift-F10/Menu-key context
menus; rows take focus on pointer down so click-then-type works.
Drag to reorder re-mints through `reorder`, drag onto a group header
refiles through `moveToGroup`, and collapse intent persists via
`AppPreferences.sidebarCollapsedGroups`. The Connections section
lists only live pool rows from `ConnectionStatusController`
(disconnect plus blocked-key review actions included), and favorite
rows compose probe dots from the new `SidebarProbeOwner` — the
multi-favorite `ProbeController` driver that replaced
`probe_coordinator.dart`, subscribing before commanding, reconciling
server-backed favorites, and purging device-local facts only on
explicit deletion.

Adoption follows through: `AppEngine.removeBookmark` lets the
controller cascade deletes into the engine before probe cleanup,
`PaneView`/`PaneTabsView`/`save_favorite_bar` widen to the
`BookmarkStore` type, and `save_favorite_bar` adopts
`sortKeyForInsert` — the #161 disclosed follow-up — so interim uuid
sort-key mints are gone from app code. `FakeBookmarkStore` now
implements the full store seam (`save`, `moveToGroup`, `reorder`,
`changes`, plus a `saveFailure` knob). The deleted surface's
coverage moved: `production_engine_wiring_test` and
`workspace_panes_test` exercise the inline sidebar for live
connections and remote opens, and `sidebar_view_test` /
`sidebar_controller_test` / `sidebar_probe_owner_test` carry
grouping, collapse persistence, menu/mutation, keyboard, live-row
filtering, and probe-lifecycle coverage. `POLTERGEIST_CAPTURE=1`
writes grouped, collapsed-group, and context-menu captures to
`tasks/run3-task76/captures/`.

## M5 — workspaces capture/restore (2026-09-19)

02 §3's saved workspaces are now real: a workspace IS a
`BookmarkKind.workspace` favorite — one bookmark per workspace —
while the full tab-set snapshot stays device-local. The bookmark
carries only what the pinned schema allows (04 §2.1): label,
sidebar order (`sortKey`), group/accent, and each pane's headline
endpoint (`left`/`right` `BookmarkLocation`s — the active tab's
location, else the first bound tab's, else `~` for a launcher
pane; remote endpoints carry host/port/user/`secretRef`, never a
secret). The exact tab sets — kind, path/remote identity, filter
query and field state, hidden-files, view mode per tab — persist
in the versioned `workspaces.saved` detail document inside
`settings.json`, keyed by the bookmark's id
(`WorkspaceListDocument` schema 2; a v1 decode flags itself so
`WorkspaceLibrary.load` mints each record's favorite under the
same id once, then rewrites v2 — and a v2 detail without its
favorite is a deleted row's residue, pruned rather than
resurrected). `WorkspaceLibrary` joins the two layers in favorite
order and answers `store.changes` — a sidebar rename re-labels
the workspace, a sidebar delete drops the detail.

Restore lands through the existing seams only: opening the
sidebar row or the `workspace.open.<id>` command runs the same
`openWorkspaceBookmark` helper — `WorkspaceController`'s guarded
both-pane replacement (close-guard confirmation before anything
moves), the 12 s opened toast whose Undo replays the displaced
snapshot through the same guard, and `markOpened`'s recency
stamp. Remote tabs restore disconnected-but-targeted via the
session restoration path (bookmark identity + path persisted on
`SessionTabState`, `markRestored` semantics, Reconnect bar, no
auto-secret use); a detail-less favorite — a synced-in record —
degrades to the schema's own reduced shape, one tab per pane at
the recorded endpoints. Re-capture is an update, never a
duplicate: `workspace.save` over a matching label and the sidebar
row's new "Update Workspace" verb (`sidebarWorkspaceUpdate`,
keyed `sidebar.menu.updateWorkspace`, hidden when the seam is
unwired) both rewrite the existing bookmark's endpoints in place
— group, order, accent, and id survive.

The workspace row drops the modifier-open verbs (new tab /
opposite pane do not apply to a two-pane restore). No sync, no
`savedSync` behavior (its row still posts the honest not-yet
notice), no new engine surfaces. `FakeBookmarkStore`'s
`sortKeyForInsert` learned the file store's real no-neighbor
contract (tail append) after the command-ordering test caught it
midpoint-minting.

Coverage: `workspace_library_test` exercises bookmark-backed
save/recapture-without-duplicate, restart reload, remote
identity/`secretRef` retention, empty-launcher endpoints, the
v1→v2 migration, and payload purity (no secret-bearing keys in
the bookmark JSON); `workspace_state_test` pins the schema flag;
`workspace_commands_test` keeps favorites-order submenu rows;
`sidebar_view_test` covers the Update verb's presence/absence and
the modifier-verb swap; `workspace_capture_test` writes
`workspaces-submenu`, `workspace-toast`, and the new
`workspace-sidebar-restore` captures under `tasks/run3-task77/`
(POLTERGEIST_CAPTURE=1). `flutter analyze` clean; the full app
suite passes.

## M5 — exit-criteria audit and close (2026-09-19)

All four 07 §3.6 exit criteria audited against the post-#163 main
head `eb13c03`; the per-criterion evidence record lives in
[tasks/m5-closure-record.md](../tasks/m5-closure-record.md).
Verdicts:

1. **Bookmark CRUD, grouping, reorder persist across restart —
   MET.** The core suite already proved the store layer
   (`bookmark_store_test.dart`: restart persistence, group/reorder
   key minting, updatedAt stamping). The audit's named gap was the
   SIDEBAR surface: every `SidebarController` test ran against
   `FakeBookmarkStore`, so no proof existed that the row verbs'
   writes survive a relaunch through the real store. The new
   `test/services/sidebar_persistence_test.dart` drives
   reorder/refile/rename/delete through the controller over a real
   `FileBookmarkStore`, then reads the same file through a fresh
   store + controller — order, group filing, rename, and deletion
   all survive the restart boundary.
2. **localFolder/remotePath open in the chosen pane; workspaces
   restore tab sets exactly — MET.** Workspace exact-restore was
   already proven (`workspace_apply_test`: both-pane replacement,
   saved active tab, per-tab lenses; `workspace_library_test`:
   full-restart persistence; `workspace_commands_test`: menu open +
   Undo). The gap was the §4 preferred-pane rule: only
   remotePath→active-pane was exercised. New
   `workspace_panes_test.dart` cases pin `preferredPane` winning
   over the active pane for remote AND local favorites, and the
   other-pane verb resolving against the preferred side.
3. **Device-local fields proven non-syncing — MET**, and the
   purity suite now covers the M5 workspace keys at every depth:
   `left`/`right` were already in the synced-key allowlist, and a
   new test walks every nested map (`left`, `right`, `server`,
   `sync`) asserting no device-local key appears at any depth,
   plus a shape pin that a workspace location is `{server?,
   path}` (`path` required, `server` the optional remote
   endpoint).
4. **Sidebar fully keyboard-operable + D20 semantics on every row
   kind — MET after one real fix.** Arrow traversal, Enter/Space
   activation, and Shift+F10 context-menu coverage is new (drag
   reorder/group were already covered). The D20 audit found a
   defect the pointer-only tests missed: a favorite row announced
   `button: true` even with no open seam — the same dead
   affordance the connection row's `button:` gate exists to
   prevent. Red-first test, then the one-line gate fix in
   `sidebar_view.dart`; the all-kinds semantics test now asserts
   the announced label + button flag per row kind plus
   header/button/expanded state on both section-header kinds.

Risk check (no schema drift, no silent fork): PORTS.md's M5 entry
is accurate — the `Bookmark` model is consumed through the
`2e6d1f1` pin with PR-S1 in its ancestry, so 04 §2.1's
temporary-copy clause stays retired and nothing in
`src/bookmarks/` copies Séance source (`sortKeyBetween` and
`groupBookmarks` are fresh code over the upstream struct).

The #162 review's AltGr+S collision is recorded, not resolved:
Windows reports AltGr as Ctrl+Alt, so the entire Ctrl+Alt+letter
column of 02 §8.3's table (S/A/P/B/N/E/Y and pane-focus arrows)
fires on AltGr letters on e.g. Polish and Turkish layouts. The
needed decision — re-letter §8.3's Windows/Linux column versus
suppressing app-scope activators while a text field holds focus —
is a spec call, recorded as open item 24.

§3.12 chores at this close: STATUS swept (header, this section,
item 24); PORTS.md needed no update (the M5 entry already records
the no-copy posture; re-verified against the pin this audit); the
pin cannot bump (no Séance tag contains `2e6d1f1` — open item 2;
the S1 release M6 needs is also that tag); no `TODO(pin)` markers
exist; the §5 M5 mobile invariant **re-verifies clean** — the
synced `Bookmark` model carries no device-local fields at all, so
per-device grants (scoped-access blobs, future SAF tree URIs) have
nowhere to hide: they live in the separate device-local stores
(collapse state, workspace detail document, probe facts) the
purity suite fences off. The `v0.5.0` tag chore is **not run
here**, matching M3/M4's untagged closes — a tag push publishes
release assets, left to the supervisor/owner.

## M6 — sync record store + BookmarkCoordinator (2026-09-19)

The engine-side M6 foundation per 04 §3.1–3.2, all in
`poltergeist_core` — no transport, no enrollment, no UI:

- **`PersistentLocalRecordStore`** (`src/sync/`) is the real
  `LocalRecordStore` Séance's app lacks: one versioned JSON document
  (`version`, `highWaterSeq`, `lastAppliedSeq`, per-record `dirty`
  flags, and a `displaced` stash) rewritten atomically through the
  house temp+rename writer after every mutation. Dirty tracking is
  per-record (only actual edits push), pulls are deltas off
  `highWaterSeq`, tombstones are retained indefinitely (no GC — a
  long-offline device must never resurrect a deletion), and a corrupt
  file quarantines under a unique existence-checked
  `corrupt-<stamp>-<n>` name before restarting empty (`quarantinedPath`
  is the durable-notice seam). A newer `version` fails closed in place.
- **`SyncRecordStore`** extends the pinned interface with the §3.2
  bookkeeping: the `lastAppliedSeq` apply cursor (persisted like
  `highWaterSeq`, reset with it by `resetSyncCursors` for the one-time
  full-resync fallback), and the displaced-winner resurface — a pulled
  record that loses to a dirty local (or a clean winner a local edit
  evicts) is parked, and `restoreDisplaced` puts it back when the
  rival's push is rejected, since the server still holds that copy.
- **`BookmarkCoordinator`** (`src/bookmarks/`) is change-driven out
  (`onBookmarkSaved`/`onBookmarkDeleted` seal just the edited row —
  deletes mint real empty-blob tombstones) and delta-scanned in
  (`applyPulled` dispatches `seq > lastAppliedSeq` in order, advancing
  the cursor only past applied-or-terminally-skipped records, never a
  deferred one). Dispatch switches on the id prefix **before**
  decrypting: `secret:`/`snippet:`/unknown `<prefix>:` ids — and
  prefixless ids in separate mode — are skip-preserved unopened. The
  decrypted kind is the second gate: prefix/kind mismatch or strict
  `Bookmark.fromJson` failure trips the durable §4.2 tripwire
  (decrypt failure alone does not — wrong-key is a different signal).
  Pulled records apply under the materialized-tuple guard: a record
  losing to a pending local edit or tombstone tuple defers for the
  rival's push resolution instead of resurrecting/clobbering.
- **`hostkey:` handling** per §3.2: pins flow in unless they conflict
  with the local TOFU store — conflicts are quarantined behind the
  re-derived `pinConflicts` diff, negative pins (forget-host) hold the
  pulled record unapplied, kept-local verdicts suppress repeat warnings
  for the same rejected fingerprint only, `hostkey:` tombstones never
  delete a local pin, and `onHostKeyPinned`/`onHostKeyForgotten`/
  `keepLocalPin`/`acceptPulledPin` implement the resolution verbs.
- **`SeanceServerCatalog`** (shared mode only) materializes pulled
  prefixless `serverConfig` records, rebuilt from the record store each
  apply pass — tombstones remove entries.
- **`FileBookmarkStore`** now implements `SyncTrackingBookmarkStore`:
  per-row `(updatedAt, deviceId, deleted)` tuples persist in the same
  atomic document under `syncTuples` (absent entirely while sync is
  unconfigured, so the M5-pinned document shape is unchanged for
  non-sync installs). `reSealAfterStoreLoss` re-seals every row —
  including tombstone tuples, which makes pending deletions recoverable
  too — under each row's *persisted* winning tuple rather than this
  install's id.
- Transport is the later slice: `SyncApi` stays the seam, faked in
  tests; `SyncCursorRejectedException` is the cursor-rejection signal
  that drives the resync fallback.

Coverage (`test/sync/`, 46 tests): two-device create/edit/delete
convergence, delete-loses-to-newer-edit resurrection per the spec rule,
tombstone-stays-won across rounds, `flurb`-kind byte-identical
survival, malformed-bookmark skip without aborting the round,
relabeled-secret refusal, undecryptable preservation, tombstone-tuple
deferral, rejected-push resurface, LWW tie idempotence, delta cursors,
cursor-rejection resync, the hostkey matrix, shared-mode catalog,
corruption re-seal, rejected-push round termination, and
queued-write displaced restore — plus the store-level
persistence/LWW/quarantine matrix (including missing-version and
non-int-watermark quarantine). `dart analyze` and the full `dart test
packages/poltergeist_core` suite (1285 tests) are green.

## M6 — Design B enrollment (2026-09-19)

The enrollment slice per 04 §4.1/§4.5, in `poltergeist_core` plus the app
keystore seam — no settings UI (next slice), no Design A, no Séance
changes, no pin bump:

- **`SyncEnrollmentApi`** extends the `SyncApi` seam with
  register/prelogin/login plus the session `token` getter — the account
  endpoints Séance's `HttpSyncClient` already satisfies; tests fake it
  (`FakeEnrollmentApi` models register→prelogin→login, LWW push with seq
  minting, a `registration_closed` 403, a KDF-downgrade override, and a
  pull-error injector).
- **`SyncEnrollment.registerSeparate`** (Design B): random 16-byte salt,
  `Argon2Params()` defaults, Séance's `_deriveSyncKeys` split (password →
  auth verifier, encryption passphrase → vault key, one Argon2 pass when
  the two strings match), `POST /v1/register`, then persist — a fresh
  registration never sets `passphraseUnverified`. A 403
  `registration_closed` throws `RegistrationClosedException` carrying
  the §4.3 copy verbatim.
- **`SyncEnrollment.login`** mirrors Séance's `loginSync` with §4.5's
  divergences: prelogin → `meetsMinimum(Argon2Params.minimum)` refusal
  (`KdfDowngradeException` — no derive, no login, no token) → derive →
  login → a **full** pull (`since = 0`, always — a retained high-water
  mark must never skip the check) → trial-decrypt the first
  non-tombstone record on a decryptable id (prefixless, `bookmark:`,
  `hostkey:` — never `secret:`/`snippet:`/unrecognized;
  `isDecryptableSyncId` binds §3.2's dispatch to enrollment too). A
  failed trial does **not** abort (unlike Séance): the three-cause
  warning copy is returned, `passphraseUnverified` is set, and
  enrollment completes held. No decryptable candidate → flag set, no
  warning. The pulled ciphertext merges into the §3.1 record store
  before the keystore writes.
- **Push hold + the deferred foreign-record check** in
  `BookmarkCoordinator.runRound`: while `passphraseUnverified` stands,
  no push leaves the device; decrypt failures defer (not skip) so the
  apply cursor never passes a record the corrected passphrase must
  re-try; and the round ends with the deferred check — only a
  non-tombstone `deviceId != ours` record on a decryptable id can clear
  the flag (self-authored output cannot vacuously clear it), every
  foreign candidate is tried, and an all-failed pass raises the durable
  `passphraseCheckFailed` notice with pushes still held.
  `reSealPendingWrites` re-seals every dirty record under the verified
  key (the envelope tuple preserved verbatim, plaintext re-sourced from
  the materialized stores) before held pushes release.
- **401 `unauthorized`** on pull or push ends the round local-only and
  raises the durable `accountAuthFailed` notice (04 §7.3's dead-account
  posture); a good pull clears it. There is no token refresh —
  server-side tokens never expire.
- **Credential seams**: `SyncCredentialStore` (keystore: `writeToken`/
  `readToken`/`deleteToken`/`writeVaultKey`) and `SyncEnrollmentState`
  (durable settings: device id, hold flag, notice set, account facts —
  never the §3.1 record store, whose corruption quarantine restarts
  empty and must not erase the hold). App side:
  `SecureSyncCredentialStore` over `MasterKeyManager` (new
  `putApiKey`/`getApiKey`/`deleteApiKey` under `poltergeist.apikey.*`;
  the token entry is `poltergeist.apikey.sync.token`, the vault key
  stays `poltergeist.vault.masterKey.v1`) and
  `SettingsSyncEnrollmentState` over `SettingsStore` (settings.json).
- **§5.6 PR-S1 shim: not needed.** Its trigger is a pin that cannot
  include PR-S1 in time for Design-B work; the pinned rev `2e6d1f1`
  already carries `RecordKind.bookmark` (Séance #58 merged upstream
  before the pin), so records seal through the real `RecordCodec` and
  no shim-written records exist to migrate.

Coverage (`test/sync/enrollment_test.dart`, 14 tests, plus 6 app tests):
register round-trip, 403 copy verbatim with nothing persisted, login
round-trip with the `since = 0` pull asserted, empty-account flag,
KDF-downgrade refusal (no derive/login/token), trial-decrypt failure →
three-cause warning + hold + preserved record, never-decrypt prefix
exclusion, wrong-passphrase push hold, self-record non-clearing,
foreign `hostkey:` record clear + release, failing-foreign durable
notice, corrected-passphrase re-apply with the re-sealed push
decryptable under the real key, 401 local-only + notice + recovery, and
the token-not-on-disk sweep. App tests cover the keystore round-trip
under the exact §4.5 key name, locked-keystore loud-write/tolerant-read
behavior, device-id durability across instances, notice/account
round-trips, and a token-free settings file.

## M6 — Settings → Backup UI + B→A switch (2026-09-20)

The 04 §4.3 settings surface, the §4.4 separate-to-shared switch flow,
and the gated Design A rendering. App-side except for two core seams;
no Séance change, no pin bump:

- **`BookmarkBackupService`** (`lib/services/`) owns the orchestration
  over the durable seams: loads enrollment facts, last-sync status,
  notices, and retained-account state at startup; binds a
  `BookmarkCoordinator` to the live record store and vault key; and
  exposes register, login, `backUpNow`, `signOut`,
  `deleteSeparateAccount` (typed name confirmation; refused in shared
  mode), and the §4.4 `switchToShared` driver — retain the separate
  token under `poltergeist.apikey.sync.token.retained.v1`, wipe and
  recreate the local record store, log into the shared account, pull
  before any push, mark local bookmarks dirty under their existing
  ids, re-seal non-held pins, then hold on per-host conflicts for
  explicit adopt-fleet or keep-local decisions. A login that fails
  before any account write restores the pre-wipe store and the
  separate token, so the old account keeps working; retained facts
  persist for the optional post-switch deletion offer.
- **The Design A gate** (`sync_account_gate.dart`) is injectable;
  production records `kMinimumSharedAccountSeanceVersion = 'v0.9.0'`
  (the published release carrying PR-S1) and
  `kMinSharedVersionIncludesSeance56Fix = false` (Séance #56 stays
  open), so Design A renders with the pin-conflict security
  disclosure and Continue stays gated on the fleet-version checkbox;
  a null tag disables the shared option outright.
- **The ported validator** (`sync_enrollment_validation.dart`) keeps
  Séance's rules byte-identical while reporting a typed
  `SyncEnrollmentIssue` the render site maps to ARB copy (D20).
- **UI** (`lib/ui/settings/`): the section renders the §4.3 verbatim
  copy (title, intro, both option cards with Design B preselected,
  the fleet checkbox, the #56 disclosure, the passphrase warning,
  registration-closed guidance), the register/login segmented
  control, live-region status and errors, the enrolled summary with
  Back up now / Sign out / Switch to shared account / Delete backup
  account (shared mode hides delete; separate mode requires typing
  the account name), durable notices, per-host pin conflicts with
  Keep local key / Use synced key and no bulk resolution, and the
  switch dialog driving §4.4's phases. A `backup.openSettings`
  command opens the surface.
- **Seams**: `SecureSyncCredentialStore` grows retained-token
  read/write/delete (keystore only); `FilePinVerdictStore` and
  `FileSyncTripwireStore` persist §3.2 verdicts in settings.json;
  `SyncTransportFactory` closes each `HttpSyncClient` it mints;
  `EngineSession.pinStore` is exposed for composition;
  `FileBookmarkStore.syncDeviceId` widens to `String? Function()` so
  a non-enrolled install emits no sync tuples; the core barrel now
  exports `HttpSyncClient` for the transport factory.

Coverage: `bookmark_backup_service_test.dart` (21 tests — enrollment,
KDF refusal, registration-closed, trial-decrypt hold, manual round,
dead-account notice, sign-out, typed delete, shared-mode refusal, the
full §4.4 ordering and retention, conflict adopt/keep, retained
delete/decline, failed-switch restoration) plus verdict-store and
validator files; `backup_settings_test.dart` (19 widget tests —
form/gate/copy, enrolled states, switch phases, conflict resolution)
with five `POLTERGEIST_CAPTURE` states under
`tasks/run3-task81-captures/` (not committed). App suite 1378 and
core 1303 green; analyze clean on both sides.

## M6 — exit-criteria audit and close (2026-09-20)

All five 07 §3.7 exit criteria audited against the post-#167 main
head `2aee7d3`; the per-criterion evidence record lives in
[tasks/m6-closure-record.md](../tasks/m6-closure-record.md).
Verdicts:

1. **Two-device convergence against `seance_sync_server` in Docker —
   MET**, launch form recorded. Docker is absent on the audit host;
   the committed
   `test/integration/sync_server_convergence_test.dart`
   (`@Tags(['integration'])`, `POLTERGEIST_SYNC_SERVER`-gated) ran
   locally against the pinned server compiled natively from the
   `2e6d1f1` checkout — real `HttpSyncClient`, real register/login
   enrollments, create/edit/delete convergence, a server-verified
   tombstone that stays won against a stale push. The criterion's
   named Docker form runs in the new `sync_integration` CI job
   (builds the same pinned checkout via its Dockerfile, exports the
   variable, runs the tagged suite) — evidence attaches to the audit
   PR's CI run.
2. **flurb survives / malformed skips — MET on the real round
   path.** The fake-side proofs stay cited; the new suite re-proves
   both over real HTTP: byte-identical blob AND unchanged server seq
   across rounds for `flurb:x1`, tripwire-not-abort for
   `bookmark:bad` while `bookmark:good` applies.
3. **Enrollment security behaviors — MET on HEAD:** KDF-downgrade
   refusal, §4.5 trial-decrypt + foreign-record + push hold (14
   enrollment tests), token-in-keystore confinement, §4.4 switch
   ordering/retention/restore, gate-disabled-without-tag and
   Continue-gated-on-fleet-checkbox widget proofs.
4. **Design A against a patched Séance — PARTIAL (open item 25).**
   Correcting the brief's premise: PR-S1 IS released — v0.9.0/v0.9.1
   both contain merge `599ff936` (ancestry-verified), so the gate
   correctly *offers* the shared option behind the fleet checkbox
   (verified: null-tag disables outright; recorded tag gates
   Continue; the #56 disclosure renders while
   `kMinSharedVersionIncludesSeance56Fix` is false). Against a
   patched Séance, the new suite drives the pinned
   `seance_core` `SyncCoordinator` itself to the real server:
   shared-mode login trial-decrypts Séance's own record, the catalog
   materializes (`fleet-web`), the pin lands, and `TofuVerifier`
   returns `trusted` — connect with no first-use prompt; Séance's
   `excludeFromSync` tombstone empties the catalog. Residuals
   recorded honestly: no "Your Séance servers" picker/sidebar
   section exists on HEAD, and no running-Séance-app + real-SSH leg
   ran.
5. **§4.3 strings verbatim + 403 copy — MET.** `app_en.arb` carries
   every §4.3 string verbatim (diffed against the chapter during the
   audit); `RegistrationClosedException` carries the copy and the
   enrollment test asserts nothing persisted on a 403.

The 04 §5.6 shim question re-checked on the final state: **not
needed** — the `2e6d1f1` pin contains PR-S1 (ancestry-verified;
`RecordKind.bookmark`/`unknown` in the pinned record.dart), records
seal through the real `RecordCodec`, no shim was ever written and
none exists to delete or migrate.

§3.12 chores at this close: STATUS swept (header, this section, item
25); PORTS.md needed no update for app-facing ports (the M6
validator entry is accurate; the only new binding is the CI-only
loopback 127.0.0.1:8799 published by the `sync_integration` job);
the pin CAN now bump — `v0.9.1` contains
`2e6d1f1` — deferred per the audit task's non-goals into item 25; no
`TODO(pin)` markers; the §5 M6 mobile invariant **re-verifies clean**
— sync enrollment and the record store are pure core Dart with no
pane, watcher, or window coupling, durable state in file stores +
settings, credentials only in the keystore seam; earlier rows hold.
The `v0.6.0` tag chore is **not run here**, matching the prior
untagged closes — a tag push publishes release assets, left to the
supervisor/owner.

## M7 — managed-checkout foundation (CheckoutManager + store + queue hop) (2026-09-20)

06 §3's managed-checkout pipeline lands in `poltergeist_core`
(`src/checkout/`), ported from Séance's `remote_files_controller` /
`managed_remote_file` / `managed_remote_file_store` at pin `2e6d1f1`
with the plan's hardening (PORTS.md records every divergence):

- **Durable store** (`ManagedRemoteFileStore`): the
  `<app-support>/managed_remote_files.json` index plus
  `checkouts/<sha256(record id)>/` dirs — atomic index writes, a
  cross-process `fcntl` lock plus a same-process held-paths guard,
  generation epoch markers, the `.poltergeist-abandoned` in-flight
  sweep (a payload-bearing unindexed dir is preserved, never swept),
  recovered-payload listing with explicit-only deletion, symlink-safe
  create/delete, frozen `.poltergeist-<uuid>.upload` snapshots, and
  streamed SHA-256. The pinned sanitizer divergences are in: device
  names keep their extension under a `file-` prefix (full 09 §3.5
  reserved list on the stem), overlong names truncate to 255 UTF-8
  bytes, and the index/temp/quarantine/snapshot all carry owner-only
  modes on Linux/macOS via the new shared
  `restrictLocalPathPermissions` in `local_fs_safety.dart`.
- **Queue hop** (`TransferQueue.enqueueManagedCheckout` +
  `ManagedCheckoutSpec`): one journaled, panel-visible, cancellable
  file task per checkout/save — §4.7's priority shape (outside the
  in-flight cap and queue pause; per-task pause/cancel still hold).
  Uploads carry the record snapshot as `expectedTarget` with
  `computeHash` on, so the destination adapter's mandatory SHA-256
  CAS is the conflict authority (D7). A latent `_pipe` hang is fixed
  alongside: `StreamController.close()` never resolves on a
  never-listened stream, so an upload that dies before subscribing
  wedged the pipe — the pipe now treats the destination's own
  completion as the drain proof.
- **`CheckoutManager`**: checkout acquisition through the queue with
  byte-limit and free-space preflights; `editSessionId = serverId`
  (D17 — per-server identity survives pane/tab churn); parent-dir
  watch + 600 ms debounce filtering only the exact generated temp
  shapes (a checkout legitimately named `.poltergeist-<hex>.upload`
  keeps dirty detection); reconcile-on-resume and post-launch
  recovery; `uploadLocalCopy` serialized per record with the frozen
  snapshot, preflight stat, CAS, and the post-commit re-stat that
  degrades to a synthesized snapshot + `needsReconcile` instead of
  failing the committed save; prefix-wise `migrateRename` with
  occupant displacement; discard/acceptLocalCopy/forgetRecovered.
  Nothing ever auto-uploads and no remote change is silently
  overwritten — conflicts throw the typed `conflict` error for the
  caller's escalation flow.
- **App seam** (`services/checkout_session.dart`): the app-wide
  `ChangeNotifier` session the future editor UI consumes — composed
  in `main.dart` over the queue session's concrete queue and shared
  connection seam, forwarded through `PoltergeistApp` →
  `WorkspaceShell`, and reconciled on `AppLifecycleState.resumed`.
  Remote verbs ride the same honest-`unsupported` seam as the queue
  (item 23 stays open for the engine-hosted slice).

Coverage: 44 `checkout_manager_test` + 17 store tests (round-trip,
per-server identity, debounce + temp-shape filter, resume/relaunch,
remote-change/deletion/tamper conflict blocks, explicit overwrite,
rename migration, queue visibility both directions) and 5
`checkout_session_test` composition tests (boot, panel-visible honest
failure, relaunch persistence + resume reconcile, discard, refused
upload). Core: 1347 passed / 21 skipped, analyze clean.

Editor UI, external editors, Quick Look, and the §3.7 review surface
remain future M7 slices; this lands the pipeline they all build on.

## M7 — built-in editor (document I/O + syntax + checkout wiring) (2026-09-20)

06's Séance-compatible editor lands as the second M7 slice, split
across the §2.1/§2.3 seam (PORTS.md records every divergence):

- **Document model** (`poltergeist_core/src/editor/`): BOM and
  per-line-ending state are load-time facts reconstructed exactly on
  save — BOM-present, BOM-less, CRLF, and mixed-EOL files round-trip
  byte-identical. The atomic save writes a 0600
  `.poltergeist-<uuid>.tmp` sibling before rename, the size cap refuses
  oversized reads, and the `expectedSha256` guard is the
  modified-on-disk conflict the UI surfaces (never bypasses).
- **Syntax + find** (`ui/editor_syntax.dart` + the screen): the ported
  tokenizer/engine covers 06 §7's language set incl. the data-only
  additions; the find bar counts, navigates, wraps, and toggles case
  per 06 §2.2.
- **Checkout wiring** (06 §4.2): `file.editBuiltIn` registers per D21
  (selection scope, ⌥⌘E / Ctrl+Alt+E, File menu order 63), opens a
  remote row through the managed checkout download, and pushes the
  editor route with the checkout session's `reconcile`/`uploadLocalCopy`
  verbs. Save-and-upload rides the composed queue — the upload row is
  panel-visible — and a remote that moved under the open checkout
  surfaces the §3.4 overwrite dialog; cancel keeps the local save and
  writes nothing.
- **Captures**: `tasks/run3-task84/` (find bar mid-search, the
  conflict-blocked save dialog) under `POLTERGEIST_CAPTURE=1`.

Coverage: 28 core document tests, 16 editor widget tests, the syntax
suite, the `file.editBuiltIn` command test, 3 shell-level
editor-over-checkout integration tests, and the 2 capture tests.
External editors, Quick Look, sync, and the §3.7 review surface remain
open M7 slices.

## M7 — external editors (registry + Open With + upload-on-save) (2026-09-20)

06 §4/§3.3's external-editor slice lands, ported from Séance's
`external_file_opener.dart` and `external_editor_test.dart` at
`bb3fa4b` (in the live pin's ancestry; PORTS.md records every
divergence):

- **Registry + opener** (`services/external_file_opener.dart`):
  `EditorRegistry` carries the `poltergeist.system`/`poltergeist.builtin`
  selectors (the whole `poltergeist.` prefix is reserved — a synced
  definition can never shadow them), per-extension bindings via
  `extensionDefaults`, `effectiveDefaultFor` resolution (extension
  first, then global), orphan-binding cleanup on remove, and
  compatible-editor filtering. `ExternalFileOpener` launches bundle ids
  through the ported `poltergeist/files` macOS channel, detaches
  executables on Linux/Windows, opens the system default through the
  core `LocalFileOpener` (no `open_file` plugin), and picks
  applications through the channel or `file_picker`.
- **Persistence** (`services/editor_registry_controller.dart`):
  `editorRegistry` in the shared `SettingsStore` — mutations persist
  first, restore the pre-mutation registry and report the error on a
  failed write, and only then notify.
- **Open With** (`ui/panes/open_with_commands.dart`, D21's
  `open-with-external` at File-menu order 62): built-in / compatible
  configured editors / system default / Other… / Configure Editors…
  as a `SubmenuButton` and as the chooser dialog. `Other…` picks,
  registers, offers §4.1's remember-choice per-extension binding, then
  opens — cancel aborts without launching. Configure Editors… opens
  the §8 bounded settings mount (default-editor dropdown plus the
  registry list with edit/remove/add) until the full Settings screen
  lands.
- **Dispatch + upload-on-save**: remote Open routes through the
  effective default — an explicit external choice runs the managed
  checkout without the built-in cap, an explicit built-in choice
  refuses over-cap with the reason plus an Open With action, and the
  unconfigured path keeps its system-default fallback. The §3.3 loop
  watches the managed copy (600 ms debounce + SHA-256 reconcile), posts
  the once-per-dirty-edge `"name" changed locally. Upload it?` toast,
  and uploads through the composed queue — a typed `conflict` opens
  the §3.4 overwrite dialog; cancel writes nothing. The prompt's
  post-frame re-check schedules its own frame so an idle window can't
  starve it.
- **Captures**: `tasks/run3-task85/` (Open With submenu, chooser,
  remember prompt, editor settings, dirty-upload toast) under
  `POLTERGEIST_CAPTURE=1`.

Coverage: the `external_editor_test` registry/persistence port plus 15
shell-level integration tests in `external_editor_checkout_test.dart`
(default resolution both directions, uncapped external open, built-in
refusal with the Open With action, unknown-size fallback, local
launch, dirty→upload, conflict cancel/overwrite, atomic-replace
detection, menu rows, remember/cancel) and the capture test.

Quick Look, sync, and the §3.7 review surface remain open M7 slices.

## M7 — preview and Quick Look (cache + produce + panel) (2026-09-21)

06 §5 lands end to end — Space previews local files directly and
remote files through the new preview cache, on macOS via the native
Quick Look panel and everywhere via the docked in-app panel:

- **Core** (`packages/poltergeist_core/lib/src/preview/`): the §5.2
  kind classifier (extension table + UTF-8 sniff for unknown text,
  case-insensitive names, per-kind size caps), `PreviewCache` under
  `<app-support>/preview-cache/` (hash-keyed entries, unsafe extensions
  dropped so sniffing decides, executable extensions kept — the
  blocklist guards OS launches, not cache writes; prepare/commit with
  temp-file sweep and `canAccommodate` refusal, LRU-ish eviction,
  `sweepTemps`/`clear`), and the produce seam — `PreviewProduceSpec`,
  `PreviewByteGate` (the unknown-size mid-stream threshold park with
  confirm/cancel and resume), `TransferQueue.enqueueProduce` (head
  insertion, pause/cap/throttle bypass, two-task in-flight cap, never
  journaled per 03 §4.6 — the Future dies with the process), and
  `QueuePreviewProducer` bridging the session to the queue.
- **Session** (`services/preview_session.dart`): the §5.2/§5.3 state
  machine — selection shows the metadata card or a prompt; Space
  downloads via produce; known over-threshold sizes confirm first;
  unknown sizes park at the byte gate; Esc cancels production
  (including inside the cache-prepare window, before the task
  registers), closes cards, then the panel; refusal cards keep the
  Open/Open With affordances. Quick Look routing follows §5.1: Space
  opens the native panel on macOS when the docked panel is hidden, the
  produced cache path delivers via `showPreview`/`updatePreview` even
  when the panel hasn't opened yet, and the in-window overlay card
  hosts the confirm/gate/progress states Quick Look cannot render.
- **Panel** (`ui/preview_panel.dart`): the docked 320px panel per
  02 §1 — metadata rows, prompt/progress/confirm/gate/refused cards,
  rendered text on the §2.1 document+syntax layer (first-1 MiB partial
  read truncating on a codepoint boundary), image rows with dimension
  captions, and the PDF row through the `PreviewPdfBuilder` seam
  (`ui/pdf_preview.dart` binds it to `pdfrx` — new dependency).
- **Quick Look channel** (`services/quick_look_channel.dart` +
  `macos/Runner/MainFlutterWindow.swift`): `poltergeist/quicklook`
  carries `showPreview`/`updatePreview`/`hidePreview`/`isAvailable`/
  `isVisible` to `QLPreviewPanel` — the same seam shape as
  `poltergeist/files`.
- **Settings** (`ui/settings/preview_settings.dart` +
  `services/app_preferences.dart`): the §8 "Preview & downloads"
  rows — cache cap and the shared large-download threshold — persist
  through `preview.cacheCapacityBytes` /
  `preview.largeDownloadThresholdBytes`, mounted in the bounded
  Editing-settings dialog with the immediate-persist revert idiom;
  `Clear Preview Cache` toasts the reclaimed bytes.
- **Commands/keys** (D21): `file.preview` and `view.togglePreview`
  registered; Space hits the pane dispatch below the §-ordered Esc
  tiers, Option/Command+P on macOS and Control/Alt+P elsewhere toggle
  the docked panel.

Test findings folded back into the implementation: Quick Look's
first-press delivery gated on the panel's active flag so a produced
remote preview never reached the native panel (now keyed on the
request flag); the confirm/gate cards' action rows overflowed the
320px panel (now `Wrap`); the rendered path never loaded text content
(text-kind dispatch added); Esc during `cache.prepare` could not
cancel (pending-start tracking added). `Process.run`/`chmod` hangs
under the widget-test fake zone, so production-driving steps run in
`tester.runAsync` with real-delay waits, and the capture test loads
real faces in a runAsync that returns before any mount — paragraphs
laid out mid-registration stay tofu; `tasks/run3-task86/` holds the
ten PNGs (prompt, producing, rendered text/image/PDF, confirm, gate,
refusal, Quick Look overlay, settings dialog).

Coverage: 45 core preview tests (kinds, cache, gate, produce), 28
session tests, the panel/settings widget suites, and the capture test.
Sync and the §3.7 review surface remain open M7 slices; the §4.6
pool-level produce reservation is a recorded follow-up (PORTS.md).

## M7 — exit-criteria audit and close (2026-09-21)

All four 07 §3.8 exit criteria audited against the post-#172 main head
`31a15ab`; the per-criterion evidence record lives in
[tasks/m7-closure-record.md](../tasks/m7-closure-record.md). Verdicts:

1. **Edit round-trip conflict — MET on HEAD.** The core remote-change/
   deletion/tamper cases block with CAS intact; the built-in suite's
   `conflict dialog — cancel writes nothing` reseeds the remote under a
   live checkout and asserts the save is blocked, never a silent
   overwrite (the overwrite path retries with CAS waived).
2. **Kill with dirty checkouts; relaunch reconciles and offers resume
   per 06 — MET after the audit's gap fix.** The reconcile half
   (record reload + `reconcileAll` + watcher re-arm) was already
   proven; the §3.7 *offer* was absent — HEAD had only the transient
   dirty toast. The audit lands the missing surface: a persistent
   per-pane `LocalEditsBanner` (count of `dirty || missing` copies for
   the bound server), the server-scoped `LocalEditsReviewDialog`
   (records with Open / Upload — disabled offline — / confirmed
   Discard; displaced rows marked Recovered; preserved recordless
   payloads listed per-file with Open/Discard only, never
   uploadable), a remotePath favorite's `Local Edits…` context item,
   and the store's new per-row `deleteRecoveredFile` verb — driven by
   six widget tests over a real process-death relaunch.
3. **External editor save → upload with activity-panel progress —
   MET.** The watch → debounce → dirty → CAS-upload loop was already
   proven; the audit added the missing panel-side assertion (the
   completed managed-upload task lists inside the activity panel,
   progress rendered through `_TaskProgress`).
4. **Spacebar preview local + remote (preview cache), preview pane
   text/images/PDF — MET with the native boundary recorded.** The
   channel contract and dispatch decisions are CI-proven (28 session
   tests; the panel/widget/capture suites); the real
   `QLPreviewPanel` runtime needs a macOS host — open item 26.

The §3.7 risk re-checked: parent-directory watching catches
atomic-replace saves — proven by the external suite's
write-temp/rename-over case against the real watcher.

§3.12 chores at this close: STATUS swept (header, this section, item
26); PORTS.md updated for the two new recovered-payload verbs; pin
unchanged (the `v0.9.1` bump stays in item 25); no `TODO(pin)`
markers; the §5 mobile invariant re-verifies (checkout store/manager
and preview cache stay pure core Dart; the Quick Look channel is an
app-side platform seam). The tag chore is **not run**, matching the
prior untagged closes.

## M8 — Séance v0.9.1 tag re-pin + `poltergeist_sync` scanner core (2026-09-21)

The first M8 slice satisfies the §3.9 S3 gate in its steady-state form
and lands the engine's scan/comparison foundation.

**Pin re-pin (open items 2 and 25).** `2e6d1f1` → tag `v0.9.1`
(`035b0d880b47639e390af8cbbd6d316cb5edc86d`). The tag contains the
pinned rev, which itself descends from the PR-S3 merge
`2f99f4efb25a83340605464635bdf0f3ba95d931` — so `setTimes`, `setOwner`,
and opt-out `computeHash` are all in the pin's ancestry, and the rev-pin
bridge retires per D2. `packages/poltergeist_core/pubspec.yaml` and the
bench declaration carry `ref: v0.9.1`; `pubspec.lock`,
`packages/poltergeist_bench/pubspec.lock`, `tool/bench/pubspec.lock`,
and `app/poltergeist_app/pubspec.lock` all resolve to `035b0d8`, and the
bench harness's `pinnedSeanceRevision` follows. The full
ancestor/tree/license/identity audit was regenerated into `docs/PORTS.md`
and `scripts/audit-seance-pin.sh` verifies clean
("Séance pin audit matches docs/PORTS.md").

**Pin fallout, fixed red-first at the tag:**

- `VaultStore.putSecretBlobs` (upstream's batched, all-or-none vault
  write) — `FileVaultStore` now loads once, encodes every blob, updates
  the in-memory map, and flushes once atomically
  (`app/poltergeist_app/lib/services/file_stores.dart`).
- `ServerIcon` widened to ~45 values upstream — the app switch was
  extended exhaustively with the upstream glyph mapping
  (`app/poltergeist_app/lib/ui/server_appearance.dart`).

`flutter analyze` clean and the full app suite green (+1546) at the
tag; `dart analyze`/`dart test` green for `poltergeist_core` (the
`linux_watch_backend` descriptor test flaked once and passed on
rerun — timing-sensitive FD accounting, not fallout).

**`packages/poltergeist_sync` (new workspace member, pure Dart).** The
05 §11 package boundary: `poltergeist_core` (the one VFS — D3) plus
`unorm_dart 0.3.2` for NFC matching; no Flutter, no dartssh2, no
`dart:io` `Process` — the package's own analyzer-walked invariants test
enforces the whole set (aliased imports included, 08 §3.3), alongside
the repo-wide `check-imports.sh` coverage every `packages/*` member
already gets. What landed:

- `plan.dart` — the §6 model verbatim: `SyncPair`/`SyncEndpoint`
  (Local + Remote over `BookmarkServerRef`), `SyncRuleSet` with the
  spec'd defaults (Update = one-way/no-deletes, Mirror = one-way +
  `DeletionPolicy`, additive two-way = bidirectional/never-deletes),
  `EntrySnapshot`, `SyncItem`, `ScanWarning`, `SyncPlan`/`PlanTotals`,
  `SyncRunRecord`.
- `ignore.dart` — gitignore-style `SyncIgnoreRules` with the §3 fixed
  ordering (pair globs → `.*` when `includeHidden:false` → app
  defaults, so no `!` can re-include `.poltergeist*`, `.DS_Store`,
  `Thumbs.db`, `desktop.ini`, `*.poltergeist-*`), full `*`/`?`/`**`
  semantics, anchored vs floating patterns, dir-only rules, `!`
  re-include, and the always-excluded effective trash root.
- `scan.dart` — `TreeScanner` over `RemoteFileSystem` (D3 — no second
  VFS): pipelined `listDirectory` at the M0-tuned depth of 8
  outstanding calls, `/`-separated flat map, symlinks recorded as
  `kind: symlink` and never followed (cycles terminate), unlistable
  subtrees warn-and-exclude while an unlistable root aborts ("errors
  are exclusions, never emptiness"), out-of-range mtimes keep their
  originals and warn, cooperative `ScanCancellation`, progress
  callbacks, the before-walk case-sensitivity write probe
  (override > probe > assumption, `CaseSensitivityBasis` recorded),
  and the effective trash root always excluded — including a hard
  refusal when trash == root, which would otherwise scan empty and
  invite Mirror to delete the other side.
- `compare.dart` — `EntryComparator` for `sizeAndMtime`/`sizeOnly`/
  `contentHash` with the frozen boundary (truncated Δmtime of exactly
  2 s equal, 3 s different), `acceptedTimeShifts` (DST ±N within
  tolerance), §4's clamped comparison whenever either original mtime
  lies outside the SFTP v3 uint32 range, `streamedSha256` through
  `RemoteFileSystem.download` for the hash mode, `nfcKey`/`foldedKey`
  matching, and the §3 first-class hazards (`NormalizationCollision`,
  `CaseCollision`, `InvalidNameOnDestination` via `validateLocalName`).

63 tests cover tree-walk parity, symlink recording/never-follow/cycle,
permission-error exclusion and root abort, glob semantics including
`!` and app-default immunity, the mtime tolerance and clamping
boundaries, size-only detection, streamed hashing, NFC/case/invalid-name
hazards, cancellation, progress, and the case-probe paths (probed
sensitive, unwritable → assumed + warning, explicit override).

Not in this slice (per the task bound): `diff.dart`, `executor.dart`,
`journal.dart`, `rsync_export.dart`, engine-side two-side concurrency,
remote-pair scanning, `SyncPlan` preview UI, chown UI.

## M8 — SyncPlan execution engine + the 05 §5/§8 safety rails (2026-09-22)

The second M8 slice executes the plan the preview rendered — rail 1 in
code: `SyncExecutor.run(SyncPlan)` is the only execute path; nothing
re-scans or recomputes behavior.

- `executor.dart` — §6's three phases over two injected
  `RemoteFileSystem` roots (D3): makeDirs shallowest-first, copies/
  updates under `transferConcurrency` with rule-4 pre-delete items as
  drain-then-remove barriers, deletes deepest-first behind a clean
  copy phase (failures *and* conflicts gate it — gated items land as
  `skipped: earlier errors`). Rail 7 re-stats every destination
  (kind → size → tolerant mtime, size-only when §4 flags distrust
  clocks) plus the destination parent chain for since-scan links;
  mismatches flip `conflicted`, a vanished source fails just that
  item. Replaced directories verify the scan-captured recursive entry
  set (`SyncItem.destinationSubtree`) before the pre-delete removes it
  wholesale. Copies stream through a bounded chunk pipe (no whole-file
  buffering); updates under `backups: none` use the adapter's
  `expectedTarget` compare-and-swap, and every absent-target write is
  `overwrite: false`. `setTimes` stamps atime+mtime then re-stats —
  divergence beyond tolerance, or a refusing setTimes, journals
  `setstatIgnored` and raises that side's `mtimeUnreliable` flag for
  §9's sizeOnly fallback. Deletes and overwrite backups route through
  `RemoteTrash` with D15 flat `<seq>-<basename>` names inside
  `.poltergeist-trash/<runId>` (per-side `trashPath*` out-of-root
  honored), and rail 5's copy-then-delete fallback on EXDEV-classified
  local renames or any non-collision remote rename failure — fallback
  copies journal their SHA-256 for restore verification.
- Rails 3–4 in `assessDeletions`: per-side non-directory removals
  (delete-phase items plus per-file pre-delete counts — never "one
  item = one deletion") against the side's scanned file count
  (`SyncPlan.leftFileCount`/`rightFileCount`, differ-supplied). The
  ≥ 90 % floor wins over the `deleteFractionWarn`-and-≥ 10 clause, and
  `maxDelete` refuses the whole run before any item executes — never a
  stripped partial run. A delete item inside a no-delete plan fails
  loudly rather than deleting.
- `journal.dart` — the §8 rail-9 JSONL run journal under
  `sync_runs/<runId>.jsonl`: `SyncRunRecord` header, per-item lines
  (action/side/outcome/attempt/bytes/duration/override/
  `trashLocation`/`trashBytes`/`trashContentSha256`/
  `observedMtimeAfterWrite`/`setstatIgnored`), per-file `trash` and
  `rmdir` lines for rule-4 pre-deletes, `remove` lines for permanent
  deletions, a summary carrying the §4 flags, and the `purged` marker
  that releases pruning. Appends flush per line — a torn tail is
  dropped on replay. `Retry Failed` re-runs only `failed` items at
  attempt n+1 under the same runId (a source whose stat no longer
  matches the snapshot flips conflicted — a retried item never pushes
  un-previewed content). `restoreTrashedFiles` reverses the recorded
  renames after a post-state check — absence for deletions, the
  written file's size+observed mtime for updates, the recorded
  end-of-run entry set for created directories — skips and reports any
  divergence, recreates emptied chains shallowest-first, and
  hash-verifies copy-fallback trash entries. Pruning keeps the newest
  20 per pair and never a journal guarding live trash.
- Core seam: `SyncItem.destinationSubtree` added for rule-4
  snapshots. Run ids reuse the `RemoteTrash` minter for their uuid
  half — no `uuidV4` barrel re-export (it would collide with the
  app's own `services/uuid.dart` under `ambiguous_import`).
  `journal.dart` is the package's one `dart:io` user — the invariants
  test's allowlist records exactly that.

36 new red-first tests cover the three modes, both rail-3 clauses plus
near-misses, `maxDelete` refusal, rail-7 conflict flips (dest changed,
copy-new target appeared, subtree changed), vanished-source failure,
the copy-phase delete barrier, mtime preservation + setstat-ignored
flagging, EXDEV trash fallback with digest, D15 naming/runId shape,
out-of-root trash, dir→file replace journaling and full revert,
retry-attempt tracking, journal replay/torn-tail/purged/prune, and the
restore post-state skips. 107 tests pass in the package; core analyze
clean and 1440 tests pass.

Not in this slice: `diff.dart` (plan production), `rsync_export.dart`,
the §7 preview UI, §9 `sync_state` persistence, purge UI,
remote-pair integration tests.

## M8 — sync plan view + savedSync bookmarks + activity-panel runs (2026-09-22)

The third M8 slice mounts the §7 preview as a first-class pane tab and
drives it scan → diff → override → rails → executor. Rail 1 holds: the
reviewed plan is the only thing the executor ever runs.

- `diff.dart` (sync package) — `diffScans(left, right, pair)` turns two
  `ScanResult`s into the `SyncPlan` the view reviews: mode×direction
  action selection, §6 rule-4 `typeDiffers` pre-delete semantics,
  rule-8 subtree-exclusion mirroring, per-item hazard surfacing via
  compare.dart's collision/invalid-name helpers, `destinationSubtree`
  snapshots, mtime-degradation to size-only when §4 flags distrust.
- `pair_id.dart` — §9's canonical `pairId` (endpoint-derived, rule
  fields excluded) keys `sync_state` so a re-path or re-host re-keys
  rather than carrying stale trust flags.
- `saved_sync_codec.dart` — `SyncPair` ⇄ `BookmarkKind.savedSync`;
  endpoint and rule fields serialize under `bookmark.sync`.
- `sync_state.dart` — §9's per-pair state model + JSON codec
  (mtime-trust flags, case-probe cache, trash cache, last-run stamps).
  App-side `FileSyncStateStore` owns the dart:io — the package stays
  I/O-free per §11.
- Executor pause seam — `SyncRunPause` races `whenCancelled` at the
  three phase boundaries; no mid-item interruption.
- `SyncEnvironment` — the app-side composition root: journal dir,
  device-id for runId prefixes, endpoint → `RemoteFileSystem`
  resolution. Remote endpoints answer the honest `unsupported`
  refusal — the same posture as the transfer queue (open item 23).
- `SyncPlanController` — the view's state machine: scan/diff,
  effective-action overrides with the §7 validity table, bulk apply
  that reports `typeDiffers` skips, conflict resolution (newer-wins
  hidden on untrusted clocks), rail 3/4 assessment recomputed on every
  override, `run(deleteConfirmed:)`, retry-failed, restore-trashed,
  heavy-directory exclude suggestion, stored case-override rescans.
- `SyncQueueTasks` + `CompositeAppTransferQueue` — one sync run = one
  activity-panel task with per-item rows; pause/resume/cancel route to
  the run, retry routes to `retryFailed`, terminal rows are removable;
  sync runs journal under `sync_runs/`, never the transfer journal.
- `SyncPlanView` + `sync_plan_format.dart` — the §7 surface: mode
  picker (Update/Mirror/Additive → direction×deletion), the verbatim
  consequence sentence (Additive aggregates onto "both sides";
  trash/permanent delete clauses distinct; "Nothing will be deleted."
  only when true), warnings strip, conflict bar, filter chips +
  text filter + only-actions default, grouped rows with glyph+color
  (never color alone), tap-to-cycle and right-click override menus,
  rail 3's typed-DELETE dialog, rail 4's refusal banner, run controls,
  Copy Report.
- `SyncPairEditorDialog` — §9's pair editor (name, endpoints, paths,
  direction, deletions, backups, comparison, conflicts, excludes,
  trash paths, mtime tolerance, maxDelete, fraction warn, concurrency,
  per-side case overrides, include-hidden, preserve-mtime), shared by
  `sync.newSavedSync` and the plan view's Edit Rules.
- Wiring — `sync.synchronizePanes` (⌥⌘Y / Ctrl+Alt+Y) builds an ad-hoc
  pair from both panes' committed locations and disables when either
  side is unbound; `sync.newSavedSync` persists through
  `bookmarkFromSyncPair`, preserving group/sortKey/createdAt on edit;
  savedSync sidebar rows reopen the plan view and malformed payloads
  report instead of no-oping; `main.dart` composes `SyncEnvironment` +
  `SyncQueueTasks` and folds them into the transfer queue.

Tests: 29 differ tests (mode table, hazards, rules 4/8, mtime
degradation), pair-id + codec + state-store suites (163 sync-package
tests total), 17 controller tests (lifecycle, rails, retry, restore,
typed confirmation), facade/composite-queue tests, 11 copy-contract
format tests, command registration/enablement tests, and 7 widget
tests driving the real view — which surfaced and fixed two real bugs
(a `Spacer` inside `Wrap` in the action bar, and a
`TextEditingController` disposed before the delete dialog's exit
animation finished). Six POLTERGEIST_CAPTURE artifacts live under
`tasks/run3-task90/captures/` (grouped view, override menu, typed
dialog, maxDelete refusal, running, retry-failed).

Not in this slice (per the task bound): `rsync_export.dart`,
remote-pair integration, chown UI, purge UI, engine changes beyond
the small seams above.

## M8 — rsync exporter + Copy as rsync Command (2026-09-22)

The fourth M8 slice (PR #177) lands 05 §2.1's text-only exporter —
`buildRsyncCommand` renders the reviewed plan as a commented rsync
invocation the user pastes into a shell; it never executes anything
(the `Process` ban is machine-checked by the package invariants test).

- `rsync_export.dart` — the §2.1 flag table: `-n -i` dry-run first,
  `--size-only`/`--checksum`/`-t` per comparison mode, delete flags
  per direction×policy (never `--delete-excluded`; the app-default
  excludes land first so the in-root `.poltergeist-trash/` and
  destination-only ignored files are protected from `--delete`),
  `--backup --backup-dir` for trash policies, `# note:` caveat and
  override comments, and POSIX-sh quoting (`'` → `'\''`) covering
  spaces, quotes, `$`, glob metacharacters, and NFD names.
- `services/rsync_endpoints.dart` — endpoint → host:path spec
  resolution (embedded identities render `ssh -p`; a shared-mode
  `serverConfigId` with no catalog binding refuses rather than
  emitting a wrong host).
- `sync.copyRsyncCommand` — the action-bar verb: clipboard write,
  the differentiated toast (`Copied rsync command` vs the
  permanent-deletion paste-time warning), disabled while nothing
  exportable exists; `mtimeUnreliable` flags downgrade the emitted
  comparison to `--size-only` with a comment naming the reason.

Golden tests pin every §2.1 fixture row (flag table, quoting,
negation-then-match exclude order, the Windows-local pair's
adjust-note); controller tests cover the untrusted-clock downgrade;
widget tests cover the verb, toasts, and the unresolvable-remote
disabled state.

## M8 — exit-criteria audit and close (2026-09-22)

The §3.9 audit walked every 05 Definition-of-done item plus the three
§3.9 remote-gated criteria against post-#177 main (`187d5b7`); the
per-criterion evidence record is
[tasks/m8-closure-record.md](../tasks/m8-closure-record.md). Verdicts:

- **P7 (≥ 1 000 remote entries/s on LAN) — MET, enforced.** CI run
  `35718273275` at the audit head measured a 5-sample median of
  **2 336.627 entries/s** under `BENCH_ENFORCE_A` — an enforced pass
  over the Docker sshd fixture, not a drift skip. The 1 000 budget
  stands; no recalibration was needed (a recalibration would only
  raise the bar the run already doubles).
- **Setstat-ignoring leg + sizeOnly notice — MET after the audit's
  gap fix.** `sshd-restricted` (`sftp-server -P setstat,fsetstat`)
  was already in the Docker matrix and `run.sh` already exported it —
  but no sync test exercised it, and no UI test proved the §4 notice
  actually renders. This PR adds both:
  `packages/poltergeist_sync/test/integration/sync_sshd_test.dart`
  runs a real local→restricted pair end to end (scan → diff →
  execute → journal → re-diff), asserting `setstatIgnored` on the
  item line and in the replayed journal, `mtimeUnreliableRight` on
  the run, that the next diff still sees the divergence *without* the
  flag, and size-only convergence *with* it — plus an sshd-modern
  control proving the stamp lands and the re-diff converges on mtime
  alone. A new `sync_plan_view_test.dart` case drives a refused
  `setTimes` through the real controller and asserts the header's
  size-only notice appears after the run.
- **chown UI (D28) — DEFERRED to M9 (open item 30).** The merged pin
  (`v0.9.1`) does carry `setOwner`, so §3.9's conditional arm is
  active; the audit task explicitly prefers a dated deferral over
  new scope at close, and D28's own text allows M8/M9. No chown
  surface exists on HEAD — recorded dated with reason.
- **05 DoD — MET except the recorded residuals.** Every checklist row
  audits to a satisfying test/golden/UI except: the rail-5 purge
  surface (age-notice chip + `sync.purgeTrash` + its
  cross-pair/cross-machine rules — journal substrate `markPurged`/
  `hasUnpurgedTrash`/`prune` exists, the UI/command half does not;
  open item 27), the rail-5 docroot warning chip in the pair editor
  and plan view (item 28), and rail 6's run-startup temp-orphan sweep
  plus rail 8's committed-but-unjournaled resume post-state rule (no
  resume-from-journal entry point exists — connection loss fails the
  item and Retry Failed is the recovery path; item 29).
  Two mechanism deviations recorded in the record: §11's shared
  `poltergeist_core/lib/testing.dart` `InMemoryFileSystem` never
  landed (sync tests inject faults through `LocalFileSystem`
  subclasses over real temp dirs — the fault matrix is covered, the
  cross-package-shared fake is not), and the §3.3 invariants are
  pinned by deterministic tests rather than seeded generators.

Audit-scope additions: the two tests above, the STATUS sweep, and the
closure record — no feature work, no pin bump, no Séance edits.
§3.12 chores at this close: PORTS.md untouched (no ported file
changed), no `TODO(pin)` markers, the mobile invariant re-verifies
(the new legs are tests only; `poltergeist_sync` stays pure Dart),
and the tag chore is not run, matching every prior untagged close.
Docker is unavailable on this host — the new integration leg is
CI-verified, and its env-gated skip keeps local runs honest.

## M9 — polish pass part 1: Quick Open, import finish, a11y, i18n, chrome (2026-09-22)

The first M9 slice (02 §8.4, §13, §9–11; D20/D21/D22) — the flip plus an
audit, not a rescue. One app PR; no engine, core, or sync changes.

- **Quick Open palette (02 §8.4, D21).** `app.quickOpen` is a registered
  command (⇧⌘P on macOS, Ctrl+Shift+P elsewhere, File-menu placement)
  opening a centered 560-wide dialog over the live command registry —
  no parallel command list. Three ranked sections: commands, favorites,
  recent locations. Fuzzy match: commands by label + menu path,
  favorites by label + host + path, recents by path + host. Enabled
  commands rank before disabled; disabled rows render greyed with a
  localized reason; shortcuts sit right-aligned and menu paths show
  only on rows that carry a shortcut; favorites/recents get no shortcut
  gutter. Enter runs the normal action; Alt/Option+Enter opens a
  location row in the other pane; Ctrl/Cmd+Enter opens it in a new tab;
  command rows collapse every Enter variant to plain execution. Escape
  and the palette's own chord close it. While open, pane/selection
  chords are suspended, app-scoped chords still dispatch (disabled ones
  stay highlighted with their reason visible), and text-editing chords
  keep text-field behavior. A re-entrancy guard blocks a second open.
  Recents live in `RecentLocationsStore` — a device-local, capped
  (100), deduped, debounced list persisted inside the shared
  settings.json, stamped onto every tab controller and flushed at app
  exit; remote rows re-resolve the live bookmark by id, falling back to
  the record-time snapshot. Service tests pin the fuzzy ordering, the
  store's dedupe/cap/persist/flush contracts, and the shortcut
  formatter; widget tests pin open/navigate/accept, modifier-Enter
  variants, disabled reasons, chord scope, and the toggle.
- **Import experience (D22).** The `favorite.importSshConfig` command
  is the single entry point: File menu, the Quick Connect launcher's
  adoption offer, and the empty-favorites sidebar offer all run it
  through `_runCommand`, so enablement/session guards can't be bypassed
  and the offer can't be hit while a session modal owns the run. The
  empty state hides the offer once favorites exist. The preview dialog
  keeps its selection/duplicate/limitation surface; row checkboxes
  carry merged `sshImportRowSemantics` labels and non-importable rows
  stay inert. Verified: no FileZilla/WinSCP strings or UI remnants
  anywhere in `lib/` — ssh_config remains the only v1 source.
- **Accessibility audit (02 §13, D20).** File rows expose one merged
  semantics node with name, kind, size, and modified date; selection
  follows actual selection, not cursor; activation is a semantic
  action; rename surfaces as a `CustomSemanticsAction` only where
  valid. Flagged U+FFFD names carry a warning badge, tooltip, and
  semantics reason, and `PaneController.startRename` refuses them so a
  replacement character never reaches the wire. Path bars expose each
  segment as its own labeled button (`Go to …`) with decorative text
  excluded. Sidebar group headers merge title + spelled-out item count
  + expanded state + header/button traits. Tab chips are buttons with
  selected state and a labeled close control. Focus-visible rings are
  2px everywhere M9 touched (sidebar rows, headers, the pane splitter
  was already compliant). A new theme contrast-matrix test pins every
  foreground×surface pair M9 uses at WCAG AA; hairline dividers and the
  disabled-command reason text are recorded as exempt (decorative /
  inactive-component) with the rationale in the test. Transfer/sync
  progress retains its live-region announcements. **Linux caveat
  (honest):** Flutter Linux has no AT-SPI bridge for custom widgets —
  the semantics tree we build is largely invisible to Orca, so Linux
  screen-reader coverage is not claimed; every §13 behavior is
  verified via `flutter_test`'s semantics tree, not a native reader.
- **i18n sweep (D20).** Every new string lands in `app_en.arb` (Quick
  Open labels/placeholder/footer/reasons, the import offer, sidebar
  counts, flagged-name copy, path-segment labels). The localization
  contract test still proves zero hard-coded user-facing strings — the
  allowlist gained only technical literals (keyboard-key names,
  ellipsis) with per-entry comments; plural/reason strings are
  exercised by the palette and sidebar tests.
- **Chrome QA (02 §9–11).** The menu-invariant test re-verifies every
  command — Quick Open included — is reachable by menu or chord on
  macOS, Linux, and Windows maps, and the chord table keeps Meta on
  macOS vs Ctrl on Windows/Linux. Titlebar posture is unchanged
  (`TitlebarSafeArea` on macOS; native frames elsewhere). No custom
  scroll physics were added — Flutter's defaults already give macOS
  momentum and desktop discrete scrolling; the existing menu captures
  still cover the platform strip. **Windows IME/IMM32 caveat
  (documented, not automated):** rename is a text-field overlay, so it
  inherits Flutter's known IMM32 limitations on Windows — pre-edit
  (composition) text can render at the wrong offset and some IMEs never
  deliver composition events to the field. There is no automatable
  surface for this without a Windows desktop + IME harness; it stays a
  manual-QA item. **Manual-QA note (2026-09-22):** the automated legs
  cover chord maps, menu reachability, contrast constants,
  focus-visible presence, and captures; what remains human-only is
  real-platform verification of the macOS unified titlebar traffic
  lights, Windows/Linux native frames, momentum-vs-discrete scroll
  feel, native dialogs, Quick Look, and screen readers (VoiceOver /
  Narrator; Orca is the caveat above). PNGs:
  `tasks/run3-task93/` (`quick-open.png`, `quick-open-filtered.png`,
  `ssh-import-preview.png`) alongside the existing menu captures.

Deferred to the next M9 slice per the task split: the fast-path spike,
the `ENFORCE_B` flip, the update check, and the D28 chown UI (open item
30). No engine changes; no new features beyond the spec'd surfaces.

## M9 — polish pass part 2: bench flip + audit, local fast path, update check (2026-09-22)

The second M9 slice (07 §3.10; 08 §6; D26; D19). One PR; the full
evidence record lives in `tasks/run3-task94/audit.md`.

- **Tier-B enforcement flip (08 §6).** P1/P2/P4 are `landed: true` and
  the bench job forwards `vars.BENCH_ENFORCE_B`: once the repo variable
  is set, a > 25 % median regression against the committed tier-B
  baseline reddens main/dispatch runs. P6 stays `landed: false` —
  every leg so far produced only insufficient-frame error rows
  (~827–829 of the ≥ 1800 frames llvmpipe can deliver in 30 s), so no
  honest median exists; the checker reports its rows but never judges
  them. The evaluate step now wires the §6 drift-state store
  (`actions/cache`, restored before grading, saved on `refs/heads/main`
  runs only) and the one automatic tier-B rerun before red — tier-A
  per-scenario documents are held aside across the rerun's cleanup and
  re-merged, and the first evaluation stays read-only so a rerun cannot
  double-count one run's drift. The runner image rotated to
  `ubuntu-latest@20260920.314.1`, so the tier-B baseline and tier-A
  `calibratedFingerprint` were re-measured/recalibrated on run
  35763533669 (the only new-image main run; P5's `first-file` config
  tracks the readdir-order shift to `entry-02814.txt`). No larger
  GitHub-hosted runner class is available to this repo; the committed
  fingerprint is the §6 rotation-control instrument. Post-merge arming
  order: merge with the variable unset so the first run seeds drift
  state soft, then set `BENCH_ENFORCE_B=true` — unknown history counts
  at the escalation threshold, so arming early would redden on the
  first CPU-axis drift of the heterogeneous pool.
- **Local fast path (D26).** Adopted: `copy_file_range(2)` on Linux
  via the `LocalCopyPump` seam — measured ~6–15× the streamed path on
  this host (3.2–3.3 GB/s vs ~0.3 GB/s at 64–256 MiB) with 16 MiB
  chunks preserving per-chunk progress and between-chunk cancellation;
  unsupported-filesystem errors decline to the streamed fallback.
  Temp-file + atomic-rename commit, conflict checks, mode
  preservation, and cross-device copy+delete durability are unchanged.
  FICLONE returned EOPNOTSUPP on every filesystem here (recorded);
  Windows CopyFileEx (progress-callback + pbCancel semantics) and
  APFS clonefile are source-research notes pending their hosts.
- **Link-only update check (D19).** `UpdateCheckController` wraps the
  pinned `seance_core` `UpdateChecker` against `L-K-M/Poltergeist`'s
  latest-release endpoint — a plain GET compared locally, never a
  download or install. A dismissible banner in the workspace shell
  names the newer tag and opens the releases page externally; the
  opt-out `updates.checkEnabled` toggle lives in General settings
  (`app.settings`, ⌘,/Ctrl+,) persisted via `AppPreferences`, reverts
  on persist failure, and disables all network access when off.
  Launch-time check is best-effort after `runApp`. All strings ARB.

Verification: core analyze clean, 1441 core tests pass; benchmark
suite 138 pass with the contract pins updated for the flip; app
analyze clean; 17 targeted D19 tests pass. The first enforced tier-B
main run is verified post-merge per the arming order.

## M9 — exit-criteria audit and close (2026-09-22)

M9 is CLOSED on evidence; the full per-criterion record is
[tasks/m9-closure-record.md](../tasks/m9-closure-record.md), audited at
main head `495dd9e`. The audit PR is documentation-only — every gap
found was a missing committed artifact, not a code defect: the README
known-issues section (Linux a11y + Windows IME, upstream issues linked
and dated), `docs/qa/RELEASE-CHECKLIST.md` (08 §9/DoD — required to
exist at M9; neither polish PR created it),
`docs/qa/screen-reader-notes.md` (the §3.10 walkthrough-notes criterion,
answered honestly — no VoiceOver/NVDA walkthrough has run on a native
host; the notes record exactly what the automated semantics suites prove
and what release QA still owes), and the PORTS.md entry #185 owed for
the ported `update_banner.dart` (source verified at pin `v0.9.1`).

Verified highlights: palette/imports/a11y/i18n/chrome/update-check all
test- and capture-backed per the record; the D26 spike adopted Linux
`copy_file_range` (~6–15× streamed, chunked, decline-safe). The tier-B
flip's code is landed and its audit table is committed; the
**`BENCH_ENFORCE_B` variable is unset at audit time — that arming is the
supervisor's open tail (item 31), recorded precisely rather than
duplicated**: the post-#185 main runs seeded the drift store while
measuring on the pre-rotation runner image, so
`tier-b/controlled/runnerImage` sits at 8 consecutive main runs and an
early flip would red main until a clean committed-fingerprint run lands.
Tier-A is likewise armed-but-inert on the same drift (the job annotates
it). D28 chown UI (item 30) is now flagged as unscheduled — M8 deferred
it to M9 but §3.10's scope never contained it; closing M9 does not
resolve D28 and the disposition needs an owner/plan decision.

§3.12 chores: PORTS swept (the banner entry; no other ported file
moved), pin holds `v0.9.1` (still latest upstream tag), no `TODO(pin)`
markers, mobile invariant row re-verified, tag chore not run per the
standing untagged-close pattern. Local: dart/flutter analyze clean;
190-test focused battery green.

## M10 — v1.0 release preparation (2026-09-22)

M10's docs-and-audit surface is PREPARED; the milestone itself closes
only when the owner runs `scripts/release.sh 1.0.0 --push` — this pass
deliberately holds the tag, the publish, the version-marker bump, and
the "v1.0 shipped" STATUS flip for that step. Per §3.11, criterion by
criterion:

- **Distribution checklist (§4).** Every docs/code-preparable row is
  done. `docs/INSTALL.md` is new: per-platform first-launch steps
  (macOS ad-hoc — right-click → Open or `xattr -dr
  com.apple.quarantine`; Windows — SmartScreen "More info → Run
  anyway"; Linux — `.deb` line, AppImage `chmod +x`, tarball, plus the
  libsecret/Secret Service runtime note for GNOME Keyring and KWallet),
  SHA-256 verification commands per platform with the honest
  integrity-not-origin boundary, the committed public APK-key caveat
  (matching signature proves nothing about origin; key rotation breaks
  in-place upgrades), and the Android/iOS rehearsal-artifact labels §4
  requires from v0.1.0 on. The machine-bound rows stay open and are
  marked **OWNER MANUAL QA** in `docs/qa/RELEASE-CHECKLIST.md`:
  fresh-machine installs on macOS, Windows, and one GNOME + one KDE
  Linux using only INSTALL.md, plus every native-surface row (chrome,
  IME composition, VoiceOver/NVDA, the OS first-launch gates, trash UX,
  drag/drop feel, theme/HiDPI, scroll, Quick Look, the reference
  release-mode tier-B run). Nothing human-only is claimed done.
- **README.** Carries the 01 §6 trust stance verbatim in spirit ("Your
  servers are your business" — no account, no telemetry/analytics/crash
  reporting/bundleware, the link-only update check that is on by
  default and one setting from off, keychain-sealed secrets with the
  no-keychain → no-save rule, TOFU host-key pinning, E2E-encrypted
  bookmark backup, no paid tier), the install/releases links, and a
  known-issues section that states the remote-transfer gap plainly
  (item 23). The version marker stays `0.2.0` on purpose:
  `tool/release_version` requires the marker to equal the pubspec
  version, so the lockstep `1.0.0` bump is release.sh's own write at
  tag time — flipping it here would leave the repo inconsistent.
- **Human release notes (D24).** Drafted in `CHANGELOG.md` as
  "## 1.0.0 — first stable release (prepared; ships with the v1.0.0
  tag)": personality, not a commit dump, with the remote-transfer
  limitation, the upstream a11y/IME caveats, unsigned-build
  first-launch steps, and the mobile rehearsal-artifact labels included.
- **PORTS.md swept** (§3.12 chore 2 + 04 §6): every entry re-verified
  against the `v0.9.1` pin (`035b0d8`) and re-diffed against upstream
  HEAD (`15d0fdd`); per-file drift dispositions recorded in the M10
  sweep section. Nine ready port-back issues filed on `L-K-M/Seance`:
  #114 (sync-token revocation endpoint — 04 §7.3's urgent item), #115
  (local-name validator batch), #116 (master-key corrupt-entry
  misreport + create race), #117 (identity-read normalization +
  bounded audit), #118 (VFS additions behind items 10/12/13), #119
  (managed-checkout lifecycle rails), #120 (persistent record store +
  tombstones — 04 §6 priority 2, now proven), #121 (UX patterns),
  #122 (small polish batch). Left open without issues, recorded in
  PORTS: the conditional M5 sortKey/grouping offer, the conditional
  safety-test port, and the narrowed mixed-EOL editor candidate.
- **Pin check (chore 3).** `v0.9.1` is still the newest Séance tag —
  the pin does not move; upstream HEAD drift is next-window material,
  not pin fallout. `dartssh2` stays exactly 3.0.2.
- **`TODO(pin)` grep (chore 3).** No markers in code, configs, or
  scripts — remaining hits are the plan's and STATUS's own references
  to the rule. Nothing to delete.
- **Rehearsal-tag audit (chore 4).** Only `v0.1.0` and `v0.2.0` exist;
  M3–M9 closed untagged per their closure records. **This is the
  release's headline risk, flagged prominently on the prep PR: every
  prior tag published as a pre-release, so v1.0.0 is the first
  non-prerelease run `release.yml` has ever performed — the first
  exercise of the Latest-release path, and the first full pipeline
  exercise since v0.2.0.** The owner should watch the run and be
  prepared to re-run jobs or patch the workflow if a stable-tag-only
  branch misfires; this is preparation, not a prediction of failure.
- **Mobile memo (chore 5 / §5's M10 row).** Re-read against the shipped
  code. Holds: `poltergeist_core` stays pure Dart (`check-imports.sh`
  guards it); the engine protocol stays plain data (the AST guard's
  fixture suite runs in CI); two-pane assumptions live in
  `WorkspaceController` layout, never in controllers, the queue, or
  core; the queue is suspendable (pause-all + journal restart is the
  working primitive — M4's row); sync/enrollment, editor, and scan
  code take no pane, watcher, or window dependency (M6/M8/M9 rows);
  bookmarks carry the device-local fields per-device grants need (M5
  row). **Recorded deviations:** (a) `ScopedPathAccess` exists only as
  the documented seam — no service class, no `scoped-bookmarks.json`,
  no minted blobs; local access funnels through the engine-owned
  `LocalFileSystem` and the `local_fs_safety` helpers instead. On
  unsandboxed v1 desktop that is behavior-neutral (the pass-through
  backend would grant nothing anyway), but the memo's "all local
  access already flows through `ScopedPathAccess`" overstates it: the
  mobile/sandbox milestone must build the service and plumb grants,
  not merely swap a backend. (b) The iOS background-transfer
  consequence ("every transfer interruptible and cheap to resume")
  is designed-in for local work but unproven in production for remote
  endpoints, because item 23 keeps remote verbs unwired — remote
  suspend/resume evidence waits on that slice.

**Exit-criteria state:** docs/code criteria prepared as above; the
release command, the tag, `release.yml` green, the fresh-machine
install tests, the STATUS "shipped" flip, and stripping the
CHANGELOG 1.0.0 heading's "(prepared; ships with the v1.0.0 tag)"
parenthetical remain — all owner-side by design. **Remaining QA:**
the whole OWNER MANUAL QA set in `docs/qa/RELEASE-CHECKLIST.md`.

**Fast-follows (§3.13) staged as the post-tag next-steps:** agent auth
+ ProxyJump first (D10/PR-S4); OS drag-out (D14, `super_drag_and_drop`
spike); local archives (D27); FileZilla/WinSCP/Cyberduck importers
(D22); deep links (04 §7.1) and the text-diff view as demand dictates;
then the v1.x backlog (named skip rules, batch rename, custom keymap,
native icons, Compare entry point, preview warming — and Sync Browsing
if risk 8's cut line is ever exercised). None is started here. Item
23's remote-transfer wiring is the de-facto headline fast-follow even
though §3.13 predates naming it.

## M3 follow-through — pane directory watch wiring (2026-09-24)

03 §7.5's pane policy over the engine seam of 2026-09-13, reimplemented
on current main (supersedes #113, which predated pane tabs and the
replacement rollback). `AppBrowseChannel` gains `directoryChanges`,
`watchDirectory`, and `unwatchDirectory`, forwarded to
`EngineBrowseChannel`. Each `PaneController` watches the local directory
its tab shows while that tab is its strip's visible tab (`setTabActive`,
stamped by `PaneTabsController` on every active-tab or tab-set change):

- The watch arms before the listing reads the directory, so no change
  falls between the two; a same-directory refresh keeps it, a
  navigation retargets it (the engine swaps atomically), and a remote
  binding never asks. A navigation superseded before its watch arms
  never reaches the listing.
- `changed` re-lists quietly: no recents visit, no history entry, and
  the tab close guard ignores it (`navigationInFlight`). Signals during
  an in-flight listing coalesce into one follow-up re-list; an open
  Quick Select session, a pending type-ahead buffer, or an error on
  screen holds the re-list until it ends.
- `lost` rescans at once and re-arms. A `lost` that lands before a
  retarget's reply (the replaced target's, or the new watch dying at
  subscribe) re-arms to tell the two apart. Three consecutive losses
  stop re-arming and post `PaneNotice.watchStopped`; a delivered
  change, a new directory, a refresh, or re-activation restores the
  budget.
- A failed listing drops the watch (notably `notFound`, which the
  backend may never report as a loss); Retry re-arms. A refused watch
  request leaves the listing unwatched and the listing reports the
  path's own fault; an untyped failure reports.
- Background tabs release their watch and re-list on activation. Esc's
  snapshot restore re-arms the restored directory without re-listing:
  a change made during the cancelled navigation shows on the next
  signal, refresh, or activation. A cancelled replacement keeps the
  parked local watch and re-lists on restore only if it signalled.

Validation: 20 tests in `test/services/pane_watch_test.dart` over the
scripted channel's new watch seam; the full app suite and
`flutter analyze` pass locally. Native backend behavior stays with the
engine seam's records (items 14 and 18).

## Open items

1. **M3 — OS Dart client matrix: validated 2026-09-12.**
   [PR #81](https://github.com/L-K-M/Poltergeist/pull/81) activates
   Ubuntu, macOS, and Windows package analysis/tests with dynamic explicit
   paths. Ubuntu tooling, SSH integration, M0 evidence gates, and all five
   client builds remain intact. No release-workflow or milestone-close change.
   [CI 34713912737](https://github.com/L-K-M/Poltergeist/actions/runs/34713912737)
   at `a5588ed` passed all executed jobs. Native package logs (Dart 3.13.3):
   Ubuntu job `103607494694`, 549 passed/16 skipped; macOS `103607494655`,
   548/13; Windows `103607494699`, 524/37. All three analyzed cleanly.
   M0 measurements/evidence jobs are dispatch-only and skipped on this PR;
   committed M0 evidence validation passed in Ubuntu tooling.
   **Skip audit:** Ubuntu: 15 unavailable SSH fixtures plus one Windows-only
   contract. macOS: 11 unavailable SSH fixtures, one Windows-only contract,
   and one distinct-case fixture on a case-insensitive volume. Windows:
   11 unavailable SSH fixtures, 17 POSIX filesystem fixtures, four incident
   store mode fixtures, two engine mode fixtures, the existing engine-link
   fixture, one distinct-case fixture, and one backslash-as-leaf fixture.
   Four additional SSH tests are Linux-only registrations. The local VFS
   and safety link helpers ran on Windows without capability skips;
   native timestamps, case-only rename, reserved names, containment,
   backup recovery, and transfer contracts remain covered. SSH job
   `103608923552` exercised the enabled fixture separately on Ubuntu.
   Initial CI `34713212268` exposed macOS getcwd alias and Windows separator
   expectations, Windows orphan-temp matching, and detached source cleanup.
   Repairs preserve those tests; the held-cleanup regression failed before
   the fix and passed afterward. Local core analysis/549 tests and the
   import/protocol scans pass; filesystem/store tests: 176 passed.
   Review runs `34713212233` and `34713912733` completed without confirmed
   important findings. Two minor-only rounds end optional review changes;
   #81 records every disposition and final-head gates. The proposed removal
   of returns after `markTestSkipped` contradicts test_api's void contract.
   Deferred: expanding the workflow comment's explicit-path rationale;
   AGENTS already documents it. No UI or pin change.
   **2026-09-07 review follow-up (#34):** before running the protocol guard's
   symlink fixture on Windows, probe link-creation privileges and skip only
   when unavailable. Its current CI job runs on Ubuntu.
   Also register fixture cleanup before setup writes, so partial setup
   failures cannot orphan temporary directories.
   **2026-09-08 review follow-up (#41):** before expanding fixture-tool
   or enabled SSH suites beyond Ubuntu, probe or explicitly gate their
   POSIX shell and GNU-timeout requirements. This includes the pool SSH
   suite; ordinary package runs skip it without fixture variables.
   These tools currently run only in the Ubuntu job (08 §8).
2. **2026-09-07 — Séance pin: flip to the next tag.** The fork bridge is
   retired (see the Done table) and the pin sits at upstream main —
   `2e6d1f1` since 2026-09-08 (probe repair, audit work, SSH-trace
   redaction; dated section above); before that `a9add15` (keepalive
   controls). No Séance tag contains #79's probe repair (all eleven tags
   checked by ancestry), so the rev-pin bridge continues. `poltergeist_core` carries the
   same rev pin (first workspace-package pin; the M0 bench pin set is
   unchanged, and the pin audit record still matches). When Séance cuts its
   next release (the same S1 release the M6 Design A gate needs), re-pin
   both declarations to that tag (D2's steady state) and drop the rev pins.
   Tag S1 before M6 Design A.
   **Closed 2026-09-21:** Séance `v0.9.1` (2026-09-14, `035b0d8`) contains
   the pinned rev `2e6d1f1` and PR-S1's `599ff936` — both declarations
   moved to `ref: v0.9.1`, all locks resolve to `035b0d8`, the bench
   harness's live-revision constant follows, and the regenerated audit
   matches `docs/PORTS.md`. The rev-pin bridge is retired (see the M8
   dated section).
3. **2026-09-04 — M2 remaining slices** (implementation complete
   2026-09-10; consolidated 2026-09-11). Every implementation slice below
   landed — each bullet carries its dated Done record, and the Done
   table's M2 row consolidates them. What remains open in this item is
   only the recorded follow-ups owned by later milestones: the
   per-favorite probe opt-out (M5's bookmark store), `removeBookmark`
   from bookmark deletion (no deletion UI before M5), audit finding C's
   residual per-serverId state (M3's Quick Connect lifecycle), and the
   review follow-up notes inline below. M2's close is contingent only on
   the v0.2.0 release rehearsal; item 4's ordering escalation is
   unaffected and stays open. The slice history, in the original order:
   - close the pool-behavior gaps in item 5 and settle item 6 before wiring
     production callers; the coverage items retain their stated gates;
   - keepalive pings (03 §3.3). **Done 2026-09-07** (see the Done table):
     the opener's built-in timer is disabled (`keepAliveInterval: null`),
     one pool-owned clock pings idle transports every 30 s — idle means no
     aggregated adapter activity and no pending channel opens/closes — and
     a ping unanswered past the adapter-matching operation timeout closes
     its transport so recovery fires on closure. Socket-level verification
     (real pings on a real transport) rides the 08 §5 real-sshd legs below.
     Reconnect recovery and the backoff-sequence tests are implemented below;
   - engine isolate + `EngineClient` + the typed port protocol (03 §5).
     Bounded progress batches, their isolate round-trip/coalescing tests,
     and the callback-field AST guard are implemented; **the connection/
     prompt half — engine spawn, `EngineClient`, requests/results, prompt
     round trips, and scope-dismissal crossing — landed 2026-09-07** (see
     the dated section). The transfer/queue requests
     (`EnqueueTransfer`, `Cancel`, `SetBandwidthLimits`, `SetQueuePaused`)
     and the `conflict` prompt pair land with M4's queue, which owns
     `TransferTaskSpec` (03 §5's precision edit records this);
   - prompt UI (host-key dialogs, keyboard-interactive, credential prompt,
     live `SshConnectionLog` transcript) over the protocol — this slice also
     owns rendering the ported keystore/vault exception messages through ARB
     (D20) rather than raw port text. **Done 2026-09-07** (see the dated
     section): the three dialogs, the coordinator, the live transcript
     surface, and the diagnostics one-liner landed; vault-unavailable and
     identity-read errors render through ARB-authored sentences;
     composition into a running app rides the production-wiring slice;
   - `ProbeService` wiring + interim server list status dots. **2026-09-08
     prerequisite ([Séance #79](https://github.com/L-K-M/Seance/pull/79)):**
     the current pin's periodic sweeps can overlap after
     pause/resume or repeated start; paused/disposed sweeps still launch
     queued probes, and target replacement can publish stale statuses.
     The upstream repair serializes periodic sweeps, snapshots targets,
     and invalidates stale queued work/results while preserving cadence
     and standalone `probeAll`. Equivalent target updates preserve active
     results. Seven regression tests failed before their repairs;
     afterward, all 16 lifecycle tests, 594 upstream Dart tests, and 449
     Flutter tests pass with clean analysis. Upstream merged as
     `4a50782659ee4aa1f7ce0cb253a6f8d3a46c407c`; all CI checks passed.
     **2026-09-08: the containing pin prerequisite is consumed** — the
     live pin is now `2e6d1f1` (dated section above); the wiring itself
     (ProbeService + interim server list status dots) remained open then.
     **2026-09-09: engine control/status wiring and the app eligibility
     controller are implemented** (dated sections above). The controller
     applies lifecycle/settings policy to supplied device-local facts.
     Persistence, lifecycle forwarding, interim list dots, and composition
     remain open; no current app caller initiates probes.
     **2026-09-10: persistence, lifecycle forwarding, interim list dots,
     and composition are implemented** (dated section above): the
     settings.json-backed store (global opt-out + the per-server
     device-local map with retarget reset), the binding-seam lifecycle
     forwarder, the tri-state ARB/semantics dot with pinned contrast, and
     the owning-store `ProbeCoordinator` now drive the demo session as the
     first subscribing app caller. **2026-09-10: live connection-state
     composition (the Connections-section surface) landed** (dated
     section above): the `ConnectionStatusController`, the Connections
     surface and its registered command, and the composed indicator.
     **2026-09-10: startup engine-spawn composition landed** (dated
     section above): the production engine spawns at app startup seeded
     with pins and incidents together, and the demo session reuses it.
     Per-favorite opt-out persists with M5's bookmark store.
     **2026-09-09 review follow-up (#55):** the app consumer must subscribe
     to live probe snapshots before sending targets/activity. Evaluate
     replay only if its eventual ownership cannot guarantee that ordering;
     the current documented API retains no replay cache.
     Existing probes may settle; no new stale work may start.
     **2026-09-08 review follow-ups:** consider upstream tests for exact
     timeout forwarding and jitter endpoints. Both contracts are unchanged;
     neither blocks the lifecycle repair. A probe's drain is not bounded by
     one timeout: TCP connection and banner reading each have a timeout.
   - ssh_config import with preview + dedupe (D22). **Done 2026-09-08**
     (see the dated section): the core import service (pinned-importer
     consumption, top-level include resolution, D22 limitation badges,
     host+port+username dedupe, reference-style IdentityFile mapping) and
     the ARB-complete preview dialog landed. **Composition, persistence,
     and command registration landed 2026-09-10** (dated section above):
     the `favorite.importSshConfig` command, the `FileBookmarkStore`
     (M5 builds its app-wide `BookmarkStore` on it), and the shell wiring.
     The connect flow that consumes an imported IdentityFile still rides
     open item 6; M5 owns the sidebar/bookmark-management UI;
   - the debug-only connect → SFTP → `listDirectory` demo surface.
     **Done 2026-09-09** (see the dated section): the kDebugMode-gated
     `connect.demoListing` entry opens the throwaway listing view over the
     spawned engine, the pool, the real prompt coordinator, and the live
     transcript; M3 replaces it. The remaining M2 work is the
     owner-gated item 6 decision, the recorded follow-up notes above,
     and the milestone-close chores; the Docker-integration bullet
     below records the engine/pool/opener real-sshd legs as already
     landed.
   - Docker-integration pool coverage (growth, keepalive, reconnect against
     real sshd), interactive auth, TOFU flows, shared-bookmark decisions,
     and explicit trust review landed in the dated slices above; the
     auth-failure summaries land in their own 2026-09-08 slice, and M4's
     mid-transfer queue recovery retains its gate.
   - **2026-09-10 — unbounded per-serverId state (audit finding C).**
     `_events`, `EngineClient._serverStates`, and `EngineHost._servers`
     each gain an entry per serverId with no removal. `_incidentOwners`
     is drained only by `removeBookmark`/`_forgetIncident`, which the
     demo and `EngineHost._shutdown` never call for an ephemeral id, so
     it leaks the same way. Bounded by the demo session's lifetime today;
     unbounded once M3's Quick Connect mints an `adhoc:<uuid>` id per
     connect against a long-lived engine. Fix direction: drop a serverId's
     controller on its last unwatch, or add a `forgetServer(serverId)` on
     its last reference that runs the `removeBookmark` cascade plus
     controller/state teardown. Tracked for M3.
     **Partly closed 2026-09-10** (dated section above) for the removal
     path: `removeBookmark` now drops `EngineHost._servers` plus the id's
     watch, `EngineClient._serverStates`, and the manager's
     `_events`/`_lastStatuses`, and a removed bookmark's watch stream
     completes. Still open: the disconnect path keeps its controllers (a
     disconnected bookmark may reconnect, so that is correct) and
     `EngineHost._channels`, which no request maps back to a serverId.
     Also open, from the same family: a *new* open arriving between
     `disconnectServer` and the fan-out drop can register a bounded pool for
     an id being removed, and a *new* watch of an already-removed id
     allocates a controller nothing will close (the manager keeps no
     tombstone by design). Both need per-id removal state that never
     shrinks, so decide them with M3's Quick Connect lifecycle rather than
     piecemeal here.

   The bookmark model and vault/store plumbing slice is done (see the Done
   table): the model is consumed through the pin (no copy — PR-S1 is in the
   pin's ancestry), and the `MasterKeyManager`/file-store/`LockedSecretVault`
   ports carry PORTS entries and tests.

4. **2026-09-04 — escalation: milestone order** (updated 2026-09-06). M2 began while M1's
   rehearsal remained open. 07 §1 and IMPLEMENTOR prohibit this overlap;
   no recorded exception accompanies #14. The M1 close (2026-09-06) and
   #15's merged D23 change postdate the violation; the overlap itself
   still has no recorded authorization. Owner decision needed:
   retroactively authorize a documented ordering exception, or set the
   rule for future overlaps. The single-release-ownership question
   (matrix legs each invoke `action-gh-release`) was reworked inside
   #15 (hidden draft, tag-keyed concurrency, created-once guard,
   fail-loud probes); the merged direct-publish path's first
   end-to-end exercise is the v0.2.0 rehearsal — watch leg-race
   behavior there.
   **2026-09-11 — reconfirmed OPEN at M2-close prep:** the overlap still
   has no recorded authorization. The M2-close chores and this sweep do
   not close, settle, or supersede this owner decision.
   **2026-09-11 — v0.2.0 rehearsal watch result:** the merged
   direct-publish path's first end-to-end exercise ran (release run
   34560964912; dated section above). Single release ownership held (one
   surviving release; four transient duplicate drafts auto-removed by
   action-gh-release), the draft stayed hidden, tag-keyed concurrency
   had nothing to queue (single run for the tag), the created-once
   guard was not stressed by a second run, and the fail-loud probes
   fired — the run failed red on the publish step's nonexistent
   `gh release ready` subcommand (item 8, now closed) instead of silently
   stranding the draft. The authorization question itself stays OPEN —
   owner decision.
   **2026-09-11 — v0.2.0 publish-run watch result:** the recovery run
   after the item-8 fix (dispatch
   [34572521676](https://github.com/L-K-M/Poltergeist/actions/runs/34572521676)
   from the fixed ref) completed the direct-publish path end to end —
   the same leg-race shape (four transient duplicate drafts
   auto-removed by action-gh-release, one surviving release 386841889),
   the draft stayed hidden until the checksums job published it, the
   prerelease flag was correct, and the publish re-probe verified the
   flip.
5. **2026-09-04 — M2 audit follow-ups.** Not milestone completion claims:
   - **Prompt cancellation (review follow-up; manager half closed
     2026-09-06):** credential resolutions now receive a
     `CredentialResolutionScope`; abandoning the pool's last reference
     mid-resolution trips it, so a resolver-owned prompt closes instead of
     parking on an answer the pool rejects, folded first-connect callers
     fail without a user answer, and a replacement session resolves afresh
     (regressions: `pool_resolution_dismissal_test.dart`). The protocol
     half **closed 2026-09-07**: the engine bridges its resolver over the
     port, withdrawal crosses as `PromptDismissedEvent`, and shutdown
     dismisses all open prompts (see the dated section).
   - **2026-09-07 — recovery diagnostics (closed):** terminal pool failures
     fan out per current server reference; permanent home errors identify
     their pane-tab. `RecoveryFailedEvent` crosses as typed error fields
     without arbitrary causes; `EngineClient.recoveryFailures` broadcasts
     independently of state watches and closes on engine termination.
     `ServerStatus.detail` also carries the state-associated one-liner to the
     connection panel. Cancellation, stale failures, transient retries, and
     changed-key blocks produce no generic recovery diagnostic. Observer
     errors cannot replace caller failures or interrupt teardown. Arbitrary
     resolver/opener errors use a fixed summary without formatting internals.
     Neither path is telemetry or persistence (D19); production wiring and a
     milestone-close claim remain open.
     Validation: five regressions failed before the independent producers were
     wired; nine diagnostic pool tests and three host-port tests pass. Protocol
     v4 round-trips both recovery scopes, status details, and transcripts
     through spawned isolates; client tests verify stream closure and broadcast
     delivery. Review added unconditional harness recording, replaced/closed
     pane cases, and a test-only engine entrypoint seam. Core and Flutter totals
     are recorded in the dated implementation sections above.
     The app's eventual diagnostic owner must subscribe before connecting;
     these live streams keep no replay cache (03 §5).
   - **2026-09-07 — transcript follow-up (#40 review):** consider static
     recovery-stage labels (probe, credential resolution, transport open)
     and whole-pool correlation if a flat transcript needs to group per-server
     events. Opaque errors use the documented generic summary; never format
     arbitrary error internals.
   - **2026-09-07 — prompt/audit port-backs (audit legs closed 2026-09-08):**
     the pinned Séance responder drops RFC 4256's per-prompt echo bit
     before the engine protocol sees it; fields therefore start masked
     with explicit reveal. Preserve the bit when upstream exposes it —
     still open. The malformed-line and owner-only audit-storage legs
     landed upstream in [Séance #80](https://github.com/L-K-M/Seance/pull/80)
     (merge `bc534136fa427ca9605babd47e44555e5dbfd4d1`): wrong-typed
     optional JSON fields now skip as malformed instead of poisoning
     `readAll`, and the audit log is created/repaired/rotated mode 0600
     on desktop POSIX. All five behavior regressions failed against the
     previous upstream code before the repair; `flutter analyze` is
     clean and all 455 Séance app tests pass, with all nine CI checks
     green on the merged head. App-layer only, so no pin change (the
     pinned `seance_core`/`seance_protocol` trees are untouched);
     PORTS.md records the one remaining divergence — upstream's review
     added a read-side repair gate (skip the chmod when no group/other
     bits are set) that this port should mirror. Route guards — previously
     a PORTS-led candidate — closed 2026-09-09:
     [Séance #82](https://github.com/L-K-M/Seance/pull/82) ports the
     dialogs' current-route action guards upstream (dated section above).
     None of the remaining candidates blocks the safe local behavior or
     production wiring.
   - **2026-09-08 — gate regression follow-up (Séance #81):** that
     read-side gate now has durable upstream regressions —
     [Séance #81](https://github.com/L-K-M/Seance/pull/81) (merge
     `2e6d1f138f1704e683870f75e11262bf50e37379`, head
     `cb4b010075bd0519914de27bc0a2231c449e204d`) commits two rootless
     Linux procfs tests over the public `IdentityAuditLog` API: an
     owner-only `/proc/self/io` (mode 0400, readable, chmod EPERM)
     reads back empty with its mode untouched — no repair chmod fires —
     while a world-readable `/proc/self/status` (mode 0444, chmod EPERM)
     fails `readAll` closed with the repair chmod's `EPERM` pinned via
     the `PosixException` errno. The throw itself is asserted (the
     status text is not JSON, so empty entries would not prove the
     rejection ran); fixtures use only this process's non-sensitive
     metadata, never modify permissions, and skip off Linux or without
     the fixture with an explicit reason while running in Ubuntu CI.
     Runtime fail/pass evidence exists per branch: the skip-gate test
     fails against pre-gate `70db26c` (EPERM out of `readAll`) and the
     fail-closed test against pre-privacy `41d5261` (no throw; empty
     entries returned), both passing on merged main with all nine
     upstream CI checks and all 457 app tests green. This closes the
     durable-regression gap. **2026-09-08 — local gate mirror landed
     ([PR #52](https://github.com/L-K-M/Poltergeist/pull/52)):**
     `readAll` now gates its repair chmod on the group/other mode bits
     (`_groupOtherBits`, mirrored from Séance's `cb4b010`) — an
     already-private log skips the chmod and stays readable on
     chmod-incapable mounts, while a permissive log that cannot be
     restricted still fails the read closed. All six #80/#81 audit
     tests (fresh-file mode, write repair, read repair, absent-field
     defaults, both procfs regressions) are ported; the skip-repair
     regression was observed failing at runtime before the gate
     (EPERM out of `readAll`) and passing after, and the fail-closed
     test passed before and after. Local validation: app analysis
     clean, 220 app tests pass; core analysis clean, 302 core tests
     pass (15 integration skips); import guard 92 + repo scan pass;
     the procfs fixtures run in the Ubuntu CI flutter job. PORTS.md
     closes the gate-mirror candidate; no pin change (app-layer source
     reuse).
   - **2026-09-05 — optional cleanup diagnostics (review follow-up):**
     consider an upstream observer if real-sshd debugging needs cleanup
     failures. The pinned helper's ignore mode exposes no observer. This
     does not block the teardown repair or change error preservation.
   - **Dependency-contract coverage (updated 2026-09-08; hash-off CAS leg
     closed):** 09 §5's upgrade guards are covered below. The
     hash-off second-preflight/CAS gap is closed upstream in
     [Séance #78](https://github.com/L-K-M/Seance/pull/78) (merge
     `41d526178a65470142cf4bcb60b8da548af1dbba`, test-only, so no pin
     change per D2): six socket-free tests through the real adapter over a
     path-aware SFTP fake cover both preflights, the `expectedTarget`
     snapshot and digest CAS with `computeHash: false` (disabling the
     outgoing digest never disables the CAS hash), preservation of
     externally written targets, no commit rename on refusal, and temp
     cleanup; guard liveness was proven with isolated, reverted adapter
     mutations. Tests stay upstream (08 §2). No production adapter code
     changed — this was a coverage gap, never an observed VFS failure.

6. **2026-09-05 — escalation: trust-incident recovery (D18).**
   Escalated because unresolved incidents survive disconnect but not
   process restart, a returning trusted key stays blocked without a
   changed-key verdict for the current review callback, and the manager
   has no bookmark-removal signal.
   **Owner decision 2026-09-09T19:52Z** (the owner chose recommendations
   1a/2a/3a; the question is closed):
   - **1a)** a presented host key that returns to the originally pinned
     key lifts the declined-incident block and connects normally (matches
     trust; no new verdict or prompt);
   - **2a)** declined incidents persist to disk across app restarts
     (device-local only, D19 unchanged);
   - **3a)** deleting a bookmark cascades deletion of its incident.
   **Implemented 2026-09-10** in the trust-incident lifecycle slice
   (dated section above): restored-key unblock, incident persistence with
   a defined record schema/keying, and the bookmark-removal cascade.
   **The engine-protocol bridging landed 2026-09-10** (dated section
   above): incident seeding at spawn coupled with pin seeding, the typed
   incident-change mirror events, and the `removeBookmark` request
   crossing — plus the load-time rule that refuses to restore a record
   whose pin is gone or moved on, the coupling audit finding A required
   (`tasks/run3-audit-m2-report.md`), which is closed.
   **The app-side composition landed 2026-09-10** (startup
   engine-spawn composition, dated section above): production engines
   spawn seeded from both stores and the mirror events persist
   idempotently. Remaining: `removeBookmark` from bookmark deletion —
   no app-side bookmark deletion exists before M5's store.
   The mirror's idempotent-removal and never-re-seed contract is
   implemented and pinned by the session suite.
7. **2026-09-08 — CI/fixture hardening suggestions (#41 review).** Evaluate
   consistent `pub get --enforce-lockfile` use across CI and commit-SHA
   pinning for third-party actions. The new integration job follows existing
   resolution/action conventions; the Séance audit separately checks manifest
   and lock pins. Also consider checking retained fixture account UIDs before
   supporting modified base images; current restart tests reuse accounts
   created by the same entrypoint in digest-pinned containers.
   **2026-09-08 — keyswap recovery follow-up (closed):** `restore-modern`
   stops both swap services, waits for their fixed shared port to clear,
   then starts modern and verifies its SSH banner. Cleanup works before
   keyswap exists, after either startup/readiness failure, and on repeat.
   Six regressions failed on the old port lookup; all eleven new checks pass,
   including Compose-port consistency and stop/free/start/banner failure
   propagation. The smoke suite now restores before the first swap and
   twice afterward. Review added a key check after each restoration: a wrong
   first key previously passed when the second cleanup repaired it. That
   regression failed before the check and passes afterward; a wrong second
   key is also rejected. All 61 fixture-tool, 257 core, and 196 app tests pass locally
   (15 real-sshd skips); fixture/core/Flutter analysis is clean. Docker is
   unavailable locally; real-service smoke, all 15 SSH tests, and all five
   client builds pass in [CI run 34224282442](https://github.com/L-K-M/Poltergeist/actions/runs/34224282442).
   `run.sh` retains final profiled-stack teardown. No port or pin change.
   No offline-review path, removal API, or new store/schema is added here.
8. **2026-09-11 — release.yml publish step bug (`gh release ready`).**
   The Checksums job's Publish step calls `gh release ready`, which does
   not exist in the gh CLI ([run 34560964912](https://github.com/L-K-M/Poltergeist/actions/runs/34560964912),
   job 103144720210). Every leg before it succeeded; the v0.2.0 draft
   sits hidden with all assets, sums, and notes attached. The line had
   never executed before: v0.1.0 published manually under D23's
   one-time carve-out, so the merged direct-publish path was never
   exercised end to end until this rehearsal. Fix:
   `gh release edit "$RELEASE_TAG" --draft=false`, followed by a
   post-publish probe that fails loud if the release is still a draft
   (the green-over-unpublished failure mode the step's own comment
   names), with coverage — a grep/lint or dry-run guard; the bug is one
   command name. Dispatch provenance hazard, verified 2026-09-11: the
   client job's `actions/checkout` carries no `ref:` pin, so a dispatch
   from a branch builds that branch's tree while labeling assets with
   the tag — the fix PR must pin checkout to the tag input (or the
   recovery must otherwise guarantee the built commit equals the tag's
   commit), and the draft deletion must remove the release only, never
   the tag (no `--cleanup-tag`). Then D23's
   recovery: delete the hidden draft and re-run the release for tag
   `v0.2.0` via `workflow_dispatch` from a ref that carries the fix
   (dispatching the tag ref re-runs the tag's buggy workflow file; the
   created-once guard refuses while the draft exists). Only a published
   v0.2.0 closes M2.
   **2026-09-11 — fix:** the publish step now calls
   `gh release edit "$RELEASE_TAG" --draft=false` and re-reads `isDraft`
   afterward (a silent no-op publish fails loud instead of going green
   over a hidden draft), and both `actions/checkout` steps pin the
   resolved ref — an existing tag checks out itself, a not-yet-created
   dispatch tag falls back to the dispatched commit — so a dispatch from
   the fixed ref builds the tag's own commit (target_commitish is
   ignored for existing tags). Coverage in
   `tool/release_version/test/release_workflow_test.dart`: the shape
   assertions pin the new command and the re-probe, the fake gh drops
   its `ready` case (a regression now fails loudly), a new still-draft
   dry-run fails the publish, and the checkout-ref resolution has shape
   and fake-curl dry-run tests — all three red against the unfixed
   workflow (including a dry-run reproduction of the rehearsal's
   unknown-command failure), green after; `dart analyze
   tool/release_version` clean. Recovery (delete the draft only, then
   dispatch v0.2.0 from the fixed ref) and publish verification followed
   the merge; the item stayed open until the v0.2.0 release was public.
   **Closed 2026-09-11.** The fix merged in
   [PR #72](https://github.com/L-K-M/Poltergeist/pull/72) (merge
   `c96681d`); the D23 recovery deleted the hidden draft (release
   object only — tag v0.2.0 untouched at `5f8ed9a`) and re-dispatched
   release.yml from `main` at the fix merge with tag input v0.2.0 (run
   [34572521676](https://github.com/L-K-M/Poltergeist/actions/runs/34572521676),
   every leg green, publish re-probe clean). The publish verification
   (public pre-release, 8 assets, checksum spot-check) is in the dated
   close section above; v0.2.0 is public and M2 is closed.
9. **2026-09-11 — M3: port 03 §2.3's local-safety helpers.**
   `LocalFileSystem` (first M3 slice) implements upload's commit dance
   and leaf-name validation as private in-class originals following
   §2.3's spec. The plan's own instruction for the four helpers is a
   *port* of Séance's `RemoteFilesController` statics with their Séance
   tests and a PORTS.md entry each — deliberately not in the
   LocalFileSystem PR (original code only). When the port lands in
   `poltergeist_core/lib/src/fs/local_fs_safety.dart` (public, with
   `ensureSafeLocalDirectory` + `validateLocalName`/
   `validatePathComponent` and the crash-recovery sweep semantics for
   orphaned `*.poltergeist-*.backup` siblings), switch
   `LocalFileSystem`'s commit/validation paths to it and delete the
   private copies. Owner of the remaining call sites: the transfer
   queue's download executor, the checkout store, and the sync executor
   as those land (M4/M7/M8).
   **Closed 2026-09-11.** The port, the switch, the deletion, the
   sweep, Séance parity (the one upstream test that exercises the
   shared contract, re-homed per 08 §2), and both PORTS.md entries
   landed — see the dated section above. The M4/M7/M8 call sites stay
   owned by their slices as originally scoped.
10. **2026-09-11 — M3: upstream `pathTypeChanged` into the pin.**
    `LocalPathTypeChangedException` (kind `other`) exists because the
    pinned `RemoteFileErrorKind` carries no `pathTypeChanged` member
    (03 §2.2's same-PR precision edit records the representation).
    At the next Séance upstream window, add the enum member upstream
    (an additive kind in PR-S3's pattern — note it breaks downstream
    exhaustive switches over the enum, so it needs the usual upstream
    migration care), re-map the subclass onto it
    at the pin bump, and deprecate the local subtype — including
    removing its barrel export, so generic
    `RemoteFileSystem` callers can dispatch on `kind` alone instead
    of catching an implementation-specific class.
11. **2026-09-11 — M3: engine-side local browse seam missing (blocks the
    panes-v1 foundation slice).** 07 §3.4's pane slice requires local
    panes to browse through the one VFS engine-side — 03 §5's ownership
    table assigns "LocalFileSystem instances used by panes" to the
    engine isolate, and D8 forbids direct dart:io from widgets. The M2
    engine protocol serves only SSH pool-backed channels:
    `OpenBrowseChannelRequest` requires a `ServerConfig`, and
    `EngineHost._listDirectory` executes only a pool `PaneChannel`'s
    `fs`. No request mounts a `LocalFileSystem` — the first M3 slice's
    own record scoped this ("the seam to mount a local pane rides the
    PaneController slice") and it does not exist yet. What it blocks:
    the two-pane shell, per-pane location binding, and local
    listDirectory/navigation/error-taxonomy surfaces; the app-side
    pane slice stopped without app changes rather than widen its
    boundary (core stays closed to it, per the task's own rule).
    Least-blocking path: a dedicated core PR adds the seam — engine
    protocol (a local channel-open request; no `ServerConfig`, no
    pool/server-state surface), host-side `LocalFileSystem`-backed
    channels serving the existing listDirectory plumbing, the
    `EngineClient` facade, and tests — after which the pane slice
    resumes against it. Directory watching (03 §7.5), per-location
    view prefs, and the rest of 07 §3.4 stay with their own slices.
    **Closed 2026-09-11** (its own dated section above, the engine-side
    local browse seam of 2026-09-11 — not the panes section of
    2026-09-12 that follows the resume).
12. **2026-09-12 — M3: cancellable listings require an upstream VFS change.**
    The pin (`2e6d1f1`) defines `RemoteFileSystem.listDirectory(String path)`
    without a cancellation token; its SFTP implementation awaits
    `SftpClient.listdir`. `EngineBrowseChannel.listDirectory` also has no
    token or cancellation message. This blocks 09 §3.2–3.3's controller
    wiring: dropping a stale result does not stop the old listing, and
    closing a shared channel would cancel other consumers. Add listing
    cancellation upstream with tests, then bump the pin and bridge a
    request-id-scoped engine cancellation message to each listing's token.
    Local listing cancellation must use the same VFS contract. Preserve
    typed `cancelled` failures, observe late completions, release request
    state on every terminal path, and keep sibling listings alive.
    The ungated pure listing-state reducer landed first; it does not claim
    to cancel I/O. No upstream PR has been opened for this follow-up.
13. **2026-09-12: M3 raw-name metadata before pane browsing ships.**
    The pinned `RemoteFileEntry` exposes decoded name/path only, with no
    raw bytes or invalid-UTF-8 flag. This blocks 02 §13's collision ordering,
    escaped-name disambiguation, and disabled operations on flagged rows.
    The pure sorter orders decoded names only; a path tiebreak cannot
    distinguish two byte names decoded to the same string. Add metadata
    upstream and bridge it through the engine before wiring those pane
    behaviors; preserve the raw-byte tiebreak before the path fallback.
    D25 still defers byte-preserving operations. No local VFS fork or
    replacement interface is authorized by this item.
14. **2026-09-13 — M3: Linux inotify overflow is invisible through
    dart:io (closed by the inotify backend).** The watch
    seam's `LocalDirectoryWatcher` (dated section above) could not
    observe `IN_Q_OVERFLOW` through dart:io: the kernel posts the
    overflow event with watch descriptor −1, which matches no watched
    path in the SDK's event routing, and its decoded mask is 0 — nothing
    reached a Dart listener, so a Linux overflow silently dropped events
    with no signal (verified against Dart 3.13.3
    `runtime/bin/file_system_watcher_linux.cc`). Closed by the Linux
    inotify backend behind the same `LocalWatchBackend` seam (dated
    section above): the backend decodes the raw event stream through a
    helper-isolate `poll` bridge and surfaces the overflow as a backend
    error — the adapter's immediate `lost`. Native failing-first evidence
    and the repaired run are recorded in the dated section.
16. **2026-09-13: M3 Windows watched-root loss (closed by PR #92).**
    The dated section above replaces the original diagnosis with native
    failing-first evidence: populated deletion timed out; empty deletion
    already signalled. The Windows backend now adds parent notifications
    for root renames and event-driven metadata checks for delete-pending
    roots. Native tests cover populated, empty, already-emptied, and
    rename/recreate cases. No skip hides Windows root deletion. Higher
    ancestor invalidation remains item 18; Linux overflow is closed by the
    inotify backend (item 14).
    **History (the pre-#92 diagnosis, superseded):** empty-directory
    root removal was believed unobservable through dart:io
    (delete-pending deferral); the native evidence in #92 showed the
    empty case already signalled and the populated case needed the
    metadata check, not a parent-watch redesign.

15. **2026-09-13: M3 Quick Select performance at pane wiring (#85 review).**
    Each preview folds the immutable row names again, including on mode
    changes. Measure live input over large Unicode listings when the field
    lands; consider caching folded names or matched keys within the session
    if needed. This model slice introduces no UI timing surface. Keep folding
    encapsulated in core rather than exposing a pre-folded-string API before
    the consumer and measurements establish the required contract.

17. **2026-09-13: M3 view preference composition (#89 review).** Before
    pane wiring, measure recency-only writes with 500 saved locations against
    the browse budgets. Reads currently persist touches immediately through
    the asynchronous atomic writer; the future recents debounce/quit-flush
    path (03 §6) may coalesce them if measurements warrant it. No telemetry
    (D19). Also provide an explicit recovery flow for semantically damaged
    view preferences when settings error UI lands: preserve rejected data
    and require deliberate reset rather than silently replacing malformed
    or newer schemas. The store currently reports `FormatException` without
    changing the section; `reset(location)` cannot bypass that validation.

18. **2026-09-13: M3 ancestor invalidation follow-up (OPEN).** PR #93
    corrects an unsupported Windows premise without changing production.
    Native ancestor moves on the tested Windows runner/SDK are refused while
    descendant watches remain live; another supported mechanism would need
    its own permitted-move reproducer before a loss fix is justified.
    **Separate Linux/macOS follow-up:** baseline `7afbefc`, CI `34762015179`,
    misses loss after permitted ancestor renames. Preserve those regressions
    from `archive/task20-ancestor-candidate-6366437` and `tasks/task20-logs/`;
    the recreate case must recreate the full watched path to test masking.
    Address detection without regressing traverse-only ancestor access or
    silently increasing watch resources. No fix or closure is claimed here.
    Keep #92's root-loss/cancellation behavior; Linux overflow is closed
    (item 14).

19. **2026-09-13: Windows incident-store test intermittency (#92 CI).**
    `a declined incident survives a real store round-trip on disk` failed
    on [job 103721821421](
    https://github.com/L-K-M/Poltergeist/actions/runs/34756562117/job/103721821421)
    at `4ef9a03`: disk retained only the first incident until the five-second
    deadline. The same job passed on retry. This test uses the pool directly,
    before the watch tests run; its code is unchanged by #92. A concurrent
    Windows read/replace sharing failure is a hypothesis, not a confirmed
    diagnosis. If it recurs, capture `first.incidentStoreErrors` before
    changing the timeout or persistence behavior.

20. **2026-09-12: M3 pane location identity remains app-side.**
    `lib/services/pane_location.dart` belongs in core (02 §2), but this
    bounded app slice adds no core consumer. Move it when composing view
    preferences or recents; apply NFC and volume-aware case folding before
    equality/keying. Paths currently compare raw strings. Bookmark landing
    paths can contain spelling variants; VFS-derived paths alone do not
    establish canonical equality.
21. **2026-09-14: M3 D12 benchmark jobs remain partially open.** The
    relocation gave the harness its planned home, the offline checker PR
    landed `test/benchmarks/check.dart` + `budgets.json` with all P1–P7
    still unlanded, the P3/P5/P7 tier-A collectors landed under
    `packages/poltergeist_core/benchmark/`, and the tier-A `bench` job
    is on `ci.yml` reusing `run.sh --lifecycle-only` (dated section
    above). Still open: real calibration of the tier-A
    `calibratedScenarioConfig`/`calibratedFingerprint` (a dedicated
    tier-A calibration step; the baseline-refresh procedure covers
    tier B only), landing
    scenarios as their surfaces arrive (`BENCH_ENFORCE_A` from each
    introduction), the drift-state artifact fetch/update wiring
    (`--update-drift-state` requires `--tiers`
    including `b`). The P4 tab-switch suite merged 2026-09-15 with the
    other tier-B xvfb suites (dated section above) — trend-only until
    M9. The tier-B baseline committed 2026-09-15 (dated section above)
    arms fingerprint-drift evaluation on `--tiers ab` runs; P6 has no
    entry yet (its leg has never produced an `ok` row — insufficient
    frame capture under llvmpipe; the harness question is the P6
    owner's). Budgets gate nothing yet.
22. **2026-09-14: M3 D12 P3/P5 budgets unreachable on the CI fixture as
    specified.** The bench job's first real medians (P3 ≈ 4.3–4.6 s,
    P5 ≈ 4.7–4.9 s — the dated analysis section above) are runner/
    fixture reality: ~104 serialized READDIR round trips at ~35–52 ms
    each on the shared-runner Docker-published loopback. 02 §12's
    absolute values (< 50 ms / < 500 ms) assume LAN-class sub-ms round
    trips and cannot be met by construction on this environment — and
    likely not even on a genuine ~1 ms LAN while the VFS listing stays
    sequential (dartssh2 awaits each 100-entry READDIR batch serially;
    OpenSSH's 100-entry reply cap bounds entries per round trip).
    Before any `landed` flip on P3/P5: owner decision between
    recalibrating the budget values against the CI fingerprint (a
    02 §12 plan-level change), reshaping the scenario/config, or an
    upstream pipelined-READDIR change (D2-gated). P7's pass is the same
    bottleneck's ceiling, not health — do not read it as evidence the
    budgets are calibrated.
    **Closed 2026-09-17:** the owner ruled Option 1 (recalibrate to the
    CI-fingerprint reference values, flip tier-A `landed`, enable
    `BENCH_ENFORCE_A`; upstream pipelined READDIR explicitly
    non-blocking). Implemented in the dated section above: P3 < 5 500 ms
    and P5 < 6 000 ms (pooled median × 1.2, rounded up to the next
    500 ms), P7's ≥ 1 000 entries/s unchanged, all three landed with
    per-scenario calibrated configs, and the repo variable plus
    `vars.BENCH_ENFORCE_A` forwarding arm enforcement.

23. **2026-09-19: M4 quit guard is inert in production until queue
    composition lands.** The prevent-close → journal-flush chain (07
    §3.5, this milestone's quit-guard entry above) is fully wired and
    tested, but `main.dart` still boots `PoltergeistApp` with no
    `transferQueue`, so `QuitGuard` always takes the silent-close path
    for real users. When the queue-composition slice lands: wire
    `transferQueue` into `main.dart`'s `PoltergeistApp`, and add a
    boot-path smoke assertion that the production guard sees a live
    queue seam (fail loudly if it is ever constructed with none).
    Separately deferred from the #158 review: a last-resort "Quit
    Anyway" escape hatch on the flush-failure dialog — the current
    design (per the task brief) never destroys over an unflushed
    journal, so a persistently failing disk leaves force-quit as the
    only exit; whether an explicit double-confirmed override is
    acceptable is a product decision for the spec owner.
    **Composition half closed 2026-09-19** (the M5-bridge dated
    section): `main.dart` composes the real journaled queue at
    startup and every consumer — pane drops, activity panel, quit
    guard — shares it; the composition test's delegate-identity
    assertion is the requested boot-path smoke check. The deferred
    "Quit Anyway" decision above is unchanged. **Still open:** remote
    transfers — until the engine protocol grows transfer verbs and an
    engine-hosted queue (or a bridged lease) exists, remote-endpoint
    tasks enqueued through the composed queue fail with a typed
    `unsupported` error instead of running; local↔local work runs
    for real.
24. **2026-09-19: Ctrl+Alt+letter chords collide with AltGr on
    Windows/Linux international layouts (spec decision needed).**
    Windows reports AltGr as Ctrl+Alt, so 02 §8.3's Windows/Linux
    chord column — `Ctrl+Alt+S` sidebar, `Ctrl+Alt+A` activity,
    `Ctrl+Alt+P` preview, `Ctrl+Alt+B` sync browsing, `Ctrl+Alt+N`
    new file, `Ctrl+Alt+E` edit, `Ctrl+Alt+Y` synchronize, and the
    `Ctrl+Alt+←/→` pane-focus pair — also fires on AltGr letters
    that produce text (AltGr+S → ś/ş on Polish and Turkish
    layouts, and so on for the rest of the family). The #162
    review surfaced this on the sidebar chord;
    `pane_commands.dart` documents it at the activator. The
    decision the spec owner needs to make: re-letter §8.3's
    Windows/Linux column off Ctrl+Alt+letter, or suppress
    app-scope activators while a text field holds focus (does not
    help outside fields), or both — possibly per-chord. The M5
    audit records the collision; no chord changed under it.
25. **2026-09-20: Séance v0.9.1 closes the rev-pin bridge and the
    PR-S1 release wait — re-pin to the tag; the shared-mode "Your
    Séance servers" surface is still unbuilt.** Two releases landed
    during M6: `v0.9.0` (2026-09-13) and `v0.9.1` (2026-09-14), both
    containing merge `599ff936` (PR-S1) AND the current pin rev
    `2e6d1f1` (ancestry-verified against the fetched tags). Item 2's
    re-pin is now satisfiable: bump both declarations and the locks
    to `v0.9.1` (D2 steady state), re-diff the PORTS ledger, and
    close item 2. The Design A gate constant already records
    `'v0.9.0'` (verified at its tag tree during #167; #56 stays
    open so the `false` companion boolean and the §4.3 disclosure
    remain correct). The M6 residual: §4.2's "Your Séance servers"
    picker/sidebar section does not exist on HEAD —
    `SeanceServerCatalog` materializes at the service seam (proven
    end-to-end by the audit's shared-mode integration test) but no
    UI renders it, so `serverConfigId` bookmarks cannot yet be
    created and the shared option is honest-but-unproductive until
    that surface lands. The running-patched-Séance + real-SSH legs
    of the §3.7 criterion ride the same follow-up. Deferred per the
    M6 audit task's non-goals (no pin bump, no new features).
    **2026-09-21 — the re-pin half is done:** `ref: v0.9.1` in both
    declarations, `035b0d8` in every lock, audit regenerated and
    matching (M8 dated section; item 2 closed). Still open: the
    shared-mode "Your Séance servers" UI surface and its
    running-patched-Séance/real-SSH QA legs.
    **2026-09-24 — surface + write path landed on
    `feat/seance-catalog-surface`:** the sidebar renders a "Séance
    servers" section (Séance's grouping/filter rules, reachability dots,
    Sync-now button), and `serverConfigId` bookmarks resolve through the
    catalog at open time. Bidirectionality is now the design per the
    2026-09-24 §4.2 amendment (owner directive): `SyncTrackingServerStore`
    (`servers.json`), coordinator `onServerSaved`/`onServerDeleted`/
    `onServerSecretSaved` write paths with prefixless `serverConfig`
    records and tombstones, pulled-`secret` vault apply under the
    exclusion shield + freshness floor, `FileVaultStore` re-key journal
    (enrollment swaps the keystore key without orphaning credentials),
    and a `DynamicSecretVault` seam for prompt/engine consumers.
    **2026-09-24 — the editor half landed:** ported `server_editor.dart`
    (driven by a `ServerEditorDelegate` seam in place of `AppState`),
    the mark/color pickers, `connection_test_report`/`connection_log_view`,
    `badge_image`, and `server_duplication`; `ServerEditorBackend`
    composes the delegate over the backup service, dynamic vault, pin
    store, and identity audit log; catalog rows gain add/edit/duplicate/
    delete verbs (read-only when no backend is wired), deletes
    disconnect live sessions and name managed checkout edits in the
    confirmation. **Review fixes, same day:** server deletes and their
    credential retractions stamp past every version seen (Séance's
    `_deletionStamp`), and credentials sync only behind the device-level
    "Sync saved passwords & keys" switch (Settings → Backup, shared
    mode, off by default — Séance's `syncSecrets`). Still open: the
    running-patched-Séance/real-SSH QA legs.
26. **2026-09-21: M7's native-boundary QA is manual — Quick Look's
    real `QLPreviewPanel` runtime and the engine-driven remote
    checkout path.** The §3.8 audit's criterion 4 is met on the
    CI-provable contract — the `poltergeist/quicklook` channel,
    dispatch decisions, and cache/produce flow are test-covered — but
    no CI runner opens the native panel; the macOS
    open/update/close/hide leg needs a manual pass on a macOS host.
    Likewise, every M7 checkout leg drives the scripted
    `FakeEditorRemoteFs` endpoint; the production engine's remote
    `checkout`/`upload` calls join open item 23's remaining half once
    the engine protocol grows transfer verbs.
27. **2026-09-22: M8 — the rail-5 purge surface is unbuilt.** The
    journal substrate exists (`markPurged`, `hasUnpurgedTrash`, the
    live-trash retention exception in `SyncRunJournal.prune`, the §9
    `trashCache` model), but nothing produces a purge: no plan-view
    age-notice chip (`N trashed files from M runs older than 30 days`),
    no `sync.purgeTrash` command, no confirm dialog stating the
    cross-pair scope and the undo forfeit, no
    own-prefix/foreign-prefix runId classification, no
    absent-directory `purged: true` marking, no in-flight-run
    exclusion. Until this lands, `.poltergeist-trash/<runId>`
    directories and their guarding journals accumulate forever —
    `Restore Trashed Files…` keeps working, but nothing ever releases
    them. Spec: 05 §8 rail 5 (1096–1179); the surface is feature-sized
    and was deferred at audit close rather than rushed.
28. **2026-09-22: M8 — the rail-5 docroot warning chip is unbuilt.**
    05 §8 (1083–1095) requires a warning — in the pair editor AND as a
    persistent plan-view chip — when in-root trash will sit under a
    path that looks like an HTTP docroot (`public_html`, `www`,
    `htdocs`, `/var/www`), with a one-click out-of-root suggestion
    (`~/.poltergeist-trash/<root-slug>`; ad-hoc pairs route through
    rail 4's save-and-edit pattern). Neither surface exists: a
    `Blog → webserver` pair's overwritten secrets sit web-retrievable
    with no notice. Deferred with item 27's purge work — the chip's
    action shares the same editor-focus machinery.
29. **2026-09-22: M8 — rail 6's run-startup temp sweep and rail 8's
    resume post-state rule are unbuilt.** §8 rail 6 asks each run to
    sweep orphaned `.poltergeist-*.tmp` (and the adapter's
    `.seance-upload-*.tmp`) siblings older than the longest plausible
    prior run — the transfer queue sweeps its own destinations but no
    sync-side sweep exists. Rail 8's committed-but-unjournaled rule
    (a resumed item whose destination matches the intended post-state
    journals done rather than conflicting, with the sizeOnly-path
    signature for setstat-ignoring servers) has no entry point: no
    `resume(journal)` API exists on `SyncExecutor` — connection loss
    fails the affected item and `Retry Failed` (re-stat + attempt n+1)
    is the shipped recovery. Both are recorded residuals; the
    §11/§8-matrix language that presumes a resume leg should be read
    against this item.
30. **2026-09-22: M8 — D28 chown UI deferred to M9.** The §3.9
    criterion's conditional arm is active — the merged Séance pin
    `v0.9.1` carries `RemoteFileSystem.setOwner` — but no chown
    surface exists on HEAD (the permissions editor covers mode only;
    no `setOwner` wiring anywhere in the app). Deferred per the audit
    task's close-scope rule and D28's own "ships with M8/M9" wording:
    uid/gid editing needs ownership-semantics UI decisions (numeric vs
    name resolution, per-platform legality, failure surfacing) that
    belong to a feature slice, not an audit patch. The pin capability
    is already proven by the pin itself; the work is UI + wiring.
    **2026-09-22 update (M9 close):** still unlanded, and now
    unscheduled — §3.10's M9 scope never contained it, so the deferral
    target passed without the work. Closing M9 does not resolve D28;
    disposition (v1.x vs a scoped slice) is an owner/plan decision.
31. **2026-09-22: M9 — `BENCH_ENFORCE_B` arming tail (supervisor-owned).**
    The flip's code is on main (#185): `budgets.json` marks P1/P2/P4
    landed, `ci.yml` forwards `vars.BENCH_ENFORCE_B`, the drift-state
    store and rerun-before-red are wired. The repo variable itself is
    deliberately unset: the post-#185 main runs seeded the drift store
    while measuring on the pre-rotation image
    (`ubuntu-latest@20260907.300.1` vs the committed `20260920.314.1`),
    so `tier-b/controlled/runnerImage` stands at 8 consecutive main runs
    (≥ the 7-run stale threshold). Arming before a fully clean main run
    lands — matching image *and* baseline CPU (`AMD EPYC 7763`) — reds
    main on the stale streak. Until then tier-A enforcement is also
    inert (drift-skipped; the bench job annotates this). Supervisor
    dispatch runs 35781589991 (completed soft) and 35782936812 (pending
    at audit time) are the apparent seeding attempts; the merge run and
    the completed dispatch both drew the old image, while the pending
    run's image was unknown at audit time. Do not flip until the store
    shows a clean committed-fingerprint observation.
32. **2026-09-22: M9 — human-only QA residual.** Everything automation
    cannot see is collected in
    [`docs/qa/RELEASE-CHECKLIST.md`](qa/RELEASE-CHECKLIST.md): native
    screen-reader walkthroughs (VoiceOver/NVDA — honestly unrun, per
    `docs/qa/screen-reader-notes.md`), native chrome and dialogs, scroll
    feel, macOS Quick Look on real hardware, and real-IME entry. First
    fill is due with the v1.0 release PR.

## Independent audit

- **Scope (2026-09-04):** merged #9, #10, #12, #13, #14 and Séance #62;
  release/version wiring, pinned VFS/auth code, pool lifetimes, PORTS, STATUS,
  and M0 evidence. This audit started no new milestone feature or release.
- **Validation:** existing tool/fixture tests (228), bench tests (73), and
  Flutter tests (108) pass. Core regression results accompany each repair
  below. The 78-row committed M0 bundle revalidates; the license gate reports
  two declarations, one Unlicense-bearing revision; the pin audit matches
  PORTS. No Séance release tag yet contains PR-S3.
- **Limits:** Docker is unavailable locally; real-sshd tests and native
  install QA were not rerun. Frozen M0 evidence was validated, not remeasured.
  PR #15 was neither edited nor reviewed by this audit.
- **Record corrections:** PR-S3's pin gate is satisfied, the atomic-file
  ports already exist, and M2's bookmark/vault work is explicitly open.
  Chapter 04's pre-license publication exception is removed to match D30.
  Chapters 08/09 no longer claim `dart analyze` accepts only one root;
  multiple explicit roots were verified with Dart 3.12.0 and 3.13.2.

## Audit repairs

- **2026-09-07 — stale recovery home failures.** A replacement transport
  can die while its home canonicalization is pending. Its late error now
  rechecks the recovery cycle and acquired handle before classifying a
  permanent pane failure. The pane survives for the next backoff attempt;
  errors from a live handle retain the existing pane-only failure behavior.
  The regression failed before the guard and passes after it.
  Review added a failing regression for a disconnected home operation whose
  transport's completion notification lags. Transport death is recorded before
  the new guards, preserving retirement and the next retry's handle replacement.
  A second regression covers permission denial with that lag: observing a closed
  transport retires all its bindings, so both panes rebind on the next retry.
  Core analysis and 224 tests pass (one existing fixture skip); Flutter
  analysis and 121 tests pass. Import and protocol guards pass.
  No milestone-close claim; production wiring and real-sshd coverage remain
  open.

- **2026-09-06 — deterministic benchmark timeout test.** The transfer
  timeout test now withholds the completion sentinel behind an explicit
  release gate and always closes its session through test teardown. A
  temporary delayed-flush reproducer made the old test fail by delivering
  the sentinel before timeout installation. The repaired harness passes
  all 77 tests (one existing sshd-fixture skip), with clean analysis.
  Production timeout behavior, evidence, pins, and ports are unchanged.

- **2026-09-06 — resolver-prompt dismissal.** Credential resolution now
  carries a `CredentialResolutionScope` (03 §3.2 precision edit in the
  same PR): the manager registers each first-connect resolution's scope
  on its pool and trips it when the last serverId disconnects
  mid-resolution — the only pool-lifetime end that can race a
  resolution. A prompt-owning resolver observes `dismissed`, closes its
  dialog, and fails the resolution; folded first-connect callers fail
  disconnected without a user answer; sibling references keep the prompt
  alive; failed resolutions hand their retry a fresh scope; completed
  resolutions are never dismissed — including when the last reference
  disconnects mid-handshake, after the resolution returned (the scope
  retires at resolution completion; review round 1 caught it armed
  through the handshake); a dismissal racing the answer in the same
  microtask turn is documented at pool-observation granularity and
  regression-pinned as tolerated (round 2); replacement sessions
  resolve afresh without waiting on the abandoned future. Eight
  regressions failed before the seam existed (the scope type did not
  compile) and pass after. Core analysis is clean; 134 tests pass (one
  fixture skip). The engine-protocol half (03 §5) remains with that
  slice.
- **2026-09-06 — pinned dependency contracts.** Seven core tests cover
  HKDF salt domains with empty info, Argon2 KiB units, both sealed-blob
  layout directions, and RegExp flag behavior. Independent known answers
  prevent matching encoder/decoder drift from passing. Four harness tests
  verify actual SSH host-key callback bytes through a signed in-memory
  handshake and bind the exercised cryptography/dartssh2 versions to both
  workspace and app locks (the app resolves separately). Review fixed the
  lock lookup's working-directory dependency: the
  root-launched test failed before and passes after URI anchoring. Raw SSH
  stays in the sanctioned harness. Immediate client close also failed before
  and passes after guarding the peer's buffered writes; missing lock entries
  now produce matcher diagnostics. Ordinary CI runs all eleven tests.
  Core analysis and 99 tests pass; harness analysis and 77 tests pass, each
  suite with one existing sshd-fixture skip. Import and release-version
  guards pass. No dependency versions, pins, or production behavior change.
  Chapter 09 corrects obsolete HKDF-info and keyboard-interactive export
  claims against the locked APIs. Other M2 gates remain open.

- **2026-09-06 — credential lifetime and prompt provenance.** Config lookup
  now precedes pool lookup without resolving secrets. The serialized first
  connect resolves credentials once per pool; server references retain config
  only. Pane/lease teardown and failed first connects require fresh resolution.
  Explicit resolver prompt provenance caps growth even when SSH reports
  `storedPassword`. Late resolution cannot revive a disconnected pool;
  a surviving sibling keeps its pending resolution and active credentials.
  Fresh attempts discard credentials left by dead-slot eviction before
  resolving, preventing concurrent growth from borrowing that stale secret.
  Seven regressions failed before their repairs; 13 credential tests and all
  92 core tests pass (one fixture skip), with clean core analysis. Chapter 03
  clarifies the resolution boundary and teardown lifetime. This closes
  item 5's credential gap; items 4 and 6 still gate production integration.

- **2026-09-06 — dependency boundaries.** Replaced the import guard's grep
  scan with parsed Dart directives and resolved pubspec checks. Conditional
  imports/exports, escaped literals, plugin metadata, runtime dependency
  chains, unused declarations, and local overrides are checked. External
  development dependencies do not classify a pure library as Flutter.
  Missing/malformed metadata and linked scan inputs fail closed; generated
  Apple `Pods` trees are excluded. Review added explicit diagnostics for
  unresolved Flutter SDK imports, interpolated directives, and missing
  package configuration. Output exclusions are scoped to project/native
  output locations; similarly named source folders remain scanned. Empty
  package URIs and malformed pubspecs produce specific diagnostics. SSH
  fixtures use their own metadata; linked scan roots are rejected too.
  Forty-one regressions failed before their repairs; 92 guard tests and
  the real repository scan pass. CI analyzes and tests the guard first.
  Dependency versions and Séance pins are unchanged. This closes item 5's import-guard
  gap; dependency-contract tests and item 4's ordering escalation remain.

- **2026-09-05 — bounded teardown.** Pool cleanup and SSH/SFTP wrappers use
  the pinned cleanup helper with a five-second bound per close. Detached
  channels close concurrently, then transports, so stalls cannot serialize
  the grace period across every resource (two phases, ten seconds total).
  Failed-open cleanup retains any shorter caller timeout. Seven pool regressions
  failed before and pass after the repair (`pool_teardown_test.dart`): disconnect,
  sibling preservation, pane lifetime, changed-key blocking, stale connects,
  and late channel cleanup; late close errors remain observed. The shorter
  timeout regression also failed before repair; `ssh_cleanup_test.dart`
  checks shorter/longer budgets and prompt completion on success and errors.
  Cleanup errors, including `Error` subtypes, cannot replace the operation's
  outcome. Core analysis is clean; 79 tests pass with one fixture skip.
  This closes item 5's bounded teardown gap; real-sshd coverage and item 4's
  ordering escalation remain open.

- **2026-09-05 — live state fan-out.** Existing watchers now receive the
  current state when their serverId joins a shared pool, including connects
  in flight and blocked transfer joins. Siblings receive no duplicate join
  event. Five regressions failed before and pass after the repair
  (`pool_state_test.dart`), including failed-connect and disconnect/rejoin
  coverage. Core analysis is clean; 67 tests pass with one fixture skip.
  Disconnecting a blocked joiner leaves its sibling blocked. This repairs existing code;
  item 4's milestone-order escalation remains open.

- **2026-09-04 — channel ownership (PR #16).** Pane views own a specific
  binding; stale closes cannot remove a replacement, even when it shares the same SFTP
  channel. Lease release is borrower-scoped, so a delayed second release
  cannot free another worker's lease. Four regressions failed before the fix
  and pass afterward (`channel_ownership_test.dart`).

- **2026-09-04–05 — changed-key review (PR #18).** Workers cannot review an
  existing or inherited block; fresh first connects may still prompt (D5).
  Credential-free incidents outlive retired pools. Current approval clears
  before auth, so auth failure cannot strand an approved key. Stale replies
  cannot pin or clear replacement incidents. Trusted-key returns stay blocked;
  live watchers see the inherited block during review. Deleted pins cannot
  enable first-use approval under a block. Trust epochs reject old growth
  handshakes, verdicts, and auth results; growth also respects a newer
  interactive-auth cap. Thirteen regressions failed before and pass after
  the repair (`pool_trust_test.dart`), with additional coverage for current
  approval and fresh-transfer prompting.

- **2026-09-04 — channel waiters.** The first browse binding now wakes
  queued browse requests through LRU sharing, even behind transfer waiters.
  A server rejecting every SFTP open fails requests with the typed open error
  instead of waiting for an impossible release. Error provenance stays with
  its live transport; recovery, teardown, or eviction cannot leave a stale
  pool-wide classification. Release pumps also try every available transport
  and fail impossible waits. Eight regressions
  failed before and pass after the repair (`channel_waiters_test.dart`); 03 §3.2
  clarifies capacity exhaustion versus unavailable SFTP. Transfer refusal
  and reconnect after refusal have additional coverage.

- **2026-09-04 — acquisition lifecycle.** Disconnect invalidates pending
  resolver identities and rejects late browse/transfer acquisitions, including
  when a sibling keeps the pool alive. A new session cannot join an abandoned
  first connect. Pending acquisitions hold pane-lifetime teardown until they
  bind or fail. Cleanup failures preserve the acquisition error. Seven
  regressions failed before and pass after the repair
  (`pool_lifecycle_test.dart`). This supplies new evidence against PR #14's
  round-2 decline of post-await reference checks; transfer revival belongs to
  the future queue, not an untracked lease for a disconnected serverId.

## Housekeeping

- **2026-09-09 — review tooling:** this session lacks
  `subscribe_pr_activity` / `send_later`; GitHub polling and an hourly
  Paseo heartbeat cover PR monitoring, with heartbeat deletion on completion.
- No server component is planned: bookmark backup uses Séance's sync server
  (E2E-encrypted blobs). Poltergeist's release ships client artifacts only.
- `media-sources/icon.png` (the master icon since 2026-09-24; the original
  minimal `poltergeist-icon.png` stays in the tree) was created together
  with the app scaffold; `scripts/package-linux.sh` requires it.
