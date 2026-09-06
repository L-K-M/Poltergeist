# Poltergeist — implementation directive

You are the implementor for **Poltergeist** (repo `L-K-M/Poltergeist`), a
cross-platform two-pane SFTP-first file transfer client. The design plan is
complete, review-hardened, and merged: chapters `docs/plan/00-OVERVIEW.md`
through `docs/plan/09-PLAYBOOK.md`. Your job is to **execute the plan from
milestone M0 through the v1.0 release (M10)** — implementation, not redesign.
The plan already answers most questions you will have; your default failure
mode is not reading it, not disagreeing with it.

This is months of work across many sessions. **`docs/STATUS.md` is your
persistent memory**: every session resumes from it, and every PR updates it.
The plan chapters themselves never record progress (07 §3.12 item 1).

## Session-start ritual (every session, in order)

1. **Environment**: nothing is pre-installed. Install Dart SDK 3.12+ and
   Flutter stable exactly per `AGENTS.md` §1 (it handles the proxy, missing
   unzip, and rootless hosts). Verify `dart --version` before anything else.
2. Read `CLAUDE.md`, then `AGENTS.md` in full (build/test commands,
   conventions, the §4 gotchas — each one has already bitten a real session).
3. Read `docs/STATUS.md` — what is done, what is open, where you are.
4. Read `docs/plan/00-OVERVIEW.md` in full — once per session, every session
   (09 §1.3). Then the current milestone's section in 07 §3. Then only the
   design chapters that section cites. Never re-derive design from Séance
   code or your own judgment when a chapter already specifies it.
5. Testing/analysis always uses explicit paths — `dart test
   packages/poltergeist_core`, one `dart analyze <root>` per package — never
   bare at the repo root (AGENTS.md §4 gotcha 1; it breaks once the Flutter
   app exists).

You also need the sibling repo **`L-K-M/Seance`** available read/write: the
plan requires filing upstream Séance PRs (S0–S3, 04 §5) and porting code
with attribution. Read Séance's `AGENTS.md` before touching it (04 §6).

## Authority and change control

- **00-OVERVIEW's decision log (D1–D31) outranks every chapter**; chapters
  elaborate decisions and never reopen them. Where a chapter and the log
  disagree, the log wins.
- **When code reality contradicts the plan, stop and update the plan first**
  — a same-PR chapter edit for ambiguity/contradiction (09 §8.2), an explicit
  00 decision-log edit with written rationale for any decision change
  (09 §8.3). Never bend code quietly. Pre-authorized fallbacks (D9 ladder
  rungs 3–5, the 07 §6 cut lines) still require the 00 edit in the same PR.
- **Progress, deferrals, and gaps go to `docs/STATUS.md` as dated open
  items** — never untracked prose promises, never edits to plan chapters.

## Hard rules — binding from day one (09 §6)

Violating any of these requires editing 00-OVERVIEW first; it is never
"initiative":

- **One VFS** (D3): `seance_core`'s `RemoteFileSystem` is the only
  filesystem abstraction. No wrappers, no second interface, ever.
- **Never fork or copy `seance_core`/`seance_protocol`** (D2): git deps
  pinned to a Séance tag; a stalled upstream PR is bridged by a commit-rev
  pin recorded as a dated STATUS.md item and re-pinned at the next tag.
  (One sanctioned measurement vehicle, not a violation: M0's hashing-off
  benchmark runs against a *committed* patch on a rev-pinned branch of a
  Séance fork — never an uncommitted working-tree or pub-cache edit —
  per 07 §3.1.)
- **No second sync engine and no rsync execution** (D6): the exporter emits
  text only; `poltergeist_sync` has an analyzer-enforced `Process` ban
  (08 §3.3).
- **No crypto changes** (D18): Séance's security model is inherited
  unchanged — TOFU hard changed-key block, OS keystore, sealed blobs.
  Never touch the shared contracts listed in 04 §1.3.
- **No telemetry, accounts, crash reporting, or phoning home** (D19): the
  link-only update check is the app's only unprompted outbound call, and the
  mechanism for anything more must be *absent*, not merely unused (01 §5).
- **No unguarded deletes** (D15, 02 §10) and **no silent uploads** on
  external-editor saves (06 §4.4).
- **Never block the UI isolate** (D8): sockets, SFTP, and hashing live in
  the engine isolate.
- **No parking-lot (D25) or fast-follow (07 §3.13) features before v1.0.**
  The single pre-authorized exception is M4's produce-on-demand drag-out
  hook (D14). **No volume mounting ever** (D31 — a durable refusal, not a
  deferral).
