# Status & next steps

Living snapshot of where Poltergeist is, what's proven, and what to pick up
next. Read [AGENTS.md](../AGENTS.md) first for how to build/test.

_Last updated: 2026-08-31 — the design plan is complete and merged; next
up is implementation, starting at milestone M0._

## Done

| Area | State |
|---|---|
| Repo infrastructure | CI (`ci.yml`: Dart analyze+test now; Flutter + client-matrix jobs self-activate when `app/poltergeist_app` appears), GLM PR review workflow, release workflow (`v*` tags → per-platform client assets), `scripts/build.sh` / `release.sh` / `package-linux.sh` adapted from Séance, Unlicense, analyzer config, pub workspace. |
| `poltergeist_core` | Scaffold only: product identity constants + a test guarding the ASCII-name invariant (macOS codesign rejects accented bundle file names). Real modules land per the plan. |
| The plan | Complete in [`docs/plan/`](plan/) — overview + decision log (D1–D31), product, UX spec, architecture, Séance integration, sync, editor, milestones, testing, playbook. Reviewed via the GLM PR workflow, internal consistency passes, and a final whole-plan coherence pass (2026-08-31). |

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
