# Run3 task94 — M9 polish pass 2 audit (2026-09-22)

Scope: the `BENCH_ENFORCE_B` flip + full-D12 audit, the local
fast-path spike (D26), the link-only update check (D19). One PR on
`poltergeist/m9-polish-2`.

## 1. D12 audit — per-benchmark status

Evidence runs (main-branch `ci.yml`, artifact `bench-results`):

- 35763533669 (2026-09-22) — runner image `ubuntu-latest@20260920.314.1`,
  CPU `AMD EPYC 7763 64-Core Processor`. **The baseline/calibration
  fingerprint.** The only main run on the rotated image so far.
- 35739239853, 35721017653, 35721016487, 35718273275, 35702484810,
  35676648317, 35662527435 (2026-09-21/22) — image
  `ubuntu-latest@20260907.300.1` across five CPU models (7763, 8573C,
  6973P-C, 9V45, 9V74); used for fleet-shape evidence only.
- Historical calibration pool (tier-A budgets): 35005140193,
  35028604913, 35033568776, 35086417157, 35125183171.

Medians vs budgets on the recorded fingerprint (run 35763533669):

| Scenario | Exists | Runs | Median | Budget / rule | Status |
|---|---|---|---|---|---|
| P1 first paint 10k | yes | 3 ok | 1044.803 ms | <150 ms product target; tier-B gate is trend (baseline 1044.803 ms, fail > +25%) | landed + enforced |
| P2 first paint 100k | yes | 3 ok | 11836.997 ms | <1 s target; trend vs baseline 11836.997 ms | landed + enforced |
| P3 listing overhead | yes | 5 ok | 4498.053 ms | <5500 ms (calibrated) | landed + enforced, pass |
| P4 tab switch | yes | 5 ok | 40.004 ms | <100 ms target; trend vs baseline 40.004 ms | landed + enforced |
| P5 drop→start | yes | 5 ok | 4818.734 ms | <6000 ms (calibrated) | landed + enforced, pass |
| P6 scroll frames | yes | 3 errored | — | ≤0.2% over deadline; needs ≥1800 frames/30 s | **structurally absent** |
| P7 scan rate | yes | 5 ok | 2248.033 entries/s | ≥1000 entries/s | landed + enforced, pass |

Enforcement rule for the absent scenario: expectations are derived
from `landed` scenarios only (check.dart's documented scope rule — a
landed scenario missing or erroring fails in every mode, an unlanded
one is reported but never judged). P6 stays `landed: false` in
`budgets.json`, so enforcement covers exactly the present set
{P1, P2, P4} on tier B plus {P3, P5, P7} on tier A. P6's blocker is
structural: under llvmpipe the 30 s scripted scroll captures ~750–830
frames (latest run: 827, 829) against the ≥1800-frame floor the
measured ~60 Hz vsync cadence implies — no honest median exists, so
none was fabricated.

Absolute-vs-trend honesty note: P1's ~1.0 s and P2's ~11.8 s are the
llvmpipe software stack, not the <150 ms/<1 s product budgets — the
tier-B gate is the §6 trend mechanism (>25 % regression vs the
committed baseline), which is exactly what it exists to expose. Tier-A
budgets are the 2026-09-17 calibrated values and all three pass on the
new image.

## 2. The flip — what changed

