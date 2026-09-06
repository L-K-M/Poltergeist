# Dependency guard

Run `dart pub get`, then `bash scripts/check-imports.sh` in the checkout.
The script also accepts invocation by absolute path. CI analyzes and tests
it with explicit `tool/import_guard` paths.

Run `dart test tool/import_guard/test` from the checkout root after
`dart pub get`. The CI target is
Linux; the shell fixtures require Bash and permission to create symlinks.

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

Known Flutter SDK package names are diagnosed directly when absent from
pure-Dart resolution. Other package names require resolved metadata.

Missing, malformed, or linked scan inputs fail closed. Project-root generated
directories (`.dart_tool`, `build`, `.symlinks`, `ephemeral`, `.git`) and
known native build, Flutter cache, and Apple `Pods` locations are excluded.
Directories with those names inside source trees remain covered, as does a
package named `build`. The guard excludes the plan-sanctioned M0 harness
under `tool/`. This checks package directives
and dependency metadata; normal Dart analysis still validates library access
and types.
