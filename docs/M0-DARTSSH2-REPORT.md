# M0 dartssh2 fitness report

<!-- m0-evidence-state: pending -->

<!-- Finalize only from a complete, validated canonical artifact. Runs
33458209337, 33481554062, and 33504660759 are partial; 33534298280 stopped in
preflight. All are inadmissible. -->

## Verdict

Pending final evidence.

## Evidence and method

| Item | Value |
|---|---|
| Poltergeist input | Pending final run. |
| Workflow | Pending final run. |
| Canonical artifact | Pending final upload. |
| dartssh2 | `2.22.0` |
| Séance | fork `BigBoyDevBox/Seance`, revision `142db7b40fd6bdaab35fe295267035dca547d240` |
| Séance ancestry | S0 merge `4d8ee1e026ce4e5d939d6390d9fd98a78fabcf6e`; S1 merge `599ff936b8222e6cd77920495dcdcc4a50643f44` |
| Modern fixture | Alpine `20260805` at `sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000`; OpenSSH `10.5_p1-r1`; iproute2 `7.1.0-r0` |
| Legacy fixture | `ghcr.io/l-k-m/poltergeist-sshd-legacy@sha256:7c3e2ef3c54f27c484e916ce5937297e2429d5f39edcd407bc01d0f1e1eb41dd`; OpenSSH `8.4p1` |
| Rows | Pending validation: 78 canonical rows. |

Rates use decimal MB/s (`bytes / elapsedUs`). Every throughput trial primes
only its source, uses a unique absent destination, warms its selected client
with 1 MB, then verifies destination size and SHA-256 outside timing. Affordable
cells run in `ABCCBA` order, yielding two samples per variant; each value is
that variant's floor-midpoint median. Each shaped 1 GB value instead combines
two isolated hosted-job replicates under a 315-minute monotonic lifecycle cap
and is descriptive evidence only. The shaped profile applies 50 ms delay with
25 ms jitter in each direction; every source retains seven end-to-end SSH RTT
probes.

Pipeline trials warm each variant, use fresh connections, run in forward and
reverse order, and report their two-sample median. File reads verify the known
fixture SHA-256 after timing. Concurrent readdirs verify directory-specific
names, so duplicated or swapped responses fail.

The isolate comparison warms both contexts, interleaves three samples per
context, and compares median throughput. Its remaining gates measure
cross-port cancellation, progress coalescing, and main-isolate timer stalls.

## Throughput

Pending final evidence.

## Algorithm audit

Pending final evidence.

## Pipelining and pool policy

Pending final evidence.

## Isolate proof

Pending final evidence.

## Reproduction and limits

The committed harness can run the unsplit diagnostic locally:

```bash
dart pub get --directory tool/bench
test/integration/run.sh --lifecycle-only -- tool/bench/run.sh full
```

The final 13-source artifact reconstruction command is recorded with the
validated run.

Pending final limitations.
