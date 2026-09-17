# D12 benchmark checker (08 §6)

Offline evaluation of Poltergeist's D12 performance budgets. The CI
`bench` job (08 §8) produces the inputs; this checker only
consumes files, prints an honest table plus notices, and exits with the
plan's status. Every
scenario in `budgets.json` stays `landed: false` until the real harness/job
introduces its surface
(07 §1), and the tier-A `calibratedFingerprint` stays `null` until real
calibration — the tier-A scenarios P3/P5/P7 crossed both gates on
2026-09-17 (owner decision on STATUS item 22; provenance under
"Tier-A calibration and the landed flip" below). The tier-B baseline **is** committed
(`tier-b-baseline.json`, measured from real main-branch bench artifacts —
provenance below), so a declared tier-B scope now runs the per-run
fingerprint-drift evaluation against it instead of printing the
absent-baseline notice; per-scenario trend lines still wait on the
`landed` flips, which are a separate step.

## Invocation

```
dart run test/benchmarks/check.dart --results <bench-results.json> \
    --tiers a|b|ab [--budgets <path>] [--baseline <path>] \
    [--drift-state <path>] [--update-drift-state]
```

Exit codes: `0` success (including soft overruns and drift skips that 08
§6 keeps non-failing), `1` graded failure (missing/errored expected
scenario in every mode; overruns/drift once the tier's enforcement flag
is set — and a declared tier whose baseline file is absent once that
tier is enforced), `64` usage, `65` malformed input documents (including
files that are not valid UTF-8), `74` IO errors.

`BENCH_ENFORCE_A` / `BENCH_ENFORCE_B` (environment) carry the two tiers'
separate enforcement semantics (08 §6). Accepted values are
`0`/`false`/unset and `1`/`true`; anything else is a usage error — an
unexpected value never silently reads as unenforced.

## Input documents

All JSON, versioned by a `schema` string. These are D12-specific formats;
they deliberately do not reuse or alter the M0 evidence envelope in
`packages/poltergeist_bench` (different schema, validator, provenance).

