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

For focused iteration, start the fixture lifecycle around one command and run
`dart run bin/bench.dart --help` from `tool/bench/`. `throughput` requires
`--implementation dart|openssh`; the runner resets each link between them. It measures
1 MB, 100 MB, and 1 GB uploads/downloads through Séance's concrete VFS with
hashing on/off and a persistent OpenSSH `sftp` baseline. `algorithms` audits
the four sshd profiles. `pipeline` byte-verifies concurrent reads, readdirs,
channels, and transports. `isolate` enforces the cancellation, progress,
timer-stall, socket/channel, and throughput-parity gates.
