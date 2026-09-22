# Installing Poltergeist

Download Poltergeist only from this repository's
[Releases page](https://github.com/L-K-M/Poltergeist/releases). The desktop
builds are unsigned (macOS: ad-hoc), so the first launch on each platform
takes one extra step — below.

## Verify your download first

Every release publishes `SHA256SUMS` beside its assets, and the release notes
carry the same checksums. Before bypassing any OS gate, confirm what you
downloaded is what CI built:

```bash
# Linux
sha256sum -c SHA256SUMS --ignore-missing   # run in the download directory

# macOS
shasum -a 256 -c SHA256SUMS --ignore-missing

# Windows (PowerShell)
Get-FileHash .\poltergeist-windows-x64.zip -Algorithm SHA256
# compare the printed hash with the release-notes line for that file
```

What the checksums prove — and what they do not: they are computed by CI
alongside the artifacts, so they catch a corrupted download or a foreign
mirror. They cannot attest a compromised release pipeline, and a matching
checksum says nothing about who produced the binary. Origin assurance is
"this repository's CI built from the pushed tag" — nothing more. Any
"update available" prompt or installer offered anywhere other than this
repo's Releases page is fake by definition: Poltergeist never prompts for
or auto-installs updates.

## macOS

`poltergeist-macos-universal.zip` — unzip, then move `Poltergeist.app` to
Applications (or anywhere you like).

The app is ad-hoc signed, so Gatekeeper blocks the first launch:

- right-click (or Control-click) `Poltergeist.app` → **Open** → confirm in
  the dialog, **or**
- `xattr -dr com.apple.quarantine /path/to/Poltergeist.app`

## Windows

`poltergeist-windows-x64.zip` — extract somewhere permanent (the folder is
the installation; there is no installer), then run `poltergeist_app.exe`
inside `poltergeist-windows-x64/`.

The binary is unsigned, so SmartScreen shows "Windows protected your PC":
click **More info → Run anyway**.

## Linux

Three assets, pick one:

- `poltergeist_<version>-1_amd64.deb` (Debian/Ubuntu):
  `sudo apt install ./poltergeist_*_amd64.deb` — apt resolves the
  dependencies from the package metadata.
- `poltergeist-linux-x64.AppImage` (any distro):
  `chmod +x poltergeist-linux-x64.AppImage` and run it.
- `poltergeist-linux-x64.tar.gz` (plain bundle): extract and run the
  `poltergeist` binary inside.

Runtime dependency worth knowing: saving passwords and secrets requires a
Secret Service keyring — `libsecret-1` plus a provider such as GNOME
Keyring or KWallet. Without one the app runs fine but refuses to store
secrets rather than writing them somewhere weaker (that is deliberate).
The `.deb` declares the library; AppImage and tarball users may need to
install `libsecret-1-0` (Debian/Ubuntu), `libsecret` (Fedora/Arch), or
equivalent themselves.

## Android and iOS — rehearsal artifacts, not supported

Every release also attaches `poltergeist-android.apk` and
`poltergeist-ios-unsigned.ipa`. These are rehearsal artifacts of the
desktop codebase: mobile is not a supported v1 target.

- The APK is signed with a committed, deliberately public debug-grade
  key — that is what lets each release's APK upgrade an installed one in
  place. It also means a matching signature proves nothing about origin:
  anyone can build a correctly-signed APK, which is why the checksum
  verification above matters. If the key is ever replaced, existing
  installs must uninstall and reinstall (Android rejects the signature
  change) — the release notes will say so.
- The IPA is unsigned and cannot be installed on any device without a
  separate re-signing step (AltStore, Sideloadly, or an Xcode free
  account).

## Getting help

File issues at <https://github.com/L-K-M/Poltergeist/issues>. The release
notes and [`README`](../README.md)'s known-issues section list the
limitations we already know about.
