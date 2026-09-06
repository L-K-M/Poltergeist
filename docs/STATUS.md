# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) for build/test commands and
[09-PLAYBOOK.md](plan/09-PLAYBOOK.md) for the PR process.

_Last updated: 2026-09-07 — M0 is complete; M1 is closed: the
scaffold, deterministic release versions, the D23 direct-publish release
pipeline (#15), and the v0.1.0 pre-release publish are done, and 05's two
dated precision items (D6 exporter note, D15 rail-5 alignment) are closed;
the Séance fork pin is retired onto upstream main (`2f99f4e`, post PR-S3).
M2 is the active milestone: the initial pooled `ConnectionManager`,
dependency-contract upgrade guards, extra-transport idle teardown, and
resolver-prompt dismissal are in; the bookmark-model + vault/store-plumbing
slice is in (see the Done table); open items 3–6 track remaining
slices, audit gaps, and decisions._

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Product identity constants plus the connection layer's first slice: the Séance git pin (upstream `2f99f4e`), `PoolPolicy` (D9's frozen numbers, test-pinned), the endpoint-keyed `PooledConnectionManager` with the 03 §3.2 growth rules (serialized first connect + single TOFU prompt, interactive-auth single-transport cap, prompting-disabled growth with auth-challenge fallback to sharing, on-demand transports, LRU browse sharing at exhaustion, refcounted shared pools, pane-lifetime teardown), the changed-key hard block with its one prompt-cleared re-pin path, and the `scripts/check-imports.sh` CI guard for the 03 §1 dartssh2 boundary. Connection suites run socket-free per 08 §3.2. This is an initial slice, not M2 completion; audit follow-ups remain in open item 5. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |
| Séance pin | Upstream `L-K-M/Seance@2f99f4e` (main, PR-S3 merge) — the M0 fork bridge (`BigBoyDevBox/Seance@0a69597`) is retired; the bench harness's `computeHash` calls now resolve against upstream, its test suite passes on the new pin, and the PORTS.md audit record is regenerated. Committed-bundle validation now binds to the pins M0 actually measured instead of the live pin, so future re-pins cannot invalidate frozen evidence. Ported `atomic_file` sources re-diffed clean through the new pin. |
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

## Open items

1. **M3 — OS Dart client matrix.** Deliberately deferred until M3, when
   `LocalFileSystem` lands; this is not an M1 closure claim.
2. **Séance pin: flip to the next tag.** The fork bridge is retired (see
   the Done table) and the pin sits at upstream main `2f99f4e` — no Séance
   tag contains the PR-S3 merge yet. `poltergeist_core` now carries the
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
   - keepalive pings and auto-reconnect
     with backoff + downward-only jitter (03 §3.3; `PoolPolicy` constants
     are already defined), incl. the 08 §3.2 backoff-sequence tests;
   - engine isolate + `EngineClient` + the typed port protocol (03 §5),
     incl. the protocol round-trip and coalescing tests;
   - prompt UI (host-key dialogs, keyboard-interactive, credential prompt,
     live `SshConnectionLog` transcript) over the protocol — this slice also
     owns rendering the ported keystore/vault exception messages through ARB
     (D20) rather than raw port text;
   - `ProbeService` wiring + interim server list status dots;
   - ssh_config import with preview + dedupe (D22);
   - the debug-only connect → SFTP → `listDirectory` demo surface;
   - then the Docker-integration legs of 08 §5's pool suite (growth,
     keepalive, reconnect against real sshd) — the matrix exists from M0.

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
     (regressions: `pool_resolution_dismissal_test.dart`). Remaining:
     carry cancellation through the engine protocol (03 §5) when that
     slice lands.
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
