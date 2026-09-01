# M0 SSH fitness harness

Run every M0 scenario inside the fixture's single lifecycle:

```bash
dart pub get --directory tool/bench
test/integration/run.sh --lifecycle-only -- tool/bench/run.sh
```

Results are written atomically to `tool/bench/bench-results.json`. Each row
records raw bytes and microseconds, the measured RTT for shaped runs, the exact
dartssh2 version and Séance revision, UTC capture time, and host. MB/s is
derived from bytes and microseconds.

CI runs `standard` and `rtt100-1gb-upload` shards in parallel. The slow shard
keeps its three variants in one counterbalanced cell. `bin/aggregate.dart`
accepts only the attributable 75 + 3 scenario sets and publishes 78 rows in a
canonical order.

For focused iteration, start the fixture lifecycle around one command and run
`dart run bin/bench.dart --help` from `tool/bench/`. `throughput` measures
1 MB, 100 MB, and 1 GB uploads/downloads through Séance's concrete VFS with
hashing on/off and a persistent OpenSSH `sftp` baseline. Each full path is
primed once; the selected persistent variant gets a 1 MB warmup immediately
before each timed trial. Mirrored, repeated trials reduce to a median on one
shared link profile. `algorithms` audits the four sshd profiles. `pipeline` runs warmed,
forward/reverse byte-verified reads, readdirs, channels, and transports on
fresh connections. `isolate` enforces the cancellation, progress, timer-stall,
socket/channel, and throughput-parity gates.