**`budgets.json`** — the committed P1–P7 catalog mirroring 02 §12:
per-scenario `tier`, `operator` (`lessThan`/`atMost`/`atLeast` — the
exact boundary operators of 02 §12), `value`, `unit`,
`minimumRepetitions` (P3: 5 per 07 §3.4's median-of-≥5 warm runs; all
other scenarios: 3 per 08 §6's in-job repetition floor), `landed`, plus
the tier-A calibration. Scenario config is a **per-scenario** axis: in
schema `poltergeist-d12-budgets-2` (the committed canonical form) each
tier-A scenario carries its own `calibratedScenarioConfig` — required
when landed, because a budget measured under an unrecorded config could
never be honestly compared — and the singular `calibratedFingerprint`
records only the common controlled axes (null until a real calibration
run records it; a landed tier-A scenario with a null calibration is
rejected). The legacy schema `-1` (a singular
calibratedFingerprint.scenarioConfig) remains readable: its config,
when present, calibrates every tier-A scenario, with a loud deprecation
notice; a `-1` file carrying `calibratedScenarioConfig` (or a `-2`
calibration claiming a job-wide config) is rejected as a mixed form.

**bench-results.json** — one job's observations: rows of
`{scenario, repetition, status, value?, unit?, error?, fingerprint}`.
The repetition index is part of the aggregation key: duplicates are
rejected, and the tier comparison uses the median of the per-repetition
values. `status: "error"` rows are kept and reported, never silently
dropped — and an errored repetition of an expected scenario fails the
run in every mode, with the repetition and message attributed in the
failure line; successful siblings cannot hide it. An empty `rows` list
is a valid, fully unobserved job (no fingerprint is fabricated for it):
it yields the honest no-budgets-evaluated outcome when nothing is
landed, and explicit missing-scenario failures when something is. Rows
must share one environment fingerprint **per tier** — within a tier,
every axis except `scenarioConfig` (two runtimes in one tier are two
measurement classes). Across tiers only the machine axes `runnerImage`,
`arch`, and `cpuModel` must agree (two machines in one job are two
environments); the runtime axes differ per tier by construction — tier
A runs standalone Dart AOT collectors, tier B runs inside the Flutter
engine under profile mode, so `dartVersion`, `flutterVersion`, and
`mode` never carry the same values and one `--tiers ab` job writes both
sets into this file. The runtime axes are instead validated per store:
row eligibility filters non-AOT/non-profile rows as ineligible with a
loud notice, and the calibration/baseline must record their tier's
runtime. `scenarioConfig` is
agreed **per scenario**: one scenario's repetitions must share one
config (conflicting configs are a malformed measurement set, exit 65),
while distinct scenarios may carry distinct configs in the one results
file — each landed tier-A scenario is compared against its own
calibrated config, never another scenario's, so two config-carrying
scenarios coexist in one file and both still compare.

**tier-B baseline** (`tier-b-baseline.json`, committed) — per-scenario
medians under one
fingerprint, plus each entry's own `scenarioConfig`: the config its
median was measured under. In schema
`poltergeist-d12-baseline-2` (the committed canonical form) every entry
must carry the key explicitly — `null` records a config-free collector;
an absent key is ambiguous and rejected. A run compares a scenario only
against the entry recording the same config: a recorded-but-different
config is a loud non-comparison skip (never cross-compared — a changed
workload is a changed measurement), and a legacy
`poltergeist-d12-baseline-1` file — still readable, with a loud
deprecation notice — records no configs at all, so every entry reports
`baseline-config-missing` and skips rather than inventing one. Both
non-comparison outcomes stay soft (notice, exit zero) while
`BENCH_ENFORCE_B` is unset and fail once it is set, and both veto the
drift-state reset like any unexecuted comparison. The fingerprint's
`scenarioConfig` must still be null — a job-wide claim could never be
attributed to one scenario. Tier-B comparisons that do run fail on a
median regressing
strictly more than 25 % against the baseline median once enforced. A
declared tier whose baseline file is absent prints a loud non-enforced
notice and exits zero while soft, non-zero once `BENCH_ENFORCE_B` is
set (the M3 spike window).

**drift state** — the small store time-boxing drift skips
(`consecutiveMainRuns` per drift-notice key, tier-B keys only: tier-A
drift skips never redden in any mode). Main-branch runs pass
`--update-drift-state` (a `DriftRunKind.mainRun` in the evaluator); PR
invocations are read-only: they may inspect persisted history but never
grade a hypothetical next main count — six actual main runs stay six
for a PR, and only an actual main run can reach the escalation
threshold. The same tier-B drift notice firing on ≥ 7 consecutive main
runs reddens with `baseline stale — refresh required` once
`BENCH_ENFORCE_B` is set. Only a genuinely clean main run — no graded
failures, no fresh drift, and every expected tier-B comparison actually
observed (at least one) — may reset prior counts; failed, missing, or
unobserved tier-B
comparisons preserve them (though drift that genuinely fired still
counts even when other gates fail: measurement validity, drift, and
budget failures are distinct). A run with nothing to record leaves the
store byte-identical. A missing or unreadable state means history is
unknown: fired notices count conservatively at the escalation
threshold, never as a fresh count (08 §6's "never a reset").
Controlled-axis mismatch against the baseline is a hard non-zero exit
once enforced but a loud exit-zero notice while soft; the CPU-model axis
skips with a notice and never auto-reddens on its own. State
publication is atomic through an owned, uniquely named temporary file
(`<state>.checker-<pid>-<seq>.tmp`) on the target filesystem: a
pre-existing `<state>.tmp` file or symlink is never overwritten or
followed, and cleanup removes only the temp this run created.

## CI artifact handoff

The `bench` job in `.github/workflows/ci.yml` writes
`bench-results.json` by merging the collectors' per-scenario documents
(`scripts/bench-tier-a.sh` for P3/P5/P7 under
`test/integration/run.sh --lifecycle-only`; `scripts/bench-tier-b.sh`
for P1/P2/P4/P6 — see below), evaluates it here with `if: always()` so
partial results are graded, and uploads it as the always-present
`bench-results` artifact. The evaluate step forwards the
`BENCH_ENFORCE_A` repo variable into the checker's environment (set
2026-09-17 with the tier-A landed flip — an unset/empty variable reads
as unenforced), so landed tier-A rows now gate on their calibrated
fingerprint. `BENCH_ENFORCE_B` is not forwarded: tier B stays
trend-only until M9.

**Tier-B leg (M3 spike).** On pushes to `main` and manual dispatch the
job additionally runs the profile-mode UI benchmarks under Xvfb:
`scripts/bench-tier-b.sh` builds local filesystem fixtures
(`entries-10000`, `entries-100000` under a per-run temp root — no
Docker) and drives each suite in
`app/poltergeist_app/integration_test/perf/` via
`flutter drive --driver=test_driver/integration_test.dart --profile
--device-id linux`. Each suite boots the real app over a real engine
session, drives the left pane's production `PaneController`, and
captures raster timing through
`SchedulerBinding.addTimingsCallback` — the primary mechanism;
`traceAction` summaries are not consumed. P1/P2 anchor first paint on
the navigate()-issue timestamp through the first frame whose build
began after the listing landed; P4 seeds a five-tab strip on the
10 000-entry fixture and times each scripted `activateTab` from issue
to the first post-activation frame's raster completion (a switch is an
atomic active-pointer change — 02 §3 — so that frame is the first that
can carry the target tab's already-loaded listing); P6 runs a scripted
30 s linear scroll of the 100 000-entry fixture, derives the refresh
rate from the smallest positive vsync interval (recorded in the row's
`scenarioConfig`; dropped frames only ever lengthen an interval, so
the minimum is the display period a median would mask), and reports
the percent of frames whose vsync-to-raster span exceeded the deadline
— or an error row carrying the captured count when the window delivered
fewer than `floor(30 s × measured Hz)` frames (>= 1800 at 60 Hz), never
a ratio over a too-small sample. Timing reduction lives in
`app/poltergeist_app/lib/bench/` with deterministic unit tests under
`test/bench/`. One harness subtlety: the suites run under
`LiveTestWidgetsFlutterBindingFramePolicy.fullyLive` — the default
`fadePointers` policy silently skips platform BeginFrames nothing
explicitly pumped, and under Xvfb (no Present extension, no free-running
vsync) a ticker-driven scroll would starve without ever timing out.
Under llvmpipe the observed platform rate is ~11 fps; the measured-Hz
floor and deadline scale accordingly, which is real trend evidence for
a software stack.

Tier-B rows land in the same `bench-results.json` and the checker runs
`--tiers ab` on main/dispatch, `--tiers a` on PRs (the tier-B leg never
runs on a PR — PR invocations must not write drift state). The leg is
trend-only until M9: no `BENCH_ENFORCE_B` and no `landed` flips — the
committed baseline (below) arms the fingerprint-drift evaluation on
`--tiers ab` runs while every scenario stays reported-not-judged.

Local iteration needs a display plus the Linux toolchain; the same
script honors `XVFB_RUN`/`FLUTTER_BIN`/`DART_BIN` overrides, e.g.
`XVFB_RUN="xvfb-run -a" scripts/bench-tier-b.sh`, and software GL via
`LIBGL_ALWAYS_SOFTWARE=1` suffices for real Impeller raster timings.

Still ahead for tier B (08 §6/§8): flip each tier-B scenario's `landed`
as its surface's introduction step allows, so the committed baseline
starts producing per-scenario trend lines; fetch the drift
state from the latest main-branch bench job's artifact and pass it via
`--drift-state` (the checker's drift state is its own standalone JSON
file — the always-present artifact, or an `actions/cache` entry keyed
on the fingerprint, is the documented single state store); add
`--update-drift-state` on main-branch runs only — the checker rejects
it on tier-B-blind runs, so drift state only ever flows through a run
that evaluated tier B. PR invocations stay read-only and never mutate
the store.

## Baseline refresh procedure (08 §6's dedicated PR)

A tier-B drift notice — controlled-axis or CPU — never auto-clears: a
human opens a **dedicated baseline-refresh PR** that re-measures on the
current fingerprint and updates `tier-b-baseline.json` in one commit.
The refresh is measurement, not authoring:

1. Download the `bench-results` artifact of the last few successful
   **main-branch** `ci.yml` runs (the tier-B leg runs only on main
   pushes and manual dispatch — PR artifacts never carry it):
   `gh run list --repo L-K-M/Poltergeist --workflow ci.yml --branch main`
   then `gh run download <run-id> --repo L-K-M/Poltergeist --name
   bench-results`. Use at least three runs that include the tier-B leg
   (a scenario whose suite has reached main fewer times pools whatever
   `ok` rows exist — its `repetitions` records the shortfall, as P4's
   first entry below does); the merged `bench-results.json` holds the
   per-repetition rows.
2. Read the tier-B rows' shared fingerprint (every axis except
   `scenarioConfig`, which is per scenario). The baseline records that
   fingerprint — including the **tier-B** runtime axes (`dartVersion`
   is the Flutter-bundled Dart, `flutterVersion` the pinned Flutter,
   `mode` `profile`), never the job SDK's tier-A runtime. Pool
   observations only from runs matching the recorded fingerprint in
   full — a run on a different CPU model is a different environment
   (the uncontrolled axis skips its comparison anyway), so its numbers
   never fold into a baseline it would not be compared against. A
   mixed fleet (two CPU models serving `ubuntu-latest` concurrently)
   keeps printing the CPU-axis notice on the non-recorded CPU even
   after a refresh — that notice then tracks runner assignment, not
   baseline staleness, and is noted rather than refreshed away. If the
   pool's controlled axes moved, the refresh re-measures on the **new**
   fingerprint — that is the point of the procedure.
