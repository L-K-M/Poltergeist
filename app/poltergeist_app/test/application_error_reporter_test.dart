import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/settings_store.dart';

import 'support/controlled_settings_writer.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_error_reporter_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('reports an observed pane-ratio write failure once', () async {
    final errors = <Object>[];
    final writer = ControlledSettingsWriter()..failWrites = true;
    final reporter = ApplicationErrorReporter(
      sink: (error, _) => errors.add(error),
    );
    final preferences = AppPreferences(
      store: SettingsStore(
        path: settingsFile.path,
        atomicWriter: writer.call,
        onError: reporter.report,
      ),
    );

    reporter.observe(preferences.savePaneRatio(0.6));
    await writer.firstWriteStarted.future;
    await Future<void>.delayed(Duration.zero);

    expect(errors, [isA<StateError>()]);
  });

  test('contains failures raised by the reporting sink', () async {
    var sinkInvoked = false;
    final reporter = ApplicationErrorReporter(
      sink: (_, _) {
        sinkInvoked = true;
        throw StateError('sink failed');
      },
    );

    reporter.observe(Future<void>.error(StateError('operation failed')));
    await Future<void>.delayed(Duration.zero);

    expect(sinkInvoked, isTrue);
  });

  test('reports a guarded asynchronous operation failure', () async {
    final failure = StateError('window failed');
    final errors = <Object>[];
    final reporter = ApplicationErrorReporter(
      sink: (error, _) => errors.add(error),
    );

    await reporter.guard(() => Future<void>.error(failure));

    expect(errors, [same(failure)]);
  });
}
