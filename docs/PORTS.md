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

The vendored-path scan found 78 first-party files under `packages/` and the
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

- Pin: `142db7b40fd6bdaab35fe295267035dca547d240` from `https://github.com/BigBoyDevBox/Seance.git`
- Identity: 36 lines; `sha256:fcb7f916a499fa579f42518c1d904c0e6a6ba35ee05fe9dbc84adf0b303f67de`
- Companion: 202 lines; `sha256:c9db753ba280620fab9837e53653622c02b37b1837053ad7167bad21080a38ed`
- Companion orphans: 3 lines; `sha256:3524fd6a0a4be2fe4f959eee3375c2606783cfa51ad7ec7f2e5d21207e67e4d6`
- Pinpoints: 355 lines; `sha256:31231ffebf297fdf5e87f8cc17df4db7d28276d13edaa2e65065f4de7d17bf21`
- License scan: 29 lines; `sha256:613540f623c6a6f55891e278b86330301f67633cd975cebb51c9ed24206b07a5`
- Vendored paths: 190 lines; `sha256:e6380cde116c4924eca72533c495f712002b82700379a39edb33e58bd0aef9da`
- Gitlinks: 0 lines; `sha256:0723d64622d2ac39f8ba4e3108814baa23cca856073df636d88329fc17029d54`
- Tree: 435 lines; `sha256:ac7422038c184cd35e62838c24b0aa6afb03bd2425d8e9b985d910e32dc45bf7`
<!-- SEANCE_PIN_AUDIT_V1:END -->
