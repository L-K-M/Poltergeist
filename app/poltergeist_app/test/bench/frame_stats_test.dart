// Deterministic unit coverage for the tier-B frame-timing aggregation
// (02 §12 P6, 08 §6): the integration suites collect real FrameTiming
// data; this suite pins the math that reduces it — refresh-rate
// estimation, deadline classification, the >= duration*hz frame floor,
// and the first-paint frame selection — without a display.

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/bench/frame_stats.dart';

FrameSlice frame(
  int vsyncStartUs, {
  int buildUs = 4000,
  int rasterUs = 8000,
}) {
  return FrameSlice(
    vsyncStartUs: vsyncStartUs,
    buildStartUs: vsyncStartUs + 500,
    buildFinishUs: vsyncStartUs + 500 + buildUs,
    rasterStartUs: vsyncStartUs + 500 + buildUs + 100,
    rasterFinishUs: vsyncStartUs + 500 + buildUs + 100 + rasterUs,
  );
}

/// [count] frames on a perfect [intervalUs] vsync grid starting at 0.
/// 16666 us is the closest integral grid to 60 Hz (measured 60.0024 Hz,
/// deadline 16666.0 us).
List<FrameSlice> grid(int count, [int intervalUs = 16666]) =>
    [for (var i = 0; i < count; i++) frame(i * intervalUs)];

void main() {
  group('estimateRefreshHz', () {
    test('derives ~60 Hz from a 16666 us vsync grid', () {
      expect(estimateRefreshHz(grid(1800)), closeTo(60.0, 0.01));
    });

    test('uses the median interval so a single pause does not skew it', () {
      final frames = grid(100);
      frames[50] = frame(frames[50].vsyncStartUs + 500000);
      expect(estimateRefreshHz(frames), closeTo(60.0, 0.01));
    });

    test('rejects a capture too small to estimate from', () {
      expect(
        () => estimateRefreshHz(grid(1)),
        throwsA(isA<InsufficientFramesException>()),
      );
    });
  });

  group('summarizeScrollWindow', () {
    test('counts frames strictly over the deadline as late', () {
      // At the measured ~60 Hz the deadline is 16666.0 us. The grid
      // helper's spans are 12600 us — under. Patch three frames past it.
      final frames = grid(1800);
      FrameSlice over(int vsyncStartUs) => FrameSlice(
        vsyncStartUs: vsyncStartUs,
        buildStartUs: vsyncStartUs + 500,
        buildFinishUs: vsyncStartUs + 9000,
        rasterStartUs: vsyncStartUs + 9100,
        rasterFinishUs: vsyncStartUs + 20000,
      );
      frames[0] = over(0);
      frames[1] = over(16666);
      frames[2] = over(33332);
      final stats = summarizeScrollWindow(frames: frames, windowSeconds: 30);
      expect(stats.frameCount, 1800);
      expect(stats.lateFrames, 3);
      expect(stats.latePercent, closeTo(100.0 * 3 / 1800, 1e-9));
      expect(stats.refreshHz, closeTo(60.0, 0.01));
      expect(stats.requiredFrames, 1800);
    });

    test('a frame spanning exactly the deadline is not late', () {
      final frames = grid(1800);
      // deadline = 1e6 / hz = 16666.0 us exactly at this interval.
      frames[0] = const FrameSlice(
        vsyncStartUs: 0,
        buildStartUs: 0,
        buildFinishUs: 0,
        rasterStartUs: 0,
        rasterFinishUs: 16666, // span == deadline — clean.
      );
      frames[1] = const FrameSlice(
        vsyncStartUs: 16666,
        buildStartUs: 16666,
        buildFinishUs: 16666,
        rasterStartUs: 16666,
        rasterFinishUs: 16666 + 16667, // span 16667 > deadline — late.
      );
      final stats = summarizeScrollWindow(frames: frames, windowSeconds: 30);
      expect(stats.lateFrames, 1);
    });

    test('refuses a ratio from an undersized capture (>= 1800 at 60 Hz)',
        () {
      final frames = grid(1799);
      expect(
        () => summarizeScrollWindow(frames: frames, windowSeconds: 30),
        throwsA(
          isA<InsufficientFramesException>()
              .having((e) => e.captured, 'captured', 1799)
              .having((e) => e.required, 'required', 1800),
        ),
      );
    });

    test('scales the floor with the measured rate (120 Hz -> 3600)', () {
      // 8333 us -> 120.0048 Hz; floor(120.0048 * 30) = 3600.
      expect(
        () => summarizeScrollWindow(frames: grid(3000, 8333), windowSeconds: 30),
        throwsA(
          isA<InsufficientFramesException>().having(
            (e) => e.required,
            'required',
            3600,
          ),
        ),
      );
      final stats = summarizeScrollWindow(
        frames: grid(3600, 8333),
        windowSeconds: 30,
      );
      expect(stats.frameCount, 3600);
    });
  });

  group('firstPaintedFrame', () {
    test('selects the first frame whose build began after acceptance', () {
      const frames = <FrameSlice>[
        // In-flight frame when the listing landed — build began before
        // acceptedAt, so it cannot render the new rows.
        FrameSlice(
          vsyncStartUs: 1000,
          buildStartUs: 1100,
          buildFinishUs: 1500,
          rasterStartUs: 1600,
          rasterFinishUs: 9000,
        ),
        // First frame that can contain the new listing.
        FrameSlice(
          vsyncStartUs: 10000,
          buildStartUs: 10100,
          buildFinishUs: 14000,
          rasterStartUs: 14100,
          rasterFinishUs: 25000,
        ),
      ];
      final painted = firstPaintedFrame(frames, 5000);
      expect(painted, same(frames[1]));
      // Latency anchored on the navigate() issue timestamp.
      expect(painted!.rasterFinishUs - 4000, 21000);
    });

    test('returns null when no frame builds after acceptance', () {
      expect(firstPaintedFrame(grid(3), 1 << 40), isNull);
      expect(firstPaintedFrame(const [], 0), isNull);
    });
  });
}
