# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) first for how to build/test.

_Last updated: 2026-09-02 — M0 is complete; the M1 scaffold and deterministic
release versions are implemented, but M1 remains open pending v0.1.0._

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Scaffold only: product identity constants + a test guarding the ASCII-name invariant (macOS codesign rejects accented bundle file names). Real modules land per the plan. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |
| Séance PR-S0 | LICENSE audit and Unlicense grant merged in [Séance #57](https://github.com/L-K-M/Seance/pull/57), merge `4d8ee1e026ce4e5d939d6390d9fd98a78fabcf6e`. |
| Séance PR-S1 | Record-kind forward compatibility merged in [Séance #58](https://github.com/L-K-M/Seance/pull/58), merge `599ff936b8222e6cd77920495dcdcc4a50643f44`. A release is still required before M6 Design A. |
| Séance cancellation cleanup | dartssh2 3.0.2 and bounded asynchronous SSH teardown merged in [Séance #59](https://github.com/L-K-M/Seance/pull/59), merge `da9d45492ac7d25cbc4eefb97a6ec29254de219f`. |
| Séance PR-S2 | `openAuthenticatedClient` split merged in [Séance #61](https://github.com/L-K-M/Seance/pull/61), merge `dad6d4f66dbfba6c170b98c204980e5801a890cb`. |
| M0 — engine fitness | Complete from workflow-dispatch run [`33563514640`](https://github.com/L-K-M/Poltergeist/actions/runs/33563514640), attempt 1, measured commit `6b8873eafdaaa3a4157e265dee838ab3b47219b3`. The 78-row canonical bundle is committed at [`docs/evidence/m0`](evidence/m0); `m0-evidence.json` SHA-256 is `b93660b9f1c06bac206096d25c6fff472bcb31d13589a4d81bd5a3df70fa7fcc`. D7 is final: managed checkouts always hash; bulk transfers and sync hashing are opt-in. D8 passed every isolate gate, so sockets, SFTP, transfers, and hashing stay in the engine isolate. D9 adopts dartssh2 3.0.2 at ladder rung 4: document the roughly 10–11× single-file LAN ceiling versus OpenSSH, compensate with bounded channels/transports, and do not adopt libssh2. `PoolPolicy` is finalized at 2 transports, 4 transfer channels per transport, 8 total channels per transport, 6 global in-flight transfers, and remote readdir depth 8. Keepalive remains 30 seconds, extra idle 60 seconds, reconnect cap 30 seconds, and retry limit 5; these are retained design defaults, not M0-tuned values. Earlier runs `33458209337`, `33481554062`, and `33504660759` were partial; `33534298280` stopped in preflight; `33535334440` diagnosed dartssh2 2.22.0's detached cancellation error. None is admissible evidence. M0 closes untagged. |
| M1 — app scaffold implementation | Implemented in [PR #8](https://github.com/L-K-M/Poltergeist/pull/8) with Flutter 3.47.2, exact dependency pins, generated platform icons from the 1024×1024 master, and the verified platform identity contract. Flutter analysis, 108 tests, and all five client builds pass; see the [PR checks](https://github.com/L-K-M/Poltergeist/pull/8/checks). M1 is not closed: the v0.1.0 rehearsal remains. |
| M1 — release versions | Release versions accept canonical `X.Y.Z` only, derive ordered Android codes, keep every versioned pubspec plus the app lock, Apple metadata, and README synchronized, and gate CI and release tags against drift or downgrade. Stable-only is the selected 07 §3.12 rule; suffixed releases are unsupported. The app starts at `0.1.0+10099`; CI verifies that code in the built APK, while Apple and Windows use bounded semantic mappings. |

## Open items

1. **2026-09-02 — close M1.** The scaffold, Flutter checks, and full client
   matrix are green. Follow the [implementation playbook](plan/09-PLAYBOOK.md)
   to bring `release.yml` to D23, then run the v0.1.0 rehearsal with its
   required client assets. Deterministic Android version codes are complete.
   The remaining release work must add the draft publication gate, checksums
   and signed-list handoff, and the unsigned `.xcarchive` → IPA path. Before
   publishing Linux assets,
   include the verbatim Unlicense in the Debian copyright file and replace
   ABI-tag-derived dependency floors with Debian package-version mapping.
   The signed tag, signed checksum list, and independently published
   fingerprint require the owner's OpenPGP key; this environment has none.
   The observed Linux
   X11 identity is instance `com.lkm.poltergeist_app`, class
   `Com.lkm.poltergeist_app`; `StartupWMClass` uses the case-sensitive class.
   The app requires Flutter 3.47.2 and uses the exact pins recorded in its
   [README](../app/poltergeist_app/README.md); its icon source is the master
   at `media-sources/poltergeist-icon.png`.
2. **M3 — OS Dart client matrix.** Deliberately deferred until M3, when
   `LocalFileSystem` lands; this is not an M1 closure claim.
3. **Séance upstream PR-S3** (see
   [`docs/plan/04-SEANCE-INTEGRATION.md`](plan/04-SEANCE-INTEGRATION.md)
   §5): file the VFS additions at their planned cadence. Tag S1 before M6
   Design A.
4. **2026-08-31 — rsync-exporter `# note:` interim patch (00 D6).** The
   "Copy as rsync command" exporter (05 §2) must render a prominent
   `# note:` line — or refuse to render — whenever the pair's connection
   settings include an identity file or a jump host, so the pasted
   command cannot silently connect with the wrong credentials or via the
   wrong path. 05's merged text doesn't state this yet; per 00 D6 this
   **blocks "Copy as rsync command" from shipping in any milestone**
   until it lands in 05.
5. **2026-08-31 — 05 rail-5 precision alignment (00 D15).** 05 states the
   trash-rename fallback trigger as "cross-filesystem" without D15's
   remote/errno distinction (EXDEV is classifiable only for local pairs;
   for a remote pair *any* rename failure not resolved by the sequence
   prefix triggers the copy-then-delete fallback) and without the per-run
   sequence-prefix entry naming (`<runId>/000042-<name>`). Align 05's
   rail-5 text to D15 the next time 05 is edited.

## Housekeeping

- No server component is planned: bookmark backup uses Séance's sync server
  (E2E-encrypted blobs). Poltergeist's release ships client artifacts only.
- `media-sources/poltergeist-icon.png` (the master icon) is created together
  with the app scaffold; `scripts/package-linux.sh` requires it.
