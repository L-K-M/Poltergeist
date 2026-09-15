// Shared harness for the tier-B UI benchmarks (02 §12 P1/P2/P4/P6,
// 08 §6): boots the real app over a real engine session under
// `flutter drive --profile`, drives the pane through its production
// controller, and captures raster timing through
// SchedulerBinding.addTimingsCallback — the primary mechanism; no
// traceAction summaries are consumed.
//
// Each scenario's test file writes one `poltergeist-d12-results-1`
// document (path from POLTERGEIST_BENCH_OUTPUT) that the bench job merges
// with the tier-A documents into bench-results.json.
//
// Required --dart-define inputs (scripts/bench-tier-b.sh supplies them):
//   POLTERGEIST_BENCH_OUTPUT          results document path to write
//   POLTERGEIST_BENCH_FIXTURE_ROOT    dir holding entries-<n> fixtures
// Optional fingerprint axes:
//   POLTERGEIST_BENCH_RUNNER_IMAGE    runner image label (default local)
//   POLTERGEIST_BENCH_CPU_MODEL       CPU axis override
//   POLTERGEIST_BENCH_FLUTTER_VERSION Flutter version axis

import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/bench/bench_results.dart';
import 'package:poltergeist_app/bench/frame_stats.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';

/// Measurement configuration carried in through dart-defines. Absent
/// required values fail fast — a run writing to the default path or
/// against a guessed fixture would produce evidence pointing nowhere.
class BenchConfig {
  static const outputPath = String.fromEnvironment(
    'POLTERGEIST_BENCH_OUTPUT',
  );
  static const fixtureRoot = String.fromEnvironment(
    'POLTERGEIST_BENCH_FIXTURE_ROOT',
  );
  static const runnerImage = String.fromEnvironment(
    'POLTERGEIST_BENCH_RUNNER_IMAGE',
    defaultValue: 'local',
  );
  static const cpuModelOverride = String.fromEnvironment(
    'POLTERGEIST_BENCH_CPU_MODEL',
  );
  static const flutterVersion = String.fromEnvironment(
    'POLTERGEIST_BENCH_FLUTTER_VERSION',
  );

  static void require(String name, String value) {
    if (value.isEmpty) {
      throw StateError('--dart-define=$name is required');
    }
  }
}

/// The warmed app under test: the left pane's production controller plus
/// the session to tear down. Local browsing runs through the engine's
/// local channel exactly as the shipped app drives it — no fixture lane.
final class BenchmarkRig {
  const BenchmarkRig({
    required this.tester,
    required this.pane,
    required this.tabs,
    required this.session,
    required this.supportDirectory,
  });

  final WidgetTester tester;

  /// The left pane's controller — the measured surface.
  final PaneController pane;

  /// The left pane's tab strip — the P4 measured surface. Strips live
  /// for the workspace's lifetime, so the reference stays valid across
  /// the tab activations that swap the mounted PaneView under it.
  final PaneTabsController tabs;

  final EngineSession session;
  final Directory supportDirectory;

  Finder _listingFinder() {
    final paneFinder = find.byWidgetPredicate(
      (widget) => widget is PaneView && identical(widget.controller, pane),
    );
    return find.descendant(
      of: paneFinder,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ListView &&
            widget.childrenDelegate is SliverChildBuilderDelegate,
      ),
    );
  }

  /// Whether the measured pane's listing ListView.builder has been built
  /// into the element tree yet. The controller publishes its entries
  /// before the frame that materializes the scrollable runs, and the
  /// timer-polled [waitFor] does not wait for that build — poll this
  /// instead of assuming pump ordering under the live binding.
  bool get listingMounted => _listingFinder().evaluate().isNotEmpty;

  /// The scrollable listing inside the measured pane (the fixed-extent
  /// ListView.builder — the path bar's horizontal ListView is excluded
  /// by its children delegate).
  ScrollableState listingScrollable() {
    final listFinder = _listingFinder();
    expect(listFinder, findsOneWidget);
    return tester.state<ScrollableState>(
      find.descendant(of: listFinder, matching: find.byType(Scrollable)),
    );
  }

  Future<void> dispose() async {
    await session.shutdown();
    try {
      await supportDirectory.delete(recursive: true);
    } on FileSystemException {
      // Best-effort: the temp root is per-run.
    }
  }
}

