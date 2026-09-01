# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) first for how to build/test.

_Last updated: 2026-09-01 — M0 is in progress in draft PR #7._

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Scaffold only: product identity constants + a test guarding the ASCII-name invariant (macOS codesign rejects accented bundle file names). Real modules land per the plan. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |
| Séance PR-S0 | LICENSE audit and Unlicense grant merged in [Séance #57](https://github.com/L-K-M/Seance/pull/57), merge `4d8ee1e026ce4e5d939d6390d9fd98a78fabcf6e`. |
| Séance PR-S1 | Record-kind forward compatibility merged in [Séance #58](https://github.com/L-K-M/Seance/pull/58), merge `599ff936b8222e6cd77920495dcdcc4a50643f44`. A release is still required before M6 Design A. |

## Open items

1. **2026-09-01 — close M0 in draft
   [PR #7](https://github.com/L-K-M/Poltergeist/pull/7).** The harness,
   Docker matrix, D30 gate, pin audit, and isolate/pipeline proofs are
   implemented. The measurement-only Séance fork is pinned to
   `142db7b40fd6bdaab35fe295267035dca547d240`, which contains S0 and S1.
   Runs `33458209337`, `33481554062`, and `33504660759` produced no complete
   canonical artifact; partial rows are inadmissible. Run `33534298280` stopped
   in preflight because a test's fixed monotonic anchor exceeded the fresh
   runner's uptime; no measurement job started. The shaped 1 GB cells exceed
   GitHub-hosted runners' six-hour job limit. The plan and harness now split
   those cells into twelve attributable single-sample jobs, checkpoint every
   trial, and verify direction-correct transfers independently. Push the fixed
   measurement commit, dispatch the exact 13-job matrix, commit its validated
   canonical evidence, fill `docs/M0-DARTSSH2-REPORT.md`, finalize D7/D9 and
   pool defaults, then take the PR through review and merge. M0 closes
   untagged; preserve the measured commit as an ancestor when merging.
2. **Séance upstream PRs S2–S3** (see
   [`docs/plan/04-SEANCE-INTEGRATION.md`](plan/04-SEANCE-INTEGRATION.md)
   §5): file the `openAuthenticatedClient` split during M1 and the VFS
   additions at its planned cadence. Tag S1 before M6 Design A.
3. **2026-08-31 — rsync-exporter `# note:` interim patch (00 D6).** The
   "Copy as rsync command" exporter (05 §2) must render a prominent
   `# note:` line — or refuse to render — whenever the pair's connection
   settings include an identity file or a jump host, so the pasted
   command cannot silently connect with the wrong credentials or via the
   wrong path. 05's merged text doesn't state this yet; per 00 D6 this
   **blocks "Copy as rsync command" from shipping in any milestone**
   until it lands in 05.
4. **2026-08-31 — 05 rail-5 precision alignment (00 D15).** 05 states the
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