3. Per tier-B scenario, take the median of all pooled `ok` rows and set
   `repetitions` to the pooled observation count — and record the
   scenario's own `scenarioConfig` from the same rows (schema
   `poltergeist-d12-baseline-2`; the within-run agreement check
   guarantees each scenario carried one config per run, so pooling is
   only honest when every pooled run's config for that scenario agrees —
   a run measured under a different config belongs to a new baseline,
   not this one). A scenario with no
   `ok` rows gets **no entry** — never a fabricated median; the checker
   reports a landed scenario without an entry loudly (and fails it once
   enforced).
4. Run the checker against one of the real artifacts and confirm the
   drift notice is gone; run `dart test test/benchmarks` (the committed
   file's contract is pinned by tests) and `dart analyze
   test/benchmarks`, then open the refresh PR. Nothing else rides along
   — no `landed` flips, no `BENCH_ENFORCE_*`, no budget edits.

## First committed baseline (2026-09-15)

Measured from the `bench-results` artifacts of the main-branch CI runs
34920829912, 34925105848, 34925201167, and 34937535607 (run
34934485531 ran on `AMD EPYC 9V74`, a different uncontrolled-axis
environment, so its rows were excluded; the dispatch run 34935534520 on
the P4-suite branch corroborates P4 at a 36.8 ms median but is not a
main-branch artifact). The recorded fingerprint is the one those runs
share: `ubuntu-latest@20260907.300.1`, `linux_x64`, Flutter 3.47.2's
bundled Dart 3.13.2, `profile`, `AMD EPYC 7763 64-Core Processor`.
Per-run medians of the pooled runs: P1 1006.5–1089.3 ms (pooled median
1061.087, n=12), P2 10465.3–11286.0 ms (pooled 10781.459, n=12), P4
35.398 ms (n=5, one run — the P4 suite landed in #127 and has run on
main only once). **P6 has no baseline entry**: every tier-B leg so far
returned error rows for it (insufficient frame capture — ~750–800
frames in 30 s against the >= 1800-frame floor the ~60 Hz measured
vsync cadence implies under llvmpipe), so no honest median exists; a
harness fix lands with its owner before any P6 baseline is possible.
The trend these medians anchor is environment-scale (llvmpipe raster),
not a budget read — P1's ~1.06 s against the < 150 ms budget is the
software stack talking, which is exactly what trend-only exists to
expose before M9.

The file moved to schema `poltergeist-d12-baseline-2` the same day
(fusion review round 2, finding F9): each entry now records the
`scenarioConfig` its rows actually carried in those artifacts — P1
`local-entries-10000-first-paint`, P2
`local-entries-100000-first-paint`, P4
`local-tabs-5-entries-10000-tab-switch` — so a run only ever compares
against a median measured under the same workload. Medians, repetition
counts, and the fingerprint are unchanged from the -1 commit (re-verified
against the same artifacts).

## First fixture-backed observations (2026-09-14)

The job's first real runs produced stable medians (within-run spread
< 2 %): P3 ≈ 4.3–4.6 s, P5 ≈ 4.7–4.9 s, P7 ≈ 2 230–2 330 entries/s.
These miss 02 §12's P3 (< 50 ms) and P5 (< 500 ms) budgets by ~90×/~10×
while P7 (≥ 1 000 entries/s) passes — and the gap is environment, not
measurement error.

The measured legs are dominated by serialized SFTP round trips, not
collector overhead: OpenSSH sftp-server caps one `READDIR` reply at 100
entries (each `lstat`'d server-side), and dartssh2 3.0.2's `listdir`
awaits each batch before requesting the next, so one 10 000-entry
`listDirectory` is ~104 strictly sequential request/response pairs. On
this job's path — loopback to a Docker-published port on a shared
`ubuntu-latest` runner, with no netem shaping applied — one such pair
costs ~35–52 ms (P3's 4-request control leg prices it at ~35 ms; M0's
`pipeline-readdir-1-lan` priced it at ~41–52 ms on the same stack — its
800 entries span 8 sibling directories listed serially, ~4–5 round trips
each). P5's leg
contains that same root listing plus a stat, a transfer-channel lease,
and the first-byte read; P7's critical path is the same serialized
10 000-entry stream, so its passing rate is the bottleneck's ceiling,
not health.

Consequence: the absolute P3/P5 budgets are unreachable by construction
on this environment (≈104 sequential round trips would need < 0.5 ms
each). Landing them needed the 08 §6 calibration path plus an
owner-level budget decision — resolved 2026-09-17 (STATUS item 22); see
the next section.

## Tier-A calibration and the landed flip (2026-09-17)

Owner ruling on STATUS item 22 (Option 1, recommendation accepted):
recalibrate the P3/P5 budgets to the CI-fingerprint reference values,
flip the tier-A scenarios `landed`, and enable `BENCH_ENFORCE_A`. P7
kept its plan budget (≥ 1 000 entries/s — it passes at ~2 280/s
observed). An upstream pipelined READDIR is explicitly not a blocker.

**Calibration pool.** The five main-branch `ci.yml` runs matching the
recorded tier-A fingerprint in full — 35005140193, 35028604913,
35033568776, 35086417157, 35125183171 (2026-09-15/16) — 25 `ok`
repetitions per scenario. Recorded fingerprint: runner image
`ubuntu-latest@20260907.300.1`, `linux_x64`, Dart `3.13.4` (the job
SDK's stable, AOT collectors), `aot` mode, `AMD EPYC 7763 64-Core
Processor`, no job-wide `scenarioConfig` (each scenario records its own
`calibratedScenarioConfig` — the strings the artifacts actually carry).
Earlier same-image runs on Dart 3.13.3 (34920829912, 34925105848,
34925201167, 34937535607) corroborate within ~1.5 % but sit on the other
side of the controlled `dartVersion` axis, so they are not pooled. Runs
on the fleet's other CPUs (9V74, 9V45, Xeon 6973P-C/8573C) are likewise
excluded — a different environment, per the pooling rule.

**Policy and derived budgets.** observed pooled median × 1.2 headroom,
rounded up to the next 500 ms:

| Scenario | Pooled median (n=25) | × 1.2 | Budget |
|---|---|---|---|
| P3 | 4 451.612 ms | 5 341.9 ms | < 5 500 ms |
| P5 | 4 775.815 ms | 5 731.0 ms | < 6 000 ms |
| P7 | 2 280.1 entries/s | — | ≥ 1 000 entries/s (unchanged) |

Within-pool spread is < 0.4 % per scenario; the pooled runs' per-run
medians sit within ~0.1 % of the pooled value — the serialized-READDIR
fixture is remarkably stable. The same four named 3.13.3 runs put P3 at
4 448–4 521 ms and P5 at 4 774–4 843 ms, corroborating the calibration
independently of the pooled set.

## Tests

`check_test.dart` covers the pure arithmetic/validation (medians, exact
boundary operators, regression fractions, axis comparison, drift-state
transitions, document validation, and the committed catalog mirroring
02 §12). `check_cli_test.dart` drives the CLI end to end with synthetic
temp-file fixtures (no fabricated production baselines) — scoped
expectations, repetition floors, soft/enforced combinations, both drift
axes, drift-state progression/reset/PR-read-only, and exit codes.
`legacy_entrypoints_test.dart` is the pre-existing M0 relocation
contract suite.
