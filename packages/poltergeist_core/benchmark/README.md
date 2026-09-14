# D12 tier-A collectors

Three pure-Dart tier-A entrypoints live here:
`p3_listing_overhead.dart` (P3, listing overhead),
`p5_drop_to_start.dart` (P5, drop → transfer start), and
`p7_scan_rate.dart` (P7, scan rate). All run against the §5 Docker
fixture on loopback under `test/integration/run.sh --lifecycle-only`,
emit the shared `poltergeist-d12-results-1` document with their own
per-scenario `scenarioConfig` axis, and stay unlanded in
`test/benchmarks/budgets.json` until real calibration lands (open item
21) — the CI `bench` job runs them but only reports while nothing is
landed. All collectors are read-only against the fixture:
`canonicalize`, `listDirectory`, and (P5 only) a first-byte `download`
that cancels itself after the first chunk — never a write.

## CI bench job

The `bench` job in `.github/workflows/ci.yml` runs all three collectors
through `scripts/bench-tier-a.sh` under `run.sh --lifecycle-only`:
each is compiled AOT (`dart compile exe`), run against `sshd-modern`,
and its per-scenario document is merged by
`scripts/merge_bench_results.dart` into the single `bench-results.json`
that `test/benchmarks/check.dart --tiers a` grades and the job uploads
as the `bench-results` artifact. The per-collector invocations below are
the same commands that script issues; they remain useful for local
iteration against a hand-started fixture.

## P3 — remote listing overhead

`p3_listing_overhead.dart` is the tier-A entrypoint for scenario P3 of
02 §12 ("remote listing overhead over network time", < 50 ms), measured
per 07 §3.4's exit criterion: the **median of ≥ 5 warm paired runs of the
target listing minus a control listing over the same retained browse
channel** — never a single-run absolute wall clock.

## P3 measurement protocol

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
  directories. No retries; per-listing and whole-run deadlines bound
  every listing **wait** at the lesser of the two limits — the pinned VFS
  offers no IO cancellation (open item 12), so expiry means the collector
  reports, stops waiting, and retires the channel inside the bounded
  cleanup while the wedged listing's IO may still finish engine-side.
- Rows match the `poltergeist-d12-results-1` schema consumed by
  `test/benchmarks/check.dart`; the per-row fingerprint carries
  `scenarioConfig` (canonical paths, entry counts, warmups, repetitions).
  The checker treats it as a per-scenario axis — one config within a
  scenario's repetitions, distinct configs across the job's scenarios —
  and compares each landed tier-A scenario against its own calibrated
  config (budgets schema -2), so a changed tree surfaces as that
  scenario's controlled-axis drift, never a silent comparison and never
  a rejection of the one shared results file.
- A tree that changes size mid-run fails the run at the changing pair;
  the completed rows (and the error row) keep the frozen entry counts
  the measurements were taken under, and the changed observation is
  reported only in the error row's text (`10000->9999`).

## P3 truthful run mode

The fingerprint's `mode` axis is detected, never declared: `dart compile
exe` output reports `aot`, and anything running from Dart/kernel sources
reports `jit` (including product-mode JIT). The checker only counts `aot`
rows toward the tier-A repetition floor (08 §6), so `dart run` numbers
can never gate a budget.

## P3 real-fixture invocation

Docker on this host is unavailable, so this command is documented, not
locally verified (the CI `bench` job runs exactly this):

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

## P3 local iteration

`dart run benchmark/p3_listing_overhead.dart --help` from this package
works without the fixture (usage/argument contracts only); every
measurement attempt without the fixture env exits 2 naming what is
missing. Local numbers are JIT and must never be quoted against a budget.

## P3 validation status

- Deterministic contract tests:
  `test/benchmark/p3_listing_overhead_test.dart` (sampler pairing,
  ordering, one-channel, warmup discard, repetition identities, honest
  failure/partial output, cleanup, mode detection, CLI subprocess
  contracts, and the real `check.dart` CLI evaluating collector output
  against a test-owned catalog).
- AOT compile of the exact source is verified locally
  (`dart compile exe`); the fixture-backed measurement itself was not run
  on this host (no Docker); the CI `bench` job owns fixture runs.

## P7 — sync scan rate

`p7_scan_rate.dart` is the tier-A entrypoint for scenario P7 of 02 §12
("sync scan rate, LAN", ≥ 1 000 remote entries/s): **sustained bulk
listing throughput of a fixture tree over one retained browse channel** —
the measurement substrate of 05 §3's `TreeScanner` (which lands with the
sync engine; the scenario itself gates at M8 per 07 §3.4).

## P7 measurement protocol

```
connect (untimed)  →  canonicalize target root (untimed)
      →  W warmup scans (discarded)  →  R measured scans (rows)
