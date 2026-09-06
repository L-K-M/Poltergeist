# Dependency guard

Run `dart pub get`, then `bash scripts/check-imports.sh` from any directory.
The script locates its own checkout. CI analyzes and tests this tool with
explicit `tool/import_guard` paths.

The guard parses import/export directives, including conditional branches
and escaped literals, in `packages/` and `app/`. Only the core connection
module may reference `package:dartssh2`. Pure-Dart packages cannot reference
`dart:ui`, `dart:ui_web`, Flutter packages, or plugins.

Plugin classification uses the root's resolved package configuration and
each dependency's pubspec: `flutter.plugin`, `environment.flutter`, or a
Flutter SDK dependency. Runtime dependencies propagate that classification;
external development dependencies do not. Local dependencies, development
dependencies, and overrides are checked even when unused. No app dependency
resolution or network access is needed.

Missing, malformed, or linked scan inputs fail closed. Generated directories
(`.dart_tool`, `build`, `.symlinks`, `ephemeral`, `.git`) are excluded, as is
the plan-sanctioned M0 harness under `tool/`. This checks package directives
and dependency metadata; normal Dart analysis still validates library access
and types.
