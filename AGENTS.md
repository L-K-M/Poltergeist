# AGENTS.md — working guide for Poltergeist

Read this first. It captures what isn't obvious from the code: how to get a
toolchain in a fresh environment, how to build/test each piece, and the
conventions this repo family shares.

Poltergeist is a cross-platform two-pane file transfer client (SFTP first),
patterned after Transmit and ForkLift, and a sibling of
[Séance](https://github.com/L-K-M/Seance). The product design and the
implementation plan live in [docs/plan/](docs/plan/) — start with the
overview (the decision log); current status and the next-steps checklist
live in [docs/STATUS.md](docs/STATUS.md).

## Repository layout

```
pubspec.yaml              pub WORKSPACE root — members are the pure-Dart packages
packages/
  poltergeist_core/       pure Dart — scaffold today; connections, transfers,
                          sync engine, and bookmark model per the plan
app/
  poltergeist_app/        Flutter — NOT created yet; scaffolded in milestone
                          M1 per docs/plan/07-MILESTONES.md (M0 is a spike
                          that creates no app), and NOT a workspace
                          member (it needs the Flutter SDK; members must not)
docs/plan/                the design plan (read 00-OVERVIEW.md first —
                          it is the decision log; 09-PLAYBOOK.md is the
                          implementation operating manual)
docs/STATUS.md            what's done / tested / still open
scripts/                  build.sh, release.sh, package-linux.sh
media-sources/            master icon (poltergeist-icon.png; created with the app)
```

The layout deliberately mirrors Séance's proven shape (`packages/` + `app/`),
so knowledge and tooling transfer both ways. How Poltergeist consumes
Séance code is decided per layer in the plan (docs/plan/00-OVERVIEW.md,
decision D2) — don't preempt it by copying code ad hoc.

## Build & test

Requires the Dart SDK (3.12+) for the pure-Dart packages and the Flutter SDK
for the app (once it exists).

```bash
# Pure-Dart packages — always with explicit paths (a bare `dart test` at the
# repo root would try to resolve the Flutter app once it exists, and fail)
dart pub get
dart analyze packages/poltergeist_core
dart test    packages/poltergeist_core

# Flutter app (after it is scaffolded per the plan)
cd app/poltergeist_app
flutter pub get && flutter analyze && flutter test
flutter run -d linux    # or macos / windows / a device

# Everything this host can build, staged into dist/
scripts/build.sh          # app + apk; missing toolchains are skipped
scripts/build.sh --install  # build + install the app for this host
```

CI (`.github/workflows/ci.yml`) runs the Dart analyze+test on every push/PR.
The Flutter analyze/test job and the per-platform client build matrix
activate automatically once `app/poltergeist_app` exists — no workflow edit
needed when the app lands.

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

Note: tagging a release before `app/poltergeist_app` exists fails the client
build jobs by design — there is nothing to release yet.

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

# Flutter SDK (for the app). Its bundled Dart must match the ^3.12 constraint.
git clone --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter
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
  evidence.
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
  `linux/CMakeLists.txt`) `com.lkm.poltergeist_app` — that last one must
  match the `StartupWMClass` hard-coded in `scripts/package-linux.sh`, so
  scaffold with `flutter create --org com.lkm` or edit the CMakeLists (the
  flutter-create default `com.example.poltergeist_app` would break
  window-to-desktop-entry mapping in the .deb/AppImage).
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
