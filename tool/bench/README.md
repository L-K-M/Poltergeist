# M0 SSH fitness harness

Run every M0 scenario inside the fixture's single lifecycle:

```bash
dart pub get --directory tool/bench
test/integration/run.sh --lifecycle-only -- tool/bench/run.sh
```

Results are written atomically to `tool/bench/bench-results.json`. Each row
records raw bytes and microseconds, the measured RTT for shaped runs, the exact
dartssh2 version and Séance revision, UTC capture time, and host. MB/s is
derived from bytes and microseconds. Throughput attempts are checkpointed in
`bench-results.json.attempts.json` before and after every prime, warmup, and
timed transfer.

CI runs one `standard` shard plus twelve isolated shaped-1-GB samples: both
directions, three variants, and two replicates. Each job creates
`bench-shard.json` before fixture setup and finalizes it on success or failure.
`bin/aggregate.dart` accepts exactly those thirteen source envelopes, embeds
their raw evidence, and publishes 78 manifest-ordered results with a SHA-256
source manifest.

For focused iteration, start the fixture lifecycle around one command and run
`dart run bin/bench.dart --help` from `tool/bench/`. `throughput` measures
1 MB, 100 MB, and 1 GB uploads/downloads through Séance's concrete VFS with
hashing on/off and a persistent OpenSSH `sftp` baseline. Each full path is
source-primed once; the selected persistent variant gets a 1 MB warmup
immediately before each timed trial. Every transfer uses a new destination and
is size/SHA-256 verified after timing. Affordable cells run in mirrored
`ABCCBA` order on one link profile. Isolated shaped-1-GB samples use a
315-minute monotonic lifecycle deadline, a 240-minute transfer cap, and a
30-minute evidence reserve. `algorithms` audits the client/server profiles.
`pipeline` runs
warmed, forward/reverse byte-verified reads, readdirs, channels, and transports
on fresh connections. `isolate` enforces the cancellation, progress,
timer-stall, socket/channel, and throughput-parity gates.
