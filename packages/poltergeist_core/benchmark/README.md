# P3 — remote listing overhead collector (D12 tier A)

`p3_listing_overhead.dart` is the tier-A entrypoint for scenario P3 of
02 §12 ("remote listing overhead over network time", < 50 ms), measured
per 07 §3.4's exit criterion: the **median of ≥ 5 warm paired runs of the
target listing minus a control listing over the same retained browse
channel** — never a single-run absolute wall clock.

## Measurement protocol

```
connect (untimed)  →  canonicalize target + control (untimed, must differ)
      →  W warmup pairs (discarded)  →  R measured pairs (rows)
pair   =  control listing  then  target listing, one channel, both timed
row    =  value = target − control (ms, unclipped: negative stays negative)
         + raw controlMs/targetMs + environment fingerprint
```

- One `PaneChannel` from the production `PooledConnectionManager` serves
  every listing of the run — the same-connection difference cancels
  network/crypto latency and isolates per-entry overhead.
- Authentication, channel setup, and canonicalization are untimed.
- Failure paths are honest: a failed listing or deadline writes the
  completed rows plus one `status: "error"` row naming the failure, and
  exits non-zero. Usage failures (missing flags/env, aliasing paths)
  exit 2 with an actionable message and write nothing.
- The collector never writes to the server: only `listDirectory` and
  `canonicalize` are issued against the two caller-supplied existing
  directories. No retries; per-listing and whole-run deadlines bound it.
- Rows match the `poltergeist-d12-results-1` schema consumed by
  `test/benchmarks/check.dart`; the per-row fingerprint carries
  `scenarioConfig` (canonical paths, entry counts, warmups, repetitions)
  so a changed tree surfaces as controlled-axis drift, not a silent
  comparison.

## Truthful run mode

The fingerprint's `mode` axis is detected, never declared: `dart compile
exe` output reports `aot`, and anything running from Dart/kernel sources
reports `jit` (including product-mode JIT). The checker only counts `aot`
rows toward the tier-A repetition floor (08 §6), so `dart run` numbers
can never gate a budget.

## Real-fixture invocation

Docker on this host is unavailable, so this command is documented, not
locally verified (CI's bench job owns the first real run — open item 21):

```bash
test/integration/run.sh --lifecycle-only -- bash -c '
  set -e
  cd packages/poltergeist_core
  dart compile exe benchmark/p3_listing_overhead.dart -o /tmp/p3-collector
  /tmp/p3-collector \
    --output bench-results.json \
    --target /home/poltergeist/bench/fixtures/entries-10000 \
    --control /home/poltergeist/bench
'
```

- `run.sh --lifecycle-only` owns the fixture lifecycle (readiness, smoke,
  teardown) and exports the collector's required environment, invoking the
  child command from the repo root (`run.sh` cds there): `POLTERGEIST_SSHD`
  (host), `POLTERGEIST_SSHD_MODERN` (port), `POLTERGEIST_SSHD_USER`, and
  `POLTERGEIST_SSHD_KEY` (per-run user private key path). The collector
  treats unset and empty identically and exits 2 naming every missing
  variable; optional overrides: `POLTERGEIST_BENCH_RUNNER_IMAGE`,
  `POLTERGEIST_BENCH_CPU_MODEL`.
- The suggested pair: `entries-10000` (10 000 committed fixture entries)
  as the target and `/home/poltergeist/bench` (the two-directory bench
  root) as the minimal control. Any existing, distinct directories work;
  canonical aliasing is rejected.
- The trust setup follows the 08 §5 non-TOFU convention: the in-memory
  pin store is pre-seeded from the committed fixture host public key at
  `test/integration/keys/ssh_host_ed25519_key.pub` (the `--host-key-pub`
  default, resolved from the repo root `run.sh` cds to; the required
  env vars above carry the *user* key, not this host key), so a healthy
  fixture never prompts; an unexpected host-key review aborts the run
  instead of benchmarking against an unverified server.

## Local iteration

`dart run benchmark/p3_listing_overhead.dart --help` from this package
works without the fixture (usage/argument contracts only); every
measurement attempt without the fixture env exits 2 naming what is
missing. Local numbers are JIT and must never be quoted against a budget.

## Validation status

- Deterministic contract tests:
  `test/benchmark/p3_listing_overhead_test.dart` (sampler pairing,
  ordering, one-channel, warmup discard, repetition identities, honest
  failure/partial output, cleanup, mode detection, CLI subprocess
  contracts, and the real `check.dart` CLI evaluating collector output
  against a test-owned catalog).
- AOT compile of the exact source is verified locally
  (`dart compile exe`); the fixture-backed measurement itself was not run
  on this host (no Docker) and remains open item 21's CI job.
