import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _agentsPath = '../../AGENTS.md';
const _flutterVersion = '3.47.2';
const _workflowPaths = {
  '../../.github/workflows/ci.yml',
  '../../.github/workflows/release.yml',
};

void main() {
  test('pins the documented Flutter checkout', () {
    final agents = File(_agentsPath).readAsStringSync();

    expect(
      agents,
      contains(
        'git clone --depth 1 --branch $_flutterVersion '
        'https://github.com/flutter/flutter.git /opt/flutter',
      ),
    );
    expect(agents, isNot(contains('git clone --depth 1 -b stable')));
  });

  test('keeps one Flutter pin per workflow', () {
    for (final path in _workflowPaths) {
      final workflow = File(path).readAsStringSync();

      expect(
        RegExp("FLUTTER_VERSION: '$_flutterVersion'").allMatches(workflow),
        hasLength(1),
        reason: path,
      );
      expect(workflow, isNot(contains("flutter-version: '$_flutterVersion'")));
      expect(
        workflow,
        contains(r'flutter-version: ${{ env.FLUTTER_VERSION }}'),
      );
    }
  });
}
