# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) first for how to build/test.

_Last updated: 2026-08-30 — the design plan is complete and merged; next
up is implementation, starting at milestone M0._

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Scaffold only: product identity constants + a test guarding the ASCII-name invariant (macOS codesign rejects accented bundle file names). Real modules land per the plan. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D30), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow and three internal consistency passes. |

## Open items

1. **Implementation, milestone by milestone** per
   [`docs/plan/07-MILESTONES.md`](plan/07-MILESTONES.md), starting with
   **M0** (the dartssh2 fitness spike + isolate PoC) — work the loop in
   [`docs/plan/09-PLAYBOOK.md`](plan/09-PLAYBOOK.md).
2. **Séance upstream PRs S0–S3** (see
   [`docs/plan/04-SEANCE-INTEGRATION.md`](plan/04-SEANCE-INTEGRATION.md)
   §5): LICENSE, record-kind forward-compat (the shared-account gate),
   the `openAuthenticatedClient` split, and the VFS additions — S0/S1 can
   proceed independently of M0.

## Housekeeping

- No server component is planned: bookmark backup uses Séance's sync server
  (E2E-encrypted blobs). Poltergeist's release ships client artifacts only.
- `media-sources/poltergeist-icon.png` (the master icon) is created together
  with the app scaffold; `scripts/package-linux.sh` requires it.
