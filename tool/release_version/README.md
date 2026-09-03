# Release versions

Accepted versions are `X.Y.Z`. Components are canonical decimal; minor and
patch are `0..99`. Suffixed releases are unsupported; stable-only is the
selected [milestone §3.12](../../docs/plan/07-MILESTONES.md) rule.

Android uses:

```text
major * 1,000,000 + minor * 10,000 + patch * 100 + 99
```

The result cannot exceed `2,100,000,000`.

```bash
dart run tool/release_version/bin/release_version.dart validate --version 1.2.3
dart run tool/release_version/bin/release_version.dart check
dart run tool/release_version/bin/release_version.dart check-tag --tag v1.2.3
```

`scripts/release.sh` invokes `sync` after the shared release tool updates
semantic versions. Only the app pubspec receives Flutter's `+versionCode`.
Apple bundle versions use `(major + 1).minor.patch`, preserving order while
keeping the first component positive. Windows numeric resources use the
semantic components.
