import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const _organization = 'com.lkm';
const _androidId = '$_organization.poltergeist_app';
const _appleId = 'com.lkm.poltergeistApp';
const _linuxBinaryName = 'poltergeist';
const _linuxDesktopId = 'com.lkm.poltergeist_app';
const _linuxStartupWmClass = 'Com.lkm.poltergeist_app';
const _macBundleName = 'Poltergeist.app';
const _macExecutableName = 'Poltergeist';
const _productName = 'Poltergeist';
const _pngSignature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
final _flutterEphemeralPath = RegExp(
  r'[/\\]flutter[/\\]ephemeral[/\\]',
  caseSensitive: false,
);

void main() {
  test('keeps platform identifiers and product names aligned', () {
    expect(
      _read('android/app/build.gradle.kts'),
      allOf(
        contains('namespace = "$_androidId"'),
        contains('applicationId = "$_androidId"'),
      ),
    );
    expect(
      _read('ios/Runner.xcodeproj/project.pbxproj'),
      contains('PRODUCT_BUNDLE_IDENTIFIER = $_appleId;'),
    );
    expect(
      _read('macos/Runner/Configs/AppInfo.xcconfig'),
      allOf(
        contains('PRODUCT_BUNDLE_IDENTIFIER = $_appleId'),
        contains('PRODUCT_NAME = $_productName'),
      ),
    );
    expect(
      _read('linux/CMakeLists.txt'),
      allOf(
        contains('set(BINARY_NAME "$_linuxBinaryName")'),
        contains('set(APPLICATION_ID "$_androidId")'),
      ),
    );
    expect(
      _read('windows/runner/Runner.rc'),
      contains('VALUE "ProductName", "$_productName"'),
    );
  });

  test('contains no default organization identifiers', () {
    final offenders = <String>[];
    for (final entity in Directory.current.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !_isTextProjectFile(entity.path)) continue;

      // Interpolated so this scan does not flag its own source file.
      if (_read(entity.path).contains('com${'.'}example')) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
  });

  test('keeps iOS asset symbol generation enabled in every mode', () {
    final project = _read('ios/Runner.xcodeproj/project.pbxproj');
    const setting =
        'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS';

    expect(RegExp('$setting = YES;').allMatches(project), hasLength(3));
    expect(project, isNot(contains('$setting = AppIcon;')));
  });

  test('grants release APKs network access', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');

    expect(
      manifest,
      contains('<uses-permission android:name="android.permission.INTERNET"/>'),
    );
  });

  test('keeps shipped application and bundle names ASCII', () {
    for (final name in [_linuxBinaryName, _macExecutableName, _productName]) {
      expect(ascii.encode(name), hasLength(name.length));
    }
  });

  test('keeps native metadata consistent with the Unlicense', () {
    for (final path in [
      'macos/Runner/Configs/AppInfo.xcconfig',
      'windows/runner/Runner.rc',
    ]) {
      expect(_read(path), isNot(contains('All rights reserved')));
    }
  });

  test('keeps the Linux desktop entry aligned with WM_CLASS', () {
    expect(
      '${_linuxDesktopId[0].toUpperCase()}${_linuxDesktopId.substring(1)}',
      _linuxStartupWmClass,
    );
    expect(
      _read('../../scripts/package-linux.sh'),
      allOf(
        contains('BUNDLE_EXECUTABLE="$_linuxBinaryName"'),
        contains('LINUX_APPLICATION_ID="$_linuxDesktopId"'),
        contains(r'LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"'),
        contains(r'LINUX_DESKTOP_FILE="$LINUX_APPLICATION_ID.desktop"'),
        contains('StartupWMClass=\$LINUX_STARTUP_WM_CLASS'),
        contains(r'$LINUX_DESKTOP_FILE'),
      ),
    );
  });

  test('defines the Linux window title once', () {
    final runner = _read('linux/runner/my_application.cc');

    expect(
      runner,
      contains('constexpr char kWindowTitle[] = "$_productName";'),
    );
    expect(RegExp('"$_productName"').allMatches(runner), hasLength(1));
    expect(
      RegExp('set_title\\([^;]*kWindowTitle').allMatches(runner),
      hasLength(2),
    );
  });

  test('guards late Windows font changes after teardown', () {
    final runner = _read('windows/runner/flutter_window.cpp');

    expect(
      runner,
      contains(
        'case WM_FONTCHANGE:\n'
        '      if (flutter_controller_) {\n'
        '        flutter_controller_->engine()->ReloadSystemFonts();',
      ),
    );
  });

  test('fails closed when a committed platform scaffold is missing', () {
    expect(
      _read('../../scripts/build.sh'),
      allOf(
        contains('platform scaffold is missing'),
        isNot(contains('flutter create --org')),
      ),
    );
  });

  test('keeps macOS product references aligned with the bundle name', () {
    final project = _read('macos/Runner.xcodeproj/project.pbxproj');
    final scheme = _read(
      'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
    );

    expect(
      project,
      allOf(
        contains('path = "$_macBundleName"'),
        contains('productReference = '),
        contains(
          'TEST_HOST = "\$(BUILT_PRODUCTS_DIR)/$_macBundleName/'
          '\$(BUNDLE_EXECUTABLE_FOLDER_PATH)/$_macExecutableName"',
        ),
        isNot(contains('poltergeist_app.app')),
      ),
    );
    expect(
      scheme,
      allOf(
        contains('BuildableName = "$_macBundleName"'),
        isNot(contains('BuildableName = "poltergeist_app.app"')),
      ),
    );
  });

  test('uses the product name in the native macOS menu and window', () {
    final menu = _read('macos/Runner/Base.lproj/MainMenu.xib');

    expect(menu, isNot(contains('APP_NAME')));
    expect(menu, contains('title="About $_productName"'));
    expect(menu, contains('title="Hide $_productName"'));
    expect(menu, contains('title="Quit $_productName"'));
    expect(menu, contains('<window title="$_productName"'));
  });

  test('keeps macOS desktop builds unsandboxed', () {
    for (final path in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      expect(
        _read(path),
        isNot(contains('com.apple.security.app-sandbox')),
        reason: '$path must allow arbitrary filesystem access',
      );
    }
  });

  test('preserves the configured macOS titlebar during show', () {
    final lifecycle = _read('lib/services/desktop_window_lifecycle.dart');

    expect(lifecycle, contains('enableFullSizeContentView()'));
    expect(lifecycle, contains('makeTitlebarTransparent()'));
    expect(lifecycle, contains('hideTitle()'));
    expect(lifecycle, isNot(contains('titleBarStyle: TitleBarStyle.normal')));
  });

  test('master icon is a 1024px square PNG', () {
    final bytes = File(
      '../../media-sources/poltergeist-icon.png',
    ).readAsBytesSync();
    final data = ByteData.sublistView(bytes);

    expect(bytes.sublist(0, _pngSignature.length), _pngSignature);
    expect(data.getUint32(16), 1024);
    expect(data.getUint32(20), 1024);
  });

  test('excludes generated Flutter directories case-insensitively', () {
    expect(
      _isTextProjectFile('macos/Flutter/ephemeral/Generated.xcconfig'),
      isFalse,
    );
  });
}

String _read(String path) => File(path).readAsStringSync();

bool _isTextProjectFile(String path) {
  if (path.contains(
    '${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}',
  )) {
    return false;
  }
  if (path.contains(
    '${Platform.pathSeparator}build${Platform.pathSeparator}',
  )) {
    return false;
  }
  if (path.contains(_flutterEphemeralPath)) {
    return false;
  }

  return const {
    '.dart',
    '.gradle',
    '.kts',
    '.plist',
    '.swift',
    '.xml',
    '.xcconfig',
    '.pbxproj',
    '.cmake',
    '.cpp',
    '.cc',
    '.h',
    '.rc',
  }.any(path.endsWith);
}
