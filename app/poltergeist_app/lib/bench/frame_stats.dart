// Tier-B frame-timing aggregation (02 §12 P6, 08 §6): the reduction from
// a captured `FrameTiming` stream to the reported numbers — refresh-rate
// estimation, deadline classification, the duration*hz frame floor, and
// the first-paint frame selection — lives here so it can be unit-tested
// deterministically while the integration suites only collect.
//
// All timestamps are microseconds on the engine's monotonic clock (the
// same domain `dart:developer`'s `Timeline.now` reports), so a latency
// anchored at the navigate() call can be diffed against a frame's
// rasterFinish directly.

import 'dart:ui' show FramePhase, FrameTiming;

/// A capture that cannot honestly yield its number — too few frames to
/// estimate the refresh rate, or fewer frames than the window demands.
/// Surfaced as an error row by the harness, never as a ratio computed
/// from a too-small sample (02 §12: >= 1800 frames for a 30 s scroll at
/// 60 Hz).
class InsufficientFramesException implements Exception {
  const InsufficientFramesException({
    required this.captured,
    required this.required,
  });

  /// Frames actually captured in the window.
  final int captured;

  /// Frames the window requires (floor of windowSeconds * measured Hz).
  final int required;

  @override
  String toString() =>
      'captured $captured frame(s), but the scroll window requires >= '
      '$required';
}

/// One captured frame's phase timestamps, microseconds on the engine
/// monotonic clock. Carried as plain ints so the aggregation math is
/// testable without a live `dart:ui` binding.
final class FrameSlice {
  const FrameSlice({
    required this.vsyncStartUs,
    required this.buildStartUs,
    required this.buildFinishUs,
    required this.rasterStartUs,
    required this.rasterFinishUs,
  });

  factory FrameSlice.fromTiming(FrameTiming timing) => FrameSlice(
    vsyncStartUs: timing.timestampInMicroseconds(FramePhase.vsyncStart),
    buildStartUs: timing.timestampInMicroseconds(FramePhase.buildStart),
    buildFinishUs: timing.timestampInMicroseconds(FramePhase.buildFinish),
    rasterStartUs: timing.timestampInMicroseconds(FramePhase.rasterStart),
    rasterFinishUs: timing.timestampInMicroseconds(FramePhase.rasterFinish),
  );

  final int vsyncStartUs;
  final int buildStartUs;
  final int buildFinishUs;
  final int rasterStartUs;
  final int rasterFinishUs;

  /// vsync-to-raster-done span: the honest "did this frame make its
  /// deadline" measure for the scroll budget (build + raster + waits).
  int get totalSpanUs => rasterFinishUs - vsyncStartUs;
}

/// The refresh rate implied by the smallest positive interval between
/// consecutive vsync starts — measured, never assumed, because the
/// deadline and the frame floor both derive from it. Dropped frames
/// only ever lengthen a vsync interval, never shorten it, so the
/// smallest observed interval is the display period; a median would
/// double the deadline — and halve the frame floor — exactly when the
/// app is dropping half its frames. Throws [InsufficientFramesException]
/// below two frames: one vsync stamps no interval.
double estimateRefreshHz(List<FrameSlice> frames) {
  if (frames.length < 2) {
    throw InsufficientFramesException(
      captured: frames.length,
      required: 2,
    );
  }
  final sorted = [...frames]
    ..sort((a, b) => a.vsyncStartUs.compareTo(b.vsyncStartUs));
  final intervals = <int>[
    for (var i = 1; i < sorted.length; i++)
      sorted[i].vsyncStartUs - sorted[i - 1].vsyncStartUs,
  ]..sort();
  final positive = intervals.where((interval) => interval > 0).toList();
  if (positive.isEmpty) {
    // No interval crossed a vsync tick — no rate is honest here.
    throw StateError(
      'no positive vsync interval in ${intervals.length} samples',
    );
  }
  return 1e6 / positive.first;
}

/// The reduced scroll-window statistic: how many captured frames missed
/// the display deadline, as a percent of the capture (02 §12 P6's
/// "<= 0.2 % of frames over the frame deadline").
final class ScrollWindowStats {
  const ScrollWindowStats({
    required this.frameCount,
    required this.requiredFrames,
    required this.refreshHz,
    required this.deadlineUs,
    required this.lateFrames,
    required this.latePercent,
  });

  /// Frames captured inside the scroll window.
  final int frameCount;

  /// floor(windowSeconds * refreshHz): the minimum honest sample — 1800
  /// for a 30 s window at 60 Hz.
  final int requiredFrames;

  /// Median-interval refresh estimate the deadline and floor derive from.
  final double refreshHz;

  /// The frame budget in microseconds at [refreshHz] (1e6 / hz).
  final double deadlineUs;

  /// Frames whose vsync-to-raster span exceeded [deadlineUs].
  final int lateFrames;

  /// 100 * lateFrames / frameCount — the reported P6 value.
  final double latePercent;
}

/// Reduces a scroll-window capture. Throws [InsufficientFramesException]
/// when the capture is smaller than the window demands at the measured
/// rate — the ratio is never computed from a too-small sample.
ScrollWindowStats summarizeScrollWindow({
  required List<FrameSlice> frames,
  required double windowSeconds,
}) {
  final hz = estimateRefreshHz(frames);
  final required = (hz * windowSeconds).floor();
  if (frames.length < required) {
    throw InsufficientFramesException(
      captured: frames.length,
      required: required,
    );
  }
  final deadlineUs = 1e6 / hz;
  final late = frames.where((frame) => frame.totalSpanUs > deadlineUs).length;
  return ScrollWindowStats(
    frameCount: frames.length,
    requiredFrames: required,
    refreshHz: hz,
    deadlineUs: deadlineUs,
    lateFrames: late,
    latePercent: 100.0 * late / frames.length,
  );
}

/// The first frame that can contain a listing whose rows were accepted
/// at [acceptedAtUs] (the controller's notify instant): its build must
/// have begun after the accept. A frame already mid-build at the accept
/// renders the previous listing — it is skipped, so the chosen frame may
/// over-report the paint by up to one frame, never under-report it.
FrameSlice? firstPaintedFrame(List<FrameSlice> frames, int acceptedAtUs) {
  for (final frame in frames) {
    if (frame.buildStartUs >= acceptedAtUs) return frame;
  }
  return null;
}
