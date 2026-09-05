# Release runbook

How a Poltergeist release ships. Releases publish straight from CI with
**no human step** (00 D23, decision change 2026-09-03): no signatures, no
maintainer key. The checksums are an integrity channel — they catch
corrupted downloads, not a compromised pipeline.

## 1. Cut the tag

    scripts/release.sh X.Y.Z --push

The version grammar is stable `X.Y.Z` only; the tag is a plain annotated
tag. Pushing it triggers [`release.yml`](../.github/workflows/release.yml):
the release-existence guard, the test gate, the five client builds, and the
sums job. `v0.*` tags publish as pre-releases automatically.

## 2. What CI does, in order

1. Creates the release **hidden** and attaches each client's asset as its
   build finishes (Android APK, Linux `.deb` + AppImage + bundle, macOS
   zip, Windows zip, unsigned iOS IPA — the IPA is zipped out of the
   `--no-codesign` `.xcarchive`).
2. Once every leg is green, the sums job downloads the full asset set,
   enforces the rehearsal floor (07 §3.2: the APK and the Linux set must
   exist — their absence is a pipeline bug), attaches `SHA256SUMS`, writes
   the same sums plus the unsupported-platform labels (Android APK and iOS
   IPA are rehearsal artifacts of the desktop codebase; D29) into the
   notes, and **publishes** the release.

The public never sees a partial or sum-less release. A failed run leaves
an invisible draft.

## 3. Verify (recommended, not gating)

When the workflow is green, the release is already public. Worth a minute:

- `gh release download vX.Y.Z && sha256sum -c SHA256SUMS`
  (`shasum -a 256 -c` on macOS) — catches a corrupted upload early, while
  few people have downloaded it.
- Confirm the release is flagged pre-release (`v0.*`), not "Latest".

## Invariants and rules

- A release is created once and never updated: any run whose tag already
  has a release — draft or published — fails instead of overwriting
  same-named assets, and runs serialize behind a concurrency group keyed
  on the tag.
- Recovery from a broken run: fix on `main`, delete the release **and the
  tag**, then dispatch the workflow on the fixed commit (the dispatch path
  recreates the tag there) — re-running against the old tag only rebuilds
  the broken commit. Deleting a published release never recalls assets
  that were already downloaded.
- Never rotate, move, or delete the committed Android keystore — in-place
  APK upgrades depend on it (07 §4's signing policy covers the public-key
  risk posture).
- Keep `ci.yml` and `release.yml` client matrices in lockstep.
