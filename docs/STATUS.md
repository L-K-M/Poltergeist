# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) for build/test commands and
[09-PLAYBOOK.md](plan/09-PLAYBOOK.md) for the PR process.

_Last updated: 2026-09-04 — M0 is complete; the M1 scaffold, deterministic
release versions, and the D23 release pipeline are implemented, and 05's two
dated precision items (D6 exporter note, D15 rail-5 alignment) are closed;
the Séance fork pin is retired onto upstream main (`2f99f4e`, post PR-S3);
M1 remains open pending the owner-signed v0.1.0 rehearsal (open item 1), and
M2 has started: the initial pooled `ConnectionManager` is in; open items
4–7 track remaining slices, audit gaps, and decisions._

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Product identity constants plus the connection layer's first slice: the Séance git pin (upstream `2f99f4e`), `PoolPolicy` (D9's frozen numbers, test-pinned), the endpoint-keyed `PooledConnectionManager` with the 03 §3.2 growth rules (serialized first connect + single TOFU prompt, interactive-auth single-transport cap, prompting-disabled growth with auth-challenge fallback to sharing, on-demand transports, LRU browse sharing at exhaustion, refcounted shared pools, pane-lifetime teardown), the changed-key hard block with its one prompt-cleared re-pin path, and the `scripts/check-imports.sh` CI guard for the 03 §1 dartssh2 boundary. Connection suites run socket-free per 08 §3.2. This is an initial slice, not M2 completion; audit follow-ups remain in open item 6. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |
| Séance pin | Upstream `L-K-M/Seance@2f99f4e` (main, PR-S3 merge) — the M0 fork bridge (`BigBoyDevBox/Seance@0a69597`) is retired; the bench harness's `computeHash` calls now resolve against upstream, its test suite passes on the new pin, and the PORTS.md audit record is regenerated. Committed-bundle validation now binds to the pins M0 actually measured instead of the live pin, so future re-pins cannot invalidate frozen evidence. Ported `atomic_file` sources re-diffed clean through the new pin. |
| Séance PR-S0 | LICENSE audit and Unlicense grant merged in [Séance #57](https://github.com/L-K-M/Seance/pull/57), merge `4d8ee1e026ce4e5d939d6390d9fd98a78fabcf6e`. |
| Séance PR-S1 | Record-kind forward compatibility merged in [Séance #58](https://github.com/L-K-M/Seance/pull/58), merge `599ff936b8222e6cd77920495dcdcc4a50643f44`. A release is still required before M6 Design A. |
| Séance cancellation cleanup | dartssh2 3.0.2 and bounded asynchronous SSH teardown merged in [Séance #59](https://github.com/L-K-M/Seance/pull/59), merge `da9d45492ac7d25cbc4eefb97a6ec29254de219f`. |
| Séance PR-S2 | `openAuthenticatedClient` split merged in [Séance #61](https://github.com/L-K-M/Seance/pull/61), merge `dad6d4f66dbfba6c170b98c204980e5801a890cb`. |
| Séance PR-S3 | `RemoteFileSystem` additions (`setTimes`, `setOwner`, opt-out `computeHash` on transfers) merged in [Séance #62](https://github.com/L-K-M/Seance/pull/62), merge `2f99f4efb25a83340605464635bdf0f3ba95d931`. The upstream-and-pin gate is satisfied by #13 (bench) and #14 (core); remote sync, chown UI, and bulk verification remain future milestone work. |
| M0 — engine fitness | Complete from workflow-dispatch run [`33563514640`](https://github.com/L-K-M/Poltergeist/actions/runs/33563514640), attempt 1, measured commit `6b8873eafdaaa3a4157e265dee838ab3b47219b3`. The 78-row canonical bundle is committed at [`docs/evidence/m0`](evidence/m0); `m0-evidence.json` SHA-256 is `b93660b9f1c06bac206096d25c6fff472bcb31d13589a4d81bd5a3df70fa7fcc`. D7 is final: managed checkouts always hash; bulk transfers and sync hashing are opt-in. D8 passed every isolate gate, so sockets, SFTP, transfers, and hashing stay in the engine isolate. D9 adopts dartssh2 3.0.2 at ladder rung 4: document the roughly 10–11× single-file LAN ceiling versus OpenSSH, compensate with bounded channels/transports, and do not adopt libssh2. `PoolPolicy` is finalized at 2 transports, 4 transfer channels per transport, 8 total channels per transport, 6 global in-flight transfers, and remote readdir depth 8. Keepalive remains 30 seconds, extra idle 60 seconds, reconnect cap 30 seconds, and retry limit 5; these are retained design defaults, not M0-tuned values. Earlier runs `33458209337`, `33481554062`, and `33504660759` were partial; `33534298280` stopped in preflight; `33535334440` diagnosed dartssh2 2.22.0's detached cancellation error. None is admissible evidence. M0 closes untagged. |
| M1 — app scaffold implementation | Implemented in [PR #8](https://github.com/L-K-M/Poltergeist/pull/8) with Flutter 3.47.2, exact dependency pins, generated platform icons from the 1024×1024 master, and the verified platform identity contract. Flutter analysis, 108 tests, and all five client builds pass; see the [PR checks](https://github.com/L-K-M/Poltergeist/pull/8/checks). M1 is not closed: the v0.1.0 rehearsal remains. |
| M1 — release versions | Release versions accept canonical `X.Y.Z` only, derive ordered Android codes, keep every versioned pubspec plus the app lock, Apple metadata, and README synchronized, and gate CI and release tags against drift or downgrade. Stable-only is the selected 07 §3.12 rule; suffixed releases are unsupported. The app starts at `0.1.0+10099`; CI verifies that code in the built APK, while Apple and Windows use bounded semantic mappings. |
| M1 — release pipeline (D23) | `release.yml` never publishes on its own: client builds attach to a draft release (created once — a release-existence guard refuses updates, and the concurrency group is keyed on the tag so a tag push and a dispatch can never race it), a sums job attaches `SHA256SUMS` and writes the same sums plus the unsupported-platform labels into the notes, enforcing the rehearsal floor (APK + Linux set) before certifying anything. The iOS IPA is zipped out of the `--no-codesign` `.xcarchive` (`flutter build ipa`, ci.yml in lockstep). The Debian copyright file embeds the verbatim Unlicense, and Depends floors map ABI symbol tags to Debian package versions (a raw `GLIBCXX_3.4.30` floor is unsatisfiable under dpkg's ordering — the previous shape would not install). `scripts/release.sh` requires a signed tag (`RELEASE_SIGN_TAG=required`); the maintainer's draft-to-published dance lives in [`docs/RELEASE.md`](RELEASE.md). |
| Plan precision patches | Closed the two dated 05 items: §2.1's exporter spec now carries 00 D6's interim ruling — a per-side `connectionShape` flag set on `ResolvedSyncEndpoints` and a prominent `# note:` per flagged gap whenever the pair's connection settings include an identity file or a jump host (golden fixtures pin the identity-file, jump-host, and both-flags variants) — and §8 rail 5 states 00 D15's trash naming (flat `<runId>/<seq>-<basename>` entries, journal-mapped origins) and the copy-then-delete fallback trigger (local pairs fall back only on EXDEV; other local rename failures surface as errors; for a remote pair any rename failure the sequence prefix did not prevent falls back), with rail 9's restore passage aligned. |

## Open items

1. **2026-09-02 — close M1.** The scaffold, Flutter checks, the full client
   matrix, and the D23 release pipeline are done (see the Done table). What
   remains is the v0.1.0 rehearsal itself, and it is gated on the owner's
   OpenPGP key — this environment has none:
   - cut `v0.1.0` with `scripts/release.sh 0.1.0 --push` on a host with the
     signing key (the script refuses to tag unsigned);
   - after `release.yml` turns green, walk [`docs/RELEASE.md`](RELEASE.md):
     recompute the sums, spot-check one platform against a local build,
     attach `SHA256SUMS.asc`, verify, publish the draft, re-verify;
   - publish the key fingerprint out-of-band (personal domain or a verified
     keys.openpgp.org entry — 00 D23 has the rationale);
   - then tick the remaining M1 exit box (rehearsal assets verified,
     pre-release marking confirmed) and run the §3.12 close chores
     (STATUS sweep, PORTS sweep — the atomic-file source and tests are
     already ported, tag `v0.1.0` itself is the
     chore item). The Android keystore and secret-scanner allowlisting for
     it are already in place from the scaffold PR.
2. **M3 — OS Dart client matrix.** Deliberately deferred until M3, when
   `LocalFileSystem` lands; this is not an M1 closure claim.
3. **Séance pin: flip to the next tag.** The fork bridge is retired (see
   the Done table) and the pin sits at upstream main `2f99f4e` — no Séance
   tag contains the PR-S3 merge yet. `poltergeist_core` now carries the
   same rev pin (first workspace-package pin; the M0 bench pin set is
   unchanged, and the pin audit record still matches). When Séance cuts its
   next release (the same S1 release the M6 Design A gate needs), re-pin
   both declarations to that tag (D2's steady state) and drop the rev pins.
   Tag S1 before M6 Design A.
4. **2026-09-04 — M2 remaining slices.** The initial pool, TOFU gate, and
   channel budgets are in. Still open, in
   roughly this order, subject to open item 5:
   - close the pool-behavior gaps in item 6 and settle item 7 before wiring
     production callers; the coverage items retain their stated gates;
   - the pinned bookmark model and vault/store plumbing (07 §3.3), including
     legacy macOS keychain options and PORTS entries for new copies;
   - keepalive pings, idle extra-transport teardown, and auto-reconnect
     with backoff + downward-only jitter (03 §3.3; `PoolPolicy` constants
     are already defined), incl. the 08 §3.2 backoff-sequence tests;
   - engine isolate + `EngineClient` + the typed port protocol (03 §5),
     incl. the protocol round-trip and coalescing tests;
   - prompt UI (host-key dialogs, keyboard-interactive, credential prompt,
     live `SshConnectionLog` transcript) over the protocol;
   - `ProbeService` wiring + interim server list status dots;
   - ssh_config import with preview + dedupe (D22);
   - the debug-only connect → SFTP → `listDirectory` demo surface;
   - then the Docker-integration legs of 08 §5's pool suite (growth,
     keepalive, reconnect against real sshd) — the matrix exists from M0.

5. **2026-09-04 — escalation: milestone order.** M2 began while M1's
   rehearsal remained open. 07 §1 and IMPLEMENTOR prohibit this overlap;
   no recorded exception accompanies #14. Owner decision needed: require the
   M1 rehearsal before further M2 work, or authorize a documented ordering
   exception. This audit does neither. PR #15's D23 review is untouched;
   until it merges, main's signed-draft policy remains authoritative.
   The rehearsal must also check single-release ownership: main invokes
   `action-gh-release` in every client leg, while tag-level concurrency
   serializes workflows, not their matrix legs. Concurrent draft creation
   remains a release-path risk reserved for the PR #15 workstream.
6. **2026-09-04 — M2 audit follow-ups.** Not milestone completion claims:
   - **Credential lifetime and prompt provenance (security-relevant):**
     `_resolveServer` runs per
     serverId before pool lookup; `_ServerReference.credentials` survives
     pane-lifetime teardown, and the next first connect reuses it. Serialize
     vault resolution per pool, drop retained credentials on teardown, and
     test fresh resolution. A password prompted by that resolver arrives as
     `AuthKind.storedPassword`; carry its interactive origin so growth cannot
     misclassify it. Complete this before prompt/vault integration (D5, D18).
   - **Live state fan-out:** a subscriber listening before a sibling joins an
     already-connected pool gets no connected event. The current tests check
     only subscriptions started after joining. Add the missing transition
     test and emission before wiring ProbeService.
   - **Bounded teardown:** the new transport/channel wrappers directly await
     dartssh2 closes; they do not inherit Séance #59's session-level bounded
     cleanup. Add stalled-close tests and bounds before the real-sshd pool
     suite; exception swallowing alone does not bound a stalled future.
   - **Guard coverage:** `check-imports.sh` has no executable regression suite
     and explicitly omits plugin detection, although 03 §1 requires it.
     Add adversarial fixtures and dependency-aware enforcement. Add 09 §5's
     pinned dependency-contract tests before the next pin bump; hash-off
     second-preflight/CAS coverage also remains absent from the inspected
     Séance #62 adapter tests. These are test gaps, not observed VFS failures.

7. **2026-09-05 — escalation: trust-incident recovery (D18).** Unresolved
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
  live watchers see the inherited block during review. Eight regressions
  failed before and pass after the repair (`pool_trust_test.dart`), with
  additional coverage for current approval and fresh-transfer prompting.

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
