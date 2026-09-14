# D12 benchmark checker (08 §6)

Offline evaluation of Poltergeist's D12 performance budgets. The CI
`bench` job (08 §8) produces the inputs; this checker only
consumes files, prints an honest table plus notices, and exits with the
plan's status. No calibration data or baseline is committed here: every
scenario in `budgets.json` stays `landed: false` until the real harness/job
introduces its surface
(07 §1), and `calibratedFingerprint` stays `null` until real calibration.

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
landed, and explicit missing-scenario failures when something is. All
rows must share one job-wide environment fingerprint — the controlled
axes `runnerImage`, `arch`, `dartVersion`, `flutterVersion` plus the
uncontrolled-but-row-checked `cpuModel` (two CPUs in one job are two
environments). `mode` differs per tier by design: tier A runs AOT, tier
B runs profile, and one `--tiers ab` job writes both into this file —
`mode` is instead validated per store: row eligibility filters
non-AOT/non-profile rows as ineligible with a loud notice, and the
calibration/baseline must record their tier's mode. `scenarioConfig` is
agreed **per scenario**: one scenario's repetitions must share one
config (conflicting configs are a malformed measurement set, exit 65),
while distinct scenarios may carry distinct configs in the one results
file — each landed tier-A scenario is compared against its own
calibrated config, never another scenario's, so two config-carrying
scenarios coexist in one file and both still compare.

**tier-B baseline** (`tier-b-baseline.json`, absent until a real
calibration commits it) — committed per-scenario medians under one
fingerprint; the fingerprint's `scenarioConfig` must be null (configs
are per-scenario; no tier-B scenario carries one yet, and the baseline
schema grows per-scenario configs with the first config-carrying
tier-B collector). Tier-B comparisons fail on a median regressing
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

The `bench` job in `.github/workflows/ci.yml` (tier A only so far)
writes `bench-results.json` by merging the three collectors' per-scenario
documents (`scripts/bench-tier-a.sh` + `scripts/merge_bench_results.dart`,
run under `test/integration/run.sh --lifecycle-only`), evaluates it here
with `--tiers a` and `if: always()` so partial results are graded, and
uploads it as the always-present `bench-results` artifact. With every
scenario unlanded the run is a report, not a gate; no `BENCH_ENFORCE_*`
flag is set by the job.

Still ahead for the tier-B leg (08 §6/§8): pass `--tiers ab` on
main/dispatch once tier-B collectors exist; fetch the drift state from
the latest main-branch bench job's artifact and pass it via
`--drift-state` (the checker's drift state is its own standalone JSON
file — the always-present artifact, or an `actions/cache` entry keyed on
the fingerprint, is the documented single state store); add
`--update-drift-state` on main-branch runs only — the checker rejects it
on tier-B-blind runs, so drift state only ever flows through a run that
evaluated tier B. PR invocations stay read-only and never mutate the
store.

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
