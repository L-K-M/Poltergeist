import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/session_persistence.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/session_state_store.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart';

/// The controlled debounce from desktop_window_lifecycle_test: scheduled
/// callbacks queue until [fire] runs them in order.
final class _Debounce {
  final _pending = <Future<void> Function()>[];
  int cancelCount = 0;
  Duration? lastDelay;

  void Function() schedule(Duration delay, Future<void> Function() callback) {
    lastDelay = delay;
    _pending.add(callback);
    return () {
      if (_pending.remove(callback)) cancelCount++;
    };
  }

  Future<void> fire() async {
    final pending = List.of(_pending);
    _pending.clear();
    for (final callback in pending) {
      await callback();
    }
  }
}

RemoteFileEntry _row(String name) => RemoteFileEntry(
  path: '/home/tester/$name',
  name: name,
  type: RemoteFileType.file,
);

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;
  late FakePaneLanes lanes;
  late _Debounce debounce;
  late int writeCount;
  late SessionPersistence persistence;
  late WorkspaceController workspace;
  late PaneTabsController left;
  late PaneTabsController right;

  Map<String, dynamic> sessionJson() =>
      (jsonDecode(settingsFile.readAsStringSync())
          as Map<String, dynamic>)['session.state']
          as Map<String, dynamic>;

  List<dynamic> tabsOf(String paneId) => [
    for (final pane in sessionJson()['panes']! as List<dynamic>)
      if ((pane! as Map)['paneId'] == paneId)
        ...(pane['tabs']! as List<dynamic>),
  ];

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_session_persistence_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
    lanes = FakePaneLanes();
    debounce = _Debounce();
    writeCount = 0;
    persistence = SessionPersistence(
      store: SessionStateStore(
        store: SettingsStore(
          path: settingsFile.path,
          atomicWriter: (target, contents) async {
            writeCount++;
            await target.writeAsString(contents);
          },
        ),
      ),
      scheduleDebounce: debounce.schedule,
    );
    left = PaneTabsController(
      paneId: PaneTabsController.leftPaneId,
      lanes: lanes,
    );
    right = PaneTabsController(
      paneId: PaneTabsController.rightPaneId,
      lanes: lanes,
    );
    workspace = WorkspaceController(left: left, right: right);
    addTearDown(() async {
      persistence.detach();
      workspace.dispose();
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });
  });

  Future<FakePaneChannel> bindLocal(
    PaneTabsController strip,
    String path, {
    List<RemoteFileEntry> rows = const [],
  }) {
    final channel = FakePaneChannel('/home/tester')..listings[path] = rows;
    lanes.nextLocalChannel = channel;
    strip.newTab(target: NewTabTarget.launcher);
    strip.activeTab!.controller.openLocalAt(path);
    return Future.value(channel);
  }

  test('attach schedules the first write; flush writes immediately',
      () async {
    persistence.attach(workspace);
    expect(debounce.lastDelay, isNotNull);

    await persistence.flush();
    expect(sessionJson()['version'], SessionState.schemaVersion);
  });

  test('tab open is a commit point', () async {
    persistence.attach(workspace);
    await debounce.fire();
    final writesBefore = writeCount;

    await bindLocal(left, '/home/tester/docs');
    await debounce.fire();

    expect(tabsOf(PaneTabsController.leftPaneId), hasLength(1));
    expect(writeCount, greaterThan(writesBefore));
  });

  test('navigation commit persists the new location', () async {
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_row('docs')]
      ..listings['/home/tester/docs'] = [];
    lanes.nextLocalChannel = channel;
    persistence.attach(workspace);
    left.newTab(target: NewTabTarget.launcher);
    await left.activeTab!.controller.openLocalAt('/home/tester');
    await Future<void>.delayed(Duration.zero);
    await debounce.fire();

    left.activeTab!.controller.navigate('/home/tester/docs');
    await Future<void>.delayed(Duration.zero);
    await debounce.fire();

    expect(
      (tabsOf(PaneTabsController.leftPaneId).single as Map)['path'],
      '/home/tester/docs',
    );
  });

  test('tab switch is a commit point', () async {
    persistence.attach(workspace);
    await bindLocal(left, '/a');
    left.newTab(target: NewTabTarget.launcher);
    await debounce.fire();

    left.activateTab(left.tabs[0]);
    await debounce.fire();

    expect(
      (sessionJson()['panes']! as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (pane) => pane['paneId'] == PaneTabsController.leftPaneId,
          )['activeTab'],
      0,
    );
  });

  test('tab close is a commit point', () async {
    persistence.attach(workspace);
    await bindLocal(left, '/a');
    await debounce.fire();

    await left.requestCloseTab(left.tabs.single);
    await debounce.fire();

    expect(tabsOf(PaneTabsController.leftPaneId), isEmpty);
  });

  test('pane toggle is a commit point', () async {
    persistence.attach(workspace);
    await debounce.fire();

    workspace.setSecondPaneHidden(true);
    await debounce.fire();

    expect(sessionJson()['secondPaneHidden'], isTrue);
  });

  test('a selection-only change costs no write', () async {
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_row('a'), _row('b')];
    lanes.nextLocalChannel = channel;
    persistence.attach(workspace);
    left.newTab(target: NewTabTarget.launcher);
    await left.activeTab!.controller.openLocalAt('/home/tester');
    await Future<void>.delayed(Duration.zero);
    await debounce.fire();
    final writesBefore = writeCount;

    left.activeTab!.controller.setCursorIndex(1);
    await debounce.fire();

    expect(writeCount, writesBefore);
  });

  test('an empty session persists legally — zero tabs per pane', () async {
    persistence.attach(workspace);
    await persistence.flush();

    for (final pane in sessionJson()['panes']! as List<dynamic>) {
      expect((pane! as Map)['tabs'], isEmpty);
      expect(pane['activeTab'], -1);
    }
  });

  test('the written document decodes back to the live session', () async {
    persistence.attach(workspace);
    await bindLocal(
      left,
      '/home/tester/docs',
      rows: [_row('a.txt')],
    );
    await Future<void>.delayed(Duration.zero);
    workspace.setSecondPaneHidden(true);
    await persistence.flush();

    final decoded = SessionState.fromJson(sessionJson());
    expect(decoded.secondPaneHidden, isTrue);
    expect(decoded.panes[0].tabs.single.path, '/home/tester/docs');
    expect(decoded.panes[0].tabs.single.listing.single.name, 'a.txt');
  });
}
