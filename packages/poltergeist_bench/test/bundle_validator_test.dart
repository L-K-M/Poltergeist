import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_m0_bench/bundle_validator.dart';
import 'package:poltergeist_m0_bench/result_aggregator.dart';
import 'package:poltergeist_m0_bench/result_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('requires one explicit report evidence state', () async {
    final directory = await Directory.systemTemp.createTemp('m0-neutral-');
    addTearDown(() => directory.delete(recursive: true));
    final report = File('${directory.path}/report.md');
    final bundlePath = '${directory.path}/missing';

    Future<BundleValidationOutcome> validate(String text) async {
      await report.writeAsString(text);

      return validateCommittedEvidence(
        bundleDirectory: bundlePath,
        reportPath: report.path,
        repositoryRoot: directory.path,
        diffChecker: const _NoDiffChecker(),
      );
    }

    expect(
      await validate('<!-- m0-evidence-state: pending -->\n'),
      BundleValidationOutcome.neutral,
    );
    for (final text in [
      '# Missing state\n',
      '<!-- m0-evidence-state: pending -->\n'
          '<!-- m0-evidence-state: pending -->\n',
      '<!-- m0-evidence-state: unknown -->\n',
      '<!-- m0-evidence-state: pending -->\n'
          '<!-- m0-evidence-sha256: ${'a' * 64} -->\n',
      '<!-- m0-evidence-state: pending -->\n'
          '<!-- m0-evidence-sha256: malformed -->\n',
      '<!-- m0-evidence-state: pending -->\n'
          '<!-- m0-result-map-start -->\n',
      '<!-- m0-evidence-state: pending -->\n'
          '<!-- m0-evidence-state: malformed value -->\n',
      '<!-- m0-evidence-state: required -->\n',
    ]) {
      await expectLater(
        validate(text),
        throwsA(isA<BundleValidationException>()),
      );
    }

    await Directory(bundlePath).create();
    await expectLater(
      validate('<!-- m0-evidence-state: pending -->\n'),
      throwsA(isA<BundleValidationException>()),
    );
    await expectLater(
      validate('<!-- m0-evidence-state: required -->\n'),
      throwsA(isA<BundleValidationException>()),
    );
  });

  test('maps every reported scenario to canonical values', () {
    final canonicalResults = <Map<String, Object?>>[
      {
        'scenario': 'dart-hash-on-download-1mb-lan',
        'bytes': 1000000,
        'elapsedUs': 1250,
        'note': 'samples=2',
        'sampleIds': ['a', 'b'],
      },
      {
        'scenario': 'algorithm-default',
        'bytes': 0,
        'elapsedUs': 10,
        'note': 'negotiated | current',
        'sourceShardIds': ['standard'],
      },
    ];
    final report = renderReportResultMapping(canonicalResults);

    validateReportResultMapping(
      reportText: report,
      canonicalResults: canonicalResults,
    );
    expect(report, contains('| algorithm-default | 0 | 10 |'));
    expect(report, contains('negotiated &#124; current'));
    expect(
      () => validateReportResultMapping(
        reportText: '',
        canonicalResults: canonicalResults,
      ),
      throwsA(isA<BundleValidationException>()),
    );

    final drifted = report.replaceFirst(
      '| 1000000 | 1250 |',
      '| 1000000 | 1 |',
    );
    expect(
      () => validateReportResultMapping(
        reportText: drifted,
        canonicalResults: canonicalResults,
      ),
      throwsA(isA<BundleValidationException>()),
    );
    final renamed = report.replaceFirst(
      'dart-hash-on-download-1mb-lan',
      'dart-hash-off-download-1mb-lan',
    );
    expect(
      () => validateReportResultMapping(
        reportText: renamed,
        canonicalResults: canonicalResults,
      ),
      throwsA(isA<BundleValidationException>()),
    );
    expect(
      () => validateReportResultMapping(
        reportText: '$report\n$report',
        canonicalResults: canonicalResults,
      ),
      throwsA(isA<BundleValidationException>()),
    );
    final extraField = report.replaceFirst(
      '| Scenario | Bytes |',
      '| Extra | Scenario | Bytes |',
    );
    expect(
      () => validateReportResultMapping(
        reportText: extraField,
        canonicalResults: canonicalResults,
      ),
      throwsA(isA<BundleValidationException>()),
    );
  });

  test('validates sorted SHA-256 entries and detects tampering', () async {
    final directory = await Directory.systemTemp.createTemp('m0-digests-');
    addTearDown(() => directory.delete(recursive: true));
    final raw = Directory('${directory.path}/$rawEvidenceDirectoryName');
    await raw.create();
    final canonical = File('${directory.path}/$canonicalEvidenceFileName');
    final source = File('${raw.path}/standard.json');
    await canonical.writeAsString('{}\n');
    await source.writeAsString('{"state":"succeeded"}\n');
    final entries = [canonicalEvidenceFileName, 'raw/standard.json'];
    final lines = <String>[];
    for (final entry in entries) {
      final digest = sha256.convert(
        await File('${directory.path}/$entry').readAsBytes(),
      );
      lines.add('$digest  $entry');
    }
    await File(
      '${directory.path}/$sha256ManifestFileName',
    ).writeAsString('${lines.join('\n')}\n');

    await validateBundleDigests(directory.path);

    await source.writeAsString('{"state":"failed"}\n');
    expect(
      () => validateBundleDigests(directory.path),
      throwsA(isA<BundleValidationException>()),
    );
  });

  test(
    'wraps invalid raw aggregation and rejects extra digest prefixes',
    () async {
      final fixture = await _InvalidBundleFixture.create();
      addTearDown(fixture.delete);

      await expectLater(
        fixture.validate(),
        throwsA(
          isA<BundleValidationException>().having(
            (error) => error.message,
            'message',
            contains('Canonical evidence is invalid:'),
          ),
        ),
      );

      await fixture.report.writeAsString(
        '${await fixture.report.readAsString()}\n'
        '<!-- m0-evidence-sha256: malformed -->\n',
      );
      await expectLater(
        fixture.validate(),
        throwsA(
          isA<BundleValidationException>().having(
            (error) => error.message,
            'message',
            contains('exactly one report digest marker'),
          ),
        ),
      );
    },
  );

  test(
    'freezes inputs through evidence capture but permits later milestones',
    () async {
      final accepted = await _GitEvidenceFixture.create();
      addTearDown(accepted.delete);
      const checker = GitMeasurementDiffChecker();

      await accepted.recordEvidence();
      await accepted.changeMeasurementInputs('m1');
      await checker.ensureUnchanged(
        repositoryRoot: accepted.root.path,
        recordedSha: accepted.recordedSha,
        fixtureTree: accepted.fixtureTree,
        canonicalPath: accepted.canonical.path,
        reportPath: accepted.report.path,
      );
      await expectLater(
        checker.ensureUnchanged(
          repositoryRoot: accepted.root.path,
          recordedSha: accepted.recordedSha,
          fixtureTree: '0' * accepted.fixtureTree.length,
          canonicalPath: accepted.canonical.path,
          reportPath: accepted.report.path,
        ),
        throwsA(isA<BundleValidationException>()),
      );

      await accepted.changeCanonicalEvidence();
      await expectLater(
        checker.ensureUnchanged(
          repositoryRoot: accepted.root.path,
          recordedSha: accepted.recordedSha,
          fixtureTree: accepted.fixtureTree,
          canonicalPath: accepted.canonical.path,
          reportPath: accepted.report.path,
        ),
        throwsA(isA<BundleValidationException>()),
      );

      final rejected = await _GitEvidenceFixture.create();
      addTearDown(rejected.delete);
      await rejected.changeMeasurementInputs('pre-evidence');
      await rejected.recordEvidence();
      await expectLater(
        checker.ensureUnchanged(
          repositoryRoot: rejected.root.path,
          recordedSha: rejected.recordedSha,
          fixtureTree: rejected.fixtureTree,
          canonicalPath: rejected.canonical.path,
          reportPath: rejected.report.path,
        ),
        throwsA(isA<BundleValidationException>()),
      );
    },
  );

  test('requires one required evidence-introduction commit', () async {
    const checker = GitMeasurementDiffChecker();
    final pending = await _GitEvidenceFixture.create();
    addTearDown(pending.delete);
    await pending.recordEvidence(state: _BoundaryReportState.pending);

    await expectLater(
      checker.ensureUnchanged(
        repositoryRoot: pending.root.path,
        recordedSha: pending.recordedSha,
        fixtureTree: pending.fixtureTree,
        canonicalPath: pending.canonical.path,
        reportPath: pending.report.path,
      ),
      throwsA(isA<BundleValidationException>()),
    );

    final readded = await _GitEvidenceFixture.create();
    addTearDown(readded.delete);
    await readded.recordEvidence();
    await readded.readdCanonicalEvidence();

    await expectLater(
      checker.ensureUnchanged(
        repositoryRoot: readded.root.path,
        recordedSha: readded.recordedSha,
        fixtureTree: readded.fixtureTree,
        canonicalPath: readded.canonical.path,
        reportPath: readded.report.path,
      ),
      throwsA(isA<BundleValidationException>()),
    );
  });
}

