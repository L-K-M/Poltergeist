# M6 CLOSURE RECORD — 2026-09-20

M6 (bookmark sync, R5) is CLOSED on evidence with one bounded residual
recorded as open item 25. Audited against main head `2aee7d3`
(post-#167). One audit PR adds the real-server integration suite, a CI
job that runs it in the criterion's named Docker form, the STATUS
sweep, and this record; no features, no M7 work, no Séance edits, no
pin bump.

## Exit criteria (07 §3.7)

1. **Two-device convergence against `seance_sync_server` in Docker:
   create/edit/delete on A converge on B; tombstones win and stay
   won** — MET, with the launch form recorded exactly. Docker is
   absent on this audit host (`docker` not installed), so the local
   run used the task's fallback: a locally-launched server binary
   speaking the real protocol. New
   `packages/poltergeist_core/test/integration/sync_server_convergence_test.dart`
   (`@Tags(['integration'])`, gated on `POLTERGEIST_SYNC_SERVER`)
   drives two real devices — `PersistentLocalRecordStore` +
   `FileBookmarkStore` + `BookmarkCoordinator` — through the pinned
   `HttpSyncClient` over real HTTP: a real
   `SyncEnrollment.registerSeparate` (production Argon2) on A, a real
   `SyncEnrollment.login` on B whose trial-decrypt verifies against
   A's pushed record, then create → converge, edit → converge back,
   delete → a server-verified tombstone that converges on B, and a
   stale live copy pushed afterward losing server-side LWW
   (`accepted == false`) so the tombstone stays won on the server and
   both peers. **What ran locally:** the pinned `seance_sync_server`
   at rev `2e6d1f1` compiled natively (`dart compile exe
   packages/seance_sync_server/bin/seance_sync_server.dart`) from the
   pub-cache checkout, launched `SEANCE_OPEN_REGISTRATION=1
   SEANCE_BIND=127.0.0.1 SEANCE_PORT=8799` with in-memory storage —
   3/3 tests pass. **The criterion's named form runs in CI:** the new
   `sync_integration` job (same `detect_integration` gate as the SSH
   leg) builds that identical pinned checkout through
   `packages/seance_sync_server/Dockerfile`, publishes to
   127.0.0.1:8799, and runs `dart test -t integration
   packages/poltergeist_core` — Docker exists on ubuntu-latest; the
   job's run IDs are recorded in the PR body. Everywhere the
   variable is unset the tests skip cleanly (verified: the full
   package suite's skip count includes them).

2. **flurb-kind record survives rounds unmodified; malformed known
   kind skips without aborting — MET on the real round path**, not
   only the fake. Fake-side proofs already on main:
   `bookmark_coordinator_test.dart`'s `a flurb-kind record survives
   rounds byte-identical` and `a malformed bookmark record is
   skipped without aborting the round`. The new integration suite
   repeats both over real HTTP: a `flurb:x1` record pushed to the
   real server keeps a byte-identical blob AND an unchanged server
   `seq` across multiple rounds including one that pushes the
   device's own write (never re-pushed, never tombstoned, never
   decoded, never tripwired), while a malformed `bookmark:bad` trips
   the §3.2 durable tripwire and the sibling `bookmark:good` applies
   in the same round — the round itself does not abort.

3. **Enrollment security behaviors tested — MET on current HEAD.**
   - KDF refusal meetsMinimum: `enrollment_test.dart`'s
     KDF-downgrade case refuses before any derive/login/token; the
     integration `login` derives only after
     `meetsMinimum(Argon2Params.minimum)` passes against the real
     server's registered params.
   - Trial-decrypt + foreign-record rule + push hold: the §4.5
     group in `enrollment_test.dart` (14 tests: `since = 0` full
     pull, failed-trial warning + hold + preserved record,
     never-decrypt prefix exclusion, wrong-passphrase push hold,
     self-record non-clearing, foreign `hostkey:` clear + release,
     failing-foreign durable notice, corrected-passphrase re-apply,
     401 local-only + recovery). Both integration tests re-run the
     real trial over HTTP — B's login verifies against A's record,
     the shared login verifies against Séance's own.
   - Token only in OS keystore: `keystore confinement — the bearer
     token never lands on disk outside the keystore seam` (walks
     every persisted byte) plus the app-side keystore round-trip
     under `poltergeist.apikey.sync.token`.
   - B→A switch end-to-end: `bookmark_backup_service_test.dart`'s
     §4.4 ordering/retention/conflict/failed-switch-restore group
     and `backup_settings_test.dart`'s switch phases — 47 focused
     app tests green on HEAD.
   - Design A gated-until-tag: `a null gate tag disables the shared
     option outright` (no fleet checkbox, tap cannot select) and
     `the shared option gates Continue on the fleet checkbox`.

4. **Design A against a patched Séance — PARTIAL, bounded and
   recorded (open item 25).** Correcting the audit brief's premise:
   PR-S1 **is** released — Séance `v0.9.0` (2026-09-13) and `v0.9.1`
   (2026-09-14) both contain merge
   `599ff936b8222e6cd77920495dcdcc4a50643f44` (git ancestry-verified
   against the fetched tags), and both contain the pinned rev
   `2e6d1f1`. The production gate correctly records
   `kMinimumSharedAccountSeanceVersion = 'v0.9.0'`, so the shared
   option is **offered** behind the §4.3 fleet checkbox — verified:
   `the shared option gates Continue on the fleet checkbox` renders
   the tag-interpolated copy and the #56 disclosure
   (`kMinSharedVersionIncludesSeance56Fix = false`, correct: #56 is
   still open upstream); nothing bypasses the gate (Continue is
   inert until the assertion; the null-tag path disables the option
   outright). **Against a patched Séance:** the integration suite
   drives the pinned `seance_core` `SyncCoordinator` itself —
   Séance's own production sync engine, in-process — publishing a
   `serverConfig` and a `hostkey:` pin to the real server; the
   shared-mode login's trial-decrypt verifies the passphrase against
   Séance's own prefixless record; the round materializes
   `SeanceServerCatalog` (the `fleet-web` server renders) and
   installs the pin, after which `TofuVerifier.check` on a host
   presenting that fingerprint returns `trusted` — the no-TOFU-prompt
   consequence, proven at the trust-decision seam the connect path
   consults (the UI prompt layer for `trusted` verdicts is M2's
   already-covered no-prompt path); Séance's `excludeFromSync`
   retraction then tombstones the record and the catalog empties.
   **Honest residuals:** (a) the §4.2 "Your Séance servers"
   picker/sidebar section does not exist on HEAD — the catalog
   materializes at the service seam but nothing renders it, so
   `serverConfigId` bookmarks cannot yet be created; (b) no leg ran
   a *running* patched Séance app plus a real SSH connect — both are
   recorded in open item 25 rather than claimed.

5. **All 04 §4.3 strings verbatim in ARB; 403 `registration_closed`
   shows its documented copy — MET.** `app_en.arb` carries every
   §4.3 string verbatim — title, intro, both option cards (Design B
   preselected), fleet checkbox + helper, the #56 auto-trust
   disclosure, `backupRegistrationClosed`, and the passphrase
   callout — diffed against 04 §4.3 in this audit;
   `localization_contract_test.dart` pins the render-site key
   usage. The 403 path: `RegistrationClosedException` carries the
   verbatim copy and `enrollment_test.dart`'s registration-closed
   case asserts nothing persisted; the widget suite renders it.

## 04 §5.6 sealing-shim re-check

Trigger re-evaluated on the final state: the shim exists only when
the pin cannot include PR-S1 in time for Design-B work. The pinned
rev `2e6d1f1` **contains** merge `599ff936` (ancestry-verified;
`RecordKind.bookmark`/`unknown` and the `orElse: unknown` decoder
are present in the pinned `record.dart`). Every record seals through
the real `RecordCodec`; no shim was ever written, so there is
nothing to delete and no shim-written records to migrate.
**Decision: not needed** — unchanged from the Design-B dated
section's record, re-verified here.

## §3.12 close chores

- STATUS.md swept: header reads M3+M4+M5+M6 closed / M7 next; dated
  closure section added; open item 25 added.
- PORTS.md: no update needed — the M6 `sync_enrollment_validation`
  entry (ported 2026-09-20, pin `2e6d1f1`, typed-issue divergence
  recorded) is accurate; this audit adds no ported files.
- Séance pin **can now bump** — `v0.9.1` contains `2e6d1f1` (open
  item 25); the bump itself is deferred per this task's non-goals.
- No `TODO(pin)` markers in the tree.
- Mobile invariant (07 §5, M6 row) re-verified: sync enrollment and
  the record store are pure `poltergeist_core` Dart — no pane,
  watcher, or window coupling; durable state stays in file stores
  and settings, credentials in the keystore seam. Earlier rows still
  hold (no shared type changed shape this milestone).
- `v0.6.0` tag chore NOT run — matching M3/M4/M5's untagged closes;
  a tag push publishes release assets, left to the supervisor/owner
  (`lkm-release` at `~/.local/bin`).

## Honest gaps carried forward

- Open item 25 (above): the tag re-pin is now possible; the "Your
  Séance servers" surface and the full cross-app legs (running
  patched Séance, real SSH connect) remain unproven/unbuilt.
- Open item 24: the Ctrl+Alt+letter chord family still needs a spec
  decision (AltGr collision).
- Open item 23's remote half: remote transfers still fail honestly
  until the engine protocol grows transfer verbs.
- The sync-integration CI leg exercises the Docker form; the local
  binary path is the documented fallback for Docker-less hosts —
  both are recorded so neither pretends to be the other.

## Local verification (this audit host)

- `POLTERGEIST_SYNC_SERVER=http://127.0.0.1:8799 dart test --tags
  integration packages/poltergeist_core/test/integration/sync_server_convergence_test.dart`
  — **3/3 pass** against the natively compiled pinned server
  (`SEANCE_OPEN_REGISTRATION=1`, in-memory, 127.0.0.1:8799);
  `/healthz` answered `ok`, unauthenticated `/v1/sync` 401s.
- `dart test packages/poltergeist_core` — **1303 passed, 21
  skipped** (fixture-gated: the 3 new tests skip without the env,
  SSH/bench skips as before).
- `dart analyze packages/poltergeist_core` — clean.
- `flutter test test/ui/settings/backup_settings_test.dart
  test/services/bookmark_backup_service_test.dart
  test/localization_contract_test.dart` — **47 passed**.
- `flutter analyze` (app) — clean.
- `actionlint .github/workflows/ci.yml` — clean.
- CI run IDs for the exact PR head (including the `sync_integration`
  job's Docker run) are recorded in the PR body.