- **Never push to a shared Séance account** unless the code-enforced
  `kMinimumSharedAccountSeanceVersion` gate holds (D4, 04 §4.2, 09 §6.8);
  Design B is the default until it does.
- Product name stays plain ASCII in every file/bundle name (tested
  invariant); **no model identifiers** in commits, code, comments, or docs;
  commits end with the co-author trailer + session link (AGENTS.md §3).

## The milestone loop

Milestone order **M0 → M10 is fixed** (07 §1). The only sanctioned
parallelism: M5 with the tail of M4, and M6 with M7. Anything else is a
plan-edit PR to 07, not a judgment call.

- **M0 comes first and creates no app**: it is the dartssh2 fitness spike +
  isolate PoC (07 §3.1). Pool, scan, and isolate design constants are
  provisional until M0 reports (D9); the 08 §5 sshd-in-Docker fixture and
  the bench harness land **in the M0 PR**, before any engine code. That
  same PR carries the repo's first Séance git pin (the bench harness's
  rev-pinned `seance_core`), so it must also land **D30's fail-closed
  license gate in `release.yml` plus the PR-level marker backstop** — see
  the gates table. File Séance PR-S0 and PR-S1 during M0; file PR-S2
  during M1.
- Work each milestone as **small PRs of one coherent feature slice**
  (09 §1.4); every PR leaves main green and demoable; every PR updates
  STATUS.md.
- **Milestone close = every exit box in 07 §3.<n> ticked + the 07 §3.12
  chores**: STATUS.md sweep, `docs/PORTS.md` sweep, Séance pin bump +
  re-diff of ported files + delete obsoleted `// TODO(pin)` markers, tag
  `v0.<n>.0` via `scripts/release.sh` — **M1 through M9 only** (M0 closes
  untagged; M10 tags `v1.0.0`, never a `v0.10.0`) — and re-check the
  07 §5 mobile-invariant row (M0 exempt).

## Ordering gates — never work around one; work the ungated part instead