Future<ProcessResult> _git(String repository, List<String> arguments) async {
  final result = await Process.run('git', ['-C', repository, ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }

  return result;
}

class _NoDiffChecker implements MeasurementDiffChecker {
  const _NoDiffChecker();

  @override
  Future<void> ensureUnchanged({
    required String repositoryRoot,
    required String recordedSha,
    required String fixtureTree,
    required String canonicalPath,
    required String reportPath,
  }) async {}
}

class _GitEvidenceFixture {
  final Directory root;
  final File measurement;
  final File workflow;
  final File decisionLog;
  final File canonical;
  final File report;
  final String recordedSha;
  final String fixtureTree;

  const _GitEvidenceFixture({
    required this.root,
    required this.measurement,
    required this.workflow,
    required this.decisionLog,
    required this.canonical,
    required this.report,
    required this.recordedSha,
    required this.fixtureTree,
  });

  static Future<_GitEvidenceFixture> create() async {
    final root = await Directory.systemTemp.createTemp('m0-git-diff-');
    final measurement = File('${root.path}/tool/bench/input.txt');
    final workflow = File('${root.path}/.github/workflows/ci.yml');
    final integration = File('${root.path}/test/integration/fixture.txt');
    final decisionLog = File('${root.path}/docs/plan/00-OVERVIEW.md');
    final canonical = File(
      '${root.path}/docs/evidence/m0/$canonicalEvidenceFileName',
    );
    final report = File('${root.path}/docs/M0-DARTSSH2-REPORT.md');
    for (final file in [measurement, workflow, integration, decisionLog]) {
      await file.parent.create(recursive: true);
    }
    await measurement.writeAsString('measured\n');
    await workflow.writeAsString('measured workflow\n');
    await integration.writeAsString('fixture\n');
    await decisionLog.writeAsString('D9: pending measurement\n');
    await _git(root.path, ['init', '--quiet']);
    await _git(root.path, ['config', 'user.email', 'test@example.invalid']);
    await _git(root.path, ['config', 'user.name', 'M0 test']);
    await _git(root.path, ['add', '.']);
    await _git(root.path, ['commit', '--quiet', '-m', 'Measured']);
    final recordedSha = (await _git(root.path, [
      'rev-parse',
      'HEAD',
    ])).stdout.toString().trim();
    final fixtureTree = (await _git(root.path, [
      'rev-parse',
      '$recordedSha:test/integration',
    ])).stdout.toString().trim();

    return _GitEvidenceFixture(
      root: root,
      measurement: measurement,
      workflow: workflow,
      decisionLog: decisionLog,
      canonical: canonical,
      report: report,
      recordedSha: recordedSha,
      fixtureTree: fixtureTree,
    );
  }

  Future<void> recordEvidence({
    _BoundaryReportState state = _BoundaryReportState.required,
  }) async {
    await canonical.parent.create(recursive: true);
    await canonical.writeAsString('{}\n');
    final marker = switch (state) {
      _BoundaryReportState.pending => reportEvidencePendingMarker,
      _BoundaryReportState.required => reportEvidenceRequiredMarker,
    };
    await report.writeAsString('$marker\n');
    await decisionLog.writeAsString('D9: measured decision\n');
    await _commit('Record evidence');
  }

  Future<void> changeMeasurementInputs(String value) async {
    await measurement.writeAsString('$value measurement\n');
    await workflow.writeAsString('$value workflow\n');
    await _commit('Advance implementation');
  }

  Future<void> changeCanonicalEvidence() async {
    await canonical.writeAsString('{"changed":true}\n');
    await _commit('Change evidence');
  }

  Future<void> readdCanonicalEvidence() async {
    await canonical.delete();
    await _commit('Remove evidence');
    await canonical.writeAsString('{}\n');
    await _commit('Readd evidence');
  }

  Future<void> delete() => root.delete(recursive: true);

  Future<void> _commit(String message) async {
    await _git(root.path, ['add', '.']);
    await _git(root.path, ['commit', '--quiet', '-m', message]);
  }
}

enum _BoundaryReportState { pending, required }

class _InvalidBundleFixture {
  static const _recordedSha = '0123456789abcdef0123456789abcdef01234567';
  static const _fixtureTree = 'fedcba9876543210fedcba9876543210fedcba98';

  final Directory root;
  final Directory bundle;
  final File report;

  const _InvalidBundleFixture(this.root, this.bundle, this.report);

  static Future<_InvalidBundleFixture> create() async {
    final root = await Directory.systemTemp.createTemp('m0-invalid-bundle-');
    final bundle = Directory('${root.path}/bundle');
    final raw = Directory('${bundle.path}/$rawEvidenceDirectoryName');
    await raw.create(recursive: true);
    for (final source in m0SourceManifest) {
      await File('${raw.path}/${source.id}.json').writeAsString('{}\n');
    }
    final canonical = File('${bundle.path}/$canonicalEvidenceFileName');
    await canonical.writeAsString(
      '${jsonEncode({
        'schemaVersion': canonicalEvidenceSchemaVersion,
        'identity': {
          'poltergeistSha': _recordedSha,
          'workflowRunId': '1',
          'workflowRunAttempt': 1,
          'fixture': {'tree': _fixtureTree},
        },
        'sources': <Object?>[],
        'results': <Object?>[],
      })}\n',
    );
    await _writeDigests(bundle);
    final canonicalDigest = sha256.convert(await canonical.readAsBytes());
    final report = File('${root.path}/report.md');
    await report.writeAsString(
      '$reportEvidenceRequiredMarker\n'
      '$reportDigestMarkerPrefix$canonicalDigest -->\n'
      '${renderReportResultMapping(const [])}\n',
    );

    return _InvalidBundleFixture(root, bundle, report);
  }

  Future<BundleValidationOutcome> validate() => validateCommittedEvidence(
    bundleDirectory: bundle.path,
    reportPath: report.path,
    repositoryRoot: root.path,
    diffChecker: const _NoDiffChecker(),
  );

  Future<void> delete() => root.delete(recursive: true);

  static Future<void> _writeDigests(Directory bundle) async {
    final paths = <String>[
      canonicalEvidenceFileName,
      for (final source in m0SourceManifest)
        '$rawEvidenceDirectoryName/${source.id}.json',
    ]..sort();
    final lines = <String>[];
    for (final path in paths) {
      final digest = sha256.convert(
        await File('${bundle.path}/$path').readAsBytes(),
      );
      lines.add('$digest  $path');
    }
    await File(
      '${bundle.path}/$sha256ManifestFileName',
    ).writeAsString('${lines.join('\n')}\n');
  }
}
