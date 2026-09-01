# SFTP integration fixture

The fixture exposes test-only OpenSSH servers on IPv4 loopback. It creates
sparse, zero-filled benchmark payloads at runtime, so no large blobs enter Git.

```bash
test/integration/run.sh
```

`run.sh` regenerates the user key, builds the current image, pulls the frozen
legacy image by digest, checks every rendered Compose profile for unsafe
publishing, waits for real SSH banners, runs the OpenSSH smoke checks, then
runs tagged Dart integration tests serially. Its exit trap removes all
services, including the profiled keyswap service.

`sshd-legacy/Dockerfile` records how the public GHCR artifact was built. CI
never rebuilds it, so an archive or package-index change cannot alter M0.

Run a benchmark inside the same lifecycle owner:

```bash
test/integration/run.sh --lifecycle-only -- tool/bench/run.sh
```

Benchmark defaults:

| Endpoint | Port | Purpose |
|---|---:|---|
| `sshd-modern` | 2201 | LAN baseline |
| `sshd-modern` | 2201 | ~100 ms RTT after `network-profile.sh rtt100` |
| `sshd-legacy` | 2202 | OpenSSH 8.4 defaults |
| `sshd-chroot` | 2203 | chrooted `internal-sftp` only |
| `sshd-restricted` | 2204 | rejects `setstat` and `fsetstat` |
| `sshd-authmatrix` | 2205 | authentication failures |
| `sshd-rsa` | 2211 | RSA-SHA2 host signatures only |
| `sshd-chacha` | 2212 | chacha20 with PQ/curve25519 KEX |
| `sshd-ed25519` | 2213 | Ed25519 host key only |

The user is `poltergeist`; its test-only password is
`poltergeist-test-only`. The fresh private key is
`test/integration/runtime/id_ed25519`. Modern benchmark data is rooted at
`/home/poltergeist/bench`: read-only inputs are under `fixtures/`, and uploads
go under `uploads/`.

Generated inputs are `payload-1mb.bin`, `payload-100mb.bin`,
`payload-1gb.bin`, `entries-10000/`, and eight `readdir-00` through
`readdir-07` directories with 100 path-prefixed entries each.

Toggle latency without restarting sshd:

```bash
test/integration/network-profile.sh rtt100
test/integration/network-profile.sh measure-rtt-ms
test/integration/network-profile.sh lan
```

The RTT profile applies 50 ms delay with 25 ms jitter to both ingress and
egress. `measure-rtt-ms` prints only the median SSH version-to-KEX RTT integer.
Record that value; configured delay is not a measurement.

Host private keys in `keys/` are fake, loopback-only fixtures. They are stable
so TOFU tests are repeatable. The user key is deliberately ephemeral.
