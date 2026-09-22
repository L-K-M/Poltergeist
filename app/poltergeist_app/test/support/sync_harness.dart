// Shared sync-test harness (M8): canned-scan/differ fakes driving
// SyncPlanController's seam constructors, plus the small builders
// (pairs, snapshots, items, plans) every sync test repeats.
import 'dart:io';

import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

/// A pair over two local endpoints — the only shape the environment
/// can resolve until remote filesystems land (STATUS item 23).
SyncPair testSyncPair({
  String id = 'pair-1',
  String name = 'Docs ⇄ Mirror',
  String left = '/left',
  String right = '/right',
  SyncRuleSet rules = const SyncRuleSet(),
}) => SyncPair(
  id: id,
  name: name,
  left: LocalEndpoint(left),
  right: LocalEndpoint(right),
  rules: rules,
);

/// The environment bound to in-memory state and a scratch runs dir —
/// `localFileSystem` defaults to the real LocalFileSystem since the
/// executor tests write into temp directories.
SyncEnvironment testSyncEnvironment(
  Directory scratch, {
  SyncStateStore? states,
  RemoteFileSystem Function()? localFileSystem,
}) {
  final runs = Directory('${scratch.path}/sync_runs')
    ..createSync(recursive: true);
  return SyncEnvironment(
    states: states ?? MemorySyncStateStore(),
    syncRunsDirectory: runs.path,
    deviceId: () async => 'test-device',
    localFileSystem: localFileSystem,
  );
}

/// Canned-scan fake — per-side results keyed on the endpoint's root.
final class FakeSyncScanner implements SyncPairScanner {
  FakeSyncScanner({required this.left, required this.right});

  final ScanResult left;
  final ScanResult right;

  /// Captured case-override arguments per side (the controller's
  /// stored-override rescan asserts on these).
  final overrides = <SyncSide, bool?>{};

  @override
  Future<ScanResult> scan(
    SyncEndpoint endpoint,
    SyncSide side,
    SyncRuleSet rules, {
    bool? caseSensitivityOverride,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  }) async {
    overrides[side] = caseSensitivityOverride;
    final result = side == SyncSide.left ? left : right;
    onProgress?.call(result.entries.length);
    return result;
  }
}

/// Canned-diff fake — returns the built plan (or throws [error]).
final class FakeSyncDiffer implements SyncPlanDiffer {
  FakeSyncDiffer(this.plan, {this.error});

  final SyncPlan? plan;
  final Object? error;

  @override
  Future<SyncPlan> diff(
    ScanResult left,
    ScanResult right,
    SyncPair pair, {
    bool mtimeUnreliableLeft = false,
    bool mtimeUnreliableRight = false,
  }) async {
    if (error != null) throw error!;
    return plan!;
  }
}

ScanResult testScanResult(
  String rootPath,
  Map<String, EntrySnapshot> entries, {
  List<ScanWarning> warnings = const [],
  bool caseSensitive = true,
}) => ScanResult(
  rootPath: rootPath,
  entries: entries,
  warnings: warnings,
  caseSensitive: caseSensitive,
  caseSensitivityBasis: CaseSensitivityBasis.probe,
);

EntrySnapshot testFile({int size = 4, int? mtimeSecs, String? sha256}) =>
    EntrySnapshot(
      kind: EntryKind.file,
      size: size,
      mtimeSecs: mtimeSecs,
      sha256: sha256,
    );

const testDir = EntrySnapshot(kind: EntryKind.directory);

SyncItem testItem(
  String path, {
  EntrySnapshot? left,
  EntrySnapshot? right,
  SyncActionType suggested = SyncActionType.skip,
  SyncReason reason = SyncReason.equal,
  Map<String, EntrySnapshot>? destinationSubtree,
}) => SyncItem(
  relativePath: path,
  left: left,
  right: right,
  suggested: suggested,
  effective: suggested,
  reason: reason,
  destinationSubtree: destinationSubtree,
);

SyncPlan testPlan(
  SyncPair pair,
  List<SyncItem> items, {
  List<ScanWarning> warnings = const [],
  int? leftFileCount,
  int? rightFileCount,
}) => SyncPlan(
  pair: pair,
  scannedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  items: items,
  warnings: warnings,
  totals: const PlanTotals(
    counts: {},
    bytes: {},
    replacedFiles: 0,
    replacedBytes: 0,
  ),
  leftFileCount: leftFileCount,
  rightFileCount: rightFileCount,
);

/// A controller wired to the fakes; [start] it then await
/// [pumpController] until `phase == ready`.
SyncPlanController testController({
  required SyncPair pair,
  required FakeSyncScanner scanner,
  required FakeSyncDiffer differ,
  required SyncEnvironment environment,
  SyncQueueTasks? syncTasks,
  RsyncEndpointResolver? rsyncEndpoints,
}) => SyncPlanController(
  pair: pair,
  environment: environment,
  syncTasks: syncTasks ?? SyncQueueTasks(),
  scanner: scanner,
  differ: differ,
  deviceId: 'test-device',
  rsyncEndpoints: rsyncEndpoints ?? resolveRsyncEndpoints,
);

/// Pumps the microtask queue until [condition] holds or the deadline
/// trips — `tester.pump` is a widget-test concept; service tests wait
/// on wall-clock futures instead.
Future<void> pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('pumpUntil timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
