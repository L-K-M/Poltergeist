# D12 benchmark checker (08 §6)

Offline evaluation of Poltergeist's D12 performance budgets. The future CI
bench job (08 §8 — not built yet) produces the inputs; this checker only
consumes files, prints an honest table plus notices, and exits with the
plan's status. No collectors, calibration data, baseline, or Actions
integration is committed here: every scenario in `budgets.json` stays
`landed: false` until the real harness/job introduces its surface
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
is set), `64` usage, `65` malformed input documents, `74` IO errors.

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
the tier-A `calibratedFingerprint` (controlled axes the tier-A budgets
were calibrated under; `null` until a real calibration run records it —
a landed tier-A scenario with a null calibration is rejected, because no
honest comparison would ever be possible).

**bench-results.json** — one job's observations: rows of
`{scenario, repetition, status, value?, unit?, error?, fingerprint}`.
The repetition index is part of the aggregation key: duplicates are
rejected, and the tier comparison uses the median of the per-repetition
values. `status: "error"` rows are kept and reported, never silently
dropped. All rows must share one environment fingerprint (except `mode`,
which differs per tier by design: tier A runs AOT, tier B runs profile,
and one `--tiers ab` job writes both into this file — `mode` is instead
validated per store: row eligibility filters non-AOT/non-profile rows as
ineligible with a loud notice, and the calibration/baseline must record
their tier's mode). Controlled axes: `runnerImage`, `arch`,
`dartVersion`, `flutterVersion`, `scenarioConfig`; uncontrolled:
`cpuModel`.

**tier-B baseline** (`tier-b-baseline.json`, absent until a real
calibration commits it) — committed per-scenario medians under one
fingerprint. Tier-B comparisons fail on a median regressing strictly
more than 25 % against the baseline median once enforced. A declared
tier whose baseline file is absent prints a loud non-enforced notice and
exits zero while soft, non-zero once `BENCH_ENFORCE_B` is set (the M3
spike window).

**drift state** — the small store time-boxing drift skips
(`consecutiveMainRuns` per drift-notice key, tier-B keys only: tier-A
drift skips never redden in any mode). Main-branch runs pass
`--update-drift-state`; PR invocations never mutate it. The same tier-B
drift notice firing on ≥ 7 consecutive main runs reddens with
`baseline stale — refresh required` once `BENCH_ENFORCE_B` is set; any
intervening clean main run resets the count. A missing or unreadable
state means history is unknown: fired notices count conservatively at
the escalation threshold, never as a fresh count (08 §6's "never a
reset"). Controlled-axis mismatch against the baseline is a hard
non-zero exit once enforced but a loud exit-zero notice while soft; the
CPU-model axis skips with a notice and never auto-reddens on its own.

## Future CI artifact handoff (documentation only)

The bench job planned in 08 §8 will: write `bench-results.json` for the
tiers it ran; pass `--tiers ab` on main/dispatch and `--tiers a` on PR
runs; fetch the drift state from the latest main-branch bench job's
artifact (the state rides inside `bench-results.json` or its own
always-uploaded artifact; an `actions/cache` entry keyed on the
fingerprint is the documented alternative single state store) and pass
it via `--drift-state`; add `--update-drift-state` on main-branch runs
only; and run this checker with `if: always()` so partial results are
graded. None of that wiring exists in this offline checker.

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
