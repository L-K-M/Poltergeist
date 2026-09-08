# AGENTS.md — working guide for Poltergeist

Read this first. It captures what isn't obvious from the code: how to get a
toolchain in a fresh environment, how to build/test each piece, and the
conventions this repo family shares.

Poltergeist is a cross-platform two-pane file transfer client (SFTP first),
patterned after Transmit and ForkLift, and a sibling of
[Séance](https://github.com/L-K-M/Seance). The product design and the
implementation plan live in [docs/plan/](docs/plan/) — start with
[00-OVERVIEW.md](docs/plan/00-OVERVIEW.md) (the decision log); current
status and the next-steps checklist live in
[docs/STATUS.md](docs/STATUS.md).

## Repository layout

```
pubspec.yaml              pub WORKSPACE root — members are the pure-Dart packages
packages/
  poltergeist_core/       pure Dart — scaffold today; connections, transfers,
                          sync engine, and bookmark model per the plan
app/
  poltergeist_app/        Flutter client — NOT a workspace member (it needs
                          the Flutter SDK; members must not)
docs/plan/                the design plan (read 00-OVERVIEW.md first —
                          it is the decision log; 09-PLAYBOOK.md is the
                          implementation operating manual)
docs/STATUS.md            what's done / tested / still open
scripts/                  build.sh, release.sh, package-linux.sh
media-sources/            master icon (poltergeist-icon.png)
```

The layout deliberately mirrors Séance's proven shape (`packages/` + `app/`),
so knowledge and tooling transfer both ways. How Poltergeist consumes
Séance code is decided per layer in the plan (docs/plan/00-OVERVIEW.md,
decision D2) — don't preempt it by copying code ad hoc.

## Build & test

Requires the Dart SDK (3.12+) for the pure-Dart packages and Flutter 3.47.2
for the app.

```bash
# Pure-Dart packages — always with explicit paths (a bare `dart test` at the
# repo root tries to resolve the Flutter app and fails without Flutter)
dart pub get
dart analyze packages/poltergeist_core
dart test    packages/poltergeist_core

# Flutter app
cd app/poltergeist_app
flutter pub get && flutter analyze && flutter test
flutter run -d linux    # or macos / windows / a device

# Everything this host can build, staged into dist/
scripts/build.sh          # app + apk; missing toolchains are skipped
scripts/build.sh --install  # build + install the app for this host
```

CI (`.github/workflows/ci.yml`) runs Dart and Flutter analyze+test on every
push/PR. Its client matrix compiles all five platform projects.

## Releasing

`scripts/release.sh` (a stub over the shared
[release-tool](https://github.com/L-K-M/release-tool) engine) bumps the
`version:` in every pubspec in lockstep, keeps the README version line in
step, commits, and tags `v<version>` — pushing that tag triggers
`.github/workflows/release.yml`, which tests, then builds and publishes the
app for every client platform as the GitHub Release (Android APK, Linux
`.deb` + AppImage + bundle for x64, macOS/Windows desktop bundles, unsigned
iOS IPA — the same asset shape as Séance). Poltergeist has **no server
component**: bookmark backup rides Séance's sync server (see the plan), so
there are no server binaries or Docker images to publish.

```bash
scripts/release.sh 0.2.0          # bump + commit, tag v0.2.0
scripts/release.sh 0.2.0 --push   # …also push branch + tag (CI then publishes)
```

---

## 1. Environment (nothing is pre-installed)

Dev containers for this repo family ship **no Dart or Flutter SDK**. They are
not committed and do not survive a container reset, so re-install them first:

```bash
# Dart SDK (for the pure-Dart packages)
curl -sSL -o /tmp/dartsdk.zip \
  https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip
unzip -q /tmp/dartsdk.zip -d /opt
export PATH=/opt/dart-sdk/bin:$PATH   # latest stable Dart (3.12+ required)

# Flutter SDK (for the app). Keep this pin aligned with CI and the app pubspec.
git clone --depth 1 --branch 3.47.2 https://github.com/flutter/flutter.git /opt/flutter
export PATH=/opt/flutter/bin:$PATH
flutter --version                      # first run bootstraps Dart + engine
```

Environment facts that carry over from Séance's containers (same family):
- Outbound HTTPS goes through a proxy; pub.dev and the Dart archive are
  reachable.
- If there is no root (uid 1000, no sudo), a conda-forge env substitutes for
  the Linux desktop toolchain — see Séance's AGENTS.md §1 for the exact
  `micromamba` incantation (clang 17, gcc-12 libstdc++ pin, GTK3, libsecret,
  `PKG_CONFIG_PATH` export, expat.pc stub). Everything there applies verbatim.
- Even `unzip`/`bzip2` may be missing; a static busybox in `~/opt/bin` covers
  them (Flutter's bootstrap needs unzip).

---

## 2. CI/CD overview

- **`.github/workflows/ci.yml`** — on push to main and on PRs:
  - `dart` job: `dart pub get`, then analyze + test over `packages/*`
    (discovered dynamically, so adding a package needs no workflow edit).
  - `detect` job + guarded `flutter` and `client` jobs: skipped until
    `app/poltergeist_app` exists, then analyze/test plus a compile of every
    client platform (android / linux x64 / macos / ios / windows) on native
    runners, including the Linux `.deb`/AppImage packaging step. Keep this
    matrix in step with `release.yml`'s.
- **`.github/workflows/zai-code-review.yml`** — automated GLM review on every
  non-draft PR from a same-repo branch. Treat its findings per the policy in
  [CLAUDE.md](CLAUDE.md): apply, decline with reasons, or refute with
  evidence. Review-cycle limits follow the shared stopping rules below.
- **`.github/workflows/release.yml`** — on `v*` tags (or manual dispatch with
  a tag input): test gate, then per-platform client builds published as
  GitHub Release assets.

## 3. Conventions

- Commit messages end with a co-author trailer and the session link, per repo
  family convention. **Do not put a model identifier** in commits, code, or
  docs.
- Keep new code matching the surrounding style: small focused files, doc
  comments that explain *why*, `analyze` clean before committing.
- The product name is **Poltergeist** — plain ASCII everywhere a file name or
  bundle identifier appears (Séance's codesign lesson: macOS codesign rejects
  accented file names; Poltergeist dodges the whole issue by being ASCII).
  Planned identifiers: Android application id `com.lkm.poltergeist_app`,
  Apple bundle id `com.lkm.poltergeistApp`, Linux binary/package name
  `poltergeist`, Linux GApplication id (`APPLICATION_ID` in
  `linux/CMakeLists.txt`) `com.lkm.poltergeist_app`. The packaged build
  reports X11 `WM_CLASS` as instance `com.lkm.poltergeist_app`, class
  `Com.lkm.poltergeist_app`; the case-sensitive class must match
  `StartupWMClass` in `scripts/package-linux.sh` (the flutter-create default
  `com.example.poltergeist_app` would break window-to-desktop-entry mapping
  in the .deb/AppImage).
- Cross-repo work: UX or engine improvements that apply to Séance are ported
  back — see the porting policy in the plan. Never fork shared concepts
  silently.

## 4. Gotchas inherited from Séance (they will bite here too)

- **`dart test` / `dart analyze` with no path** at the repo root will fail
  once the Flutter app exists ("requires the Flutter SDK"). Always pass
  explicit package paths.
- The Flutter app must stay **out** of the root `workspace:` list; it
  path-depends on the workspace members instead (resolves fine even though
  members declare `resolution: workspace` — verified in Séance).
- **`pkill -f <name>` kills your own shell** when the pattern matches the
  bash command line running it. Kill by PID.
- **file_picker ≥11 breaks APK builds** on AGP 9+ unless Kotlin is re-applied
  to that subproject (see Séance's `android/build.gradle.kts` workaround and
  [flutter_file_picker#1973](https://github.com/miguelpruivo/flutter_file_picker/issues/1973)).
- macOS: the restricted `keychain-access-groups` entitlement blocks ad-hoc
  signed builds from launching; use the legacy login keychain
  (`MacOsOptions(usesDataProtectionKeychain: false)`) like Séance does.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->
