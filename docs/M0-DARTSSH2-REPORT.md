# M0 dartssh2 fitness report

<!-- m0-evidence-state: required -->
<!-- m0-evidence-sha256: b93660b9f1c06bac206096d25c6fff472bcb31d13589a4d81bd5a3df70fa7fcc -->

## Verdict

Adopt dartssh2 3.0.2 at D9 ladder rung 4: it is correct, cancellable, and
scales across channels and transports, but its single-file LAN-class Docker
loopback rate is about 10–11× below OpenSSH with hashing off, and it lacks
chacha20-poly1305 and ML-KEM. Keep bounded channel/transport compensation; do
not move to libssh2.
D7 remains opt-in hashing for bulk transfers and sync, while managed checkouts
retain mandatory hashes. Every D8 gate passed, so sockets, SFTP, transfers, and
hashing remain in the engine isolate. Set `PoolPolicy` defaults to two
transports, four transfer channels per transport, eight total channels per
transport, six global files in flight, and scan readdir depth eight. Retain
the design's unmeasured 30-second keepalive, 60-second extra-transport idle
timeout, 30-second reconnect cap, and five task retries.

## Evidence and method

| Item | Value |
|---|---|
| Poltergeist input | `6b8873eafdaaa3a4157e265dee838ab3b47219b3` |
| Workflow | [run 33563514640](https://github.com/L-K-M/Poltergeist/actions/runs/33563514640), attempt 1; aggregate job `100080014085` |
| Transport artifact | `m0-bench-results`, ID `9826637498`, 87,727 bytes; archive SHA-256 `398cfb085d679546cb4c58c3abb2bcb3b4ad5b1e34a40d735ff30c525b373309` |
| Canonical artifact | [`docs/evidence/m0/m0-evidence.json`](evidence/m0/m0-evidence.json); SHA-256 `b93660b9f1c06bac206096d25c6fff472bcb31d13589a4d81bd5a3df70fa7fcc` |
| Sources and rows | 13 successful source envelopes; 78 canonical rows; independent rebuild byte-identical |
| Capture window | Standard: 2026-09-01 21:55:42–2026-09-02 00:18:59 UTC; isolated sources: 2026-09-01 21:55:38–2026-09-02 00:36:13 UTC |
| Runtime | Dart 3.13.3; GitHub `ubuntu24` image `20260823.283.1`; Linux x64 |
| dartssh2 | `3.0.2` |
| Séance | fork `BigBoyDevBox/Seance`, revision `0a695971a411a6a754593e7c2598038039440c2f` |
| Séance ancestry | S0 `4d8ee1e026ce4e5d939d6390d9fd98a78fabcf6e`; S1 `599ff936b8222e6cd77920495dcdcc4a50643f44`; cancellation `da9d45492ac7d25cbc4eefb97a6ec29254de219f`; dependency docs `812b89f182fed162edc27fc0b7022ced2cdd1a50` |
| Fixture | tree `f32dd38916909c5f51ff8d2c8ec9de7dfa225387`; data version 2 |
| OpenSSH client | `OpenSSH_9.6p1 Ubuntu-3ubuntu13.18, OpenSSL 3.0.13 30 Jan 2024` |
| Modern fixture | Alpine `20260805` at `sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000`; OpenSSH `10.5_p1-r1`; iproute2 `7.1.0-r0` |
| Legacy fixture | `ghcr.io/l-k-m/poltergeist-sshd-legacy@sha256:7c3e2ef3c54f27c484e916ce5937297e2429d5f39edcd407bc01d0f1e1eb41dd`; OpenSSH 8.4p1 |

Rates use decimal MB/s (`bytes / elapsedUs`). Every throughput trial primed
only its source, used a unique absent destination, warmed its selected client
with 1 MB, then verified destination size and SHA-256 outside timing.
Affordable cells ran in `ABCCBA` order; each value is the floor midpoint of
two samples. Each shaped 1 GB value instead combines two isolated hosted-job
replicates under a 315-minute monotonic lifecycle cap and is descriptive only.
The shaped profile applied 50 ms delay with 25 ms jitter in each direction;
every source retains seven SSH identification-to-KEX probes.

Pipeline trials warmed each setting, used fresh connections, ran in forward
and reverse order, and report their two-sample midpoint. File reads verified
the fixture SHA-256. Concurrent readdirs verified directory-specific names.
The isolate comparison warmed both contexts and interleaved three samples per
context.

## Throughput

The signed final column is `(hash-on elapsed / hash-off elapsed) - 1`.
Negative values mean the hash-on midpoint happened to be faster.

| Link | Payload | Direction | Hash on MB/s | Hash off MB/s | OpenSSH MB/s | Hash-on elapsed delta |
|---|---:|---|---:|---:|---:|---:|
| LAN-class Docker loopback | 1 MB | download | 2.076 | 2.065 | 122.504 | -0.6% |
| LAN-class Docker loopback | 1 MB | upload | 2.883 | 2.982 | 140.509 | +3.4% |
| LAN-class Docker loopback | 100 MB | download | 16.477 | 20.810 | 229.020 | +26.3% |
| LAN-class Docker loopback | 100 MB | upload | 16.607 | 20.694 | 223.554 | +24.6% |
| LAN-class Docker loopback | 1 GB | download | 17.963 | 22.793 | 225.457 | +26.9% |
| LAN-class Docker loopback | 1 GB | upload | 17.409 | 21.983 | 249.150 | +26.3% |
| 114 ms RTT | 1 MB | download | 0.331 | 0.180 | 0.214 | -45.7% |
| 114 ms RTT | 1 MB | upload | 0.150 | 0.112 | 0.129 | -24.9% |
| 114 ms RTT | 100 MB | download | 0.283 | 0.252 | 0.159 | -11.0% |
| 114 ms RTT | 100 MB | upload | 0.108 | 0.113 | 0.257 | +4.4% |

The loopback 100 MB and 1 GB cells put hashing cost at 24.6–26.9%. The
shaped cells reverse sign in several places and have wide raw spread, so they
do not support a statistical threshold. D7 therefore keeps hashing opt-in for
bulk transfers and sync; managed checkouts keep mandatory SHA-256.

The isolated shaped 1 GB rows preserve both raw rates and per-source RTT
medians; no aggregate RTT, host, or timestamp is invented.

| Direction | Client | Midpoint MB/s | Raw MB/s | Source RTT medians, ms |
|---|---|---:|---|---|
| Download | Dart, hash on | 0.216 | 0.236, 0.200 | 139, 77 |
| Download | Dart, hash off | 0.228 | 0.218, 0.239 | 139, 77 |
| Download | OpenSSH | 0.166 | 0.145, 0.194 | 91, 139 |
| Upload | Dart, hash on | 0.106 | 0.107, 0.106 | 139, 77 |
| Upload | Dart, hash off | 0.108 | 0.112, 0.104 | 139, 92 |
| Upload | OpenSSH | 0.159 | 0.176, 0.145 | 83, 92 |

OpenSSH is 9.9–11.3× faster than hash-off Dart on the loopback at 100 MB and
1 GB. Dart leads the shaped 100 MB and 1 GB downloads, while OpenSSH leads
the uploads. This direction-sensitive ceiling supports compensation and
disclosure, not a claim of parity.

## Algorithm audit

| Probe | Result |
|---|---|
| Modern defaults | Connected: curve25519-sha256, ssh-ed25519, aes128-ctr |
| OpenSSH 8.4 defaults | Connected: curve25519-sha256, ssh-ed25519, aes128-ctr |
| AES-128-GCM only | Connected with aes128-gcm@openssh.com |
| AES-256-GCM only | Connected with aes256-gcm@openssh.com |
| RSA-SHA2-512 only | Connected with rsa-sha2-512 |
| RSA-SHA2-256 only | Connected with rsa-sha2-256 |
| ed25519 host key only | Connected with ssh-ed25519 |
| chacha/PQ profile | Failed: `SSHAuthAbortError: SSHAuthAbortError(Connection closed before authentication)` |
| Client chacha20-poly1305 | Unsupported |
| Client curve25519-sha256 | Supported |
| Client mlkem768x25519-sha256 | Unsupported |

Current OpenSSH defaults interoperate through curve25519, ed25519, and AES.
The chacha-only fixture cannot connect, and the client cannot negotiate the
OpenSSH 10 default ML-KEM hybrid. D9 therefore records the compatibility and
single-file throughput ceilings at ladder rung 4, retains dartssh2 3.0.2, and
does not invoke the libssh2 fallback.

## Pipelining and pool policy

All read rows passed byte and digest verification. One-channel pipelining
worked at every tested pending-request depth.

| Pending reads | Loopback MB/s | 114 ms RTT MB/s |
|---:|---:|---:|
| 8 | 2.352 | 0.222 |
| 16 | 3.279 | 0.126 |
| 32 | 3.676 | 0.222 |

| Concurrent readdirs | Loopback entries/s | 114 ms RTT entries/s |
|---:|---:|---:|
| 1 | 482.3 | 155.3 |
| 8 | 3,639.2 | 531.2 |

| SFTP channels, one transport | Loopback MB/s | 114 ms RTT MB/s |
|---:|---:|---:|
| 1 | 3.635 | 0.160 |
| 2 | 6.921 | 0.207 |
| 3 | 9.664 | 0.185 |
| 4 | 11.969 | 1.289 |
| 8 | 17.132 | 0.543 |

| Transports | Loopback MB/s | 114 ms RTT MB/s |
|---:|---:|---:|
| 1 | 3.702 | 0.326 |
| 2 | 7.554 | 0.307 |
| 4 | 13.154 | 0.613 |

Eight readdirs improved throughput 7.5× on loopback and 3.4× on the shaped
link; the loopback result exceeds the 1,000 entries/s scan budget. Confirm
scan depth eight. Four transfer channels beat three by 23.9% on loopback and
were the shaped-link maximum; eight regressed there. Set two transports, four
transfer channels per transport, and eight total channels per transport.
The last value is the transport's browse-plus-transfer capacity, while the
independent global dispatch cap remains six files. Two transports already
expose eight transfer slots; more transports cannot raise v1 dispatch
concurrency and would add server connections. Eight simultaneous SFTP
channels completed correctly.

The remaining `PoolPolicy` defaults were not empirical M0 surfaces:
`keepAliveInterval` stays 30 seconds, `idleExtraTransportTimeout` 60 seconds,
`reconnectBackoffCap` 30 seconds, and `taskRetryLimit` five.

## Isolate proof

| Gate | Observed | Limit | Result |
|---|---:|---:|---|
| Engine/root throughput parity | 0.997 | 0.90–1.10 | Pass |
| Root / engine rate | 16.940 / 16.883 MB/s | — | Pass |
| Cross-port cancellation | 40,938 us | < 100,000 us | Pass |
| Synthetic progress input | 17,564.09 events/s | >= 10,000/s | Pass |
| UI / engine flood flushes | 26 / 26; 22.83/s | equal, nonzero, <= 30/s | Pass |
| Four-task progress | 0.44, 0.44, 0.44, 0.40/s; aggregate 1.73/s | <= 30/s each; <= 120/s aggregate | Pass |
| Main-isolate stall | 4,401 us | <= 16,000 us | Pass |
| Combined workload | 400 MB and 10,000 entries | four transfers plus listing | Pass |

Sockets, multiple SFTP channels, cancellation, progress coalescing, listing,
and transfer parity all passed inside the non-root engine isolate. D8 hardens
the planned ownership model without fallback.

## Canonical result map

The following projection is generated from canonical evidence and validated
byte-for-byte against it.

<!-- m0-result-map-start -->
| Scenario | Bytes | Elapsed µs | Note |
|---|---:|---:|---|
| dart-hash-on-download-1mb-lan | 1000000 | 481590 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025 |
| dart-hash-off-download-1mb-lan | 1000000 | 484317 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-download-1mb-lan | 1000000 | 8163 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-upload-1mb-lan | 1000000 | 346814 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025 |
| dart-hash-off-upload-1mb-lan | 1000000 | 335371 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-upload-1mb-lan | 1000000 | 7117 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-download-100mb-lan | 100000000 | 6069055 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=a993f8c574e0fea8c1cdcbcd9408d9e2e107ee6e4d120edcfa11decd53fa0cae |
| dart-hash-off-download-100mb-lan | 100000000 | 4805373 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-download-100mb-lan | 100000000 | 436643 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-upload-100mb-lan | 100000000 | 6021497 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=a993f8c574e0fea8c1cdcbcd9408d9e2e107ee6e4d120edcfa11decd53fa0cae |
| dart-hash-off-upload-100mb-lan | 100000000 | 4832213 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-upload-100mb-lan | 100000000 | 447319 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-download-1gb-lan | 1000000000 | 55669467 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=bc17f06f9d9b5f6f79ca189a1772b1a3a38d6e40c45bec50f9c4f28144efddca |
| dart-hash-off-download-1gb-lan | 1000000000 | 43872645 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-download-1gb-lan | 1000000000 | 4435427 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-upload-1gb-lan | 1000000000 | 57440553 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=bc17f06f9d9b5f6f79ca189a1772b1a3a38d6e40c45bec50f9c4f28144efddca |
| dart-hash-off-upload-1gb-lan | 1000000000 | 45489968 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-upload-1gb-lan | 1000000000 | 4013652 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-download-1mb-rtt100 | 1000000 | 3017978 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025 |
| dart-hash-off-download-1mb-rtt100 | 1000000 | 5560196 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-download-1mb-rtt100 | 1000000 | 4667559 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-upload-1mb-rtt100 | 1000000 | 6685962 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025 |
| dart-hash-off-upload-1mb-rtt100 | 1000000 | 8900319 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-upload-1mb-rtt100 | 1000000 | 7725190 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-download-100mb-rtt100 | 100000000 | 353834378 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=a993f8c574e0fea8c1cdcbcd9408d9e2e107ee6e4d120edcfa11decd53fa0cae |
| dart-hash-off-download-100mb-rtt100 | 100000000 | 397378928 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-download-100mb-rtt100 | 100000000 | 629832150 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-upload-100mb-rtt100 | 100000000 | 922247775 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=on; sha256=a993f8c574e0fea8c1cdcbcd9408d9e2e107ee6e4d120edcfa11decd53fa0cae |
| dart-hash-off-upload-100mb-rtt100 | 100000000 | 883459079 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; hash=off |
| openssh-upload-100mb-rtt100 | 100000000 | 389325403 | samples=2; aggregate=floor-midpoint; pathPrimed=true; variantWarmup=1mb-per-trial; order=ABCCBA; completion=batch-echo-drain |
| dart-hash-on-download-1gb-rtt100 | 1000000000 | 4620828884 | samples=2; aggregate=floor-midpoint; execution=isolated-hosted-jobs |
| dart-hash-off-download-1gb-rtt100 | 1000000000 | 4381631764 | samples=2; aggregate=floor-midpoint; execution=isolated-hosted-jobs |
| openssh-download-1gb-rtt100 | 1000000000 | 6032413726 | samples=2; aggregate=floor-midpoint; execution=isolated-hosted-jobs |
| dart-hash-on-upload-1gb-rtt100 | 1000000000 | 9407113332 | samples=2; aggregate=floor-midpoint; execution=isolated-hosted-jobs |
| dart-hash-off-upload-1gb-rtt100 | 1000000000 | 9244144896 | samples=2; aggregate=floor-midpoint; execution=isolated-hosted-jobs |
| openssh-upload-1gb-rtt100 | 1000000000 | 6273732695 | samples=2; aggregate=floor-midpoint; execution=isolated-hosted-jobs |
| algorithm-default | 0 | 242763 | connected: SSHTransport._kexType: SSHKexType(curve25519-sha256); SSHTransport._hostkeyType: SSHHostkeyType(ssh-ed25519); SSHTransport._clientCipherType: SSHCipherType(aes128-ctr); SSHTransport._serverCipherType: SSHCipherType(aes128-ctr); SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com); SSHTransport._serverMacType: SSHMacType(hmac-sha2-256-etm@openssh.com) |
| algorithm-legacy-default | 0 | 122963 | connected: SSHTransport._kexType: SSHKexType(curve25519-sha256); SSHTransport._hostkeyType: SSHHostkeyType(ssh-ed25519); SSHTransport._clientCipherType: SSHCipherType(aes128-ctr); SSHTransport._serverCipherType: SSHCipherType(aes128-ctr); SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com); SSHTransport._serverMacType: SSHMacType(hmac-sha2-256-etm@openssh.com) |
| algorithm-aes128-gcm | 0 | 112464 | connected: SSHTransport._kexType: SSHKexType(curve25519-sha256); SSHTransport._hostkeyType: SSHHostkeyType(ssh-ed25519); SSHTransport._clientCipherType: SSHCipherType(aes128-gcm@openssh.com); SSHTransport._serverCipherType: SSHCipherType(aes128-gcm@openssh.com); SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com); SSHTransport._serverMacType: SSHMacType(hmac-sha2-256-etm@openssh.com) |
| algorithm-aes256-gcm | 0 | 104299 | connected: SSHTransport._kexType: SSHKexType(curve25519-sha256); SSHTransport._hostkeyType: SSHHostkeyType(ssh-ed25519); SSHTransport._clientCipherType: SSHCipherType(aes256-gcm@openssh.com); SSHTransport._serverCipherType: SSHCipherType(aes256-gcm@openssh.com); SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com); SSHTransport._serverMacType: SSHMacType(hmac-sha2-256-etm@openssh.com) |
| algorithm-rsa-sha2-512 | 0 | 125928 | connected: SSHTransport._kexType: SSHKexType(curve25519-sha256); SSHTransport._hostkeyType: SSHHostkeyType(rsa-sha2-512); SSHTransport._clientCipherType: SSHCipherType(aes128-ctr); SSHTransport._serverCipherType: SSHCipherType(aes128-ctr); SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com); SSHTransport._serverMacType: SSHMacType(hmac-sha2-256-etm@openssh.com) |
| algorithm-rsa-sha2-256 | 0 | 102069 | connected: SSHTransport._kexType: SSHKexType(curve25519-sha256); SSHTransport._hostkeyType: SSHHostkeyType(rsa-sha2-256); SSHTransport._clientCipherType: SSHCipherType(aes128-ctr); SSHTransport._serverCipherType: SSHCipherType(aes128-ctr); SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com); SSHTransport._serverMacType: SSHMacType(hmac-sha2-256-etm@openssh.com) |
| algorithm-chacha-curve-pq | 0 | 13890 | failed: SSHAuthAbortError: SSHAuthAbortError(Connection closed before authentication) |
| algorithm-ed25519-only | 0 | 98796 | connected: SSHTransport._kexType: SSHKexType(curve25519-sha256); SSHTransport._hostkeyType: SSHHostkeyType(ssh-ed25519); SSHTransport._clientCipherType: SSHCipherType(aes128-ctr); SSHTransport._serverCipherType: SSHCipherType(aes128-ctr); SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com); SSHTransport._serverMacType: SSHMacType(hmac-sha2-256-etm@openssh.com) |
| algorithm-client-support-chacha20-poly1305 | 0 | 0 | supported=false; required=chacha20-poly1305@openssh.com; available=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-cbc,aes192-cbc,aes256-cbc,aes128-ctr,aes192-ctr,aes256-ctr |
| algorithm-client-support-curve25519 | 0 | 0 | supported=true; required=curve25519-sha256; available=curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1 |
| algorithm-client-support-mlkem768x25519 | 0 | 0 | supported=false; required=mlkem768x25519-sha256; available=curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1 |
| pipeline-one-channel-depth-8-lan | 1000000 | 425243 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-one-channel-depth-16-lan | 1000000 | 304964 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-one-channel-depth-32-lan | 1000000 | 272033 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-readdir-1-lan | 0 | 1658672 | entries=800; entriesPerSecond=482.3; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-readdir-8-lan | 0 | 219830 | entries=800; entriesPerSecond=3639.2; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-1-channels-one-transport-lan | 1000000 | 275133 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-2-channels-one-transport-lan | 2000000 | 288958 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-3-channels-one-transport-lan | 3000000 | 310442 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-4-channels-one-transport-lan | 4000000 | 334188 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-8-channels-one-transport-lan | 8000000 | 466958 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-1-transports-lan | 1000000 | 270094 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-2-transports-lan | 2000000 | 264749 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-4-transports-lan | 4000000 | 304088 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-one-channel-depth-8-rtt100 | 1000000 | 4507087 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-one-channel-depth-16-rtt100 | 1000000 | 7964067 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-one-channel-depth-32-rtt100 | 1000000 | 4503600 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-readdir-1-rtt100 | 0 | 5152804 | entries=800; entriesPerSecond=155.3; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-readdir-8-rtt100 | 0 | 1506105 | entries=800; entriesPerSecond=531.2; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-1-channels-one-transport-rtt100 | 1000000 | 6265786 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-2-channels-one-transport-rtt100 | 2000000 | 9682586 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-3-channels-one-transport-rtt100 | 3000000 | 16183890 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-4-channels-one-transport-rtt100 | 4000000 | 3102048 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-8-channels-one-transport-rtt100 | 8000000 | 14742309 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-1-transports-rtt100 | 1000000 | 3064592 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-2-transports-rtt100 | 2000000 | 6512785 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| pipeline-4-transports-rtt100 | 4000000 | 6524072 | sha256=d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025; samples=2; aggregate=median; warmed=true; order=forward-reverse |
| isolate-root-baseline | 100000000 | 5903128 | sha256=a993f8c574e0fea8c1cdcbcd9408d9e2e107ee6e4d120edcfa11decd53fa0cae; samples=3; aggregate=median; warmed=true; order=interleaved |
| isolate-single-transfer | 100000000 | 5923039 | rootParity=0.997; samples=3; aggregate=median; warmed=true; order=interleaved |
| isolate-cancellation | 0 | 40938 | limitUs=100000 |
| isolate-progress-flood | 0 | 1138687 | events=20000; eventsPerSecond=17564.09; uiFlushes=26; engineFlushes=26; flushesPerSecond=22.83 |
| isolate-four-transfers-listing | 400000000 | 21046982 | entries=10000; progressFlushes=47; progressWindowUs=27236494; flushRates=transfer-0=0.44/s,transfer-1=0.44/s,transfer-2=0.44/s,transfer-3=0.40/s,aggregate=1.73/s; maxMainStallUs=4401 |
<!-- m0-result-map-end -->

