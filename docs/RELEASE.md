# Release runbook

How a Poltergeist release ships. Releases publish **directly from CI**,
Séance's posture (00 D23, decision change 2026-09-03): no signatures, no
maintainer key, no draft pause. The checksums are an integrity channel —
they catch corrupted downloads, not a compromised pipeline.

## 1. Cut the tag

    scripts/release.sh X.Y.Z --push

The version grammar is stable `X.Y.Z` only; the tag is a plain annotated
tag. Pushing it triggers [`release.yml`](../.github/workflows/release.yml):
the release-existence guard, the test gate, the five client builds, and the
sums job — which attaches `SHA256SUMS` beside the assets, writes the same
sums plus the unsupported-platform labels (Android APK and iOS IPA are
rehearsal artifacts of the desktop codebase; D29) into the notes, and
enforces the rehearsal floor (07 §3.2: the APK and the Linux
`.deb`/AppImage/bundle must exist — their absence is a pipeline bug, not
lag). `v0.*` tags publish as pre-releases automatically.

## 2. Verify (recommended, not gating)

When the workflow is green, the release is already public. Worth a minute:

- `gh release download vX.Y.Z && sha256sum -c SHA256SUMS`
  (`shasum -a 256 -c` on macOS) — catches a corrupted upload early, while
  few people have downloaded it.
- Confirm the release is flagged pre-release (`v0.*`), not "Latest".

## Rules the pipeline enforces on its own

- A release is created once and never updated: any run whose tag already
  has a release — draft or published — fails instead of overwriting
  same-named assets, and runs serialize behind a concurrency group keyed
  on the tag. Recovery from a broken run: fix on `main`, delete the
  release, re-run the workflow on the tag.
- Never rotate, move, or delete the committed Android keystore — in-place
  APK upgrades depend on it (07 §4's signing policy covers the public-key
  risk posture).
- Keep `ci.yml` and `release.yml` client matrices in lockstep.