scan   =  recursive breadth-first walk of the target tree with at most 8
          outstanding listDirectory calls (05 §3's pipelined readdir at
          D9's frozen depth); symlinks are counted, never descended
row    =  value = entries / elapsed seconds (unclipped)
         + raw entries/directories/elapsedMs + environment fingerprint
```

- The same one-channel, warmup-discard, honest-failure, and owned
  exclusive-temp publication contracts as P3 hold (the temp publication
  is a faithful mirror of the `p3TempNameAttempts` pattern, the same
  ownership class the checker's drift state carries).
- Whole-run deadline and per-listing timeout bound every listing await
  — issued calls are capped at issue AND the pipeline drain is capped at
  the remaining budget, so a listing issued early is never waited out
  past the deadline.
- `--target` is the tree root; the suggested real-fixture target is
  `/home/poltergeist/bench/fixtures` (the committed fixture tree:
  `entries-10000` plus the eight `readdir-*` sibling directories and the
  payload files, ≈ 10 800 entries across ≈ 10 directories). The scan
  reads every directory once per scan.
- Row `scenario` is `P7`, `unit` is `entries/s`, `operator`-compatible
  with budgets.json's `atLeast 1000`. The catalog's
  `minimumRepetitions` for P7 is 3 — the generic 08 §6 floor the
  catalog mirrors (P3's row carries 5 because 07 §3.4 names that
  protocol explicitly; M8 names no P7 floor). The collector enforces
  the stricter ≥ 5 measured scans regardless, matching P3's protocol.

## P7 real-fixture invocation

Docker on this host is unavailable, so this command is documented, not
locally verified (the CI `bench` job runs exactly this):

```bash
test/integration/run.sh --lifecycle-only -- bash -c '
  set -e
  cd packages/poltergeist_core
  dart compile exe benchmark/p7_scan_rate.dart -o /tmp/p7-collector
  /tmp/p7-collector \
    --output bench-results.json \
    --target /home/poltergeist/bench/fixtures
'
```

The environment contract (`POLTERGEIST_SSHD*` exports, the pre-seeded
committed host key, the loopback-only guard, the optional
`POLTERGEIST_BENCH_*` fingerprint overrides) is identical to P3's above.

## P7 local iteration

`dart run benchmark/p7_scan_rate.dart --help` from this package works
without the fixture (usage/argument contracts only); every measurement
attempt without the fixture env exits 2 naming what is missing. Local
numbers are JIT and must never be quoted against a budget.

## P7 validation status

- Deterministic contract tests:
  `test/benchmark/p7_scan_rate_test.dart` (pipelined-walk ordering and
  depth bound, warmup discard, symlink non-descent, entry-count identity
  guard with frozen partial-row configs, deadline/timeout attribution,
  owned-temp collision and symlink safety, cleanup contracts, CLI
  subprocess contracts, and the real `check.dart` CLI evaluating
  collector output — including the one-file P3+P7 mixed-config shape the
  bench job will emit).
- AOT compile of the exact source is verified locally
  (`dart compile exe`); the fixture-backed measurement itself was not run
  on this host (no Docker); the CI `bench` job owns fixture runs.

## P5 — drop to transfer start

`p5_drop_to_start.dart` is the tier-A entrypoint for scenario P5 of
02 §12 ("drop → transfer starts (no upfront tree stat)", < 500 ms):
**the time from a drop event until the first payload byte of the first
transfer item arrives** — the measurement surface for the M4 transfer
queue's drop→start leg. The queue itself is M4 work and is deliberately
not implemented here; the collector models the leg over the existing
browse-channel/`leaseTransferChannel` seams: classify the drop, resolve
the first transferable file, lease a transfer channel, and measure to
the first byte through a counting `StreamSink`.

## P5 measurement protocol

```
connect (untimed)  →  canonicalize target (untimed)
      →  W warmup drops (discarded)  →  R measured drops (rows)
drop   =  one stat of the dropped root (classification; the bare-path
          conservative case — a pane drag arrives with its listing entry)
       →  breadth-first listings only until the first regular file
          (symlinks are never followed; `other` kinds are skipped)
       →  leaseTransferChannel + download to first byte, then the
          collector's own cancellation settles the leg
row    =  value = drop → first byte (ms, unclipped)
         + raw statCalls/listingCalls/firstFile/firstChunkBytes/
           legSettledMs + environment fingerprint
```

- The structural half of the budget — "no upfront tree stat" — is
  enforced as a falsifiable contract, not asserted in prose: the drop→
  start path issues exactly one stat (the classification stat) plus
  listing-only descent, and the deterministic test counts stat calls
  through a fake filesystem at 1k and 50k entries and requires the
  counts to be identical — "O(first file), not O(tree)". Every row also
  carries its own `statCalls`/`listingCalls` provenance, and a per-leg
  change in either count fails the run as an identity change.
- The same retained-browse-channel, warmup-discard, honest-failure, and
  owned exclusive-temp publication contracts as P3/P7 hold. Each leg
  additionally leases a transfer channel (the production
  `leaseTransferChannel` seam, bounded by the per-operation timeout) and
  releases it inside the bounded leg — the lease acquire/release pair is
  part of the measured window because queue-less drop→start includes it.
- The first-byte boundary is a counting `StreamSink`: the sink records
  the first chunk's size and cancels the transfer; a cancellation
  observed after that byte ends the leg cleanly, a cancellation or
  failure before any byte is an honest leg failure, and an empty first
  file fails the leg ("drop→start is unobservable on an empty file")
  rather than reporting the full-download time.
- Whole-run deadline and per-operation timeout bound every await —
  stat, listing, lease, and download alike — with run-budget expiry
  attributed distinctly from per-operation timeouts.
- `--target` is the dropped path — a directory or a single file. The
  suggested real-fixture target is
  `/home/poltergeist/bench/fixtures/entries-10000` (the committed
  10 000-entry tree; its first file in listing order starts the leg). A
  dropped *file* needs no listings at all (`kind=file` records that
  shape in `scenarioConfig`).
- Row `scenario` is `P5`, `unit` is `ms`, `operator`-compatible with
  budgets.json's `lessThan 500`. The catalog's `minimumRepetitions` for
  P5 is 3 — the generic 08 §6 floor — but the collector enforces ≥ 5
  measured drops regardless, matching the P3/P7 protocol.
- The P5-specific `scenarioConfig` carries the drop path, the dropped
  kind, the frozen root-listing size (`n/a-file-drop` for file drops),
  the frozen first-file path, warmups, repetitions, the start boundary
  (`lease+first-byte`), and `hash=off` (the leg never pays for the VFS's
  optional checksum). A mid-run change to any frozen axis fails the run
  at the changing drop; completed rows and the error row keep the frozen
  identity.

## P5 real-fixture invocation

Docker on this host is unavailable, so this command is documented, not
locally verified (the CI `bench` job runs exactly this):

```bash
test/integration/run.sh --lifecycle-only -- bash -c '
  set -e
  cd packages/poltergeist_core
  dart compile exe benchmark/p5_drop_to_start.dart -o /tmp/p5-collector
  /tmp/p5-collector \
    --output bench-results.json \
    --target /home/poltergeist/bench/fixtures/entries-10000
'
```

The environment contract (`POLTERGEIST_SSHD*` exports, the pre-seeded
committed host key, the loopback-only guard, the optional
`POLTERGEIST_BENCH_*` fingerprint overrides) is identical to P3's above.

## P5 local iteration

`dart run benchmark/p5_drop_to_start.dart --help` from this package
works without the fixture (usage/argument contracts only); every
measurement attempt without the fixture env exits 2 naming what is
missing. Local numbers are JIT and must never be quoted against a
budget.

## P5 validation status

- Deterministic contract tests:
  `test/benchmark/p5_drop_to_start_test.dart` (the two-size flat-stat
  structural assertion at 1k vs 50k entries, listing-only descent,
  warmup discard, file/symlink/empty-tree drop shapes, deadline/timeout
  attribution, mid-run identity changes with frozen partial-row configs,
  owned-temp collision and symlink safety, per-leg lease and channel
  cleanup contracts, CLI subprocess contracts, and the real `check.dart`
  CLI evaluating collector output — including a one-file P3+P5+P7
  mixed-config run under `--tiers a` with all scenarios unlanded, exit
  0, all reported).
- AOT compile of the exact source is verified locally
  (`dart compile exe`); the fixture-backed measurement itself was not run
  on this host (no Docker); the CI `bench` job owns fixture runs.