## Reproduction and limits

Download all thirteen raw source artifacts and reconstruct the bundle with:

```bash
gh run download 33563514640 --repo L-K-M/Poltergeist \
  --pattern 'm0-bench-source-*' --dir /tmp/poltergeist-m0-sources

dart pub get --directory tool/bench
cd tool/bench
dart run bin/aggregate.dart \
  --input-root /tmp/poltergeist-m0-sources \
  --output-dir /tmp/poltergeist-m0-rebuilt \
  --run-id 33563514640 \
  --run-attempt 1 \
  --git-sha 6b8873eafdaaa3a4157e265dee838ab3b47219b3
```

Throughput and pipeline medians have `n=2`; isolate parity has `n=3`;
algorithm and other isolate probes are single observations. Results come from
one GitHub-hosted experiment. Raw sources record distinct runner and image
IDs but the same hostname; runner load, shared infrastructure, and the absence
of a distinct-physical-host guarantee confound cross-job comparisons. The
shaped 1 GB rows are descriptive, not same-run comparisons. Fixtures are
synthetic zero-filled files, RTT is emulated rather than an Internet path, and
integrity verification occurs after timing. Rounded summaries are explanatory;
the canonical map and embedded raw sources are authoritative. The headless
isolate timer gate does not prove Flutter frame performance, and the forced
algorithm matrix is not exhaustive. Keepalive, idle, reconnect, and retry
defaults were retained by design rather than empirically tuned.