- `budgets.json`: `landed: true` on P1/P2/P4; `calibratedFingerprint.runnerImage`
  → `ubuntu-latest@20260920.314.1`; P5 `calibratedScenarioConfig`
  `first-file` → `entry-02814.txt` (the image rotation shifted the
  fixture's readdir order — 08368 → 02814).
- `tier-b-baseline.json`: fingerprint → `20260920.314.1`; medians
  re-measured from run 35763533669 (P1 1044.803/n=3, P2 11836.997/n=3,
  P4 40.004/n=5). One-run pool; `repetitions` records the shortfall
  per the refresh procedure. Deviation recorded: the refresh rode
  inside the flip PR rather than a dedicated refresh PR, because a
  landed gate on a stale fingerprint would hard-fail the very run that
  arms it.
- `ci.yml` bench job: forwards `vars.BENCH_ENFORCE_B`; restores the
  drift-state store from `actions/cache` (`d12-drift-state-*` keys)
  before grading; re-evaluates with `--update-drift-state` and saves
  the store on `refs/heads/main` runs only; on a failed `ab`
  evaluation re-runs `scripts/bench-tier-b.sh` once before red
  (tier-A per-scenario docs held aside across the rerun's cleanup and
  re-merged). Drift state + `evaluate.log` now ship in the
  always-uploaded artifact.
- Runner class: no larger/pinned GitHub-hosted class is available to
  this repo (runners API 403 on enumeration; free-tier labels carry no
  size pin). The committed fingerprint remains the rotation-control
  instrument per 08 §6 — a controlled-axis change hard-fails under
  enforcement and clears only via a recalibration PR.
- Checker contract tests re-pinned (`check_test.dart`,
  `check_cli_test.dart`); `dart test test/benchmarks` 138/138 green.
- Verified locally against the real artifacts: run 35763533669 grades
  green under `BENCH_ENFORCE_A=1 BENCH_ENFORCE_B=1` with a clean
  drift-state write; a pre-rotation artifact produces the expected
  soft drift notices (exit 0).

Post-merge arming order (deliberate): merge with the repo variable
unset → the merge run seeds the cache store soft → then set
`BENCH_ENFORCE_B=true`. Reason: unknown drift history counts
conservatively at the escalation threshold, so arming before the
store exists would redden on the first CPU-axis drift (the fleet is
heterogeneous — 5 CPU models in the 8 sampled runs).

## 3. D26 — local fast-path spike

Measured on this host (Linux 7.0, overlayfs `/tmp`;
`packages/poltergeist_core/benchmark/local_copy_fastpath.dart`,
median of 3 per cell, MB/s):

| Size | streamed (old path) | streamed 1 MiB buf | File.copy | FICLONE | cfr chunked 16 MiB | cfr single |
|---|---|---|---|---|---|---|
| 1 MiB | 151.3 | 405.0 | 1201.1 | EOPNOTSUPP | 2216.9 | 2245.3 |
| 64 MiB | 286.8 | 521.4 | 3009.1 | EOPNOTSUPP | 3171.9 | 3578.9 |
| 256 MiB | 358.4 | 667.9 | 3572.9 | EOPNOTSUPP | 3303.6 | 3266.2 |

tmpfs (`/dev/shm`) also returns EOPNOTSUPP for FICLONE on this kernel —
no reflink evidence anywhere on this host.

- **Adopted: Linux `copy_file_range(2)`**, ~6–15× the streamed path,
  behind the `LocalCopyPump` seam (`local_copy_pump.dart`). 16 MiB
  chunks keep progress reporting and cancellation responsive (a chunk
  is ~5 ms at kernel speed); decline conditions (EPERM/EBADF/EXDEV/
  EINVAL/ENOSYS/EOPNOTSUPP) fall back to the streamed pump. Temp-file +
  atomic rename commit, conflict checks, and mode preservation are
  unchanged in `LocalFileSystem.copyLocalFile`; `TransferQueue`
  short-circuits local→local hops to it. The bypassed `_localLimiter`
  is a documented no-op bucket — throttle semantics preserved.
- **FICLONE: deferred** — unsupported on both filesystems available
  here; no measurable win exists on this host.
- **Windows CopyFileEx:** semantics-compatible candidate
  (`CopyProgressRoutine` supplies per-chunk progress; `pbCancel` cancels
  mid-copy) but unmeasured — no Windows host. Deferred to v1.x.
- **APFS clonefile(2) (source-research only, no macOS host):**
  `clonefile`/`copyfile(COPYFILE_CLONE)` is a near-instant CoW clone —
  the strongest candidate on macOS, but it is atomic rather than
  chunked: progress is trivially "done" and there is no mid-copy
  cancel point. Semantics-compatible with the pump contract
  (progress-after-chunk trivially satisfied; cancel before start is
  honored by the caller's gate). Adopt when a macOS host can measure it.
- Coverage: 20 local-ops tests exercise the pump seam — progress,
  fallback on decline, cancellation cleanup, mtime/mode preservation,
  cross-device copy+delete, failed-copy source preservation, and the
  scripted-fault paths rerouted through the pump.

## 4. D19 — link-only update check

- `UpdateCheckController` wraps the pinned `seance_core`
  `UpdateChecker`/`AppVersion`/`UpdateInfo` (reused, not forked — D2)
  against `poltergeistUpdateRepo = 'L-K-M/Poltergeist'`. A plain GET of
  GitHub's latest-release API; the response is compared locally.
  **No asset is ever downloaded or installed** — the banner's only
  action opens `UpdateInfo.releasesUrl` externally through the app's
  local-file-opener/browser seam.
- Banner mounts in `WorkspaceShell` between toolbar and panes; names
  the newer tag; dismissible for the session.
- Opt-out setting `updates.checkEnabled` in General settings
  (`app.settings` command, ⌘, / Ctrl+,, File-menu placement), persisted
  through `AppPreferences`/`SettingsStore`; the toggle reverts if
  persistence fails; a disabled check never touches the network.
- Launch-time check is best-effort after `runApp`.
- ARB strings added; localization contract intact.
- Tests: 17 targeted (controller enabled/disabled/persist-failure/
  dismiss/versions-older-equal-newer; banner render/dismiss/link;
  settings toggle; shell-level mount + command registration).

## 5. Verification status

- `dart analyze packages/poltergeist_core` — clean.
- `dart test packages/poltergeist_core` — 1441 pass, 21 expected skips.
- `dart test test/benchmarks` — 138 pass (committed-file contract
  re-pinned for the flip).
- `dart analyze test/benchmarks` — clean.
- `flutter analyze` — clean.
- `flutter test` — 1681 pass (17 targeted D19 tests included).

Remaining QA: P6 harness fix (llvmpipe frame floor) is a recorded
deferral, not part of this task; Windows CopyFileEx and APFS clonefile
measurement need their hosts; the first enforced tier-B run is verified
on CI post-merge (variable arming order above).
