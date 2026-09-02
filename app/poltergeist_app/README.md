# Poltergeist app

Flutter 3.47.2 scaffold for the Poltergeist client. The scaffold is green in
CI; M1 remains open pending the v0.1.0 rehearsal.

Runtime pins: `intl 0.20.3`, `macos_window_utils 1.9.1`,
`path 1.9.1`, `path_provider 2.1.6`, `screen_retriever 0.2.2`,
`uuid 4.6.0`, and `window_manager 0.5.2`. Development pins are
`analyzer 14.1.0`, `flutter_launcher_icons 0.14.4`, and
`flutter_lints 6.0.0`.

The launcher source is `../../media-sources/poltergeist-icon.png` (1024×1024).
Regenerate Android, Apple, and Windows icons with
`dart run flutter_launcher_icons`; Linux packages derive their icon sizes
from the same master.

Generated localization Dart files are committed. Run `flutter gen-l10n` and
require a clean tree whenever the ARB or `l10n.yaml` changes.

```bash
flutter pub get
flutter analyze
flutter test
```
