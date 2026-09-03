# Séance ports and pin audits

## app/poltergeist_app/lib/services/atomic_file.dart

- Source: app/seance_app/lib/services/atomic_file.dart
- Séance commit: 2f99f4efb25a83340605464635bdf0f3ba95d931 (re-diffed 2026-09-03: source unchanged since the port)
- Ported: 2026-09-02
- Divergences: unique `.poltergeist-<uuid>.tmp` siblings prevent collisions
  and basename overflow; failed writes remove their temporary sibling without
  masking the original failure; the source's delete-target Windows fallback is
  omitted per 09 §3.6; corrupt quarantine is store-owned, UTC-stamped, and
  reports move failures.
- Port-back candidates: unique bounded temp names, best-effort cleanup, and
  timestamped quarantine.

## app/poltergeist_app/test/atomic_file_test.dart

- Source: app/seance_app/test/atomic_file_test.dart
- Séance commit: 2f99f4efb25a83340605464635bdf0f3ba95d931 (re-diffed 2026-09-03: source unchanged since the port)
- Ported: 2026-09-02
- Divergences: uses the Poltergeist temp-file contract, adds failed-rename
  cleanup, and maps source store round-trip/quarantine cases to
  `settings_store_test.dart`.
- Port-back candidates: none.

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

- Pin: `2f99f4efb25a83340605464635bdf0f3ba95d931` from `https://github.com/L-K-M/Seance.git`
- Identity: 38 lines; `sha256:4ceaeaf3dab51c345975bf8085195d8f7ac8205eb6a7510f746cf9c72da251f4`
- Companion: 213 lines; `sha256:8e123bcae01bb2412c412c7b1ff297f13b9b029685943fcb73835faa124552e9`
- Companion orphans: 3 lines; `sha256:c144f63fd03bfb4cffd41748b8281e2b4e119cbc236c092bd0beb582bf377417`
- Pinpoints: 387 lines; `sha256:295ee7ffd74cb8cb6b6a277bd785a5c63392dc61ffbe4def641a24b6af3adc54`
- License scan: 29 lines; `sha256:61e18e16f5f0c91c3d07b749daf4dc9f4417924abb44cf6bc7b08eb5bd785813`
- Vendored paths: 192 lines; `sha256:d49e9b6907d05d3db90884f504dacc48a6aedf38770ed0c417902f47c2103304`
- Gitlinks: 0 lines; `sha256:28c900f0ad82ab353471bf2e21c3b74bf23f9cd2b158c4f944f3d8534d7fc908`
- Tree: 437 lines; `sha256:b5c61cd90ebc7421fa6c675b0fa0960d287e54650fd7136d5a07aa9f75570f98`
<!-- SEANCE_PIN_AUDIT_V1:END -->