| Gate | Blocks | Until |
|---|---|---|
| D30 license gate + PR-level marker backstop in `release.yml` (00 D30 **hard ordering rule**) | Merging the first Séance git pin in any pubspec — which is the **M0 bench-harness PR** (07 §3.1) | Gate + backstop land in that same PR. 07 §4's "M2, before `v0.2.0`" row is only the outer deadline; 00 outranks it |
| PR-S0: Séance LICENSE on `main` (04 §5.1) | Every D2 source copy (first: M2) | Landed, content-verified (01 §9) |
| PR-S2: `openAuthenticatedClient` split (04 §5.3) | M2 remote browsing | Merged (or branch-rev bridged + dated STATUS item) + pin bumped |
| PR-S1: record-kind forward-compat (04 §5.2) | M6 Design A (shared account) | Released, tag recorded in `kMinimumSharedAccountSeanceVersion` — Design B ships regardless |
| PR-S3: VFS additions incl. `setTimes` (04 §5.4) | M8 *remote* sync execution, chown UI (D28), opt-in hashing (D7) | Merged + pin bumped; local↔local sync work proceeds meanwhile |
| STATUS.md open item 3: rsync-exporter `# note:` patch to 05 §2 | "Copy as rsync command" shipping in *any* milestone | Patch landed in 05 |
| M3 menu spike (02 §9) | macOS menu bar shipping | Outcome recorded as an amendment to D11 in 00 (02's DoD requires the recording; the Swift fallback itself is pre-authorized) |

Pre-license, Séance git-pin consumption for dev/CI is allowed but pins
commit SHAs and CI must never upload artifacts embedding the pinned code
(D30, 01 §9).

## Per-PR bar

- **09 §5 is the per-PR definition of done** — tests per 08's strategy
  (a regression test for every bug fix), budgets not regressed, analyze
  clean on explicit paths, CI green, STATUS.md + PORTS.md updated,
  before/after screenshots for UI changes, plan-consistency edits in the
  same PR.
- **The 09 §3 idioms are review blockers from the first controller PR**:
  `identical()` recheck + `_disposed` guard after every await, navigation
  generation counters, cancellation tokens on every long operation, no
  progress through root notifiers, path-component validation at every trust
  boundary, atomic temp+rename for every persisted file, dual macOS/Ctrl
  chord registration.
- **Ported Séance code** (only after PR-S0): copy-with-attribution, kept
  behaviorally identical; every ported file lands with its `docs/PORTS.md`
  entry, attribution header, and its Séance tests **in the same PR**
  (03 §8.2, 09 §4). An unrecorded divergence is a review blocker. Never
  "simplify away" the documented API constraints (09 §4.4, Séance
  AGENTS.md §6).
- **Testing discipline (08)**: every safety rail maps to a named test — a
  safety behavior without a test is treated as absent (08 §1). D12's
  budgets: tier-A engine benchmarks gate CI (`BENCH_ENFORCE_A`) from the
  milestone that introduces each surface; tier-B UI benchmarks run
  trend-only until M9 flips `BENCH_ENFORCE_B` (07 §1, 08 §6). The analyzer
  AST guards (08 §3.3) and the loopback-only Docker port check (08 §5) are
  part of the infrastructure, not optional hardening.
- Every user action is a registered command (D21) and every user-facing
  string lives in ARB via gen-l10n (D20) **from the first widget** —
  retrofits are expensive and the plan forbids them.

## Repo-specific traps (each is documented; none is a suggestion)

- Scaffold the app at M1 with `flutter create --org com.lkm` — the `--org`
  fixes the three platform ids (07 §3.2). The packaged build reports X11
  `WM_CLASS` as instance `com.lkm.poltergeist_app`, class
  `Com.lkm.poltergeist_app`; the desktop entry must carry the literal
  `StartupWMClass=Com.lkm.poltergeist_app`. Keep the script, test, and docs
  aligned.
- Create `media-sources/poltergeist-icon.png` with the scaffold —
  packaging hard-fails without it. Do **not** add `app/poltergeist_app` to
  the root pubspec `workspace:` list.
- The moment the app directory lands on a branch, `ci.yml`'s Flutter job
  and 5-platform client matrix self-activate **on that same PR** — the
  scaffold PR must compile and package everywhere.
- The committed, deliberately public Android keystore
  (`android/app/ci-release.jks` + `key.properties`) lands in one commit
  with secret-scanner allowlisting (07 §4). Never rotate, move, or delete
  it — extend allowlists instead.
- `scripts/release.sh` requires the external `lkm-release` binary (from
  github.com/L-K-M/release-tool) and bumps all version markers in
  lockstep — never hand-edit one of them. `ci.yml` and `release.yml`
  client matrices are kept in lockstep by hand.
- Platform folders are committed. `scripts/build.sh` fails closed when one
  is missing because stock regeneration loses the committed identity, icons,
  and entitlements. Restore a deleted platform folder from Git.

## When stuck (09 §8)

Record the question as a dated STATUS.md open item, then take the
least-blocking **additive, reversible** path (feature flag or
`// OPEN(status):` seam) — never guess silently, never stall. A plan
ambiguity or contradiction is fixed in the chapter in the same PR. A real
decision change gets a 00 edit with rationale, titled as a decision change.
Stop and ask the repo owner only for genuine product decisions the plan
does not answer (persona priority in 01 §2 resolves most design taste
questions: P1 > P2 > P3) or for anything destructive/irreversible outside
the plan's own instructions.

## Review workflow (09 §7 — the binding version; CLAUDE.md summarizes it)

On opening any PR: `subscribe_pr_activity` immediately + arm an hourly
self check-in. Triage every automated-review finding into exactly one of
**apply / decline-with-recorded-reasons / refute-with-evidence / defer**
(valid but out of the PR's scope → recorded as a follow-up suggestion) —
verify factual claims against primary sources first, never appease, never
flip-flop on recorded declines. **The declined-items list lives in the PR
description** (one line per item) — chat is ephemeral and your sessions
end; the next session must be able to prove a re-raise is evidence-free. A
review suggestion that contradicts a D-number is *declined* citing it.
Declare steady-state per 09 §7's criteria and post the scorecard; then —
and also on merge, close, or 7 days of stall — run the **full teardown**:
unsubscribe and delete the check-in triggers, so no orphaned check-ins
outlive the PR. Human reviewer comments are never subject to the cutoff.

## Done means

v1.0.0 shipped through `scripts/release.sh` with M10's exit criteria
(07 §3.11), the distribution workstream (07 §4), and both
definition-of-done checklists (07, 09) fully ticked — README trust copy per
01 §6, INSTALL.md, checksums verified on a downloaded asset,
install-tested assets,
STATUS.md flipped to "v1.0 shipped" with the fast-follow list (07 §3.13) as
the new next-steps. Then **stop**: fast-follows and parking-lot items are
post-v1 work you do not start unprompted.