/// Polls [predicate] on a real timer until it holds or [timeout] passes.
/// Deliberately NOT `tester.pump()`: the live binding's pump awaits a
/// real frame, and under a headless frame clock a stall there would
/// freeze the benchmark silently instead of timing out. The app
/// schedules its own frames while this loop yields.
Future<void> waitFor(
  WidgetTester tester,
  bool Function() predicate,
  String description, {
  Duration timeout = const Duration(seconds: 120),
  Duration poll = const Duration(milliseconds: 16),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed >= timeout) {
      throw TimeoutException('timed out waiting for $description', timeout);
    }
    await Future<void>.delayed(poll);
  }
}

/// Boots the production app on a per-run temp support directory with a
/// real engine session (main.dart's wiring minus the window lifecycle,
/// which must not move windows under the benchmark display). Blocks on
/// the left pane reaching an idle browsing state.
Future<BenchmarkRig> bootBenchmarkApp(WidgetTester tester) async {
  BenchConfig.require('POLTERGEIST_BENCH_OUTPUT', BenchConfig.outputPath);
  BenchConfig.require(
    'POLTERGEIST_BENCH_FIXTURE_ROOT',
    BenchConfig.fixtureRoot,
  );

  // The benchmarks need every platform-delivered BeginFrame to actually
  // build/raster. The default fadePointers policy silently SKIPS frames
  // nobody pumped or painted — under a headless frame clock (Xvfb has no
  // Present/vsync, so BeginFrames arrive only in response to a pending
  // scheduleFrame) a ticker-driven scroll would starve: its frames all
  // land in the skipped bucket and animateTo never advances. fullyLive
  // draws each BeginFrame, which also re-arms scheduleFrame, so the
  // pipeline free-runs at the platform's real rate (~11 fps under
  // llvmpipe) and reports genuine FrameTiming evidence.
  final binding = tester.binding;
  if (binding is! LiveTestWidgetsFlutterBinding) {
    throw StateError(
      'benchmarks must run under `flutter drive --profile`, not '
      '`flutter test` (binding is ${binding.runtimeType})',
    );
  }
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  final supportDirectory = await Directory.systemTemp.createTemp(
    'poltergeist-tierb-',
  );
  final bookmarks = FileBookmarkStore(
    path: '${supportDirectory.path}${Platform.pathSeparator}bookmarks.json',
  );
  final navigatorKey = GlobalKey<NavigatorState>();
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final session = await startEngineSession(
    supportDirectoryPath: supportDirectory.path,
    bookmarks: bookmarks,
    navigatorKey: navigatorKey,
    scaffoldMessengerKey: scaffoldMessengerKey,
  );
  Future<void> cleanupBoot() async {
    try {
      await supportDirectory.delete(recursive: true);
    } on FileSystemException {
      // Best-effort: the temp root is per-run.
    }
  }

  if (session == null) {
    await cleanupBoot();
    throw StateError(
      'engine session failed to start — the app boots engine-less, '
      'but a benchmark needs the real listing path',
    );
  }

  try {
    await tester.pumpWidget(
      PoltergeistApp(
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: scaffoldMessengerKey,
        bookmarks: bookmarks,
        engineSession: session,
      ),
    );

    final paneView = tester.widget<PaneView>(find.byType(PaneView).first);
    final rig = BenchmarkRig(
      tester: tester,
      pane: paneView.controller,
      tabs: paneView.pane,
      session: session,
      supportDirectory: supportDirectory,
    );
    await waitFor(
      tester,
      () => rig.pane.phase == PanePhase.browsing && !rig.pane.loading,
      'left pane initial local listing',
    );
    if (rig.pane.error != null) {
      throw StateError(
        'left pane failed to reach browsing state: ${rig.pane.error}',
      );
    }
    return rig;
  } catch (_) {
    try {
      await session.shutdown();
    } catch (_) {
      // Best-effort: a failed shutdown must not skip the temp-dir
      // cleanup or mask the original boot error.
    }
    await cleanupBoot();
    rethrow;
  }
}

