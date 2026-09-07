# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) for build/test commands and
[09-PLAYBOOK.md](plan/09-PLAYBOOK.md) for the PR process.

_Last updated: 2026-09-08 — M2 adds real-sshd pool integration coverage
and its ordinary CI job (validation below). M2's prompt dialogs, coordinator,
live connect transcript, state-associated failure details, and independent
terminal-recovery diagnostics are implemented. Recovery ignores stale home
failures from dead transports. Bounded engine progress coalescing, pooled
reconnect recovery, pool keepalive wiring, and the engine isolate +
`EngineClient` connection/prompt protocol are implemented; upstream keepalive
controls are pinned. Production wiring (app composition) remains open.
M0 is complete; M1 is closed: the
scaffold, deterministic release versions, the D23 direct-publish release
pipeline (#15), and the v0.1.0 pre-release publish are done, and 05's two
dated precision items (D6 exporter note, D15 rail-5 alignment) are closed;
the Séance pin is upstream main (`a9add15`, keepalive controls, post PR-S3).
M2 is the active milestone: the initial pooled `ConnectionManager`,
dependency-contract upgrade guards, extra-transport idle teardown, and
resolver-prompt dismissal are in; the bookmark-model + vault/store-plumbing
slice is in (see the Done table); open items 3–6 track remaining
slices, audit gaps, and decisions._

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Product identity constants plus the connection layer's first slice: the Séance git pin (upstream `a9add15`), `PoolPolicy` (D9's frozen numbers, test-pinned), the endpoint-keyed `PooledConnectionManager` with the 03 §3.2 growth rules (serialized first connect + single TOFU prompt, interactive-auth single-transport cap, prompting-disabled growth with auth-challenge fallback to sharing, on-demand transports, LRU browse sharing at exhaustion, refcounted shared pools, pane-lifetime teardown), the changed-key hard block with its one prompt-cleared re-pin path, and the `scripts/check-imports.sh` CI guard for the 03 §1 dartssh2 boundary. Connection suites run socket-free per 08 §3.2. This is an initial slice, not M2 completion; audit follow-ups remain in open item 5. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |
| Séance pin | Upstream `L-K-M/Seance@a9add15` (main, keepalive-controls merge, post PR-S3) — the M0 fork bridge (`BigBoyDevBox/Seance@0a69597`) is retired; the bench harness's `computeHash` calls now resolve against upstream, its test suite passes on the new pin, and the PORTS.md audit record is regenerated. Committed-bundle validation now binds to the pins M0 actually measured instead of the live pin, so future re-pins cannot invalidate frozen evidence. Ported `atomic_file` sources re-diffed clean through the new pin. |
| Séance PR-S0 | LICENSE audit and Unlicense grant merged in [Séance #57](https://github.com/L-K-M/Seance/pull/57), merge `4d8ee1e026ce4e5d939d6390d9fd98a78fabcf6e`. |
| Séance PR-S1 | Record-kind forward compatibility merged in [Séance #58](https://github.com/L-K-M/Seance/pull/58), merge `599ff936b8222e6cd77920495dcdcc4a50643f44`. A release is still required before M6 Design A. |
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
landed together (engine protocol v3). Engine side: `watchServer` now
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
is new. Same-PR 03 §3.2/§5 precision edits record both.

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
rotation, and panel lifecycle. After reconciliation with PR #39: core
analysis and 240 tests pass (one sshd
fixture skip); app analysis and 186 tests pass; protocol guard (49), import
guard (92), and pin audit pass. UI surfaces remain uncomposed, so screenshots
ride the wiring slice that first renders them. `posix` 6.5.2 moved from a
transitive to direct app dependency without changing resolution; no Séance
pin change or milestone-close claim. Real-sshd transcript/keepalive legs
remain with the 08 §5 matrix (open item 3).

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
dependency change, or milestone close. Interactive-auth/TOFU integration and
M4's mid-transfer queue recovery remain separate exit criteria.

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

## Open items

1. **M3 — OS Dart client matrix.** Deliberately deferred until M3, when
   `LocalFileSystem` lands; this is not an M1 closure claim.
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
   retired (see the Done table) and the pin sits at upstream main
   `a9add15` — no Séance tag contains the keepalive-controls merge yet. `poltergeist_core` now carries the
   same rev pin (first workspace-package pin; the M0 bench pin set is
   unchanged, and the pin audit record still matches). When Séance cuts its
   next release (the same S1 release the M6 Design A gate needs), re-pin
   both declarations to that tag (D2's steady state) and drop the rev pins.
   Tag S1 before M6 Design A.
3. **2026-09-04 — M2 remaining slices.** The initial pool, TOFU gate, and
   channel budgets are in. Still open, in
   roughly this order, subject to open item 4:
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
   - `ProbeService` wiring + interim server list status dots;
   - ssh_config import with preview + dedupe (D22);
   - the debug-only connect → SFTP → `listDirectory` demo surface;
   - Docker-integration pool coverage (growth, keepalive, reconnect against
     real sshd) lands in the 2026-09-08 slice above. Interactive-auth/TOFU
     flows and M4's mid-transfer queue recovery retain their own gates.

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
   - **2026-09-07 — prompt/audit port-backs:** the pinned Séance responder
     drops RFC 4256's per-prompt echo bit before the engine protocol sees it;
     fields therefore start masked with explicit reveal. Preserve the bit when
     upstream exposes it. Route guards, malformed-line handling, and owner-only
     audit storage also remain PORTS-led upstream candidates. None blocks the
     safe local behavior or production wiring.
   - **2026-09-05 — optional cleanup diagnostics (review follow-up):**
     consider an upstream observer if real-sshd debugging needs cleanup
     failures. The pinned helper's ignore mode exposes no observer. This
     does not block the teardown repair or change error preservation.
   - **Dependency-contract coverage (updated 2026-09-06):** 09 §5's
     upgrade guards are covered below. Hash-off second-preflight/CAS coverage
     remains absent from the inspected Séance #62 adapter tests; those tests
     stay upstream (08 §2). This is a test gap, not an observed VFS failure.

6. **2026-09-05 — escalation: trust-incident recovery (D18).** Unresolved
   incidents now survive disconnect, but not process restart. A returning
   trusted key remains blocked; it produces no changed-key verdict for the
   current review callback. The manager also has no bookmark-removal signal.
   Before production integration, the owner must choose restored-key
   review/removal behavior and whether incidents persist across restarts.
7. **2026-09-08 — CI/fixture hardening suggestions (#41 review).** Evaluate
   consistent `pub get --enforce-lockfile` use across CI and commit-SHA
   pinning for third-party actions. The new integration job follows existing
   resolution/action conventions; the Séance audit separately checks manifest
   and lock pins. Also consider checking retained fixture account UIDs before
   supporting modified base images; current restart tests reuse accounts
   created by the same entrypoint in digest-pinned containers.
   No offline-review path, removal API, or new store/schema is added here.

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

- No server component is planned: bookmark backup uses Séance's sync server
  (E2E-encrypted blobs). Poltergeist's release ships client artifacts only.
- `media-sources/poltergeist-icon.png` (the master icon) is created together
  with the app scaffold; `scripts/package-linux.sh` requires it.
