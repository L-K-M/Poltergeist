# Séance ports and pin audits

No Séance source has been copied into Poltergeist.

## Pin findings

The human identity aliases resolve to the repository owner. Other recorded
identities are local automation or bot metadata; no external human
contribution appears in the pin's ancestry. Three stranded assistant
attribution lines in `522c9aaea8a8fcdb81932180aa4bd5e3aa6eaf73`,
`82ba43a64e88f5fb2647b41c82f3f607cedaba58`, and
`c2d60a6f45a4f34828a596a492003822d43ed47c` are automation metadata,
not separate rights holders.

The vendored-path scan found 80 first-party files under `packages/` and the
112-file `third_party/xterm` fork. The latter retains upstream xterm.dart
4.0.0's MIT license and patch ledger; it entered at
`82ba43a64e88f5fb2647b41c82f3f607cedaba58` and is app-only, outside the
pinned `seance_core` and `seance_protocol` package trees. No gitlinks exist. The
license scan found only those notices, first-party license/config references,
and Séance's root Unlicense.

<!-- SEANCE_PIN_AUDIT_V1:START -->
## Séance pin audit

Full, non-shallow ancestor and tree audit. Raw streams are
content-addressed by SHA-256; line counts aid review. Use
`--print-findings` to reproduce them without adding names to docs.

- Pin: `0a695971a411a6a754593e7c2598038039440c2f` from `https://github.com/BigBoyDevBox/Seance.git`
- Identity: 37 lines; `sha256:6e545d2b6fdba2a3603a7b2110be1af105ef6161271c6d261c23b2f836df9803`
- Companion: 213 lines; `sha256:4ba94159a6bc284a1ca73c54edf8804b9c6ad85c218cfc05ff58b404a8323d97`
- Companion orphans: 3 lines; `sha256:b6da03e73f10c5ad1f796d95f1e994c3b2d4877290e7bceabcfcf57164adc805`
- Pinpoints: 381 lines; `sha256:d11fc1ec4387a23ec66251e40c3456ab3b324bb891a2bd85398b6b9a51294cdf`
- License scan: 29 lines; `sha256:283f2dc12212e8ddbe3c6a0224db27f68a0981b171e1df5c95180fd2807bdf24`
- Vendored paths: 192 lines; `sha256:c40fbe5c8fe1f036e0d8002cc6e670f08775e9b691b8390d9ed973f55529a88e`
- Gitlinks: 0 lines; `sha256:1cf88ed73fdedae40c735fb7053a93aa47ca48eebb46eace223de1cb92333504`
- Tree: 437 lines; `sha256:5d13ec5982f78d3503d8c4b88f9baef22885f27e33aa1e8ad4c768cab27fe235`
<!-- SEANCE_PIN_AUDIT_V1:END -->