/// The frame-timing stream subscription for one measurement window.
/// Add BEFORE the action that should be measured; [slices] accumulates
/// the engine-reported timings in delivery order.
final class FrameCapture {
  FrameCapture() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  final List<FrameSlice> slices = [];

  void _onTimings(List<FrameTiming> timings) {
    slices.addAll(timings.map(FrameSlice.fromTiming));
  }

  void detach() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }
}

/// One first-paint measurement: navigate [pane] to [targetPath] and
/// return the microseconds from the navigate() issue to the raster
/// completion of the first frame that can contain the new listing —
/// listing fetch, build, and raster all inside the number, because the
/// budget covers the user-visible whole.
///
/// Anchors are the engine monotonic clock throughout (Timeline.now at
/// issue/accept, FrameTiming stamps for the paint), never a wall-clock
/// mixture.
Future<int> measureFirstPaintMicros(
  BenchmarkRig rig, {
  required String targetPath,
  required int expectedEntries,
}) async {
  final pane = rig.pane;
  final capture = FrameCapture();
  var acceptedAtUs = -1;
  void onPaneChanged() {
    if (acceptedAtUs >= 0) return;
    if (!pane.loading &&
        pane.error == null &&
        pane.entries.length >= expectedEntries) {
      acceptedAtUs = Timeline.now;
    }
  }

  pane.addListener(onPaneChanged);
  try {
    final triggerUs = Timeline.now;
    pane.navigate(targetPath);
    await waitFor(
      rig.tester,
      () => acceptedAtUs >= 0 || pane.error != null,
      'listing of $expectedEntries entries at $targetPath',
    );
    if (pane.error != null) {
      throw StateError('navigation to $targetPath failed: ${pane.error}');
    }
    FrameSlice? painted;
    await waitFor(
      rig.tester,
      () => (painted = firstPaintedFrame(capture.slices, acceptedAtUs)) != null,
      'first frame painting $expectedEntries entries',
      timeout: const Duration(seconds: 30),
    );
    final latency = painted!.rasterFinishUs - triggerUs;
    if (latency < 0) {
      throw StateError(
        'frame-timing clock domain mismatch: rasterFinish '
        '${painted!.rasterFinishUs} precedes trigger $triggerUs',
      );
    }
    return latency;
  } finally {
    pane.removeListener(onPaneChanged);
    capture.detach();
  }
}

/// One tab-switch measurement (02 §12 P4): activate [tab] on the rig's
/// strip and return the microseconds from the activation issue to the
/// raster completion of the first frame whose build began after the
/// issue. A switch is an atomic active-pointer change — every per-tab
/// state lives on the tab's own controller (02 §3), so the activation
/// lands synchronously inside the issue call and the first post-issue
/// build is the first frame that can carry the target tab's view with
/// its already-loaded listing: the same [firstPaintedFrame] selection
/// rule P1/P2 anchor on, with the issue instant as the accept.
///
/// [tab] must not already be active: `activateTab` on the current tab
/// is a notify-less no-op, which would measure an unrelated frame.
Future<int> measureTabSwitchMicros(
  BenchmarkRig rig, {
  required PaneTab tab,
}) async {
  final tabs = rig.tabs;
  if (identical(tabs.activeTab, tab)) {
    throw ArgumentError('P4 target ${tab.id} is already the active tab');
  }
  final capture = FrameCapture();
  try {
    final triggerUs = Timeline.now;
    tabs.activateTab(tab);
    if (!identical(tabs.activeTab, tab)) {
      throw StateError(
        'activateTab(${tab.id}) did not land synchronously '
        '(active tab: ${tabs.activeTab?.id})',
      );
    }
    FrameSlice? painted;
    await waitFor(
      rig.tester,
      () => (painted = firstPaintedFrame(capture.slices, triggerUs)) != null,
      'first frame painting tab ${tab.id}',
      timeout: const Duration(seconds: 30),
    );
    // End-state sanity check — the mounted view must serve the TARGET
    // tab. This catches a swap that never landed; a swap landing one
    // frame after the measured frame can still slip past it, since the
    // tree is inspected only once a post-issue timing has been
    // delivered. 02 §3's synchronous activation is what rules that out.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is PaneView && identical(widget.controller, tab.controller),
      ),
      findsOneWidget,
    );
    final latency = painted!.rasterFinishUs - triggerUs;
    if (latency < 0) {
      throw StateError(
        'frame-timing clock domain mismatch: rasterFinish '
        '${painted!.rasterFinishUs} precedes trigger $triggerUs',
      );
    }
    return latency;
  } finally {
    capture.detach();
  }
}

