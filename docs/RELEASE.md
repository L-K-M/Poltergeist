# Release runbook

How a Poltergeist release goes from a version bump to a published GitHub
Release. The pipeline ([`release.yml`](../.github/workflows/release.yml))
never publishes on its own: it tests, builds every client asset, attaches
them plus `SHA256SUMS` to a **draft** release, and stops. Publishing is the
maintainer's verified, signed step — the whole design exists so the signing
key never lives in CI (plan [00 D23](plan/00-OVERVIEW.md),
[07 §4](plan/07-MILESTONES.md)).

## 1. Cut the tag

    scripts/release.sh X.Y.Z --push

The version grammar is stable `X.Y.Z` only. `release.sh` requires a
signing-capable Git (`RELEASE_SIGN_TAG=required`): the tag is signed with
the maintainer's local key and attests the **source commit**, never CI-built
artifacts. `v0.*` tags publish as pre-releases automatically.

Pushing the tag triggers `release.yml`: the release-existence guard, the
test gate, the five client builds attaching to the draft, and the sums job.

## 2. Verify the draft

Once the workflow is green, the draft carries the full asset set — APK,
Linux `.deb` + AppImage + bundle, macOS zip, Windows zip, unsigned IPA —
`SHA256SUMS` beside them, and the notes with the same sums plus the
unsupported-platform labels (Android APK and iOS IPA are rehearsal
artifacts of the desktop codebase; D29).

- Recompute every sum: download the assets, then `sha256sum -c SHA256SUMS`.
  These sums catch corrupted downloads and foreign mirrors; they can never
  attest a compromised pipeline — that is what the signature and the checks
  below are for.
- Spot-check one platform against a local build of the same commit: build
  the tagged commit locally, compare asset sizes within a stated tolerance,
  and run the downloaded binary. A byte-for-byte digest match is **not**
  the check — Flutter builds are not reproducible, and pretending otherwise
  would overstate what the comparison proves.

## 3. Sign the checksum list

    gpg --local-user <release-key> --armor --detach-sign SHA256SUMS
    # → SHA256SUMS.asc; attach it to the draft release

The key's fingerprint is published out-of-band — a personal domain or an
email-verified keys.openpgp.org entry, never only this repo or its release
page (a key fetched from the same server as its expected fingerprint proves
nothing). A successor-key transition statement is pre-signed at key
creation and stored offline for rotation (07 §4).

## 4. Publish

Only after both hold, in this order:

1. the signature verifies over the draft's on-release `SHA256SUMS`
   (`gpg --verify SHA256SUMS.asc SHA256SUMS`);
2. the sums digest-match every attached asset (`sha256sum -c SHA256SUMS`
   against a fresh download);

publish the draft (GitHub UI → edit → publish; keep the pre-release flag on
`v0.*`), then immediately re-verify the live release the same way.

- A digest or signature **mismatch** is acted on only when a re-fetch
  confirms it: before publishing, abort and leave the draft; after
  publishing, delete the release (the tag stays — deletion cannot recall an
  already-downloaded asset).
- An **inconclusive** check (transient API or network error) halts for a
  human decision instead: a false halt wastes attention, but an automated
  delete fired by a flaky check destroys a healthy, correctly signed
  release.

## Invariants

- Never rotate, move, or delete the committed Android keystore — in-place
  APK upgrades depend on it (07 §4's signing policy covers the public-key
  risk posture).
- CI never uploads `SHA256SUMS.asc`; it is always signed locally or on a
  hardware token.
- `ci.yml` and `release.yml` client matrices stay in lockstep.
