# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) for build/test commands and
[09-PLAYBOOK.md](plan/09-PLAYBOOK.md) for the PR process.

_Last updated: 2026-09-10. The Alpine iproute2 apk pin in the sshd
fixture is bumped to `7.2.0-r0` after upstream rotation broke main's
SSH-integration leg, with a fixture-tool pin regression (dated section
below). The debug-only demo surface now composes the
existing connection slices into the running app for the first time — engine
spawn, EngineClient, the pool, the three prompt dialogs, the live transcript,
and a connect → SFTP → listDirectory flow behind a kDebugMode-gated entry
(dated section below). The app-side probe controller now enforces
favorite eligibility and lifecycle/settings policy through the engine port
(dated section below). Persistence, lifecycle forwarding, list dots,
startup composition, and probe/pin persistence remain open. The host-key
dialog's scrollable review content
is ported back to Séance ([Séance #83](https://github.com/L-K-M/Seance/pull/83),
dated section below), closing the two scrollable host_key candidates (the
mounted-harness candidate stays open). The prompt
dialogs' current-route action
guards are ported back to Séance ([Séance #82](https://github.com/L-K-M/Seance/pull/82),
dated section below) and the four dialog PORTS entries are corrected
against a fresh upstream re-diff; engine-side probe control and status
events are implemented (dated section below); interim list dots and app
composition remain open. The Séance pin is bumped to upstream main
`2e6d1f1` (Séance #81's merge — containing #79's probe-lifecycle repair
and #80/#81's audit work) in both declarations and all three locks; the
pool's live transcript bridge now forwards upstream-redacted records
instead of the raw argument (dated section below), and the PORTS/pin-audit
record is refreshed at the new pin. Séance's identity-audit read-side
repair gate is mirrored locally with its durable procfs regressions
([PR #52](https://github.com/L-K-M/Poltergeist/pull/52); open item 5's
gate-mirror candidate closed). The port-backs themselves merged as
Séance #80/#81. Probe lifecycle
repair is in the pin; app-side `ProbeService` consumers remain open (item 3).
The ssh_config
import preview/dedupe slice
(D22) landed as a bounded, unwired component (dated section below,
including its post-merge host-alias whitespace-parity correction), and
keyswap cleanup now retries after partial swap/restoration failures
(closed in open item 7). Before that: the real-sshd auth-failure-summary coverage
(rejected key, method-not-accepted user, root prohibit-password) landed
(validation below). PR #42 added real-sshd interactive-auth/TOFU coverage,
and shared-decision/explicit-review TOFU tests landed below; merged PR #41
added real-sshd pool integration coverage and its ordinary CI job. M2's
prompt dialogs,
coordinator, live connect transcript, state-associated failure details, and independent
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
| `poltergeist_core` | Product identity constants plus the connection layer's first slice: the Séance git pin (upstream `2e6d1f1`), `PoolPolicy` (D9's frozen numbers, test-pinned), the endpoint-keyed `PooledConnectionManager` with the 03 §3.2 growth rules (serialized first connect + single TOFU prompt, interactive-auth single-transport cap, prompting-disabled growth with auth-challenge fallback to sharing, on-demand transports, LRU browse sharing at exhaustion, refcounted shared pools, pane-lifetime teardown), the changed-key hard block with its one prompt-cleared re-pin path, and the `scripts/check-imports.sh` CI guard for the 03 §1 dartssh2 boundary. Connection suites run socket-free per 08 §3.2. This is an initial slice, not M2 completion; audit follow-ups remain in open item 5. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |
| Séance pin | Upstream `L-K-M/Seance@2e6d1f1` (main, Séance #81 merge — contains #79's probe-lifecycle repair, #80/#81's audit work, and #74's SSH-trace redaction) — still a commit-rev bridge: no Séance tag contains #79 (all eleven tags checked by ancestry), so open item 2 keeps owning the next-tag re-pin. Both declarations and all three locks moved together; nothing else in the locks drifted (dartssh2 sha-identical at 3.0.2). The M0 fork bridge (`BigBoyDevBox/Seance@0a69597`) is retired; the bench harness's live-revision constant follows the pin while committed-bundle validation keeps binding to the pins M0 actually measured, so frozen evidence is unaffected. Ported sources re-diffed at the new pin with dated dispositions in PORTS.md; the full ancestor/tree/license/identity audit is regenerated. The pool's transcript bridge now forwards the upstream-redacted record (see the dated section). |
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
     the ARB-complete preview dialog landed; composition, persistence,
     and command registration remain unwired as recorded there;
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
   Remaining: the engine-protocol bridging (incident seeding at spawn, an
   incident-change event for app-side persistence, and the
   `removeBookmark` request crossing) rides production wiring (item 3) —
   no app-side bookmark deletion exists before M5's store, and the
   manager-side seam and cascade are complete and tested.
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
- `media-sources/poltergeist-icon.png` (the master icon) is created together
  with the app scaffold; `scripts/package-linux.sh` requires it.