/// Navigates the measured pane to [path] and waits for the listing to
/// settle — the inter-repetition reset that keeps each measured leg
/// independent of the previous listing's rows.
Future<void> settlePane(
  BenchmarkRig rig,
  String path,
) async {
  rig.pane.navigate(path);
  await waitFor(
    rig.tester,
    () => !rig.pane.loading,
    'settle navigation to $path',
  );
  if (rig.pane.error != null) {
    throw StateError('settle navigation to $path failed: ${rig.pane.error}');
  }
}

/// The scripted P6 scroll: a linear [duration] sweep of the listing to
/// its maximum extent, capturing every frame the scroll produces.
/// Drains straggler timing reports before detaching so the capture is
/// complete when [summarizeScrollWindow] judges its size.
Future<List<FrameSlice>> captureScroll(
  BenchmarkRig rig, {
  required Duration duration,
}) async {
  final scrollable = rig.listingScrollable();
  final capture = FrameCapture();
  try {
    // Bounded past the animation's own duration: if the frame clock
    // stalls the ticker, an unbounded animateTo hangs forever — the
    // timeout turns that into a loud error row (with the capture size)
    // instead of a dead job.
    await scrollable.position
        .animateTo(
          scrollable.position.maxScrollExtent,
          duration: duration,
          curve: Curves.linear,
        )
        .timeout(
          duration + const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException(
            'scroll animation did not complete within '
            '${duration + const Duration(seconds: 15)} '
            '(${capture.slices.length} frames captured)',
            duration,
          ),
        );
    // Timing reports arrive a beat after raster completion; drain until
    // the stream goes quiet (bounded) so the count isn't truncated by a
    // still-in-flight batch.
    var lastCount = -1;
    for (var i = 0; i < 50 && capture.slices.length != lastCount; i++) {
      lastCount = capture.slices.length;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return capture.slices;
  } finally {
    capture.detach();
  }
}

/// Builds the job fingerprint. Flutter version arrives via dart-define —
/// the VM cannot report it — so the driver script stamps it; empty stays
/// an honest null axis rather than a guess.
Future<BenchFingerprint> detectFingerprint() async => BenchFingerprint(
  runnerImage: BenchConfig.runnerImage,
  arch: BenchFingerprint.detectArch(),
  dartVersion: Platform.version,
  flutterVersion: BenchConfig.flutterVersion.isEmpty
      ? null
      : BenchConfig.flutterVersion,
  mode: BenchFingerprint.detectMode(),
  cpuModel: await BenchFingerprint.detectCpuModel(
    BenchConfig.cpuModelOverride.isEmpty
        ? null
        : BenchConfig.cpuModelOverride,
  ),
);

/// The per-scenario test scaffold: boot the rig, run [measure] (which
/// appends its rows to [results]), publish the results document even
/// when the measurement fails — the partial rows plus the error row are
/// the honest record — then rethrow so `flutter drive` exits non-zero.
Future<void> runBenchScenario(
  WidgetTester tester, {
  required String name,
  required Future<void> Function(BenchmarkRig rig, BenchResults results)
      measure,
}) async {
  final fingerprint = await detectFingerprint();
  final results = BenchResults(fingerprint: fingerprint);
  BenchmarkRig? rig;
  Object? failure;
  try {
    rig = await bootBenchmarkApp(tester);
    await measure(rig, results);
  } catch (error) {
    failure = error;
  }
  try {
    await rig?.dispose();
  } catch (error) {
    failure ??= error;
  }
  try {
    await results.writeTo(BenchConfig.outputPath);
  } catch (error) {
    failure ??= error;
  }
  if (failure != null) {
    fail('$name failed: $failure');
  }
}
